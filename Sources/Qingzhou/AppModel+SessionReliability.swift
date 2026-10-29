import Foundation
import QingzhouKit

extension AppModel {
    var hasConnectionActivity:Bool {connection == .connected || connection == .connecting || networkWaiting || wakeRecovery.active}
    var connectionAvailable:Bool {connection == .connected && !networkWaiting && !networkReconnecting && !wakeRecovery.active && !selectionNetworkUncertain && connectivityHealth == .healthy}
    var recoveryImpact:String? {
        guard let record=activeRecovery else{return nil}
        if record.kind == .tunnel {return "TUN 暂不可用，当前使用系统代理；部分应用可能不受代理覆盖"}
        if record.kind == .dns {return "代理 DNS 暂不可用，当前使用系统 DNS 解析"}
        return nil
    }
    func cancelConnectionWait() {networkWaiting=false}
    func verifyConnectionReleased() async throws {
        if let verify=dependencies.recoveryReleasedOverride {try await verify()}else{try await capture.verifyReleasedForQuit()}
    }
    func networkEnvironmentChanged() {
        invalidateOfficeResults(network:true);requestOfficeRefresh()
        recordEvent(.network,.changed,.environmentChanged)
        dependencies.downloader.networkEnvironmentChanged();latencyInvalidatedAt=dependencies.now()
        rescheduleTransientUpdates()
        // 等待期间仅唤醒同一个协调器，避免网络事件风暴创建第二条重连链路。
        automaticRefreshRequested=true
        wakeRecovery.networkChanged()
        scheduleHealthRefresh()
    }
    func releaseWhileWaitingForNetwork() async -> WakeRecoveryCheck {
        networkWaiting=true
        if networkReleased && connection != .connected && !capture.running {return .failed(.networkNotReady)}
        guard state.pinnedBypasses.isEmpty else{return .stop(.exitUnavailable)}
        busy=true;wakeRebuilding=true
        defer{wakeRebuilding=false;busy=false}
        do {
            try await disconnectInternal(preserveExternal:true)
            try await verifyConnectionReleased()
            networkReleased=true;wakeNeedsRebuild=true
            return .failed(.networkNotReady)
        }catch{recoveryPending=true;return .stop(.ownershipConflict)}
    }
    func defaultExitNodeID()->UUID? {
        let root:PolicyReference? = state.mode == .rule ? (state.ruleFinal ?? .selected):.selected
        var seen=Set<UUID>()
        func resolve(_ ref:PolicyReference?)->UUID? {
            switch ref {
            case .node(let id):return id
            case .selected:return resolve(state.activePolicy)
            case .automatic:
                guard let tag=CoreAPIClient.actualTag(proxyInfo,root:"auto"),tag.hasPrefix("node-") else{return nil}
                return UUID(uuidString:String(tag.dropFirst(5)))
            case .group(let id):
                guard seen.insert(id).inserted,let group=state.groups.first(where:{$0.id==id}) else{return nil}
                if let tag=proxyInfo[PolicyReference.group(id).tag]?.now,let member=group.members.first(where:{$0.tag==tag}) {return resolve(member)}
                return resolve(group.selected ?? group.members.first)
            default:return nil
            }
        }
        return state.mode == .direct ? nil:resolve(root)
    }
    func usesAutomaticExit()->Bool {
        guard state.mode != .direct else{return false}
        var seen=Set<UUID>()
        func uses(_ ref:PolicyReference?)->Bool {
            switch ref {
            case .automatic:return true
            case .selected:return uses(state.activePolicy)
            case .group(let id):
                guard seen.insert(id).inserted,let group=state.groups.first(where:{$0.id==id}) else{return false}
                if let tag=proxyInfo[PolicyReference.group(id).tag]?.now,let member=group.members.first(where:{$0.tag==tag}) {return uses(member)}
                return uses(group.selected ?? group.members.first)
            default:return false
            }
        }
        return uses(state.activePolicy) || (state.mode == .rule && (uses(state.ruleFinal) || state.rules.contains{uses($0.target)} || state.remoteRules.contains{uses($0.target)}))
    }
    func refreshAutomaticIfNeeded(_ client:CoreAPIClient,token:UUID) async {
        guard usesAutomaticExit(),dependencies.now().timeIntervalSince(lastAutomaticRefresh)>=30 else{return}
        lastAutomaticRefresh=dependencies.now();automaticRefreshRequested=false
        do {
            try await client.refreshAutomatic()
            let info=try await client.proxies()
            guard epoch==token,!Task.isCancelled,!stopRequested else{return}
            publishPolicyInfo(info)
        }catch{log("自动选择复查尚未完成："+Redactor.redact(error.localizedDescription))}
    }
}
