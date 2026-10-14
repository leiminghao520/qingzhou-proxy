import Foundation

public enum AddressFamilyPolicy:String,Codable,CaseIterable,Sendable {
    case ipv4Only,preferIPv4,dualStack
    public var label:String {switch self {case .ipv4Only:return "仅 IPv4（推荐）";case .preferIPv4:return "优先 IPv4";case .dualStack:return "IPv4 / IPv6 双栈"}}
    public var strategy:String {switch self {case .ipv4Only:return "ipv4_only";case .preferIPv4:return "prefer_ipv4";case .dualStack:return ""}}
}
public enum NetworkPolicy {
    // 节点引导始终走本地解析；目的域名按分流规则使用本地或代理 DNS。
    public static func apply(_ object:inout [String:Any],state:AppState,originalDNS:[String]?=nil) {
        let family=state.effectiveAddressFamilyPolicy
        var local:[String:Any]=["type":"local","tag":"local"]
        if let resolver=originalDNS?.first {local=["type":"udp","tag":"local","server":resolver]}
        let remote:[String:Any]=["type":"https","tag":"remote","server":"1.1.1.1","path":"/dns-query","tls":["enabled":true,"server_name":"cloudflare-dns.com"],"detour":"proxy"]
        var dnsRules:[[String:Any]]=[["clash_mode":"direct","action":"route","server":"local"],["domain":["localhost"]+state.nodes.map(\.server),"action":"route","server":"local"]]
        let rows=state.rules.map{($0,nil as PolicyReference?)}+state.remoteRules.flatMap{source in source.rules.map{($0,source.target as PolicyReference?)}}
        if state.mode == .rule {for (rule,override) in rows where [.domain,.suffix,.keyword].contains(rule.kind) {
            let target=override ?? rule.target ?? (rule.action == .direct ? .direct:rule.action == .reject ? .reject:.selected)
            var condition=RuleEvaluator.condition(rule)
            if target == .reject {condition["action"]="reject"} else {condition["action"]="route";condition["server"]=target == .direct || state.dnsPreference == .system ? "local":"remote"}
            dnsRules.append(condition)
        }}
        let useRemote=state.mode != .direct && state.dnsPreference == .httpsProxy
        object["dns"]=["servers":[local,remote],"rules":dnsRules,"final":useRemote ? "remote":"local","strategy":family.strategy,"reverse_mapping":true]
        var route=object["route"] as! [String:Any]
        var rules=route["rules"] as! [[String:Any]]
        // DNS 和嗅探必须先执行；IPv6 字面地址在 IPv4 模式下明确拒绝，不能直连泄漏。
        let leading=rules.filter{["sniff","hijack-dns"].contains($0["action"] as? String ?? "")}
        rules.removeAll{["sniff","hijack-dns","resolve"].contains($0["action"] as? String ?? "") || ($0["ip_version"] as? Int == 6 && $0["action"] as? String == "reject")}
        var prefix:[[String:Any]]=[]
        if family == .ipv4Only {prefix.append(["ip_version":6,"action":"reject"])}
        prefix.append(["inbound":["http-compat-in"],"auth_user":["compat-direct"],"action":"resolve","server":"local","strategy":family.strategy])
        prefix.append(["action":"resolve","strategy":family.strategy])
        route["rules"]=leading+prefix+rules
        route["default_domain_resolver"]=["server":"local","strategy":family.strategy]
        object["route"]=route
        var outbounds=object["outbounds"] as! [[String:Any]]
        for index in outbounds.indices where outbounds[index]["server"] != nil || outbounds[index]["type"] as? String == "direct" {
            outbounds[index]["domain_resolver"]=["server":"local","strategy":family.strategy]
        }
        object["outbounds"]=outbounds
    }
}
