import Foundation
import SwiftUI
import QingzhouKit

// 切换结果与核心连接状态分开，避免把运行中的核心误报为网络可用。
struct SelectionStatus: Equatable {
    enum Phase { case switching, checking, succeeded, failed }
    let target: PolicyReference
    let name: String
    let epoch: UUID
    var phase: Phase
    var message: String
    var networkUncertain = false
    var profileID: UUID? = nil
    var active: Bool { phase == .switching || phase == .checking }
}

extension AppModel {
    var currentSelectionStatus: SelectionStatus? {
        guard let status = selectionStatus, status.epoch == epoch,
              status.profileID == nil || status.profileID == currentProfileID else { return nil }
        return status
    }

    var selectionNetworkUncertain: Bool {
        connection == .connected && currentSelectionStatus?.networkUncertain == true
    }

    func selectPolicy(_ ref: PolicyReference) async {
        guard !locked, ref != state.activePolicy || selectionNetworkUncertain,
              PolicyValidator.exists(ref, in: state), ref != .selected, ref != .reject,
              let store else { return }
        cancelWakeRecovery()
        busy = true
        defer { busy = false; historyStatus = profileHistory.lastError }
        invalidateDiagnostic(); invalidateOfficeResults()
        policyRefreshRequested = true; policyRefreshSignal.wake()
        let old = state.activePolicy
        let selectionEpoch = epoch
        let profile = currentProfileID
        let wasConnected = connection == .connected
        let client = api
        selectionStatus = SelectionStatus(target: ref, name: state.label(ref), epoch: selectionEpoch,
                                          phase: .switching, message: wasConnected ? "正在切换线路" : "正在选择线路")
        selectionStatus?.profileID = profile
        var next = state
        next.selectedPolicy = ref
        if case .node(let id) = ref { next.selectedID = id }
        let tx = store.prepareChange(next)
        tx.historySource = "节点选择"
        var attempted = false
        func sameSession() -> Bool { epoch == selectionEpoch && currentProfileID == profile }
        do {
            try store.prepareHistory(tx)
            if wasConnected {
                guard let client else { throw ProxyError("控制通道不可用，未切换线路") }
                attempted = true
                try await client.select(ref)
                guard sameSession(), connection == .connected else { throw ProxyError("连接或配置已变化，本次切换已结束") }
                selectionStatus?.phase = .checking
                selectionStatus?.message = "正在检查新线路"
                let checked = await connectivityProbe(state.captureMode.usesTunnel ? nil : state.listenPort, client, state.mode)
                guard sameSession(), connection == .connected else { throw ProxyError("连接或配置已变化，本次切换已结束") }
                guard StartupConnectivityPolicy.allows(checked, mode: state.mode) else { throw ProxyError("新线路连通性检查失败") }
                connectivityResults = checked
                reachability = ConnectivityResult.combinedSummary(checked)
            }
            guard sameSession() else { throw ProxyError("配置已变化，本次选择未保存") }
            if case .node(let id) = ref { tx.next.recentUse[id.uuidString] = Date() }
            tx.connectionVerified = wasConnected
            try store.commit(tx)
            state = store.state
            verifiedSelectionTag = wasConnected && { if case .node = ref { return true }; return false }() ? ref.tag : nil
            healthFailures = HealthFailureCounter(); failedHealthCycles = 0
            if verifiedSelectionTag != nil { healthRefreshPending = false }
            selectionStatus?.phase = .succeeded
            selectionStatus?.message = wasConnected ? "已切换到 \(state.label(ref))" : "已选择 \(state.label(ref))，点击连接即可使用"
            recordEvent(.node, .changed, .nodeSelected)
            log(selectionStatus?.message ?? "线路已选择")
        } catch {
            store.abort(tx)
            verifiedSelectionTag = nil
            var message = error.localizedDescription
            var uncertain = wasConnected && client == nil
            if attempted, sameSession(), connection == .connected, let client {
                selectionStatus?.message = "切换失败，正在恢复原线路"
                do {
                    guard let old else { throw ProxyError("没有可恢复的原线路") }
                    try await client.select(old)
                    guard sameSession(), connection == .connected else { throw ProxyError("连接已变化") }
                    let restored = await connectivityProbe(state.captureMode.usesTunnel ? nil : state.listenPort, client, state.mode)
                    guard sameSession(), connection == .connected else { throw ProxyError("连接已变化") }
                    guard StartupConnectivityPolicy.allows(restored, mode: state.mode) else { throw ProxyError("原线路连通性未通过") }
                    connectivityResults = restored
                    reachability = ConnectivityResult.combinedSummary(restored)
                    message += "，已恢复原节点"
                } catch {
                    uncertain = true
                    message += "；恢复未确认：\(error.localizedDescription)"
                }
            }
            // 旧会话的完成回调不覆盖新会话的健康和切换状态。
            guard sameSession() else { selectionStatus = nil; return }
            if uncertain {
                connectivityResults = [.init("线路切换", .failed, "恢复未确认，请重试或检查网络")]
                reachability = "网络状态待确认"
            }
            selectionStatus?.phase = .failed
            selectionStatus?.message = message
            selectionStatus?.networkUncertain = uncertain
            log(message)
        }
    }
}

// 简洁与专业界面共用反馈，菜单栏发起的切换也能在主窗口看到结果。
struct SelectionFeedbackView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let status = model.currentSelectionStatus {
            HStack(alignment: .top, spacing: 8) {
                if status.active { ProgressView().controlSize(.small) }
                else { Image(systemName: status.phase == .failed ? "exclamationmark.circle" : "checkmark.circle") }
                Text(status.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if status.phase == .failed {
                    Button("重试") { Task { await model.selectPolicy(status.target) } }.disabled(model.locked)
                    Button("诊断") { model.office.diagnosticRequested = true }
                }
            }
            .foregroundStyle(status.phase == .failed ? Theme.amberAccent : Theme.accentBlue)
            .accessibilityIdentifier("dailySelectionStatus")
        }
    }
}
