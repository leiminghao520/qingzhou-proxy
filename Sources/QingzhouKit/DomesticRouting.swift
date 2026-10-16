import Foundation
import CryptoKit

public enum DomesticRouting {
    private struct Snapshot:Decodable {let version:Int;let domains:[String:[String]];let cidrs:[String]}
    private static let snapshot:Snapshot? = {
        guard let data=Data(base64Encoded:DomesticRuleData.payload),SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==DomesticRuleData.sha256 else {return nil}
        guard let value=try? JSONDecoder().decode(Snapshot.self,from:data),value.version==1,!value.cidrs.isEmpty,!value.domains.isEmpty else {return nil}
        return value
    }()
    public static func validate() throws {guard snapshot != nil else {throw ProxyError("固定国内规则校验失败，拒绝完整接管")}}
    public static var version:String {"2026-10-15 / "+String(DomesticRuleData.sha256.prefix(12))}
    public static var domainCondition:[String:Any] {snapshot?.domains ?? [:]}
    public static var cidrs:[String] {snapshot?.cidrs ?? []}
    public static func isDomestic(_ host:String)->Bool {
        guard let snapshot else {return false}
        let value=host.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
        return (snapshot.domains["domain"] ?? []).contains(value) || (snapshot.domains["domain_suffix"] ?? []).contains{value==$0 || value.hasSuffix("."+$0)} || (snapshot.domains["domain_regex"] ?? []).contains{value.range(of:$0,options:.regularExpression) != nil}
    }
    // 规则模式在用户规则之后、最终策略之前追加国内分流，两种入站使用同一核心。
    public static func appendRules(to rules:inout [[String:Any]],state:AppState) throws {
        guard state.captureMode == .compatible else {return}
        try validate()
        var resolve=domainCondition;resolve["action"]="resolve";resolve["server"]="local";resolve["strategy"]=state.effectiveAddressFamilyPolicy.strategy
        var domain=domainCondition;domain["action"]="route";domain["outbound"]="direct"
        rules += [resolve,domain,["action":"resolve","strategy":state.effectiveAddressFamilyPolicy.strategy],["ip_cidr":cidrs,"action":"route","outbound":"direct"]]
    }
    public static func conflictingRules(_ state:AppState)->[RoutingRule] {
        state.rules.filter {rule in
            let target=rule.target ?? (rule.action == .direct ? .direct:rule.action == .reject ? .reject:.selected)
            return target != .direct && [.domain,.suffix].contains(rule.kind) && isDomestic(rule.value)
        }
    }
}
