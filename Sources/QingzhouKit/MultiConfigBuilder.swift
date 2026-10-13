import Foundation
import Security
import Darwin

public struct CoreControlContext:Sendable {
    public var port:Int
    public var secret:String
    public init(port:Int,secret:String){self.port=port;self.secret=secret}
    public static func make() throws -> CoreControlContext {
        let fd=socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else {throw ProxyError("无法创建控制端口")};defer{close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        guard withUnsafePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}})==0 else {throw ProxyError("无法分配控制端口")}
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&length)}})==0 else {throw ProxyError("无法读取控制端口")}
        var bytes=[UInt8](repeating:0,count:32);guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {throw ProxyError("无法生成控制密钥")}
        return CoreControlContext(port:Int(UInt16(bigEndian:address.sin_port)),secret:bytes.map{String(format:"%02x",$0)}.joined())
    }
}
extension ConfigBuilder {
    public static let testURL="https://www.apple.com/library/test/success.html"
    public static func build(state:AppState,credentials:CredentialStore,control:CoreControlContext) throws -> Data {
        guard (1024...65535).contains(state.listenPort),(1024...65535).contains(control.port),state.listenPort != control.port,control.secret.count>=32 else {throw ProxyError("代理或控制端口、密钥无效")}
        try PolicyValidator.validate(state)
        var outbounds:[[String:Any]]=[]
        for node in state.nodes {var outbound=try outbound(node,credentials:credentials);outbound["tag"]=PolicyReference.node(node.id).tag;outbounds.append(outbound)}
        outbounds.append(["type":"direct","tag":"direct"])
        if !state.nodes.isEmpty {outbounds.append(["type":"urltest","tag":"auto","outbounds":state.nodes.map{PolicyReference.node($0.id).tag},"url":testURL,"interval":"5m","tolerance":50,"interrupt_exist_connections":false])}
        for group in state.groups {
            var item:[String:Any]=["type":group.kind == .select ? "selector" : "urltest","tag":PolicyReference.group(group.id).tag,"outbounds":group.members.map(\.tag),"interrupt_exist_connections":false]
            if group.kind == .select {item["default"]=(group.selected ?? group.members[0]).tag} else {item["url"]=testURL;item["interval"]="5m";item["tolerance"]=50}
            outbounds.append(item)
        }
        let options=(!state.nodes.isEmpty ? ["auto"] : [])+state.nodes.map{PolicyReference.node($0.id).tag}+state.groups.map{PolicyReference.group($0.id).tag}+["direct"]
        outbounds.append(["type":"selector","tag":"proxy","outbounds":options,"default":state.activePolicy?.tag ?? (state.mode == .direct ? "direct" : options.first!),"interrupt_exist_connections":false])
        var rules:[[String:Any]]=[["clash_mode":"direct","action":"route","outbound":"direct"],["clash_mode":"global","action":"route","outbound":"proxy"],["ip_is_private":true,"action":"route","outbound":"direct"],["domain":["localhost"],"action":"route","outbound":"direct"]]
        func render(_ rule:RoutingRule,override:PolicyReference?=nil) throws -> [String:Any] {
            try validate(rule)
            let key=rule.kind == .domain ? "domain" : rule.kind == .suffix ? "domain_suffix" : rule.kind == .keyword ? "domain_keyword" : "ip_cidr"
            let target=override ?? rule.target ?? (rule.action == .direct ? .direct : rule.action == .reject ? .reject : .selected)
            var object:[String:Any]=rule.kind == .match ? [:] : [key:[rule.value]]
            if target == .reject {object["action"]="reject"} else {object["action"]="route";object["outbound"]=target.tag}
            return object
        }
        for rule in state.rules {rules.append(try render(rule))}
        for source in state.remoteRules {for rule in source.rules {rules.append(try render(rule,override:source.target))}}
        var final=state.ruleFinal?.tag ?? "proxy"
        if state.ruleFinal == .reject {rules.append(["action":"reject"]);final="proxy"}
        let config:[String:Any]=["log":["level":"info","timestamp":true],"inbounds":[["type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":state.listenPort,"set_system_proxy":false]],"outbounds":outbounds,"route":["rules":rules,"final":final,"default_domain_resolver":"local"],"dns":["servers":[["type":"local","tag":"local"]],"final":"local"],"experimental":["clash_api":["external_controller":"127.0.0.1:\(control.port)","secret":control.secret,"default_mode":state.mode.rawValue,"external_ui":"","access_control_allow_private_network":false,"access_control_allow_origin":["qingzhou://local"]]]]
        return try JSONSerialization.data(withJSONObject:config,options:[.prettyPrinted,.sortedKeys])
    }
}
