import Foundation

public enum RemoteRulesParser {
    public static func clashCondition(_ kind:String,_ value:String) throws -> RoutingRule {
        let k:RuleKind
        switch kind.uppercased() {case "DOMAIN":k = .domain;case "DOMAIN-SUFFIX":k = .suffix;case "DOMAIN-KEYWORD":k = .keyword;case "IP-CIDR","IP-CIDR6":k = .cidr;default:throw ProxyError("规则类型暂不支持")}
        let rule=RoutingRule(kind:k,value:value,action:.proxy);try ConfigBuilder.validate(rule);return rule
    }
    public static func parse(_ text:String) throws -> [RoutingRule] {
        guard text.utf8.count<=2*1024*1024 else {throw ProxyError("规则文件超过 2 MiB")}
        let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines)
        var result:[RoutingRule]=[]
        func append(_ rule:RoutingRule) throws {guard result.count<50000 else {throw ProxyError("规则超过 50000 条")};try ConfigBuilder.validate(rule);result.append(rule)}
        if trimmed.hasPrefix("{") {
            let object:Any;do {object=try JSONSerialization.jsonObject(with:Data(trimmed.utf8))} catch {throw ProxyError("规则 JSON 格式无效")}
            guard let root=object as? [String:Any],let rules=root["rules"] as? [[String:Any]],Set(root.keys).isSubset(of:["version","rules"]),let version=root["version"] as? Int,(1...3).contains(version) else {throw ProxyError("规则集 JSON 版本或结构不支持")}
            let keys:[String:RuleKind]=["domain":.domain,"domain_suffix":.suffix,"domain_keyword":.keyword,"ip_cidr":.cidr]
            for entry in rules {guard entry.count==1,let pair=entry.first,let kind=keys[pair.key] else {throw ProxyError("规则集仅支持独立域名/IP条件，不支持组合或其他条件")};let values=(pair.value as? [String]) ?? (pair.value as? String).map{[$0]};guard let values else {throw ProxyError("规则集字段格式不支持")};for value in values {try append(RoutingRule(kind:kind,value:value,action:.proxy))}}
        } else {
            let lines:[String]
            if trimmed.hasPrefix("payload:") || trimmed.hasPrefix("---") {guard let root=try ProfileImporter.yaml(trimmed) as? [String:Any],let payload=root["payload"] as? [String],Set(root.keys)==Set(["payload"]) else {throw ProxyError("仅支持 payload 字符串列表")};lines=payload}
            else {lines=trimmed.components(separatedBy:.newlines)}
            for line in lines {let row=line.trimmingCharacters(in:.whitespacesAndNewlines);if row.isEmpty || row.hasPrefix("#"){continue}
                if row.contains(",") {let parts=row.components(separatedBy:",").map{$0.trimmingCharacters(in:.whitespaces)};guard (2...4).contains(parts.count),parts.count != 4 || parts[3]=="no-resolve" else {throw ProxyError("规则文本格式无效")};if parts[0].uppercased()=="MATCH" {guard parts.count==2,!parts[1].isEmpty else {throw ProxyError("MATCH 格式无效")};try append(RoutingRule(kind:.match,value:"",action:.proxy))}else{try append(clashCondition(parts[0],parts[1]))}}
                else if row.hasPrefix("+.") || row.hasPrefix(".") {try append(RoutingRule(kind:.suffix,value:row.hasPrefix("+.") ? String(row.dropFirst(2)) : String(row.dropFirst()),action:.proxy))}
                else if (try? ConfigBuilder.validate(RoutingRule(kind:.cidr,value:row,action:.proxy))) != nil {try append(RoutingRule(kind:.cidr,value:row,action:.proxy))}
                else {try append(RoutingRule(kind:.domain,value:row,action:.proxy))}
            }
        }
        guard !result.isEmpty else {throw ProxyError("规则源没有有效规则")};return result
    }
}
