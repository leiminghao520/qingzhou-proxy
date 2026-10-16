import Foundation

public struct ShadowrocketRule:Codable,Sendable {
    public var kind:String
    public var value:String
    public var policy:String
    public var noResolve:Bool
}
public struct ShadowrocketRewrite:Codable,Sendable {
    public var pattern:String
    public var replacement:String
    public var status:Int
}
public struct ShadowrocketConfiguration:Codable,Sendable {
    public var version:Int
    public var name:String
    public var sourceFile:String
    public var sourceMode:String
    public var general:[String:String]
    public var hosts:[String:String]
    public var rules:[ShadowrocketRule]
    public var rewrites:[ShadowrocketRewrite]
    public var assets:[String:[String]]
    public var assetHashes:[String:String]

    public func validate() throws {
        guard version==1,sourceMode=="Config",!rules.isEmpty,rules.count<=50000 else {throw ProxyError("Shadowrocket 配置版本、模式或规则数量不支持")}
        let supported:Set<String>=["DOMAIN","DOMAIN-SUFFIX","DOMAIN-KEYWORD","IP-CIDR","IP-CIDR6","GEOIP","IP-ASN","USER-AGENT","FINAL"]
        for rule in rules {
            guard supported.contains(rule.kind),["DIRECT","PROXY","REJECT"].contains(rule.policy) else {throw ProxyError("Shadowrocket 存在不支持的规则或策略")}
            if ["GEOIP","IP-ASN"].contains(rule.kind) {
                guard let entries=assets[rule.kind+":"+rule.value],!entries.isEmpty,entries.count<=50000 else {throw ProxyError("Shadowrocket 地理或 ASN 规则资产缺失")}
                for entry in entries {try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:entry,action:.direct))}
            } else if rule.kind=="USER-AGENT" {
                guard !rule.value.isEmpty,rule.value.utf8.count<=512,!rule.value.contains(where:{$0.isNewline}) else {throw ProxyError("User-Agent 规则无效")}
            } else if rule.kind != "FINAL" {_ = try routing(rule)}
        }
        guard rules.last?.kind=="FINAL",rules.filter({$0.kind=="FINAL"}).count==1 else {throw ProxyError("Shadowrocket FINAL 必须位于规则末尾且唯一")}
        for rewrite in rewrites {guard [301,302,307,308].contains(rewrite.status),rewrite.replacement.hasPrefix("https://") || rewrite.replacement.hasPrefix("http://") else {throw ProxyError("URL 重写只接受 HTTP 重定向")};_ = try NSRegularExpression(pattern:rewrite.pattern)}
        guard hosts.allSatisfy({$0.key=="localhost" && $0.value=="127.0.0.1"}) else {throw ProxyError("当前兼容层只接受本机 localhost Host 设置")}
    }
    private func routing(_ rule:ShadowrocketRule,value:String?=nil) throws -> RoutingRule {
        let kind:RuleKind
        switch rule.kind {case "DOMAIN":kind = .domain;case "DOMAIN-SUFFIX":kind = .suffix;case "DOMAIN-KEYWORD":kind = .keyword;case "IP-CIDR","IP-CIDR6":kind = .cidr;case "GEOIP":kind = .geoip;case "IP-ASN":kind = .asn;case "USER-AGENT":kind = .userAgent;default:throw ProxyError("规则不能转换为核心条件")}
        let action:RuleAction=rule.policy=="DIRECT" ? .direct:rule.policy=="REJECT" ? .reject:.proxy
        var result=RoutingRule(kind:kind,value:value ?? rule.value,action:action)
        result.noResolve=rule.noResolve
        try ConfigBuilder.validate(result);return result
    }
    public var requiresHTTPCompatibility:Bool {rules.contains{$0.kind=="USER-AGENT"} || !rewrites.isEmpty}
    public func applying(to existing:AppState) throws -> AppState {
        try validate()
        var next=existing
        var converted:[RoutingRule]=[]
        // skip-proxy 在系统代理兼容层和核心规则中都优先直连。
        for entry in (general["skip-proxy"] ?? "").components(separatedBy:",").map({$0.trimmingCharacters(in:.whitespaces)}).filter({!$0.isEmpty}) {
            let kind:RuleKind=entry.contains("/") ? .cidr:entry.hasPrefix("*.") ? .suffix:.domain
            let rule=RoutingRule(kind:kind,value:entry.hasPrefix("*.") ? String(entry.dropFirst(2)):entry,action:.direct)
            try ConfigBuilder.validate(rule);converted.append(rule)
        }
        for rule in rules {
            switch rule.kind {
            case "FINAL":next.ruleFinal=rule.policy=="DIRECT" ? .direct:rule.policy=="REJECT" ? .reject:.selected
            default:converted.append(try routing(rule))
            }
        }
        next.rules=converted;next.remoteRules=[];next.mode = .rule;next.dnsPreference = .system;next.captureMode = .systemProxy
        next.tunExcludedCIDRs=(general["tun-excluded-routes"] ?? "").components(separatedBy:",").map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}
        next.addressFamilyPolicy = existing.addressFamilyPolicy ?? (general["ipv6"]?.lowercased()=="false" ? .ipv4Only:general["prefer-ipv6"]?.lowercased()=="true" ? .dualStack:.preferIPv4)
        next.shadowrocket=self
        try PolicyValidator.validate(next)
        return next
    }
    public static func bundled() throws -> ShadowrocketConfiguration? {
        guard let directory=Bundle.main.resourceURL else{return nil}
        let url=directory.appendingPathComponent("shadowrocket-default.json")
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        let result=try JSONDecoder().decode(Self.self,from:Data(contentsOf:url));try result.validate();return result
    }
    public func gatewayData(listenPort:Int,corePort:Int,httpPort:Int,control:CoreControlContext,state:AppState) throws -> Data {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(self)) as! [String:Any]
        object["addressFamilyPolicy"]=state.effectiveAddressFamilyPolicy.rawValue;object["dnsPreference"]=state.dnsPreference.rawValue
        object["listenPort"]=listenPort;object["corePort"]=corePort;object["httpPort"]=httpPort;object["controlPort"]=control.port;object["secret"]=control.secret;object["mode"]=state.mode.rawValue
        func policy(_ target:PolicyReference) -> String {target == .direct ? "DIRECT":target == .reject ? "REJECT":target == .selected ? "PROXY":target.tag}
        let kinds:[RuleKind:String]=[.domain:"DOMAIN",.suffix:"DOMAIN-SUFFIX",.keyword:"DOMAIN-KEYWORD",.cidr:"IP-CIDR",.geoip:"GEOIP",.asn:"IP-ASN",.userAgent:"USER-AGENT",.match:"FINAL"]
        var rows:[[String:Any]]=state.rules.map{rule in ["kind":kinds[rule.kind]!,"value":rule.value,"policy":policy(rule.target ?? (rule.action == .direct ? .direct:rule.action == .reject ? .reject:.selected)),"noResolve":rule.noResolve ?? false]}
        for source in state.remoteRules {rows += source.rules.map{rule in ["kind":kinds[rule.kind]!,"value":rule.value,"policy":policy(source.target),"noResolve":rule.noResolve ?? false]}}
        // MATCH 是终止规则，后续远程源不得让兼容入口的 FINAL 校验失败。
        if let index=rows.firstIndex(where:{$0["kind"] as? String=="FINAL"}) {rows=Array(rows.prefix(index+1))}
        if !rows.contains(where:{$0["kind"] as? String=="FINAL"}) {
            if state.captureMode == .compatible {
                try DomesticRouting.validate()
                // 兼容层仅补充明文规则，国内兜底与核心保持同一份固定数据和优先级。
                let kinds=["domain":"DOMAIN","domain_suffix":"DOMAIN-SUFFIX","domain_regex":"DOMAIN-REGEX"]
                for key in ["domain","domain_suffix","domain_regex"] {
                    for value in DomesticRouting.domainCondition[key] as? [String] ?? [] {rows.append(["kind":kinds[key]!,"value":value,"policy":"DIRECT","noResolve":false])}
                }
                rows.append(["kind":"GEOIP","value":"QINGZHOU-CN","policy":"DIRECT","noResolve":false])
                var assets=object["assets"] as? [String:[String]] ?? [:];assets["GEOIP:QINGZHOU-CN"]=DomesticRouting.cidrs;object["assets"]=assets
            }
            rows.append(["kind":"FINAL","value":"","policy":policy(state.ruleFinal ?? .selected),"noResolve":false])
        }
        object["rules"]=rows
        object["policies"]=Array(Set(rows.compactMap{$0["policy"] as? String}.filter{$0 != "REJECT"}).union(["DIRECT","PROXY"]))
        return try JSONSerialization.data(withJSONObject:object)
    }
}
