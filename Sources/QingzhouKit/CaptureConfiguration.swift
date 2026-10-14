import Foundation

public enum CaptureConfiguration {
    public static func apply(_ object:inout [String:Any],state:AppState,plan:CapturePlan,dnsForwardPort:Int,nodeInterfaces:[String:String]=[:]) {
        var dns=object["dns"] as! [String:Any]
        var servers=dns["servers"] as! [[String:Any]]
        servers.removeAll{$0["tag"] as? String == "local"}
        servers.insert(["type":"udp","tag":"local","server":"127.0.0.1","server_port":dnsForwardPort,"bind_interface":"lo0"],at:0)
        dns["servers"]=servers
        var dnsRules=dns["rules"] as! [[String:Any]]
        if !plan.domains.isEmpty {dnsRules.insert(["domain_suffix":plan.domains,"action":"route","server":"local","strategy":""],at:0)}
        dns["rules"]=dnsRules;object["dns"]=dns
        var outbounds=object["outbounds"] as! [[String:Any]]
        for index in outbounds.indices where outbounds[index]["server"] != nil || outbounds[index]["type"] as? String == "direct" {outbounds[index]["bind_interface"]=(outbounds[index]["server"] as? String).flatMap{nodeInterfaces[$0]} ?? plan.snapshot.primaryInterface}
        let interfaces=Set(plan.protectedRoutes.map(\.interface)+plan.snapshot.resolvers.map(\.interface)).sorted()
        for interface in interfaces {outbounds.append(["type":"direct","tag":"protected-"+interface,"bind_interface":interface,"domain_resolver":["server":"local","strategy":""]])}
        object["outbounds"]=outbounds
        var route=object["route"] as! [String:Any];var rules=route["rules"] as! [[String:Any]]
        let leading=rules.filter{["sniff","hijack-dns"].contains($0["action"] as? String ?? "")}
        rules.removeAll{["sniff","hijack-dns"].contains($0["action"] as? String ?? "")}
        var protected:[[String:Any]]=[]
        protected.append(["domain_regex":["^[^.]+$"],"action":"resolve","server":"local","strategy":""])
        // 先解析内网域名，再按目标地址选择原接口；保护规则优先于 IPv6 拒绝和普通分流。
        if !plan.domains.isEmpty {protected.append(["domain_suffix":plan.domains,"action":"resolve","server":"local","strategy":""])}
        for item in plan.protectedRoutes {protected.append(["ip_cidr":[item.destination],"action":"route","outbound":"protected-"+item.interface])}
        if !plan.domains.isEmpty {
            // 不属于已知企业网段的内网结果仍通过原物理出口，不能进入代理节点。
            protected.append(["domain_suffix":plan.domains,"action":"route","outbound":"protected-"+plan.snapshot.primaryInterface])
        }
        protected.append(["ip_cidr":plan.exclusions,"action":"route","outbound":"protected-"+plan.snapshot.primaryInterface])
        route["rules"]=leading+protected+rules;object["route"]=route
    }
}
