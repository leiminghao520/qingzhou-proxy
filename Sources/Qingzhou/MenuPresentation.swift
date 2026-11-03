import Foundation
import Combine
import QingzhouKit

// 菜单只发布可见内容和操作权限的变化，流量及连接计数不重建原生菜单。
@MainActor final class MenuPresentation: ObservableObject {
    let model: AppModel
    @Published private(set) var revision: [String] = []
    private var subscriptions = Set<AnyCancellable>()
    var healthLabel: String {
        let hasCorporate = !model.state.protectedDomains.isEmpty || !model.state.enabledBypasses.isEmpty
        return "外网：" + model.office.label("external") + " · 内网路由：" + (hasCorporate ? model.office.label("routes") : "未配置")
    }
    init(model: AppModel) {
        self.model = model
        refresh()
        // objectWillChange 在赋值前发送，下一轮主线程读取已完成的状态。
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        model.office.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
    }
    func refresh() {
        let state = model.state
        var next = [model.connectionSummary, model.actualName, model.effectiveState.captureMode.label,
                    model.effectivePathSummary, model.issueTitle ?? "", healthLabel,
                    String(model.activeRecovery != nil), String(model.networkWaiting),
                    String(model.connection == .connected), String(model.connection == .connecting),
                    String(model.hasConnectionActivity), String(model.locked), String(model.stopDisabled),
                    String(model.recoveryPending), String(model.canStop), String(model.loadingFailed),
                    model.captureSwitchTarget?.rawValue ?? "", state.captureMode.rawValue, String(model.recovering), String(model.measuring), String(model.busy), state.mode.rawValue,
                    String(state.activePolicy == nil), String(state.nodes.isEmpty)]
        next += model.profiles.flatMap { [$0.id.uuidString, $0.name, String($0.id == model.currentProfileID)] }
        next += (state.savedDiagnosticTargets ?? []).prefix(5).flatMap { [$0.id.uuidString, $0.name] }
        next += state.groups.flatMap { [$0.id.uuidString, $0.name] }
        next += OfficeTelemetryCadence.menuNodes(state, actualTag: CoreAPIClient.actualTag(model.proxyInfo)).flatMap {
            [$0.id.uuidString, $0.name, String(state.activePolicy == .node($0.id)), String(state.favorites.contains($0.id))]
        }
        if revision != next { revision = next }
    }
}
