import Foundation
import Darwin

public enum DiagnosticOutcome:String,Codable,Sendable {
    case passed="通过",failed="失败",unverified="未验证",cancelled="已取消",timeout="超时",notApplicable="不适用",information="说明",warning="需检查"
}
public struct DiagnosticResult:Identifiable,Sendable,Codable {
    public var id=UUID()
    public var stage:String
    public var outcome:DiagnosticOutcome
    public var status:String {get{outcome.rawValue}set{outcome=DiagnosticOutcome(rawValue:newValue) ?? .unverified}}
    public var detail:String
    public var code:String
    public var checkedAt:Date
    public var milliseconds:Int?
    public init(_ stage:String,_ status:String,_ detail:String,code:String="unclassified",checkedAt:Date=Date(),milliseconds:Int?=nil) {
        self.stage=stage;outcome=DiagnosticOutcome(rawValue:status) ?? .unverified;self.detail=detail;self.code=code;self.checkedAt=checkedAt;self.milliseconds=milliseconds
    }
}
public enum DiagnosticErrorCategory:String,Codable,Sendable {case none,cancellation,timeout,capacity,configuration,network,unverified}
public extension DiagnosticResult {
    var errorCategory:DiagnosticErrorCategory {
        if code=="cancelled" {return .cancellation}
        if code=="timeout" {return .timeout}
        if code=="overloaded" {return .capacity}
        if code=="configurationInvalid" || code=="coreMissing" {return .configuration}
        if outcome == .failed {return .network}
        return outcome == .unverified ? .unverified:.none
    }
    var exportExplanation:String {
        switch errorCategory {
        case .cancellation:return "本次等待已取消；当前代理会话保持运行"
        case .timeout:return "本次等待超过时间预算；底层同步调用可能尚未返回"
        case .capacity:return "两个后台诊断槽位仍被占用，请稍后重试"
        case .configuration:return "本地核心或配置静态校验未通过"
        case .network:return "本阶段检查失败，需结合本机详情核对"
        case .unverified:return "证据不足，未认定网络或端口归属已验证"
        case .none:return outcome == .passed ? "本阶段检查通过":"本阶段不适用或仅提供范围说明"
        }
    }
}
public enum DiagnosticService {
    public static func local(state:AppState,corePath:String,connected:Bool)->[DiagnosticResult] {
        var result=[DiagnosticResult("核心文件",FileManager.default.isExecutableFile(atPath:corePath) ? "通过":"失败","固定版本核心可执行文件检查",code:FileManager.default.isExecutableFile(atPath:corePath) ? "coreExecutable":"coreMissing")]
        do{try PolicyValidator.validate(state);result.append(DiagnosticResult("配置与节点","通过","节点及策略图通过静态校验",code:"configurationValid"))}catch{result.append(DiagnosticResult("配置与节点","失败",Redactor.redact(error.localizedDescription),code:"configurationInvalid"))}
        let fd=socket(AF_INET,SOCK_STREAM,0);if fd>=0 {defer{close(fd)};var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(clamping:state.listenPort).bigEndian;address.sin_addr.s_addr=inet_addr("127.0.0.1");let available=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))==0}};result.append(DiagnosticResult("监听端口",available ? "通过":"未验证",available ? "端口可绑定":"端口已占用，占用者未确认；代理入口需独立探测",code:available ? "bindAvailable":"ownerUnverified"))}
        if fd<0 {result.append(DiagnosticResult("监听端口","未验证","无法创建只读端口检查套接字",code:"socketUnavailable"))}
        result.append(DiagnosticResult("覆盖范围","说明",state.captureMode == .systemProxy ? "系统代理仅覆盖遵循代理设置的应用，不接管全机 UDP/DNS":"TUN 不覆盖优先级更高的 VPN 路由或应用自有加密 DNS"));return result
    }
    public static func dns(_ server:String) async -> DiagnosticResult {
        await DiagnosticWorkPool.dns.run(stage:"节点 DNS") {
            _=try NetworkInspection.addresses(server)
            return [DiagnosticResult("节点 DNS","通过","原系统解析成功",code:"dnsResolved")]
        }.first ?? DiagnosticResult("节点 DNS","未验证","解析未完成",code:"dnsUnavailable")
    }
    public static func https(_ outcome:String)->[DiagnosticResult] {
        let passed=outcome.contains("正常") || outcome.contains("成功") || outcome.contains("HTTP 200");let cert=outcome.lowercased().contains("certificate") || outcome.contains("证书") || outcome.contains("TLS 检测失败") || outcome.contains("-120")
        return [DiagnosticResult("TLS",passed ? "通过":cert ? "失败":"未验证",passed ? "HTTPS 成功包含目标 TLS 握手":cert ? "HTTPS 检测报告证书/TLS 错误":"尚无可将失败独立归因到 TLS 的证据"),DiagnosticResult("HTTPS / 节点转发",passed ? "通过":"失败",Redactor.redact(outcome))]
    }
}
public enum NodeShare {
    public static func link(_ node:Node,credentials:CredentialStore) throws -> String {
        var c=URLComponents();c.scheme=node.kind == .hysteria2 ? "hy2":node.kind == .shadowsocks ? "ss":node.kind.rawValue;c.host=node.server.contains(":") ? "["+node.server+"]":node.server;c.port=node.port;c.fragment=node.name
        let secret=try credentials.get(node.credentialRef)
        c.user=node.kind == .shadowsocks ? Data(((node.parameters["method"] ?? "")+":"+secret).utf8).base64EncodedString():secret
        var parameters=node.parameters;parameters.removeValue(forKey:"method");if node.parameters["obfs"] != nil{parameters["obfs-password"]=try credentials.get(node.credentialRef+".obfs")}
        c.queryItems=parameters.sorted{$0.key<$1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        guard let value=c.string else{throw ProxyError("分享链接无法生成")};_=try NodeParser.parse(value);return value
    }
}
