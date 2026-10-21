import Foundation

public struct RuleTextIssue: Error, Sendable, Identifiable {
    public var id:Int {line}
    public let line:Int
    public let message:String
}
public struct RuleTextResult: Sendable {
    public var rules:[RoutingRule]
    public var issues:[RuleTextIssue]
    public init(rules:[RoutingRule],issues:[RuleTextIssue]) {self.rules=rules;self.issues=issues}
}

// 编辑器保留每条规则的动作；不能使用会覆盖目标策略的远程规则解析器。
public enum RuleTextCodec {
    public static let kinds=["DOMAIN","DOMAIN-SUFFIX","DOMAIN-KEYWORD","IP-CIDR","IP-CIDR6","MATCH"]
    public static func targetName(_ target:PolicyReference)->String {
        switch target {case .selected:return "PROXY";case .direct:return "DIRECT";case .reject:return "REJECT";case .automatic:return "AUTO";default:return target.tag}
    }
    public static func target(_ name:String,state:AppState) throws -> PolicyReference {
        switch name.uppercased() {case "PROXY":return .selected;case "DIRECT":return .direct;case "REJECT":return .reject;case "AUTO":return .automatic;default:break}
        var matches:[PolicyReference]=[]
        for node in state.nodes where name==PolicyReference.node(node.id).tag || name==node.name {matches.append(.node(node.id))}
        for group in state.groups where name==PolicyReference.group(group.id).tag || name==group.name {matches.append(.group(group.id))}
        guard matches.count==1 else {throw ProxyError(matches.isEmpty ? "目标策略不存在":"目标名称有歧义，请使用补全中的唯一标识")}
        return matches[0]
    }
    public static func encode(_ rules:[RoutingRule]) throws -> String {
        try rules.map {rule in
            let kind:String
            switch rule.kind {case .domain:kind="DOMAIN";case .suffix:kind="DOMAIN-SUFFIX";case .keyword:kind="DOMAIN-KEYWORD";case .cidr:kind=rule.value.contains(":") ? "IP-CIDR6":"IP-CIDR";case .match:kind="MATCH";default:throw ProxyError("存在 GEOIP、ASN 或 User-Agent 规则，请继续使用结构化编辑，避免丢失内容")}
            guard !rule.value.contains(","),!rule.value.contains(where:{$0.isNewline}),rule.noResolve != true || rule.kind == .cidr else {throw ProxyError("该规则无法无损转换为文本，请继续使用结构化编辑")}
            let target=targetName(rule.target ?? (rule.action == .direct ? .direct:rule.action == .reject ? .reject:.selected))
            return (rule.kind == .match ? [kind,target]:[kind,rule.value,target]).joined(separator:",")+(rule.noResolve==true ? ",no-resolve":"")
        }.joined(separator:"\n")
    }
    public static func parse(_ text:String,state:AppState,previous:[RoutingRule]=[]) -> RuleTextResult {
        guard text.utf8.count<=2*1024*1024 else {return RuleTextResult(rules:[],issues:[RuleTextIssue(line:1,message:"规则文本超过2 MiB")])}
        var result=RuleTextResult(rules:[],issues:[])
        var unchanged:[String:[RoutingRule]]=[:]
        for rule in previous {if let key=try? encode([rule]) {unchanged[key,default:[]].append(rule)}}
        for (offset,line) in text.components(separatedBy:.newlines).enumerated() {
            let value=line.trimmingCharacters(in:.whitespacesAndNewlines)
            if value.isEmpty || value.hasPrefix("#") {continue}
            do {
                guard result.rules.count<50000 else {throw ProxyError("规则超过50000条")}
                var parts=value.components(separatedBy:",").map{$0.trimmingCharacters(in:.whitespaces)}
                let noResolve=parts.last=="no-resolve"
                if noResolve {parts.removeLast()}
                let kind=parts.first?.uppercased() ?? ""
                let ruleKind:RuleKind
                switch kind {case "DOMAIN":ruleKind = .domain;case "DOMAIN-SUFFIX":ruleKind = .suffix;case "DOMAIN-KEYWORD":ruleKind = .keyword;case "IP-CIDR","IP-CIDR6":ruleKind = .cidr;case "MATCH":ruleKind = .match;default:throw ProxyError("不支持的规则类型")}
                guard parts.count==(ruleKind == .match ? 2:3),!noResolve || ruleKind == .cidr else {throw ProxyError("格式应为 类型,内容,目标；MATCH,目标；no-resolve 仅用于 IP 规则")}
                let reference=try target(parts.last!,state:state)
                var rule=RoutingRule(kind:ruleKind,value:ruleKind == .match ? "":parts[1],action:reference == .direct ? .direct:reference == .reject ? .reject:.proxy,target:reference)
                rule.noResolve=noResolve ? true:nil
                try ConfigBuilder.validate(rule)
                if kind=="IP-CIDR6",!rule.value.contains(":") {throw ProxyError("IP-CIDR6 需要 IPv6 地址")}
                if kind=="IP-CIDR",rule.value.contains(":") {throw ProxyError("IPv6 地址请使用 IP-CIDR6")}
                let key=try encode([rule])
                if var matches=unchanged[key],!matches.isEmpty {rule=matches.removeFirst();unchanged[key]=matches}
                result.rules.append(rule)
            }catch{result.issues.append(RuleTextIssue(line:offset+1,message:error.localizedDescription))}
            if result.issues.count>=100 {break}
        }
        return result
    }
}
