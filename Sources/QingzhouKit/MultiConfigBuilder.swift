import Foundation
import Security
import Darwin

public struct CoreControlContext:Codable,Sendable {
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
    public static let secondaryTestURL="https://www.gstatic.com/generate_204"
    public static let testURL="https://www.apple.com/library/test/success.html"
    public static func build(state:AppState,credentials:CredentialStore,control:CoreControlContext,httpCompatibilityPort:Int?=nil) throws -> Data {
        try JSONSerialization.data(withJSONObject:object(state:state,credentials:credentials,control:control,httpCompatibilityPort:httpCompatibilityPort),options:[.prettyPrinted,.sortedKeys])
    }
    public static func object(state:AppState,credentials:CredentialStore,control:CoreControlContext,httpCompatibilityPort:Int?=nil) throws -> [String:Any] {
        guard (1024...65535).contains(state.listenPort),(1024...65535).contains(control.port),state.listenPort != control.port,control.secret.count>=32 else {throw ProxyError("代理或控制端口、密钥无效")}
        try PolicyValidator.validate(state)
        var outbounds:[[String:Any]]=[]
        for node in state.nodes {var outbound=try outbound(node,credentials:credentials);outbound["tag"]=PolicyReference.node(node.id).tag;outbounds.append(outbound)}
        outbounds.append(["type":"direct","tag":"direct"])
        if !state.nodes.isEmpty {outbounds.append(["type":"urltest","tag":"auto","outbounds":state.nodes.map{PolicyReference.node($0.id).tag},"url":testURL,"interval":"5m","tolerance":50,"interrupt_exist_connections":false])}
        for group in state.groups {
            var item:[String:Any]=["type":group.kind != .urltest ? "selector" : "urltest","tag":PolicyReference.group(group.id).tag,"outbounds":group.members.map(\.tag),"interrupt_exist_connections":false]
            if group.kind != .urltest {item["default"]=(group.selected ?? group.members[0]).tag} else {item["url"]=testURL;item["interval"]="5m";item["tolerance"]=50}
            outbounds.append(item)
        }
        let options=(!state.nodes.isEmpty ? ["auto"] : [])+state.nodes.map{PolicyReference.node($0.id).tag}+state.groups.map{PolicyReference.group($0.id).tag}+["direct"]
        outbounds.append(["type":"selector","tag":"proxy","outbounds":options,"default":state.activePolicy?.tag ?? (state.mode == .direct ? "direct" : options.first!),"interrupt_exist_connections":false])
        var rules:[[String:Any]]=[["clash_mode":"global","action":"resolve","strategy":state.effectiveAddressFamilyPolicy.strategy],["clash_mode":"direct","action":"route","outbound":"direct"],["clash_mode":"global","action":"route","outbound":"proxy"],["ip_is_private":true,"action":"route","outbound":"direct"],["domain":["localhost"],"action":"route","outbound":"direct"]]
        func render(_ rule:RoutingRule,override:PolicyReference?=nil) throws -> [String:Any] {
            try validate(rule)
            let key=rule.kind == .domain ? "domain" : rule.kind == .suffix ? "domain_suffix" : rule.kind == .keyword ? "domain_keyword" : "ip_cidr"
            let target=override ?? rule.target ?? (rule.action == .direct ? .direct : rule.action == .reject ? .reject : .selected)
            var object:[String:Any]=try coreCondition(rule,state:state)
            if target == .reject {object["action"]="reject"} else {object["action"]="route";object["outbound"]=target.tag}
            return object
        }
        func append(_ rule:RoutingRule,override:PolicyReference?=nil) throws {
            if [.cidr,.geoip,.asn].contains(rule.kind),rule.noResolve != true {rules.append(["action":"resolve","strategy":state.effectiveAddressFamilyPolicy.strategy])}
            let item=try render(rule,override:override)
            if item["outbound"] as? String != nil,item["outbound"] as? String != "direct",![.cidr,.geoip,.asn].contains(rule.kind) {
                var resolution=try coreCondition(rule,state:state);resolution["action"]="resolve";resolution["strategy"]=state.effectiveAddressFamilyPolicy.strategy;rules.append(resolution)
            }
            rules.append(item)
        }
        for rule in state.rules where rule.kind != .userAgent {try append(rule)}
        for source in state.remoteRules {for rule in source.rules where rule.kind != .userAgent {try append(rule,override:source.target)}}
        try DomesticRouting.appendRules(to:&rules,state:state)
        var final=state.ruleFinal?.tag ?? "proxy"
        if state.ruleFinal == .reject {rules.append(["action":"reject"]);final="proxy"}
        if state.ruleFinal != .direct && state.ruleFinal != .reject {rules.append(["action":"resolve","strategy":state.effectiveAddressFamilyPolicy.strategy])}
        var config:[String:Any]=["log":["level":"info","timestamp":true],"inbounds":[["type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":state.listenPort,"set_system_proxy":false]],"outbounds":outbounds,"route":["rules":rules,"final":final,"default_domain_resolver":"local"],"dns":["servers":[["type":"local","tag":"local"]],"final":"local"],"experimental":["clash_api":["external_controller":"127.0.0.1:\(control.port)","secret":control.secret,"default_mode":state.mode.rawValue,"external_ui":"","access_control_allow_private_network":false,"access_control_allow_origin":["qingzhou://local"]]]]
        if let port=httpCompatibilityPort,let shadow=state.shadowrocket {
            let data=try shadow.gatewayData(listenPort:state.listenPort,corePort:state.listenPort,httpPort:port,control:control,state:state)
            let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let policies=object["policies"] as! [String]
            let users=policies.map{["username":"compat-"+$0.lowercased(),"password":control.secret]}
            var inbounds=config["inbounds"] as! [[String:Any]]
            inbounds.append(["type":"http","tag":"http-compat-in","listen":"127.0.0.1","listen_port":port,"users":users])
            config["inbounds"]=inbounds
            // 隔离且带认证的入站承接 HTTP 兼容层已经按顺序判定的策略。
            let forced=policies.flatMap{policy -> [[String:Any]] in
                let match:[String:Any]=["inbound":["http-compat-in"],"auth_user":["compat-"+policy.lowercased()]]
                var resolve=match;resolve["action"]="resolve";resolve["strategy"]=state.effectiveAddressFamilyPolicy.strategy
                if policy=="DIRECT" {resolve["server"]="local"}
                var route=match;route["action"]="route";route["outbound"]=policy=="DIRECT" ? "direct":policy=="PROXY" ? "proxy":policy
                return [resolve,route]
            }
            var route=config["route"] as! [String:Any];route["rules"]=forced+(route["rules"] as! [[String:Any]]);config["route"]=route
        }
        NetworkPolicy.apply(&config,state:state)
        return config
    }
}
