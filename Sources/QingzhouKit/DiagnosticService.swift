import Foundation
import Darwin

public struct DiagnosticResult:Identifiable,Sendable {
    public let id=UUID();public var stage:String;public var status:String;public var detail:String
    public init(_ stage:String,_ status:String,_ detail:String){self.stage=stage;self.status=status;self.detail=detail}
}
public enum DiagnosticService {
    public static func local(state:AppState,corePath:String,connected:Bool)->[DiagnosticResult] {
        var result=[DiagnosticResult("核心文件",FileManager.default.isExecutableFile(atPath:corePath) ? "通过":"失败","固定版本核心可执行文件检查")]
        do{try PolicyValidator.validate(state);result.append(DiagnosticResult("配置与节点","通过","节点及策略图通过静态校验"))}catch{result.append(DiagnosticResult("配置与节点","失败",Redactor.redact(error.localizedDescription)))}
        let fd=socket(AF_INET,SOCK_STREAM,0);if fd>=0 {defer{close(fd)};var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(clamping:state.listenPort).bigEndian;address.sin_addr.s_addr=inet_addr("127.0.0.1");let available=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))==0}};result.append(DiagnosticResult("监听端口",available || connected ? "通过":"失败",available ? "端口可使用":connected ? "连接中，由运行核心占用":"端口被占用，连接前请修改或释放"))}
        result.append(DiagnosticResult("覆盖范围","说明",state.captureMode == .systemProxy ? "系统代理仅覆盖遵循代理设置的应用，不接管全机 UDP/DNS":"TUN 不覆盖优先级更高的 VPN 路由或应用自有加密 DNS"));return result
    }
    public static func dns(_ server:String) async -> DiagnosticResult {
        await Task.detached {var hints=addrinfo();hints.ai_socktype=SOCK_STREAM;var head:UnsafeMutablePointer<addrinfo>?;let status=getaddrinfo(server,nil,&hints,&head);if let head{freeaddrinfo(head)};return DiagnosticResult("节点 DNS",status==0 ? "通过":"失败",status==0 ? "原系统解析成功":"原系统无法解析节点服务器")}.value
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
