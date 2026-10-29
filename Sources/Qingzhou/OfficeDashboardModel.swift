import Foundation
import SwiftUI
import QingzhouKit

@MainActor final class OfficeDashboardModel:ObservableObject {
    @Published private(set) var health:[OfficeHealthSnapshot]=[]
    @Published var sessions:[UUID:DiagnosticSession]=[:]
    @Published var running=Set<UUID>()
    @Published var importRequested=false
    @Published var diagnosticRequested=false
    @Published var linesRequested=false
    @Published var developerRequested=false
    var context=OfficeHealthContext(profileID:nil,connectionID:UUID(),networkID:UUID())
    var tasks:[UUID:Task<Void,Never>]=[:]
    var runIDs:[UUID:UUID]=[:]
    func invalidate(_ context:OfficeHealthContext) {
        if self.context.profileID != context.profileID {health=[];sessions=[:]}
        self.context=context
        for task in tasks.values {task.cancel()};tasks=[:];runIDs=[:];running=[]
        for index in health.indices {health[index].stale=true}
    }
    func set(_ id:String,title:String,status:OfficeHealthStatus,detail:String,now:Date) {
        let row=OfficeHealthSnapshot(id:id,title:title,status:status,detail:detail,checkedAt:now,context:context)
        if let index=health.firstIndex(where:{$0.id==id}) {
            let old=health[index]
            if old.context==row.context,!old.stale,old.status==status,old.detail==detail,now>=old.checkedAt,now.timeIntervalSince(old.checkedAt)<60 {return}
            health[index]=row
        }else{health.append(row)}
    }
    func label(_ id:String,now:Date=Date())->String {
        guard let row=health.first(where:{$0.id==id}) else{return "未验证"}
        return row.isCurrent(context,now:now) ? row.status.rawValue:"未验证（历史结果）"
    }
    func cancel(_ id:UUID) {tasks[id]?.cancel();tasks[id]=nil;runIDs[id]=nil;running.remove(id)
        var session=DiagnosticSession(profileID:context.profileID,connectionID:context.connectionID,nodeID:nil,results:[DiagnosticResult("收藏目标","已取消","本次检查已取消",code:"cancelled")])
        session.finishedAt=Date();sessions[id]=session
        if let index=health.firstIndex(where:{$0.id=="target-"+id.uuidString}) {health[index].status = .unverified;health[index].detail="本次检查已取消"}
    }
}

extension AppModel {
    func requestProfileChange(_ id:UUID) async {
        guard !locked,id != currentProfileID,let destination=profiles.first(where:{$0.id==id}) else{return}
        let next=destination.configuration
        let rows=["接管："+state.captureMode.label+" → "+next.captureMode.label,
                  "分流："+state.mode.label+" → "+next.mode.label,
                  "DNS："+(state.dnsPreference == .system ? "原系统":"代理 HTTPS")+" → "+(next.dnsPreference == .system ? "原系统":"代理 HTTPS"),
                  "策略："+state.label(state.activePolicy)+" → "+next.label(next.activePolicy),
                  "节点：\(state.nodes.count) → \(next.nodes.count)；规则：\(state.rules.count) → \(next.rules.count)",
                  "内网域名："+(state.protectedDomains.isEmpty ? "未配置":state.protectedDomains.prefix(8).joined(separator:", "))+" → "+(next.protectedDomains.isEmpty ? "未配置":next.protectedDomains.prefix(8).joined(separator:", ")),
                  "内网保护：\(state.protectedDomains.count) → \(next.protectedDomains.count)；绕行项：\(state.enabledBypasses.count) → \(next.enabledBypasses.count)",
                  "常用目标：\((state.savedDiagnosticTargets ?? []).count) → \((next.savedDiagnosticTargets ?? []).count)"]
        let alert=NSAlert();alert.messageText="切换到“"+destination.name+"”？"
        alert.informativeText=(rows+[connection == .connected ? "将重新连接；失败时恢复原配置。":"当前未连接；切换配置不会自动连接。"]).joined(separator:"\n")
        alert.addButton(withTitle:"取消");alert.addButton(withTitle:connection == .connected ? "应用并重连":"切换配置")
        guard alert.runModal() == .alertSecondButtonReturn else{return}
        await changeProfile(id)
    }
    var officeContext:OfficeHealthContext {OfficeHealthContext(profileID:currentProfileID,connectionID:epoch,networkID:officeNetworkID)}
    func invalidateOfficeResults(network:Bool=false) {
        if network {officeNetworkID=UUID();officeHelperDNSSignature=nil;cancelHealthRefresh()}
        office.invalidate(officeContext)
    }
    func publishOfficeConnectivity() {
        guard connection == .connected || connection == .connecting else{return}
        let status:OfficeHealthStatus
        switch connectivityHealth {case .healthy:status = .healthy;case .unhealthy:status = .failed;case .checking:status = .checking;case .unknown:status = .unverified}
        office.context=officeContext
        office.set("external",title:"外网 HTTPS",status:status,detail:ConnectivityResult.combinedSummary(connectivityResults),now:dependencies.now())
    }
    func publishOfficeHelper(_ reply:TunReply) {
        guard reply.running else{return}
        office.context=officeContext
        let hasCorporate = !state.protectedDomains.isEmpty || !state.enabledBypasses.isEmpty
        office.set("routes",title:"内网保护路由",status:hasCorporate ? (reply.protectionVerified==true ? .healthy:.unverified):.notApplicable,detail:hasCorporate ? "仅核验保护路由，不代表应用登录成功":"未配置内网保护目标",now:dependencies.now())
        let rows=reply.corporateDNSDiagnostics ?? []
        let signature=try? JSONEncoder().encode(rows)
        if !rows.isEmpty,signature != officeHelperDNSSignature {
            officeHelperDNSSignature=signature
            office.set("corporateDNS",title:"企业 DNS",status:rows.contains{$0.result.outcome == .failed} ? .failed:.healthy,detail:rows.map{ $0.outcome.label }.joined(separator:"；"),now:dependencies.now())
        }
    }
    func saveDiagnosticTargets(_ values:[SavedDiagnosticTarget],expected:Data?) throws {
        guard !locked else {throw ProxyError("当前操作中，请稍后保存")}
        let current=try SavedDiagnosticTarget.revision(state.savedDiagnosticTargets ?? [])
        guard expected==nil || current==expected else {throw ProxyError("收藏目标已在其他页面修改，请重新载入后编辑")}
        let values=try values.map{try $0.validated()};try SavedDiagnosticTarget.validate(values)
        var next=state;next.savedDiagnosticTargets=values;try persist(next)
        invalidateOfficeResults()
    }
    func inspectSavedTarget(_ target:SavedDiagnosticTarget,connect:Bool=false) {
        guard !locked,office.tasks[target.id]==nil else{return}
        guard (state.savedDiagnosticTargets ?? []).contains(target) else {errorMessage="收藏目标已变更，请重新选择";return}
        let state=self.effectiveState,context=officeContext,active=connection == .connected && activeBypasses==state.effectiveBypasses,connected=connection == .connected
        let helper=dependencies.diagnosticHelper,executor=dependencies.diagnosticExecutor
        let pathOverride=dependencies.officePathOverride,probeOverride=dependencies.officeProbeOverride
        let cancellation=DiagnosticCancellation(),session=DiagnosticSession(profileID:currentProfileID,connectionID:epoch,nodeID:nil)
        office.context=context;office.running.insert(target.id)
        office.runIDs[target.id]=session.id
        office.set("target-"+target.id.uuidString,title:target.name,status:.checking,detail:connect ? "正在测试连接":"正在检查路径",now:dependencies.now())
        office.tasks[target.id]=Task { [weak self] in
            let job=DiagnosticJob("收藏目标") {
                let tunnel=state.captureMode.usesTunnel ? (try? await helper().tunnelInterface):nil
                let box=OfficePathEvidenceBox()
                let rows=await withTaskCancellationHandler(operation:{
                    await DiagnosticWorkPool.dns.run(stage:"目标路径",timeout:10) {
                        let evidence=try pathOverride?(target,state,active,tunnel) ?? TargetPathService.inspect(target,state:state,active:active,tunnel:tunnel,cancelled:{cancellation.cancelled})
                        box.set(evidence);return evidence.rows
                    }
                },onCancel:{cancellation.cancel()})
                guard connect,!Task.isCancelled,let evidence=box.get() else{return rows}
                let result:DiagnosticResult
                if let probeOverride {result=await probeOverride(target,evidence,state,connected)}
                else {result=await TargetConnectionProbe.run(target,evidence:evidence,state:state,connected:connected)}
                return rows+[result]
            }
            let value=await executor.run(session,jobs:[job],timeout:15)
            cancellation.cancel()
            guard let self,self.officeContext==context,self.office.runIDs[target.id]==session.id else{return}
            self.office.tasks[target.id]=nil;self.office.running.remove(target.id)
            guard !Task.isCancelled else {
                self.office.set("target-"+target.id.uuidString,title:target.name,status:.unverified,detail:"本次检查已取消",now:self.dependencies.now());return
            }
            self.office.sessions[target.id]=value
            let corporate=value.results.filter{$0.code.hasPrefix("corporateDNS.")}
            if !corporate.isEmpty {
                self.office.set("corporateDNS",title:"企业 DNS",status:corporate.contains{$0.outcome == .failed} ? .failed:corporate.contains{$0.outcome == .passed} ? .healthy:.unverified,detail:"最近收藏目标的作用域 DNS 检查；不代表应用登录成功",now:self.dependencies.now())
            }
            let failed=value.results.contains{[DiagnosticOutcome.failed,.timeout].contains($0.outcome)}
            let passed=connect && value.results.contains{$0.code=="targetConnectionPassed"}
            self.office.set("target-"+target.id.uuidString,title:target.name,status:failed ? .failed:passed ? .healthy:.unverified,detail:connect ? "连接测试结果；业务登录需独立验证":"已查询 DNS、规则和路由；业务连接未验证",now:self.dependencies.now())
        }
    }
    @discardableResult
    func createOfficeProfile(name:String,template:OfficeSceneTemplate,domains:[String],cidrs:[String],dns:DNSPreference,targets:[SavedDiagnosticTarget]) async -> Bool {
        guard !locked,let store else{return false};busy=true;defer{busy=false}
        do {
            let configuration=try template.configuration(domains:domains,cidrs:cidrs,dns:dns,targets:targets)
            var catalog=store.catalog;catalog.profiles.append(ClientProfile(name:name,configuration:configuration))
            try catalog.validate();try await apply(store.prepareCatalog(catalog),reconfigure:false,source:"办公模板")
        ;return true}catch{report(error);return false}
    }
}

// 使用可唤醒的定时等待，避免为了检查刷新标记而高频轮询。
@MainActor final class OfficeRefreshSignal {
    private var sleeper:Task<Void,Never>?
    func wake() {sleeper?.cancel()}
    func wait(_ seconds:TimeInterval) async {
        let task=Task<Void,Never> {try? await Task.sleep(nanoseconds:UInt64(max(0.05,seconds)*1_000_000_000))}
        sleeper=task
        await withTaskCancellationHandler(operation:{await task.value},onCancel:{task.cancel()})
        sleeper=nil
    }
}

private final class OfficePathEvidenceBox:@unchecked Sendable {
    private let lock=NSLock()
    private var value:TargetPathEvidence?
    func set(_ value:TargetPathEvidence) {lock.lock();self.value=value;lock.unlock()}
    func get()->TargetPathEvidence? {lock.lock();defer{lock.unlock()};return value}
}
