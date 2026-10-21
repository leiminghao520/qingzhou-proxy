import Foundation
import QingzhouKit

final class DomesticRoutingIndexTests:CheckCase {
    func testIndexedDomainsPreserveMatchingSemantics() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let object=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("Resources/domestic-rules.json"))) as! [String:Any]
        let domains=object["domains"] as! [String:[String]]
        func reference(_ host:String)->Bool {
            let value=host.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
            return (domains["domain"] ?? []).contains(value) || (domains["domain_suffix"] ?? []).contains{value==$0 || value.hasSuffix("."+$0)} || (domains["domain_regex"] ?? []).contains{value.range(of:$0,options:.regularExpression) != nil}
        }
        for domain in domains["domain"] ?? [] {expectTrue(DomesticRouting.isDomestic(domain))}
        for suffix in domains["domain_suffix"] ?? [] {
            if suffix.hasPrefix(".") {expectEqual(DomesticRouting.isDomestic(suffix),reference(suffix))}
            else {expectTrue(DomesticRouting.isDomestic(suffix))}
            expectTrue(DomesticRouting.isDomestic("child."+suffix))
        }
        let regexHosts=["r1---sn-2x3abcde.googlevideo.com","cdn1-epicgames-123.file.myqcloud.com","nisx.10010.com","a.awsdns-cn-12.biz","epicgames-download1-123.file.myqcloud.com","a.awsdns-cn-1a.cn","r1---sn-ni5abcde.xn--ngstr-lra8j.com","assets-mihayo.akamaized.net"]
        var samples=regexHosts+["","localhost","EXAMPLE.COM.",".QQ.COM.","qq.com.attacker.invalid","not-qq.com","例子.invalid","192.0.2.1"]
        samples.append(contentsOf:(domains["domain"] ?? []).enumerated().filter{$0.offset.isMultiple(of:20)}.flatMap{[$0.element.uppercased()+".","child."+$0.element]})
        for sample in samples {expectEqual(DomesticRouting.isDomestic(sample),reference(sample),"索引应保留原匹配语义")}
    }
    func testConflictOrderAndDirectRulesArePreserved() {
        var state=AppState()
        let a=RoutingRule(kind:.suffix,value:"qq.com",action:.proxy)
        let b=RoutingRule(kind:.domain,value:"baidu.com",action:.reject)
        let direct=RoutingRule(kind:.suffix,value:"qq.com",action:.proxy,target:.direct)
        state.rules=[a,direct,RoutingRule(kind:.keyword,value:"qq",action:.reject),b,RoutingRule(kind:.domain,value:"example.invalid",action:.proxy)]
        expectEqual(DomesticRouting.conflictingRules(state).map(\.id),[a.id,b.id])
        var changed=a;changed.noResolve=true;expectFalse(changed==a)
    }
}
