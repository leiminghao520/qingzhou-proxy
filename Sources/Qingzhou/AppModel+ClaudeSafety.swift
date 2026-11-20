import Foundation
import AppKit
import QingzhouKit

extension AppModel {
    var claudeSafetyRecordURL: URL { directory.appendingPathComponent("claude-safety.json") }
    var claudeSafetyEnabled: Bool { claudeSafetyPreferences.session != nil }
    var claudeSafetyRetainsProtection: Bool { claudeSafetyEnabled || claudeSafetyLoadFailed }
    var claudeSafetyProxyEnabled: Bool { claudeSafetyEnabled && claudeSafetyPreferences.proxyPaused != true }
    var claudeSafetyCandidates: [Node] { ClaudeSafetyPolicy.candidates(in: state) }
    var claudeSafetyControlDisabled: Bool { locked || claudeSafetyChanging || claudeSafetyLoadFailed }
    var claudeSafetyStatus: String {
        if claudeSafetyChanging { return claudeSafetyTarget == true ? "正在开启…" : "正在关闭…" }
        if claudeSafetyLoadFailed { return "保护未确认 · 恢复记录无法读取" }
        guard claudeSafetyEnabled else { return "未开启 · 不提供 Claude 断线保护" }
        guard let protected = claudeSafetyProtection else { return "保护未确认 · 请勿使用 Claude" }
        guard protected else { return "保护未生效 · 当前允许直连" }
        guard let verifiedAt=claudeSafetyVerifiedAt, dependencies.now().timeIntervalSince(verifiedAt) >= 0, dependencies.now().timeIntervalSince(verifiedAt) < 15 else {
            return "保护未确认 · 核验证据已过期"
        }
        if connection == .connected && claudeSafetyHelperRunning && !coreFailed && !networkWaiting && !wakeRecovery.active {
            return connectivityHealth == .healthy ? (state.usesClaudeBypasses ? "公网固定代理，已允许网络绕过（\(state.enabledBypasses.count) 项）" : "保护已生效 · 整机仅经固定 VPS 联网") : "整机屏障已核验 · 代理链路待确认"
        }
        return claudeSafetyPreferences.proxyPaused == true ? "代理已关闭，整机保护保留" : "代理断线，已阻断公网"
    }

    func checkClaudeSafetyConfigurationChange() throws {
        guard !claudeSafetyLoadFailed, !claudeSafetyEnabled || claudeSafetyChanging else {
            throw ProxyError("请先明确解除整机保护，再修改配置；未改变安全出口")
        }
    }

    func receiveClaudeSafetyStatus(operation: String, reply: TunReply) {
        if operation == "status" {
            let supported = reply.supportsDisconnectProtection == true && (!claudeSafetyEnabled || reply.supportsClaudeSafetyMode == true && reply.claudePFPolicyVersion == ClaudePFPolicy.version)
            let bypassVerified = !state.usesClaudeBypasses || reply.claudeBypassPolicyVersion == ClaudeBypassPolicy.version && reply.claudeBypassMode == true
            let strictVerified = bypassVerified && (!claudeSafetyEnabled || reply.disconnectProtectionArmed == false || reply.claudeSafetyProtectionVerified == true)
            claudeSafetyProtection = reply.ok && supported && strictVerified ? reply.disconnectProtectionArmed : nil
            claudeSafetyVerifiedAt = claudeSafetyProtection == nil ? nil : dependencies.now()
            claudeSafetyHelperRunning = reply.ok && reply.running
        } else if ["releaseDisconnectProtection", "restoreNormalNetwork", "acknowledgeNormalRecovery"].contains(operation), reply.ok, reply.disconnectProtectionArmed == false {
            claudeSafetyProtection = false
            claudeSafetyHelperRunning = false
        } else {
            // 恢复记录存在不代表规则加载成功，只有辅助服务状态核验才能显示保护生效。
            claudeSafetyProtection = nil
        }
    }

    @discardableResult
    func refreshClaudeSafetyStatus() async -> Bool? {
        do {
            _ = try await capture.helperStatus()
            return claudeSafetyProtection
        } catch is HelperRequestBusy {
            // 请求尚未执行，不是核验失败；保留最近证据，由下一轮继续核验。
            return claudeSafetyProtection
        } catch {
            claudeSafetyProtection = nil
            claudeSafetyHelperRunning = false
            return nil
        }
    }

    func startClaudeSafetyMonitoring() {
        capture.claudeAllowsBypasses = { [weak self] in self?.state.usesClaudeBypasses == true }
        guard dependencies.safetyMonitoringEnabled, claudeSafetyEnabled || claudeSafetyLoadFailed else { return }
        claudeSafetyMonitor?.cancel()
        claudeSafetyMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.claudeSafetyEnabled || self.claudeSafetyLoadFailed else { return }
                // 已连接时复用原有生命周期监控，避免两套轮询争抢同一控制通道。
                if !self.busy && self.connection != .connected { await self.refreshClaudeSafetyStatus() }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }

    func setClaudeBypassesAllowed(_ allowed: Bool) {
        guard !claudeSafetyRetainsProtection, !claudeSafetyControlDisabled else { return }
        var preferences = claudeSafetyPreferences
        preferences.allowNetworkBypasses = allowed
        do { try saveClaudeSafetyPreferences(preferences) } catch { report(error) }
    }

    private func saveClaudeSafetyPreferences(_ value: ClaudeSafetyPreferences) throws {
        var preferences = value
        preferences.updatedAt = dependencies.now()
        try ClaudeSafetyStore.save(preferences, to: claudeSafetyRecordURL)
        claudeSafetyPreferences = preferences
    }

    private func recordClaudeSafetyFailure(_ error: Error) {
        guard claudeSafetyEnabled else { return }
        var preferences = claudeSafetyPreferences
        preferences.lastFailure = Redactor.redact(error.localizedDescription)
        do { try saveClaudeSafetyPreferences(preferences) }
        catch { log("保护失败原因写入未完成：" + Redactor.redact(error.localizedDescription)) }
    }

    private func preferredClaudeSafetyNode() -> UUID? {
        let candidates = claudeSafetyCandidates
        let actual = CoreAPIClient.actualTag(proxyInfo)
        if connection == .connected, let node = candidates.first(where: { PolicyReference.node($0.id).tag == actual }) { return node.id }
        if case .node(let id) = state.activePolicy, candidates.contains(where: { $0.id == id }) { return id }
        if let id = claudeSafetyPreferences.preferredNodeID, candidates.contains(where: { $0.id == id }) { return id }
        return candidates.count == 1 ? candidates.first?.id : nil
    }

    private func stopClaudeSafetyConnection() async throws {
        cancelWakeRecovery()
        cancelConnectionWait()
        userWantsConnection = false
        if let stop = dependencies.safetyStop {
            try await stop()
            connection = .disconnected
        } else {
            try await disconnectInternal(preserveExternal: true)
        }
    }

    private func startClaudeSafetyConnection(_ configuration: AppState) async throws {
        userWantsConnection = true
        connection = .connecting
        if let start = dependencies.safetyStart {
            try await start(configuration)
            connection = .connected
        } else {
            try await startService(configuration)
            guard capture.running, !coreFailed else { throw ProxyError("代理核心未保持运行") }
        }
    }

    func finishNormalNetworkRecovery(restored configuration: AppState? = nil) async throws {
        guard let store else { throw ProxyError("配置存储尚未就绪") }
        if let session = claudeSafetyPreferences.session, session.profileID != currentProfileID {
            throw ProxyError("恢复点所属配置不同，未覆盖当前配置")
        }
        var restored = configuration ?? claudeSafetyPreferences.session?.previous.restoring(state) ?? state
        restored.autoConnect = false
        if restored.claudeSafetyMode == true { restored.claudeSafetyMode = false }
        if restored.disconnectProtection == true { restored.disconnectProtection = false }
        try PolicyValidator.validate(restored)
        try store.commit(restored)
        state = store.state
        var preferences = claudeSafetyPreferences
        preferences.session = nil
        preferences.proxyPaused = nil
        preferences.policyVersion = nil
        if claudeSafetyLoadFailed, FileManager.default.fileExists(atPath: claudeSafetyRecordURL.path) {
            // 恢复网络允许退出损坏的保护会话，但须保留原始记录供排查。
            let archive = directory.appendingPathComponent("claude-safety.corrupt-" + UUID().uuidString + ".json")
            try SecureFile.write(Data(contentsOf: claudeSafetyRecordURL), to: archive)
        }
        try saveClaudeSafetyPreferences(preferences)
        claudeSafetyLoadFailed = false
        claudeSafetyProtection = false
        claudeSafetyHelperRunning = false
        claudeSafetyMonitor?.cancel()
        try await capture.acknowledgeNormalRecovery()
        connection = .disconnected
        recoveryPending = false
        if let warning = capture.normalRecoveryWarning { log(warning); helperStatus = warning }
    }

    func setClaudeSafetyEnabled(_ enabled: Bool, nodeID: UUID? = nil, releaseProtection: Bool = false) async {
        guard !claudeSafetyControlDisabled, let store else { return }
        guard !enabled || !claudeApplicationRunning else {
            errorMessage = "Claude 专用代理运行中，不能同时开启旧版整机保护"
            return
        }
        if !releaseProtection {
            if !enabled, claudeSafetyEnabled {
                claudeSafetyChanging = true
                claudeSafetyTarget = false
                busy = true
                defer { claudeSafetyChanging = false; claudeSafetyTarget = nil; busy = false }
                do {
                    try await stopClaudeSafetyConnection()
                    var preferences = claudeSafetyPreferences
                    preferences.proxyPaused = true
                    try saveClaudeSafetyPreferences(preferences)
                    _ = await refreshClaudeSafetyStatus()
                } catch { recordClaudeSafetyFailure(error); report(error) }
                return
            }
            if enabled, let session = claudeSafetyPreferences.session {
                claudeSafetyChanging = true
                claudeSafetyTarget = true
                busy = true
                defer { claudeSafetyChanging = false; claudeSafetyTarget = nil; busy = false }
                do {
                    let configured = try ClaudeSafetyPolicy.configuration(state, nodeID: session.nodeID, allowNetworkBypasses: state.usesClaudeBypasses)
                    try await capture.checkDisconnectProtection(requireClaudeSafetyMode: true, requireBypasses: configured.usesClaudeBypasses)
                    try await stopClaudeSafetyConnection()
                    try store.commit(configured)
                    state = store.state
                    try await startClaudeSafetyConnection(configured)
                    var preferences = claudeSafetyPreferences
                    preferences.proxyPaused = false
                    preferences.policyVersion = ClaudePFPolicy.version
                    preferences.operationID = UUID()
                    preferences.lastFailure = nil
                    try saveClaudeSafetyPreferences(preferences)
                    guard await refreshClaudeSafetyStatus() == true else { throw ProxyError("整机屏障核验未通过，请勿使用 Claude") }
                } catch { recordClaudeSafetyFailure(error); report(error) }
                return
            }
            guard enabled else { return }
        }
        if enabled && recoveryPending {
            report(ProxyError("请先恢复并核对上次网络接管，再开启 Claude 安全模式"))
            return
        }
        let selectedNode = nodeID ?? preferredClaudeSafetyNode()
        if enabled && selectedNode == nil {
            guard !claudeSafetyCandidates.isEmpty else {
                report(ProxyError("没有可用的固定公网 IP 节点，请先添加节点"))
                return
            }
            claudeSafetyChoosingNode = true
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            return
        }
        claudeSafetyChoosingNode = false
        claudeSafetyTarget = enabled
        claudeSafetyChanging = true
        busy = true
        defer {
            claudeSafetyChanging = false
            claudeSafetyTarget = nil
            busy = false
            startClaudeSafetyMonitoring()
        }
        do {
            if enabled, let selectedNode {
                let configured = try ClaudeSafetyPolicy.configuration(state, nodeID: selectedNode, allowNetworkBypasses: claudeSafetyPreferences.allowNetworkBypasses == true)
                try await capture.checkDisconnectProtection(requireClaudeSafetyMode: true, requireBypasses: configured.usesClaudeBypasses)
                var preferences = claudeSafetyPreferences
                let session = ClaudeSafetySession(state: state, profileID: currentProfileID,
                                                 wasConnected: connection == .connected, nodeID: selectedNode)
                preferences.preferredNodeID = selectedNode
                preferences.session = session
                preferences.proxyPaused = false
                preferences.policyVersion = ClaudePFPolicy.version
                preferences.operationID = UUID()
                preferences.lastFailure = nil
                // 先持久保存恢复点，再停止旧连接；崩溃后也能通过同一个开关还原。
                try saveClaudeSafetyPreferences(preferences)
                try await stopClaudeSafetyConnection()
                try store.commit(configured)
                state = store.state
                try await startClaudeSafetyConnection(configured)
                guard await refreshClaudeSafetyStatus() == true else {
                    throw ProxyError("代理已尝试连接，但防火墙保护尚未通过核验")
                }
                errorMessage = nil
                log("Claude 安全模式已开启，固定出口与断线保护核验通过")
            } else if let session = claudeSafetyPreferences.session {
                guard session.profileID == currentProfileID else {
                    throw ProxyError("当前配置与安全模式恢复点不同，未覆盖配置或解除保护")
                }
                var restored = session.previous.restoring(state)
                restored.autoConnect = false
                try PolicyValidator.validate(restored)
                cancelWakeRecovery(); cancelConnectionWait(); userWantsConnection = false
                claudeSafetyMonitor?.cancel()
                try await capture.restoreNormalNetwork()
                try await finishNormalNetworkRecovery(restored: restored)
                errorMessage = nil
                log("Claude 安全模式已关闭，原网络设置已恢复；代理保持停止、自动连接已关闭")
            }
        } catch {
            recordClaudeSafetyFailure(error)
            let detail = error.localizedDescription
            // 不走普通配置事务的自动回退，避免保护已建立后失败又启动普通出口。
            if claudeSafetyEnabled {
                let protected = await refreshClaudeSafetyStatus()
                if connection == .connecting { connection = .error }
                report(ProxyError(detail + (protected == true ? "；断线保护已保留，可重连或明确解除保护" : "；保护未确认，请勿使用 Claude，可通过解除保护入口恢复原设置")))
            } else {
                report(error)
            }
        }
    }
}
