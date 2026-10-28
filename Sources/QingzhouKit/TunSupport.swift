import Foundation
import Darwin
import SystemConfiguration

public struct TunRequest:Codable,Sendable {
    public var proxyExceptions:[String]?
    public var proxyProtectedDomains:[String]?
    public var deferToNetworkResume:Bool?
    public var progressUpdates:Bool?
    public var preserveExternal:Bool?
    public var protocolVersion:Int? = 5
    public var systemProxyPort:Int?
    public var httpCompatibilityPort:Int?
    public var operation:String
    public var verifyNetwork:Bool?
    public var state:AppState?
    public var credentials:[String:String]?
    public var control:CoreControlContext?
    public init(operation:String,state:AppState?=nil,credentials:[String:String]?=nil,control:CoreControlContext?=nil,verifyNetwork:Bool=false,httpCompatibilityPort:Int?=nil,systemProxyPort:Int?=nil,preserveExternal:Bool=false){self.preserveExternal=preserveExternal;self.systemProxyPort=systemProxyPort;self.httpCompatibilityPort=httpCompatibilityPort;self.verifyNetwork=verifyNetwork;self.operation=operation;self.state=state;self.credentials=credentials;self.control=control}
}
public struct TunReply: Codable, Sendable {
    public var supportsManagedSystemProxy:Bool?
    public var wakeRecoveryReason:WakeRecoveryReason?
    public var supportsTrustedCorporateDNS:Bool?
    public var supportsWakeRecovery:Bool?
    public var isProgress:Bool?
    public var tunnelInterface:String?
    public var supportsExternalRecovery: Bool?
    public var recoveryPending: Bool?
    public var safeToQuit: Bool?
    public var networkNotReady: Bool?
    public var coreDiagnostics: [String]?
    public var proxyVerified: Bool?
    public var protectionVerified: Bool?
    public var corporateDNSDiagnostics:[CorporateDNSDiagnostic]?
    public var protectionSummary: [String]?
    public var phase: String?
    public var dnsServer: String?
    public var protocolVersion: Int? = 5
    public var ok: Bool
    public var message: String
    public var running: Bool
    public var routesVerified: Bool?
    public var dnsVerified: Bool?
    public var stageTimings: [ConnectionStageTiming]?
    public init(ok: Bool, message: String, coreDiagnostics: [String]? = nil, running: Bool = false,
                routesVerified: Bool? = nil, dnsVerified: Bool? = nil, dnsServer: String? = nil,
                proxyVerified: Bool? = nil, protectionVerified: Bool? = nil, protectionSummary: [String]? = nil,
                phase: String? = nil, networkNotReady: Bool? = nil, stageTimings: [ConnectionStageTiming]? = nil) {
        self.networkNotReady = networkNotReady; self.coreDiagnostics = coreDiagnostics
        self.proxyVerified = proxyVerified; self.protectionVerified = protectionVerified
        self.protectionSummary = protectionSummary; self.phase = phase; self.dnsServer = dnsServer
        self.routesVerified = routesVerified; self.dnsVerified = dnsVerified
        self.ok = ok; self.message = message; self.running = running; self.stageTimings = stageTimings
    }
}

extension TunReply {
    public var networkReconnecting: Bool { phase == "networkReconnecting" || phase == "networkReplan" }
}

public enum HelperPaths {
    public static let directory="/Library/PrivilegedHelperTools/cn.qingzhou.proxy"
    public static let socket=directory+"/control.sock"
    public static let version=BuildVersion.current
}
public enum UnixChannel {
    public static let maximum=4*1024*1024
    private static func wait(_ fd:Int32,event:Int16,deadline:TimeInterval?) throws {
        guard let deadline else{return}
        while true {
            let remaining=deadline-ProcessInfo.processInfo.systemUptime
            guard remaining>0 else {throw ProxyError("辅助服务请求超过总时间预算，已停止等待并要求恢复")}
            var item=pollfd(fd:fd,events:event,revents:0)
            let ready=poll(&item,1,Int32(min(50,max(1,remaining*1000))))
            if ready<0 {if errno==EINTR {continue};throw ProxyError("辅助服务通道等待失败")}
            if item.revents & Int16(POLLHUP|POLLERR|POLLNVAL) != 0 {
                // 已收到最终帧后关闭的一端仍可能同时带有可读数据。
                if event==Int16(POLLIN),item.revents & Int16(POLLIN) != 0 {return}
                throw ProxyError("辅助服务控制通道已中断")
            }
            if ready>0 {return}
        }
    }
    public static func send(_ data:Data,fd:Int32,deadline:TimeInterval?=nil) throws {
        guard data.count<=maximum else{throw ProxyError("控制模型超过 4 MiB")}
        var length=UInt32(data.count).bigEndian;let prefix=Data(bytes:&length,count:4)
        for packet in [prefix,data] {try packet.withUnsafeBytes {buffer in
            var offset=0
            while offset<packet.count {
                try wait(fd,event:Int16(POLLOUT),deadline:deadline)
                let count=Darwin.send(fd,buffer.baseAddress!.advanced(by:offset),packet.count-offset,deadline==nil ? 0:MSG_DONTWAIT)
                if count<0,[EINTR,EAGAIN,EWOULDBLOCK].contains(errno) {continue}
                guard count>0 else{throw ProxyError("辅助服务控制通道已中断")};offset+=count
            }
        }}
    }
    public static func receive(fd:Int32,deadline:TimeInterval?=nil) throws -> Data {
        func read(_ size:Int) throws -> Data {
            var data=Data(count:size)
            try data.withUnsafeMutableBytes {buffer in
                var offset=0
                while offset<size {
                    try wait(fd,event:Int16(POLLIN),deadline:deadline)
                    let count=recv(fd,buffer.baseAddress!.advanced(by:offset),size-offset,deadline==nil ? 0:MSG_DONTWAIT)
                    if count<0,[EINTR,EAGAIN,EWOULDBLOCK].contains(errno) {continue}
                    guard count>0 else{throw ProxyError("辅助服务控制通道已中断")};offset+=count
                }
            }
            return data
        }
        let header=try read(4);let size=header.reduce(0){($0<<8)|Int($1)}
        guard size>0,size<=maximum else{throw ProxyError("控制消息大小无效")};return try read(size)
    }
    public static func address(_ path:String) throws -> sockaddr_un {var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size);let bytes=Array(path.utf8)+[0];guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw ProxyError("控制通道路径过长")};withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)};return address}
}
public struct HelperRequestBusy:Error,LocalizedError,Sendable {
    public init() {}
    public var errorDescription:String? {"辅助服务请求正在处理，未重复提交"}
}
public struct HelperConnectionError:Error,LocalizedError,Sendable {
    public let code:Int32
    public init(code:Int32){self.code=code}
    public var retryable:Bool {[ENOENT,ECONNREFUSED,EACCES].contains(code)}
    public var errorDescription:String? {"辅助服务控制通道连接失败（"+String(code)+"："+String(cString:strerror(code))+"），请检查安装状态和套接字权限"}
}
public enum HelperReadiness {
    // 只重试启动窗口内的连接错误；协议、身份校验和恢复冲突必须立即报告。
    public static func wait(timeout:TimeInterval=5,interval:TimeInterval=0.2,query:() async throws -> TunReply) async throws -> TunReply {
        let deadline=Date().addingTimeInterval(max(0,timeout))
        while true {
            do {return try await query()}
            catch let error as HelperConnectionError where error.retryable {
                let remaining=deadline.timeIntervalSinceNow
                guard remaining>0 else {throw error}
                try await Task.sleep(nanoseconds:UInt64(min(remaining,max(0.001,interval))*1_000_000_000))
            }
        }
    }
}
public actor PrivilegedServiceClient {
    private var channel:HelperRequestChannel?
    private var requestInFlight=false
    public init(){}
    public init(channel:HelperRequestChannel){self.channel=channel}
    private var onStageTimings: (@Sendable ([ConnectionStageTiming]) -> Void)?
    private var onProgress:(@Sendable (String)->Void)?
    public func setProgressObserver(_ observer:(@Sendable (String)->Void)?) {onProgress=observer}
    public func setTimingObserver(_ observer: (@Sendable ([ConnectionStageTiming]) -> Void)?) {onStageTimings=observer}
    public func request(_ request:TunRequest) async throws -> TunReply {
        guard !requestInFlight else {throw HelperRequestBusy()}
        requestInFlight=true;defer{requestInFlight=false}
        if channel==nil {let descriptor=socket(AF_UNIX,SOCK_STREAM,0);guard descriptor>=0 else{throw ProxyError("无法创建辅助服务控制通道")};var option:Int32=1;_ = setsockopt(descriptor,SOL_SOCKET,SO_NOSIGPIPE,&option,socklen_t(MemoryLayout<Int32>.size));var timeout=timeval(tv_sec:60,tv_usec:0);_ = setsockopt(descriptor,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));_ = setsockopt(descriptor,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));var address=try UnixChannel.address(HelperPaths.socket);let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(descriptor,$0,socklen_t(MemoryLayout<sockaddr_un>.size))==0}};guard connected else{let code=errno;close(descriptor);throw HelperConnectionError(code:code)};channel=HelperRequestChannel(descriptor:descriptor)}
        do {
        var outgoing=request
        if ["prepare","activate"].contains(request.operation) {outgoing.progressUpdates=true}
        guard let channel else {throw ProxyError("辅助服务通道未建立")}
        let observer=onProgress
        let reply=try await channel.exchange(JSONEncoder().encode(outgoing),progress:{observer?($0)})
        try Task.checkCancellation()
        guard self.channel === channel else {throw CancellationError()}
        if ["prepare","activate","pinBypasses"].contains(request.operation),reply.protocolVersion != 5 {throw ProxyError("辅助服务协议过旧，请更新后再开启组合接管")}
        if let timings=reply.stageTimings,!timings.isEmpty {onStageTimings?(timings)}
        try reply.validateSuccess();return reply}catch{channel?.cancel();channel=nil;throw error}
    }
    public func closeChannel(){channel?.cancel();channel=nil}
}
public enum NetworkInspection {
    public static func command(_ path:String,_ arguments:[String],deadline:Date?=nil) throws -> String {
        func uptime()->TimeInterval {TimeInterval(DispatchTime.now().uptimeNanoseconds)/1_000_000_000}
        let budget=NetworkCommandBudget(deadline:deadline,uptime:uptime())
        func remaining()->TimeInterval {budget.remaining(wallTime:Date(),uptime:uptime())}
        func timeoutError()->ProxyError {ProxyError("网络命令 "+URL(fileURLWithPath:path).lastPathComponent+(deadline == nil ? " 超过唤醒运行时间预算":" 超过总截止时间"))}
        guard remaining()>0 else {throw timeoutError()}
        let process=Process(),output=Pipe();process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments;process.standardOutput=output;process.standardError=output
        try process.run()
        // 读取管道期间仍由独立计时器终止超时进程，DNS 保护共用上层截止时间。
        let timeout=DispatchWorkItem {if process.isRunning {kill(process.processIdentifier,SIGKILL)}}
        DispatchQueue.global().asyncAfter(deadline:.now()+remaining(),execute:timeout)
        defer{timeout.cancel()}
        let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard remaining()>0 else {throw timeoutError()}
        let text=String(decoding:data,as:UTF8.self)
        guard process.terminationStatus==0 else {throw ProxyError("网络命令 "+URL(fileURLWithPath:path).lastPathComponent+" 失败（退出码 "+String(process.terminationStatus)+"）："+Redactor.redact(String(text.prefix(512))))};return text
    }
    public static func conflicts(vpn:String,routes:String,proxies:[String:Any])->String? {
        let activeVPN=vpn.components(separatedBy:.newlines).contains(where:{$0.contains("(Connected)") || $0.contains("(Connecting)")})
        let rows=routes.components(separatedBy:.newlines).map{$0.split(whereSeparator:{$0.isWhitespace}).map(String.init)}
        if activeVPN && rows.allSatisfy({$0.count<4}) {return "活动 VPN 的路由无法确认，未启用 TUN"}
        // 保留企业 VPN 的具体网段和系统链路本地隧道；只阻止公网接管重叠。
        for row in rows where row.count>=4 {
            guard row.dropFirst(2).contains(where:{$0.hasPrefix("utun") || $0.hasPrefix("ppp") || $0.hasPrefix("ipsec")}) else{continue}
            let destination=row[0],gateway=row[1],flags=row[2]
            if destination.hasPrefix("fe80") || destination.hasPrefix("ff") || destination=="::1" {continue}
            // macOS 为系统隧道保留的接口限定默认项不会接管普通公网连接。
            if destination=="default" {
                if flags.contains("I") && gateway.hasPrefix("fe80:"){continue}
                return "另一个隧道正在接管默认路由，未启用 TUN"
            }
            let parts=destination.split(separator:"/",omittingEmptySubsequences:false)
            if destination.contains(":") {
                if let last=parts.last,let bits=Int(last),bits<=3 {return "另一个隧道正在接管 IPv6 公网大网段，未启用 TUN"}
            } else {
                let octets=parts[0].split(separator:".")
                guard octets.allSatisfy({Int($0).map{(0...255).contains($0)} ?? false}) else{continue}
                let bits=parts.count==2 ? Int(parts[1]):flags.contains("H") ? 32:octets.count*8
                let first=Int(octets[0])
                if let bits,bits<=8,first != 10,first != 127 {return "另一个隧道正在接管 IPv4 公网大网段，未启用 TUN"}
            }
        }
        for key in ["HTTPEnable","HTTPSEnable","SOCKSEnable","ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable"] where (proxies[key] as? NSNumber)?.boolValue==true{return "检测到其他软件或已有系统代理，请先恢复后启用 TUN"};return nil
    }
    public static func routeField(_ label:String,_ text:String)->String? {
        text.components(separatedBy:.newlines).first{$0.trimmingCharacters(in:.whitespaces).hasPrefix(label+":")}.map{$0.components(separatedBy:":").dropFirst().joined(separator:":").trimmingCharacters(in:.whitespaces)}
    }
    // 接口直连路由没有 IP 网关；统一用链路索引表达，写入和恢复均绑定原接口。
    public static func routeGateway(_ text:String,index:(String)->UInt32={if_nametoindex($0)})->String? {
        guard let interface=routeField("interface",text),interface.range(of:"^[a-z][a-z0-9]{0,15}$",options:.regularExpression) != nil,let flags=routeField("flags",text),flags.contains("UP") else {return nil}
        if flags.contains("GATEWAY") {return routeField("gateway",text).flatMap{$0.isEmpty ? nil:$0}}
        let number=index(interface);guard number>0 else{return nil};return "link#"+String(number)
    }
    public static func routePrefix(destination:String?,mask:String?,host:Bool=false)->String? {
        guard let rawDestination=destination else{return nil};
        // 零起点分流路由也可能显示为 default，必须结合掩码区分 /1 和 /0。
        guard rawDestination != "default" || !host else{return nil}
        let destination=rawDestination == "default" ? (mask?.contains(":")==true ? "::":"0.0.0.0"):rawDestination.components(separatedBy:"%")[0]
        var bytes=[UInt8](repeating:0,count:16);let family=destination.withCString{inet_pton(AF_INET,$0,&bytes)==1 ? AF_INET:inet_pton(AF_INET6,$0,&bytes)==1 ? AF_INET6:0};guard family != 0 else{return nil}
        if host{return destination+"/"+(family==AF_INET ? "32":"128")}
        guard let mask,mask.withCString({inet_pton(family,$0,&bytes)})==1 else{return nil};let count=family==AF_INET ? 4:16;var bits=0,zero=false
        for byte in bytes.prefix(count){for i in (0..<8).reversed(){if byte&(1<<i) != 0{if zero{return nil};bits+=1}else{zero=true}}};return destination+"/\(bits)"
    }
    // 全局路由和限定路由可以拥有同一前缀；查询返回另一作用域时不能视为本次所有权。
    public static func routeScopeMatches(_ scope:String?,flags:String?,interface:String?)->Bool {
        guard let flags else{return false}
        if let scope {return flags.contains("IFSCOPE") && interface==scope}
        return !flags.contains("IFSCOPE")
    }
    public enum RouteOperation:String {case get,add,delete}
    // 限定网卡的查询、添加和恢复必须使用相同作用域，避免误处理全局接管路由。
    public static func routeArguments(_ operation:RouteOperation,destination:String,gateway:String?=nil,ipv6:Bool=false,scope:String?=nil,interface:String?=nil)->[String] {
        var args=["-n",operation.rawValue]+(ipv6 ? ["-inet6"]:[])
        if let scope {args += ["-ifscope",scope]}
        let parts=destination.split(separator:"/",omittingEmptySubsequences:false)
        let hostBits=ipv6 ? 128:32
        let isHost=destination != "default" && (parts.count==1 || (parts.count==2 && Int(parts[1])==hostBits))
        // 主机路由必须显式使用主机标志，避免 IPv6 全一掩码被网络模式解释为零前缀。
        if isHost {args += ["-host",String(parts[0])]}
        else {
            if operation != .get {args.append("-net")}
            if ipv6,parts.count==2 {args += [String(parts[0]),"-prefixlen",String(parts[1])]}
            else {args.append(destination)}
        }
        if let gateway {
            if gateway.hasPrefix("link#"),let interface {args += ["-interface",interface]} else {args.append(gateway)}
        }
        return args
    }
    // 使用独立的补充 DNS 服务，避免修改 DHCP 持有的物理服务状态后被系统刷新覆盖。
    public static func tunDNSKey(_ session:UUID)->String {"State:/Network/Service/Qingzhou-TUN-"+session.uuidString+"/DNS"}
    public static func samePrefix(_ a:String,_ b:String)->Bool {let left=a.split(separator:"/"),right=b.split(separator:"/");guard left.count==2,right.count==2,left[1]==right[1] else{return false};return RuleEvaluator.matches(RoutingRule(kind:.cidr,value:a,action:.direct),host:String(right[0]),ip:String(right[0]))==true && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:b,action:.direct),host:String(left[0]),ip:String(left[0]))==true}
    public static func checkConflicts(ownedTunnel:String?=nil,routes suppliedRoutes:String?=nil) throws {let vpn=try command("/usr/sbin/scutil",["--nc","list"]);let rawRoutes=try suppliedRoutes ?? command("/usr/sbin/netstat",["-rn"])
        let routes=rawRoutes.components(separatedBy:.newlines).filter{row in guard let ownedTunnel else{return true};return !row.split(whereSeparator:{$0.isWhitespace}).contains(Substring(ownedTunnel))}.joined(separator:"\n");guard let proxies=SCDynamicStoreCopyProxies(nil) as? [String:Any] else{throw ProxyError("不能可靠判断系统代理状态，未启用 TUN")};if let reason=conflicts(vpn:vpn,routes:routes,proxies:proxies){throw ProxyError(reason)}}
    public static func validatePreparation(interface:String,gateway:String,currentInterface:String?,currentGateway:String?,vpn:String,routes:String,proxies:[String:Any]) throws {
        guard currentInterface==interface,currentGateway==gateway else{throw ProxyError("准备期间默认网络已变化，未接管网络")}
        if let reason=conflicts(vpn:vpn,routes:routes,proxies:proxies){throw ProxyError("准备期间网络接管状态已变化："+reason)}
    }
    public static func boundedAddresses(_ host:String,timeout:TimeInterval=3,resolver:@escaping @Sendable (String) throws -> [String]=NetworkInspection.addresses) throws -> [String] {
        guard timeout>0,timeout<=10 else{throw ProxyError("DNS 等待预算无效")}
        let result=AddressResolutionResult(),completed=DispatchSemaphore(value:0)
        // 解析只读取网络状态；超时后不能继续执行任何接管步骤。
        DispatchQueue.global().async {result.set(Result{try resolver(host)});completed.signal()}
        guard completed.wait(timeout:.now()+timeout) == .success else{throw ProxyError("节点引导 DNS 解析超时，未接管网络")}
        return try result.get().get()
    }
    public static func addresses(_ host:String) throws -> [String] {var head:UnsafeMutablePointer<addrinfo>?;var hints=addrinfo();hints.ai_socktype=SOCK_STREAM;guard getaddrinfo(host,nil,&hints,&head)==0,let first=head else{throw ProxyError("节点或引导 DNS 无法解析，未启用 TUN")};defer{freeaddrinfo(first)};var cursor:UnsafeMutablePointer<addrinfo>?=first;var values=Set<String>();while let item=cursor{var buffer=[CChar](repeating:0,count:Int(NI_MAXHOST));if getnameinfo(item.pointee.ai_addr,item.pointee.ai_addrlen,&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST)==0{values.insert(String(cString:buffer))};cursor=item.pointee.ai_next};guard !values.isEmpty,values.count<=32 else{throw ProxyError("节点 DNS 地址数量无效")};return values.sorted()}
}
public enum TunConfigBuilder {
    public static func build(state:AppState,credentials:CredentialStore,control:CoreControlContext,address4:String,address6:String,originalDNS:[String],bypass:[String],httpCompatibilityPort:Int?=nil,plan:CapturePlan?=nil,dnsForwardPort:Int?=nil,nodeInterfaces:[String:String]=[:]) throws -> Data {
        try JSONSerialization.data(withJSONObject:object(state:state,credentials:credentials,control:control,address4:address4,address6:address6,originalDNS:originalDNS,bypass:bypass,httpCompatibilityPort:httpCompatibilityPort,plan:plan,dnsForwardPort:dnsForwardPort,nodeInterfaces:nodeInterfaces),options:[.sortedKeys])
    }
    public static func object(state:AppState,credentials:CredentialStore,control:CoreControlContext,address4:String,address6:String,originalDNS:[String],bypass:[String],httpCompatibilityPort:Int?=nil,plan:CapturePlan?=nil,dnsForwardPort:Int?=nil,nodeInterfaces:[String:String]=[:]) throws -> [String:Any] {
        try PolicyValidator.validate(state);guard !state.nodes.isEmpty,!originalDNS.isEmpty,originalDNS.count<=16 else{throw ProxyError("TUN 需要节点和可读取的原系统 DNS")}
        for value in [address4,address6]+bypass{try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:value,action:.direct))}
        // 权限服务只接受受限节点模型；利用分享链接往返校验阻止未支持字段进入核心。
        for node in state.nodes{let parsed=try NodeParser.parse(NodeShare.link(node,credentials:credentials));guard parsed.node.fingerprint==node.fingerprint else{throw ProxyError("节点模型参数无效")}}
        var object=try ConfigBuilder.object(state:state,credentials:credentials,control:control,httpCompatibilityPort:httpCompatibilityPort)
        var inbounds=object["inbounds"] as! [[String:Any]]
        // 路由和 DNS 由辅助服务按所有权记录管理，核心不替换现有路由。
        inbounds.append(["type":"tun","tag":"tun-in","address":[address4,address6],"mtu":1500,"stack":"gvisor","auto_route":false,"dns_mode":"disabled"]);object["inbounds"]=inbounds
        var route=object["route"] as! [String:Any];route["auto_detect_interface"]=true;var rules=route["rules"] as! [[String:Any]];rules.insert(["protocol":"dns","action":"hijack-dns"],at:0);rules.insert(["inbound":"tun-in","action":"sniff"],at:0);route["rules"]=rules;object["route"]=route
        for resolver in originalDNS {try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:resolver,action:.direct))}
        NetworkPolicy.apply(&object,state:state,originalDNS:originalDNS)
        if let plan,let dnsForwardPort {CaptureConfiguration.apply(&object,state:state,plan:plan,dnsForwardPort:dnsForwardPort,nodeInterfaces:nodeInterfaces)}
        return object
    }
}

private final class AddressResolutionResult:@unchecked Sendable {
    private let lock=NSLock()
    private var value:Result<[String],Error>?
    func set(_ value:Result<[String],Error>){lock.lock();self.value=value;lock.unlock()}
    func get()->Result<[String],Error>{lock.lock();defer{lock.unlock()};return value ?? .failure(ProxyError("DNS 解析结果缺失"))}
}

extension TunReply {
    public func validateSuccess() throws {
        guard !ok else {return}
        let detail=message+(coreDiagnostics?.suffix(5).map{"\n核心："+$0}.joined() ?? "")
        if networkNotReady == true {throw NetworkEnvironmentNotReady(detail)}
        throw ProxyError(detail)
    }
}
