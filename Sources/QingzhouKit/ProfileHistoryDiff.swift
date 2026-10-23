import Foundation

public enum ProfileHistoryDiff {
    public static func rows(current:ClientProfile?,snapshot:ProfileHistorySnapshot,credentials:CredentialStore) -> [String] {
        guard let current else{return ["原配置已删除，将恢复为新配置；不会切换当前配置","节点：\(snapshot.profile.configuration.nodes.count) 个；规则：\(snapshot.profile.configuration.rules.count) 条","恢复后暂停该配置的订阅与远程规则自动更新，可手动重新开启"]}
        let before=current.configuration,after=snapshot.profile.configuration
        var rows:[String]=[]
        if current.name != snapshot.profile.name {rows.append("配置名称已变化")}
        let old=Dictionary(uniqueKeysWithValues:before.nodes.map{($0.id,$0)}),new=Dictionary(uniqueKeysWithValues:after.nodes.map{($0.id,$0)})
        rows.append("节点：新增 \(Set(new.keys).subtracting(old.keys).count)，移除 \(Set(old.keys).subtracting(new.keys).count)")
        let modified=Set(old.keys).intersection(new.keys).filter{old[$0]!.fingerprint != new[$0]!.fingerprint || old[$0]!.name != new[$0]!.name}.count
        if modified>0 {rows.append("节点参数或名称变化：\(modified) 个")}
        let changed=Set(old.keys).intersection(new.keys).contains {id in
            let a=old[id]!.credentialRef,b=new[id]!.credentialRef
            return (try? credentials.get(a)) != snapshot.credentials[b] || (try? credentials.get(a+".obfs")) != snapshot.credentials[b+".obfs"]
        }
        let sources=before.subscriptions.contains {sub in after.subscriptions.first{$0.id==sub.id}.map{(try? credentials.get(sub.sourceRef)) != snapshot.credentials[$0.sourceRef]} ?? false}
        let remoteSources=before.remoteRules.contains {sub in after.remoteRules.first{$0.id==sub.id}.map{(try? credentials.get(sub.sourceRef)) != snapshot.credentials[$0.sourceRef]} ?? false}
        if changed || sources || remoteSources {rows.append("凭据：已变化（内容不展示）")}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        if (try? encoder.encode(before.subscriptions)) != (try? encoder.encode(after.subscriptions)) {rows.append("订阅来源或设置有变化")}
        if (try? encoder.encode(before.remoteRules)) != (try? encoder.encode(after.remoteRules)) {rows.append("远程规则来源、内容或设置有变化")}
        if (try? encoder.encode(before.rules)) != (try? encoder.encode(after.rules)) {rows.append("规则：\(before.rules.count) → \(after.rules.count) 条，内容或顺序有变化")}
        if (try? encoder.encode(before.groups)) != (try? encoder.encode(after.groups)) {rows.append("策略组：\(before.groups.count) → \(after.groups.count) 个，内容有变化")}
        if before.mode != after.mode || before.activePolicy != after.activePolicy || before.ruleFinal != after.ruleFinal {rows.append("运行模式或默认策略有变化")}
        if (try? encoder.encode(before.shadowrocket)) != (try? encoder.encode(after.shadowrocket)) {rows.append("完整配置中的高级规则或网络设置有变化")}
        if before.captureMode != after.captureMode || before.dnsPreference != after.dnsPreference || before.listenPort != after.listenPort || before.effectiveAddressFamilyPolicy != after.effectiveAddressFamilyPolicy || before.httpCompatibilityEnabled != after.httpCompatibilityEnabled || before.effectiveBypasses != after.effectiveBypasses {rows.append("接管、DNS、端口或网络绕过设置有变化")}
        rows.append("恢复后暂停该配置的订阅与远程规则自动更新，可手动重新开启")
        return rows
    }
}
