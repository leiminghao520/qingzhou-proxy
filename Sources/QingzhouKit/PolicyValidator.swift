import Foundation

public enum PolicyValidator {
    public static func exists(_ ref:PolicyReference,in state:AppState) -> Bool {
        switch ref {case .node(let id):return state.nodes.contains{$0.id==id};case .group(let id):return state.groups.contains{$0.id==id};case .automatic:return !state.nodes.isEmpty;case .selected,.direct,.reject:return true}
    }
    public static func validate(_ state:AppState) throws {
        try SavedDiagnosticTarget.validate(state.savedDiagnosticTargets ?? [])
        if let shadow=state.shadowrocket {try shadow.validate()}
        for rule in state.rules where rule.kind == .geoip || rule.kind == .asn {
            let key=(rule.kind == .geoip ? "GEOIP:":"IP-ASN:")+rule.value
            guard state.shadowrocket?.assets[key]?.isEmpty==false else{throw ProxyError("地理或 ASN 规则资产缺失")}
        }
        guard !state.rules.contains(where:{$0.kind == .userAgent}) || state.shadowrocket != nil else{throw ProxyError("User-Agent 缺少 HTTP 兼容配置")}
        guard Set(state.nodes.map(\.id)).count==state.nodes.count,Set(state.groups.map(\.id)).count==state.groups.count else {throw ProxyError("节点或策略 ID 重复")}
        guard state.nodes.count<=2000,state.groups.count<=2000,state.rules.count<=50000,state.remoteRules.reduce(0,{$0+$1.rules.count})<=50000,state.effectiveBypasses.count<=5000 else{throw ProxyError("配置数量超过限制")}
        _ = try NetworkBypassPolicy.normalize(state.effectiveBypasses)
        if state.captureMode == .compatible {try DomesticRouting.validate()}
        for cidr in state.bypassCIDRs{try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:cidr,action:.direct))}
        for source in state.remoteRules{for rule in source.rules{try ConfigBuilder.validate(rule)}}
        var visiting=Set<UUID>(),finished=Set<UUID>()
        func visit(_ id:UUID) throws {
            if finished.contains(id){return};guard !visiting.contains(id),let group=state.groups.first(where:{$0.id==id}) else {throw ProxyError("策略组存在循环或缺失引用")}
            guard !group.members.isEmpty else {throw ProxyError("策略组至少包含一个成员")};visiting.insert(id)
            if group.kind == .fallback {guard group.members.allSatisfy({if case .node=$0{return true};return false}) else{throw ProxyError("优先回退仅接受节点成员")}}
            for ref in group.members {
                guard ref != .selected,ref != .reject,exists(ref,in:state) else {throw ProxyError("策略组包含不支持或失效成员")}
                if case .group(let child)=ref {try visit(child)}
            }
            if let selected=group.selected {guard group.members.contains(selected) else {throw ProxyError("策略组选择不在成员中")}}
            visiting.remove(id);finished.insert(id)
        }
        for group in state.groups {try visit(group.id)}
        for rule in state.rules {try ConfigBuilder.validate(rule);if let target=rule.target {guard exists(target,in:state) else {throw ProxyError("规则引用的策略不存在")}}}
        for source in state.remoteRules {guard exists(source.target,in:state) else {throw ProxyError("远程规则引用的策略不存在")}}
        if let final=state.ruleFinal {guard exists(final,in:state) else {throw ProxyError("默认规则策略不存在")}}
        if let selected=state.activePolicy {guard selected != .selected,selected != .reject,exists(selected,in:state) else {throw ProxyError("当前选择已失效，请重新选择")}}
    }
    public static func repair(_ state:inout AppState) {
        let nodeIDs=Set(state.nodes.map(\.id));state.favorites.formIntersection(nodeIDs);state.latency=state.latency.filter{key,_ in UUID(uuidString:key).map{nodeIDs.contains($0)} ?? false}
        if let selected=state.selectedID,!nodeIDs.contains(selected){state.selectedID=nil}
        var changed=true
        while changed {
            let before=state.groups.count
            for i in state.groups.indices {state.groups[i].members=state.groups[i].members.filter{exists($0,in:state) && $0 != .selected && $0 != .reject};if let selected=state.groups[i].selected,!state.groups[i].members.contains(selected){state.groups[i].selected=state.groups[i].members.first}}
            state.groups.removeAll{$0.members.isEmpty};changed=before != state.groups.count
        }
        if let current=state.activePolicy,!exists(current,in:state) {state.selectedPolicy=nil;state.selectedID=nil}
        for i in state.rules.indices {if let target=state.rules[i].target,!exists(target,in:state){state.rules[i].action = .reject;state.rules[i].target=nil}}
        for i in state.remoteRules.indices {if !exists(state.remoteRules[i].target,in:state){state.remoteRules[i].target = .reject}}
        if let final=state.ruleFinal,!exists(final,in:state){state.ruleFinal = .reject}
    }
}
