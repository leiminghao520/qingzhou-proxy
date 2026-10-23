import Foundation
import Network
import Security
import SystemConfiguration

public struct TargetPathEvidence:Sendable {
    public var rows:[DiagnosticResult]
    public var addresses:[String]
    public var corporate:Bool
    public init(rows:[DiagnosticResult],addresses:[String],corporate:Bool) {self.rows=rows;self.addresses=addresses;self.corporate=corporate}
}

public enum TargetPathService {
    // 先判定原 DNS 作用域，再解析目标；企业域名不能先走通用 getaddrinfo。
    public static func inspect(_ target:SavedDiagnosticTarget,state:AppState,active:Bool,tunnel:String?,cancelled:@escaping ()->Bool) throws -> TargetPathEvidence {
        let target=try target.validated(),host=target.host
        let expected=try RuleEvaluator.explain(host,state:state)
        let explanation=DiagnosticResult("配置预期","说明",(expected.steps+["预期策略："+state.label(expected.target),"收藏目标期望："+target.expectedPath.label]+(expected.uncertainty.map{[$0]} ?? [])).joined(separator:"\n"),code:"ruleSimulation")
        var addresses:[String]=[],dnsRows:[DiagnosticResult]=[],corporate=false
        do {
        if SavedDiagnosticTarget.isIP(host) {addresses=[host]}
        else {
            guard let store=SCDynamicStoreCreate(nil,"轻舟收藏目标只读诊断" as CFString,nil,nil),let global=SCDynamicStoreCopyValue(store,"State:/Network/Global/IPv4" as CFString) as? [String:Any],let primary=global["PrimaryInterface"] as? String else {throw ProxyError("无法确认原网络 DNS 作用域")}
            let backend=NativeRouteBackend();backend.cancelled=cancelled
            let sample=try backend.snapshot()
            let keys=SCDynamicStoreCopyKeyList(store,"State:/Network/Service/Qingzhou-.*/DNS" as CFString) as? [String] ?? []
            let snapshot=try NetworkSnapshot.read(store:store,primary:primary,routes:sample.table,ownedDNSKeys:Set(keys),ownedTunnel:tunnel,structuredRoutes:sample.planningRoutes,lookup:{try backend.lookup($0,ipv6:$1).queryText})
            let plan=try CapturePlan.make(snapshot:snapshot,state:state)
            corporate=plan.protects(host)
            if corporate {
                let relay=try ScopedDNSForwarder(plan:plan,protectAnswers:{name,answers,resolver,_ in
                    for address in answers {
                        let expected=try plan.domainRoute(address:address,resolver:resolver,host:name)
                        let route=try backend.lookup(address,ipv6:address.contains(":")).route
                        guard route.interface==expected.interface,route.gateway==expected.gateway else {throw ProxyError("企业 DNS 答案当前出口未核验")}
                    }
                });defer{relay.stop()}
                for type:UInt16 in [1,28] {
                    guard !cancelled() else {throw CancellationError()}
                    _=relay.resolve(DNSPacket.query(host,type:type),name:host,budget:1)
                }
                dnsRows=relay.diagnosticResults.map(\.result)
                addresses=Array(Set(relay.diagnosticResults.flatMap(\.addresses))).sorted()
                if addresses.isEmpty || dnsRows.contains(where:{$0.outcome == .failed}) {
                    return TargetPathEvidence(rows:[explanation]+dnsRows+[DiagnosticResult("系统实际路径","失败","企业解析器或答案出口未通过，未使用公共 DNS 或建立业务连接",code:"corporateDNS.answerProtectionFailed")],addresses:[],corporate:true)
                }
            } else {
                addresses=try NetworkInspection.addresses(host)
                dnsRows=[DiagnosticResult("DNS","通过","系统作用域解析已完成",code:"dnsAnswered")]
            }
        }
        guard !cancelled() else {throw CancellationError()}
        let actual=try BypassDiagnostics.inspect(host,state:state,active:active,ownedTunnel:tunnel,cancelled:cancelled,resolve:{_ in addresses},inspectEnterpriseDNS:false)
        var mismatch=actual.hasFailure
        if expected.uncertainty==nil,active {
            if target.expectedPath == .direct,expected.target != .direct {mismatch=true}
            if target.expectedPath == .proxy,expected.target == .direct || expected.target == .reject {mismatch=true}
        }
        if target.expectedPath == .proxy,state.captureMode.usesTunnel,active {
            if let tunnel {
                let backend=NativeRouteBackend();backend.cancelled=cancelled
                for address in addresses.prefix(16) {
                    if try backend.lookup(address,ipv6:address.contains(":")).route.interface != tunnel {mismatch=true}
                }
            }else {mismatch=true}
        }
        let rows=dnsRows+[
            explanation,
            DiagnosticResult("系统实际路径",mismatch ? "失败":"未验证",actual.rows.joined(separator:"\n")+"\n系统路由不能证明代理最终出口或业务登录成功。",code:mismatch ? "pathMismatch":"businessUnverified")]
        return TargetPathEvidence(rows:rows,addresses:addresses,corporate:corporate)
        } catch {
            if cancelled() || error is CancellationError {throw CancellationError()}
            return TargetPathEvidence(rows:[explanation]+dnsRows+[DiagnosticResult("系统实际路径","未验证","无法确认本轮原网络解析或路由信息；未继续业务连接："+Redactor.redact(error.localizedDescription),code:"pathInspectionUnavailable")],addresses:[],corporate:corporate)
        }
    }
}

private actor TargetProbeSlots {
    static let shared=TargetProbeSlots()
    private var active=0
    func acquire()->Bool {guard active<2 else{return false};active+=1;return true}
    func release() {active-=1}
}

public enum TargetConnectionProbe {
    public static func run(_ rawTarget:SavedDiagnosticTarget,evidence:TargetPathEvidence,state:AppState,connected:Bool) async -> DiagnosticResult {
        let target:SavedDiagnosticTarget
        do {target=try rawTarget.validated()}catch{return DiagnosticResult("测试连接","失败","目标配置无效",code:"configurationInvalid")}
        guard connected else {return DiagnosticResult("测试连接","未验证","当前未连接，未自动连接或回退直连",code:"notConnected")}
        guard !evidence.addresses.isEmpty,!evidence.rows.contains(where:{$0.outcome == .failed}) else {return DiagnosticResult("测试连接","未验证","路径检查未通过，未建立业务连接",code:"pathUnverified")}
        guard await TargetProbeSlots.shared.acquire() else {return DiagnosticResult("测试连接","未验证","已有两项连接测试，请稍后重试",code:"overloaded")}
        let began=Date()
        let result:DiagnosticResult
        do {
            try Task.checkCancellation()
            let rule=try RuleEvaluator.explain(target.host,state:state)
            if rule.target == .reject {throw ProxyError("当前规则拒绝目标连接")}
            if target.expectedPath == .proxy,rule.target == .direct {throw ProxyError("目标预期代理，但当前规则要求直连，未建立连接")}
            if target.expectedPath == .direct,rule.uncertainty==nil,rule.target != .direct {throw ProxyError("目标预期直连，但当前规则不同，未建立连接")}
            let viaProxy = !state.captureMode.usesTunnel && rule.target != .direct && target.expectedPath != .system
            if viaProxy && evidence.corporate {throw ProxyError("企业目标不能通过未验证的代理解析路径测试")}
            guard let address=evidence.addresses.first else {throw ProxyError("目标地址未取得")}
            try await TargetSocketProbe(target:target,address:address,proxyPort:viaProxy ? state.listenPort:nil).run()
            result=DiagnosticResult("测试连接","通过",target.test.label+" 网络检查完成，不代表应用登录成功",code:"targetConnectionPassed",milliseconds:Int(Date().timeIntervalSince(began)*1000))
        } catch {
            result=DiagnosticResult("测试连接",error is CancellationError ? "已取消":"失败",error is CancellationError ? "本次检查已取消":Redactor.redact(error.localizedDescription),code:error is CancellationError ? "cancelled":"targetConnectionFailed",milliseconds:Int(Date().timeIntervalSince(began)*1000))
        }
        await TargetProbeSlots.shared.release()
        return result
    }
}

// 连接已核验的数值地址，TLS 仍按原域名校验证书；取消立即关闭本次独立连接。
private final class TargetSocketProbe:@unchecked Sendable {
    private let connection:NWConnection
    private let target:SavedDiagnosticTarget
    private let lock=NSLock()
    private var continuation:CheckedContinuation<Void,Error>?
    private var completed:Result<Void,Error>?
    private let queue=DispatchQueue(label:"cn.qingzhou.target-probe",qos:.utility)
    init(target:SavedDiagnosticTarget,address:String,proxyPort:Int?=nil) throws {
        self.target=target
        let parameters:NWParameters
        if target.test == .tcp {parameters = .tcp}
        else {
            let tls=NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions,target.host)
            parameters=NWParameters(tls:tls,tcp:NWProtocolTCP.Options())
        }
        if let proxyPort {
            guard (1...65535).contains(proxyPort) else {throw ProxyError("本地代理端口无效")}
            var proxy=ProxyConfiguration(socksv5Proxy:.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(proxyPort))!))
            proxy.allowFailover=false
            let context=NWParameters.PrivacyContext(description:"轻舟目标独立代理探测")
            context.disableLogging();context.proxyConfigurations=[proxy];parameters.setPrivacyContext(context)
        }
        // 代理保留域名供核心匹配规则；直连使用已核验地址，禁止代理故障后回退直连。
        connection=NWConnection(host:NWEndpoint.Host(proxyPort==nil ? address:target.host),port:NWEndpoint.Port(rawValue:UInt16(target.effectivePort))!,using:parameters)
    }
    func run() async throws {
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {continuation in
                lock.lock()
                if let completed {lock.unlock();continuation.resume(with:completed);return}
                self.continuation=continuation;lock.unlock()
                connection.stateUpdateHandler={ [weak self] state in
                    guard let self else{return}
                    switch state {
                    case .ready:
                        if self.target.test == .https {self.request()}else{self.finish(.success(()))}
                    case .failed: self.finish(.failure(ProxyError("目标连接或 TLS 握手失败")))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default:break
                    }
                }
                connection.start(queue:queue)
                queue.asyncAfter(deadline:.now()+10) { [weak self] in self?.finish(.failure(ProxyError("目标连接超时"))) }
            }
        },onCancel:{self.finish(.failure(CancellationError()))})
    }
    private func request() {
        let authority=target.host.contains(":") ? "["+target.host+"]":target.host
        let request="HEAD / HTTP/1.1\r\nHost: \(authority):\(target.effectivePort)\r\nConnection: close\r\n\r\n"
        connection.send(content:Data(request.utf8),completion:.contentProcessed{[weak self] error in
            guard let self else{return}
            if error != nil {self.finish(.failure(ProxyError("HTTPS 请求发送失败")));return}
            self.receive(Data())
        })
    }
    private func receive(_ previous:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] data,_,done,error in
            guard let self else{return};var buffer=previous;if let data {buffer.append(data)}
            if let line=String(data:buffer,encoding:.utf8)?.components(separatedBy:"\r\n").first,line.contains("\n")==false,buffer.range(of:Data("\r\n".utf8)) != nil {
                let fields=line.split(separator:" ")
                if fields.count>=2,fields[0].hasPrefix("HTTP/1."),let code=Int(fields[1]),(100...599).contains(code) {self.finish(.success(()));return}
                self.finish(.failure(ProxyError("目标没有返回有效 HTTP 状态")));return
            }
            if done || error != nil || buffer.count>=16384 {self.finish(.failure(ProxyError("目标未返回有效 HTTP 响应")))}else{self.receive(buffer)}
        }
    }
    private func finish(_ result:Result<Void,Error>) {
        lock.lock();guard completed==nil else{lock.unlock();return};completed=result;let continuation=self.continuation;self.continuation=nil;lock.unlock()
        connection.cancel();continuation?.resume(with:result)
    }
}
