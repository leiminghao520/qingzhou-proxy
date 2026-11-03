import Foundation
import SwiftUI
import QingzhouKit

// 切换结果与核心连接状态分开，避免把运行中的核心误报为网络可用。
struct SelectionStatus: Equatable {
    enum Phase { case switching, checking, unconfirmed, succeeded, failed }
    let id = UUID()
    let target: PolicyReference
    let name: String
    let epoch: UUID
    var phase: Phase
    var message: String
    var networkUncertain = false
    var profileID: UUID? = nil
    var groupID: UUID? = nil
    var active: Bool { phase == .switching || phase == .checking }
}

extension AppModel {
    var currentSelectionStatus: SelectionStatus? {
        guard let status = selectionStatus, status.epoch == epoch,
              status.profileID == nil || status.profileID == currentProfileID else { return nil }
        return status
    }

    var visibleSelectionStatus: SelectionStatus? {
        guard let status = currentSelectionStatus, status.id != dismissedSelectionFeedbackID else { return nil }
        return status
    }

    // 收起展示不清除未确认的网络状态；旧提示也不能隐藏后续切换结果。
    func dismissSelectionFeedback(_ id: UUID) {
        guard currentSelectionStatus?.id == id else { return }
        dismissedSelectionFeedbackID = id
    }

    var selectionNetworkUncertain: Bool {
        connection == .connected && currentSelectionStatus?.networkUncertain == true
    }

    // 关闭自动优选时固定当前实际节点，尚未连接则沿用上次手动节点。
    func setAutomaticSelection(_ enabled: Bool) async {
        if enabled { await selectPolicy(.automatic); return }
        guard state.activePolicy == .automatic else { return }
        let actual = CoreAPIClient.actualTag(proxyInfo)
        let node = state.nodes.first { PolicyReference.node($0.id).tag == actual }
            ?? state.nodes.first { $0.id == state.selectedID }
            ?? (connection == .connected ? nil : state.nodes.first)
        guard let node else { report(ProxyError("尚未确认当前节点，请点击一个节点切换到手动选择")); return }
        await selectPolicy(.node(node.id))
    }

    func selectPolicy(_ ref: PolicyReference) async {
        await changeSelection(ref, in: nil)
    }

    func changeSelection(_ ref: PolicyReference, in group: PolicyGroup?) async {
        guard !locked, PolicyValidator.exists(ref, in: state), ref != .selected, ref != .reject,
              let store else { return }
        if state.protectsDisconnect {
            report(ProxyError("断线保护已固定当前节点；更换线路前请先关闭断线保护"));return
        }
        let currentGroup = group.flatMap { item in state.groups.first { $0.id == item.id } }
        if group != nil {
            guard let currentGroup, currentGroup.kind == .select, currentGroup.members.contains(ref) else { return }
        }
        let old = currentGroup.map { $0.selected ?? $0.members.first } ?? state.activePolicy
        guard ref != old || selectionNetworkUncertain else { return }
        cancelWakeRecovery()
        cancelConnectionWait()
        busy = true
        defer { busy = false; historyStatus = profileHistory.lastError }
        invalidateDiagnostic(); invalidateOfficeResults()
        policyRefreshRequested = true; policyRefreshSignal.wake()
        let selectionEpoch = epoch, profile = currentProfileID
        let wasConnected = connection == .connected
        let client = api
        let groupTag = currentGroup.map { PolicyReference.group($0.id).tag } ?? "proxy"
        let name = state.label(ref)
        selectionStatus = SelectionStatus(target: ref, name: name, epoch: selectionEpoch,
                                          phase: .switching, message: wasConnected ? "正在切换线路" : "正在选择线路")
        selectionStatus?.profileID = profile
        selectionStatus?.groupID = currentGroup?.id
        var next = state
        if let currentGroup, let index = next.groups.firstIndex(where: { $0.id == currentGroup.id }) {
            next.groups[index].selected = ref
        } else {
            next.selectedPolicy = ref
            if case .node(let id) = ref { next.selectedID = id }
        }
        let tx = store.prepareChange(next)
        tx.historySource = currentGroup == nil ? "节点选择" : "策略组选择"
        var attempted = false
        var verification = SelectionVerification.verified
        func sameSession() -> Bool { epoch == selectionEpoch && currentProfileID == profile && !stopRequested && !Task.isCancelled }
        func inspect(_ target: PolicyReference, _ client: CoreAPIClient) async throws -> [ConnectivityResult] {
            try await client.verifySelection(target, group: groupTag)
            var results = await connectivityProbe(effectiveState.captureMode.usesTunnel ? nil : state.listenPort, client, state.mode)
            if currentGroup != nil, results.count == 3 {
                results[1] = await ConnectivityProbe.target(client: client, root: groupTag)
            }
            try await client.verifySelection(target, group: groupTag)
            return results
        }
        do {
            try store.prepareHistory(tx)
            if wasConnected {
                guard let client else { throw ProxyError("控制通道不可用，未切换线路") }
                attempted = true
                try await client.select(ref, group: groupTag)
                guard sameSession(), connection == .connected else { throw CancellationError() }
                selectionStatus?.phase = .checking
                selectionStatus?.message = "正在检查新线路"
                let checked = try await inspect(ref, client)
                guard sameSession(), connection == .connected else { throw CancellationError() }
                verification = SelectionConnectivityPolicy.evaluate(checked, requiresNode: ref != .direct && (currentGroup != nil || state.mode != .direct))
                guard verification != .failed else { throw ProxyError("新线路通道检查失败") }
                connectivityResults = checked
                reachability = ConnectivityResult.combinedSummary(checked)
            }
            guard sameSession() else { throw CancellationError() }
            if verification == .verified, case .node(let id) = ref { tx.next.recentUse[id.uuidString] = dependencies.now() }
            tx.connectionVerified = wasConnected && verification == .verified
            try store.commit(tx)
            state = store.state
            verifiedSelectionTag = wasConnected && verification == .verified && currentGroup == nil && { if case .node = ref { return true }; return false }() ? ref.tag : nil
            healthFailures = HealthFailureCounter(); exitHealth = ExitHealthTracker(); failedHealthCycles = 0
            if verifiedSelectionTag != nil { healthRefreshPending = false }
            selectionStatus?.phase = verification == .verified ? .succeeded : .unconfirmed
            selectionStatus?.networkUncertain = verification == .unconfirmed
            selectionStatus?.message = !wasConnected ? "已选择 \(name)，点击连接即可使用" : verification == .verified ? "已切换到 \(name)；已有连接继续使用原路径，失败请求可能需要重试" : "已选择 \(name)，网络尚未确认，正在后台复查"
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
                    try await client.select(old, group: groupTag)
                    guard sameSession(), connection == .connected else { throw CancellationError() }
                    let restored = try await inspect(old, client)
                    guard sameSession(), connection == .connected else { throw CancellationError() }
                    guard SelectionConnectivityPolicy.evaluate(restored, requiresNode: old != .direct && (currentGroup != nil || state.mode != .direct)) == .verified else { throw ProxyError("原线路连通性未通过") }
                    connectivityResults = restored
                    reachability = ConnectivityResult.combinedSummary(restored)
                    message += "，已恢复原节点"
                } catch {
                    uncertain = true
                    message += "；恢复未确认：\(error.localizedDescription)"
                }
            }
            // 旧会话不得覆盖新操作；手动停止后也不允许补发回滚请求。
            guard sameSession() else {
                if selectionStatus?.epoch==selectionEpoch,selectionStatus?.profileID==profile {selectionStatus=nil}
                return
            }
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

    func retrySelection() async {
        guard let status = currentSelectionStatus else { return }
        let group = status.groupID.flatMap { id in state.groups.first { $0.id == id } }
        if status.groupID != nil && group == nil { return }
        await changeSelection(status.target, in: group)
    }

}

// 简洁与专业界面共用反馈，菜单栏发起的切换也能在主窗口看到结果。
struct SelectionFeedbackView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let status = model.visibleSelectionStatus {
            HStack(alignment: .top, spacing: 8) {
                if status.active { ProgressView().controlSize(.small) }
                else { Image(systemName: status.phase == .failed || status.phase == .unconfirmed ? "exclamationmark.circle" : "checkmark.circle") }
                Text(status.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if status.phase == .failed || status.phase == .unconfirmed {
                    Button("重试") { Task { await model.retrySelection() } }.disabled(model.locked)
                    Button("诊断") { model.office.diagnosticRequested = true }
                }
                if !status.active {
                    Button { model.dismissSelectionFeedback(status.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭线路提示")
                }
            }
            .task(id: status.id.uuidString + String(describing: status.phase)) {
                guard status.phase == .succeeded else { return }
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                model.dismissSelectionFeedback(status.id)
            }
            .foregroundStyle(status.phase == .failed || status.phase == .unconfirmed ? Theme.amberAccent : Theme.accentBlue)
            .accessibilityIdentifier("dailySelectionStatus")
        }
    }
}
