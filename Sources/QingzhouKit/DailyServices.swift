import Foundation
import Darwin

public struct UpdateDiff:Sendable {
    public var added:[String]=[];public var removed:[String]=[];public var changed:[String]=[];public var certificateChanges:[String]=[];public var strategyChanges=false;public var ruleChanges=false;public var removesSelection=false
    public var ambiguousNodes:[String]=[]
    public var compatibilityChanges=false
    public var requiresReview:Bool {!ambiguousNodes.isEmpty || removesSelection || !certificateChanges.isEmpty || compatibilityChanges}
    public static func compare(old:AppState,preview:ImportPreview,subscriptionID:UUID?,credentials:CredentialStore?=nil) -> UpdateDiff {
        let oldNodes=old.nodes.filter{$0.subscriptionID==subscriptionID};let fresh=preview.candidates.map(\.node);var diff=UpdateDiff()
        let matching=SubscriptionMatching(old:oldNodes,incoming:fresh)
        diff.ambiguousNodes=fresh.filter{matching.ambiguousIncomingIDs.contains($0.id)}.map(\.name)
        for candidate in preview.candidates {
            let node=candidate.node
            if let previous=matching.previousByIncomingID[node.id] {
                let credentialsChanged=credentials.map{(try? $0.get(previous.credentialRef)) != candidate.secret || (try? $0.get(previous.credentialRef+".obfs")) != candidate.obfsSecret} ?? false
                if node.fingerprint != previous.fingerprint || node.name != previous.name || credentialsChanged {diff.changed.append(node.name)}
                if node.insecure != previous.insecure {diff.certificateChanges.append(node.name)}
            } else {diff.added.append(node.name);if node.insecure {diff.certificateChanges.append(node.name)}}
        }
        for node in oldNodes where !fresh.contains(where:{$0.fingerprint==node.fingerprint}) {diff.removed.append(node.name);var visiting=Set<UUID>()
            func uses(_ ref:PolicyReference?)->Bool {guard let ref else{return false};switch ref{case .node(let id):return id==node.id;case .automatic:return true;case .group(let id):guard visiting.insert(id).inserted,let group=old.groups.first(where:{$0.id==id}) else{return false};return group.members.contains{uses($0)};default:return false}}
            if uses(old.activePolicy){diff.removesSelection=true}}
        let oldGroups=old.groups.filter{$0.subscriptionID==subscriptionID};let oldRules=old.rules.filter{$0.subscriptionID==subscriptionID}
        func ref(_ target:PolicyReference?,nodes:[Node],groups:[PolicyGroup])->String {guard let target else{return ""};switch target{case .node(let id):return nodes.first{$0.id==id}?.fingerprint ?? target.tag;case .group(let id):return groups.first{$0.id==id}?.name ?? target.tag;default:return target.tag}}
        diff.strategyChanges=oldGroups.map{"\($0.name)|\($0.kind)|"+$0.members.map{ref($0,nodes:old.nodes,groups:old.groups)}.joined(separator:",")} != preview.groups.map{"\($0.name)|\($0.kind)|"+$0.members.map{ref($0,nodes:fresh,groups:preview.groups)}.joined(separator:",")}
        diff.ruleChanges=oldRules.map{"\($0.kind)|\($0.value)|\($0.action)|\($0.noResolve ?? false)|"+ref($0.target,nodes:old.nodes,groups:old.groups)} != preview.rules.map{"\($0.kind)|\($0.value)|\($0.action)|\($0.noResolve ?? false)|"+ref($0.target,nodes:fresh,groups:preview.groups)}
        if let incoming=preview.fullConfiguration {
            let previous=old.shadowrocket
            diff.compatibilityChanges=previous?.rewrites.map{"\($0.pattern)|\($0.replacement)|\($0.status)"} != incoming.rewrites.map{"\($0.pattern)|\($0.replacement)|\($0.status)"} || previous?.general != incoming.general || previous?.assetHashes != incoming.assetHashes
        }
        if let final=preview.final,ref(old.ruleFinal,nodes:old.nodes,groups:old.groups) != ref(final,nodes:fresh,groups:preview.groups){diff.ruleChanges=true};return diff
    }
}
public struct FallbackDecision:Sendable {public var selected:UUID?;public var unavailable:Bool}
public struct FallbackController:Sendable {
    private var successes:[UUID:Int]=[:],failures:[UUID:Int]=[:];private var lastSwitch:Date?
    public init(){}
    public mutating func evaluate(priority:[UUID],current:UUID?,results:[UUID:Bool],now:Date=Date()) -> FallbackDecision {
        successes=successes.filter{priority.contains($0.key)};failures=failures.filter{priority.contains($0.key)}
        for id in priority {if results[id]==true{successes[id,default:0]+=1;failures[id]=0}else if results[id]==false{failures[id,default:0]+=1;successes[id]=0}else{successes[id]=0;failures[id]=0}}
        if priority.isEmpty{return FallbackDecision(selected:nil,unavailable:true)}
        if priority.allSatisfy({failures[$0,default:0]>=2}){return FallbackDecision(selected:nil,unavailable:true)}
        let available=priority.first{results[$0]==true}
        guard let candidate=available else{return FallbackDecision(selected:current,unavailable:false)}
        if current==nil || !priority.contains(current!) {lastSwitch=now;return FallbackDecision(selected:candidate,unavailable:false)}
        guard candidate != current,lastSwitch.map({now.timeIntervalSince($0)>=60}) ?? true else{return FallbackDecision(selected:current,unavailable:false)}
        let preferred=priority.firstIndex(of:candidate)!<priority.firstIndex(of:current!)!
        if failures[current!,default:0]>=2 || (preferred && successes[candidate,default:0]>=2){lastSwitch=now;return FallbackDecision(selected:candidate,unavailable:false)}
        return FallbackDecision(selected:current,unavailable:false)
    }
}
public struct RuleExplanation:Sendable {public var steps:[String];public var target:PolicyReference?;public var uncertainty:String?}
public enum RuleEvaluator {
    public static func condition(_ rule:RoutingRule)->[String:Any] {let key=rule.kind == .domain ? "domain":rule.kind == .suffix ? "domain_suffix":rule.kind == .keyword ? "domain_keyword":"ip_cidr";return rule.kind == .match ? [:]:[key:[rule.value]]}
    public static func matches(_ rule:RoutingRule,host:String,ip:String?) -> Bool? {
        let host=host.lowercased(),value=rule.value.lowercased()
        switch rule.kind {case .domain:return host==value;case .suffix:return host==value || host.hasSuffix("."+value);case .keyword:return host.contains(value);case .match:return true;case .geoip,.asn,.userAgent:return nil;case .cidr:
            guard let ip else{return nil};let parts=value.split(separator:"/",omittingEmptySubsequences:false);guard !parts.isEmpty else{return false};var address=[UInt8](repeating:0,count:16),network=[UInt8](repeating:0,count:16)
            let family=ip.withCString{inet_pton(AF_INET,$0,&address)==1 ? AF_INET:inet_pton(AF_INET6,$0,&address)==1 ? AF_INET6:0};guard family != 0,String(parts[0]).withCString({inet_pton(family,$0,&network)})==1 else{return false};guard parts.count<=2,let bits=parts.count==2 ? Int(parts[1]):(family==AF_INET ? 32:128),(0...(family==AF_INET ? 32:128)).contains(bits) else{return false}
            for i in 0..<bits {let mask=UInt8(1 << (7-i%8));if address[i/8]&mask != network[i/8]&mask{return false}};return true
        }
    }
    public static func explain(_ input:String,state:AppState) throws -> RuleExplanation {
        let host=input.trimmingCharacters(in:.whitespacesAndNewlines).lowercased();guard !host.isEmpty,!host.contains("/"),!host.contains("://") else{throw ProxyError("请输入域名或 IP，不含协议和路径")}
        var bytes=[UInt8](repeating:0,count:16);let ip=host.withCString{inet_pton(AF_INET,$0,&bytes)==1 || inet_pton(AF_INET6,$0,&bytes)==1} ? host:nil
        var steps=["模拟分析：不读取真实连接，也不发起 DNS 查询"]
        if host=="localhost" || host=="::1" || host.hasPrefix("127.") {return RuleExplanation(steps:steps+["本机回环保护，不进入隧道"],target:.direct)}
        if state.enabledBypasses.contains(where:{$0.matches(host:host,ip:ip)}) {return RuleExplanation(steps:steps+["企业网络保护：系统代理绕过；完整接管需同时核验原 VPN 路由", "显式指定 HTTP/SOCKS 代理的请求可能不遵循系统例外"],target:.direct,uncertainty:"此处是配置模拟，实际接口请核对诊断中的保护计划")}
        if state.mode == .direct{return RuleExplanation(steps:steps+["全部直连模式"],target:.direct)}
        if state.mode == .global{return RuleExplanation(steps:steps+["全部代理模式"],target:state.activePolicy)}
        if host=="localhost" || ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","::1/128","fc00::/7","fe80::/10"].contains(where:{matches(RoutingRule(kind:.cidr,value:$0,action:.direct),host:host,ip:ip)==true}){return RuleExplanation(steps:steps+["本机/私网优先直连"],target:.direct)}
        let rows=state.rules.map{("用户规则",$0,nil as PolicyReference?)}+state.remoteRules.flatMap{source in source.rules.map{("规则源："+source.name,$0,source.target as PolicyReference?)}}
        for (source,rule,override) in rows {try ConfigBuilder.validate(rule);let match=rule.noResolve==true && ip==nil && [.cidr,.geoip,.asn].contains(rule.kind) ? false:matches(rule,host:host,ip:ip);if match==nil{return RuleExplanation(steps:steps+[source+"需要解析 IP"],target:nil,uncertainty:"前置 IP 规则或私网解析可能改变结果，请结合真实连接核对")};steps.append(source+" · \(rule.kind.rawValue) \(rule.value)："+(match! ? "命中":"未命中"));if match! {let ref=override ?? rule.target ?? (rule.action == .direct ? .direct:rule.action == .reject ? .reject:.selected);return RuleExplanation(steps:steps,target:ref == .selected ? state.activePolicy:ref,uncertainty:ip==nil ? "未解析域名，实际私网解析可能优先直连":nil)}}
        if state.captureMode == .compatible {
            try DomesticRouting.validate()
            if DomesticRouting.isDomestic(host) {return RuleExplanation(steps:steps+["固定国内域名规则 → 原系统公网 DNS → 直连公网出口"],target:.direct)}
            if let ip,DomesticRouting.cidrs.contains(where:{matches(RoutingRule(kind:.cidr,value:$0,action:.direct),host:host,ip:ip)==true}) {return RuleExplanation(steps:steps+["固定国内 IP 规则 → 直连公网出口"],target:.direct)}
            if ip==nil {return RuleExplanation(steps:steps+["未命中国内域名；解析后还需核对国内 IP 规则"],target:nil,uncertainty:"不主动查询 DNS，不能据此断言最终出口")}
        }
        return RuleExplanation(steps:steps+["默认策略"],target:state.ruleFinal ?? state.activePolicy,uncertainty:ip==nil ? "未解析域名，实际私网解析可能优先直连":nil)
    }
}
@MainActor public enum RuntimeTransaction {
    public static func apply(_ tx:StoreTransaction,connected:Bool,validate:() async throws -> Void,stop:() async throws -> Void,start:(AppState) async throws -> Void,commit:() throws -> Void,abort:() -> Void,restartPrevious:((AppState) async throws -> Void)?=nil) async throws {
        var changed=false
        do {try await validate();if connected {changed=true;try await stop();if tx.next.activePolicy != nil || tx.next.mode == .direct{try await start(tx.next)}};try commit()}
        catch {let original=error;if changed {do{try await stop();if tx.previous.activePolicy != nil || tx.previous.mode == .direct{if let restartPrevious {try await restartPrevious(tx.previous)} else {try await start(tx.previous)}}}catch{abort();throw ProxyError("新配置失败，上一份运行配置恢复失败，请使用恢复入口")}};abort();throw original}
    }
}
public struct RateSample:Identifiable,Sendable {public var id=UUID();public var time=Date();public var upload:Int64;public var download:Int64;public init(upload:Int64,download:Int64){self.upload=upload;self.download=download}}
