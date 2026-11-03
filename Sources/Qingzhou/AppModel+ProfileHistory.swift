import Foundation
import QingzhouKit

extension AppModel {
    func restoreHistory(_ version:ProfileHistoryVersion,expectedRevision:Data?,confirmedReconnect:Bool=false) async -> Bool {
        guard !locked,let store else{return false}
        let current=store.catalog.profiles.first{$0.id==version.profileID}
        do {
            guard version.profileID != currentProfileID || connection != .connected || confirmedReconnect else {throw ProxyError("恢复当前运行配置需要明确确认重新连接")}
            guard try current.map({try ProfileHistoryStore.revision($0)})==expectedRevision else {throw ProxyError("预览后配置已变化，请重新预览历史")}
            guard drafts.allowLeaving("恢复历史配置",profile:version.profileID) else{return false}
            busy=true;defer{busy=false}
            let snapshot=try profileHistory.snapshot(version)
            let tx=try store.prepareProfileRestore(snapshot)
            let targetID=tx.nextCatalog?.profiles.first{$0.id==version.profileID}?.id ?? tx.nextCatalog?.profiles.last?.id
            try await apply(tx,reconfigure:version.profileID==currentProfileID,source:"历史恢复",affectedProfileID:targetID)
            recordEvent(.history,.succeeded,.historyRestored,profileID:targetID,historyTransactionID:tx.historyTransactionID);return true
        }catch {historyStatus=profileHistory.lastError;recordEvent(.history,.failed,.historyFailed);report(error);return false}
    }
    func maintainHistory() {
        let now=dependencies.now()
        guard !locked,now>=nextHistoryMaintenance,let store else{return}
        nextHistoryMaintenance=now.addingTimeInterval(3600)
        do {try profileHistory.maintain(store.catalog)}catch {log("配置历史维护未完成；当前代理继续运行")}
        if historyStatus != profileHistory.lastError {historyStatus=profileHistory.lastError}
        timeline.maintain()
    }
    func setHistoryEnabled(_ enabled:Bool) {
        guard !locked else{return}
        do {try profileHistory.setEnabled(enabled);if enabled,let store {try profileHistory.initialize(store.catalog)};historyStatus=profileHistory.lastError}
        catch {historyStatus=profileHistory.lastError ?? "历史设置未完成";report(error)}
    }
}
