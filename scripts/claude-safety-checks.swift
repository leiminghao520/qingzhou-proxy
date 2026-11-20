import Foundation
import AppKit
import QingzhouKit

@MainActor final class SafetyFixture {
    var armed = false
    var running = false
    var unavailable = false
    var failPreflight = false
    var failStart = false
    var failRelease = false
    var failRecoveryAcknowledgment = false
    var allowRescue = false
    var failRescueAcknowledgment = false
    var supportsRecovery = true
    var supportsSafety = true
    var policyVersion: Int? = ClaudePFPolicy.version
    var strictProof = true
    var bypassVersion: Int? = ClaudeBypassPolicy.version
    var bypassMode = false
    var helperBusy = false
    var busyReleaseAttempts = 0
    var events: [String] = []
    var gate: CheckedContinuation<Void, Never>?
    var pausePreflight = false

    func request(_ request: TunRequest) async throws -> TunReply {
        if ["releaseDisconnectProtection", "restoreNormalNetwork"].contains(request.operation), busyReleaseAttempts > 0 {
            busyReleaseAttempts -= 1
            throw HelperRequestBusy()
        }
        if request.operation == "acknowledgeNormalRecovery", failRecoveryAcknowledgment { throw ProxyError("配置恢复确认响应丢失") }
        if helperBusy { throw HelperRequestBusy() }
        if unavailable { throw ProxyError("模拟辅助服务失联") }
        if request.operation == "checkDisconnectProtection" {
            events.append("preflight")
            if pausePreflight { await withCheckedContinuation { gate = $0 } }
            if failPreflight { throw ProxyError("模拟企业防火墙不兼容") }
        }
        if ["releaseDisconnectProtection", "restoreNormalNetwork"].contains(request.operation) {
            events.append("release")
            if failRelease { throw ProxyError("模拟解除保护失败") }
            armed = false
            running = false
        }
        var reply = TunReply(ok: true, message: "隔离辅助服务", running: running)
        reply.supportsNormalNetworkRecovery = supportsRecovery
        reply.normalNetworkRecoveryPhase = request.operation == "restoreNormalNetwork" ? "normalRecoveryCompleted" : nil
        reply.supportsDisconnectProtection = true
        reply.supportsClaudeSafetyMode = supportsSafety
        reply.claudePFPolicyVersion = policyVersion
        reply.claudeBypassPolicyVersion = bypassVersion
        reply.claudeBypassMode = bypassMode
        reply.disconnectProtectionArmed = armed
        if request.claudeSafetyEndpoint != nil { reply.claudeSafetyProtectionVerified = armed && strictProof }
        return reply
    }

    func dependencies() -> AppDependencies {
        var dependencies = AppDependencies()
        dependencies.makeCredentials = { _ in
            let credentials = MemoryCredentials()
            try! credentials.set(Data(repeating: 7, count: 32).base64EncodedString(), for: "qingzhou.profile-history.key.v1")
            return credentials
        }
        dependencies.normalRecoveryTool = { acknowledge in
            guard self.allowRescue else { throw ProxyError("模拟管理员恢复不可用") }
            self.events.append(acknowledge ? "rescue-acknowledge" : "rescue")
            if acknowledge && self.failRescueAcknowledgment { throw ProxyError("模拟管理员确认失败") }
            self.armed = false
            self.running = false
        }
        dependencies.safetyMonitoringEnabled = false
        dependencies.safetyHelperRequest = { try await self.request($0) }
        dependencies.safetyStop = { self.events.append("stop"); self.running = false }
        dependencies.safetyStart = { state in
            self.events.append(state.protectsDisconnect ? "start-protected" : "start-original")
            self.armed = state.protectsDisconnect
            self.bypassMode = state.usesClaudeBypasses
            if self.failStart { throw ProxyError("模拟代理连接失败") }
            self.running = true
        }
        dependencies.makeStore = { file, credentials in
            let exists = FileManager.default.fileExists(atPath: file.path)
            let store = try NodeStore(file: file, credentials: credentials)
            if !exists {
                var state = AppState()
                let node = Node(name: "隔离固定节点", kind: .hysteria2, server: "203.0.113.10", port: 443)
                state.nodes = [node]
                state.selectedPolicy = .node(node.id)
                state.selectedID = node.id
                state.mode = .rule
                state.captureMode = .systemProxy
                state.dnsPreference = .system
                state.httpCompatibilityEnabled = true
                try credentials.set("fixture", for: node.credentialRef)
                try store.commit(state)
            }
            for node in store.state.nodes { try credentials.set("fixture", for: node.credentialRef) }
            return store
        }
        return dependencies
    }
}

@main struct ClaudeSafetyChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { fatalError(message) }
        }
        func rejects(_ operation: () throws -> Void, _ message: String) {
            do { try operation(); check(false, message) } catch { check(true, message) }
        }
        let arguments = CommandLine.arguments
        let scenario = arguments[arguments.firstIndex(of: "--scenario")! + 1]
        let fixture = SafetyFixture()
        let dependencies = fixture.dependencies()
        let model = AppModel(dependencies: dependencies)
        check(!model.loadingFailed, "隔离配置加载成功")
        let nodeID = model.state.nodes[0].id
        let original = ClaudeSafetyNetworkSettings(model.state)
        let menu = MenuPresentation(model: model)

        switch scenario {
        case "bypass-old-helper":
            fixture.bypassVersion = nil
            model.setClaudeBypassesAllowed(true)
            model.connection = .connected
            fixture.running = true
            await model.setClaudeSafetyEnabled(true)
            check(!model.claudeSafetyEnabled, "旧服务不能启动绕过兼容会话")
            check(fixture.events.isEmpty && fixture.running, "能力检查失败不停止原连接")
            check(model.errorMessage?.contains("更新辅助服务") == true, "指出需要更新服务")
        case "bypass-happy":
            check(model.claudeSafetyPreferences.allowNetworkBypasses != true, "新选项默认关闭")
            model.setClaudeBypassesAllowed(true)
            check(try ClaudeSafetyStore.load(from: model.claudeSafetyRecordURL).allowNetworkBypasses == true, "偏好独立持久化")
            await model.setClaudeSafetyEnabled(true)
            check(model.state.usesClaudeBypasses && fixture.bypassMode, "新会话显式启用绕过")
            model.setClaudeBypassesAllowed(false)
            check(model.claudeSafetyPreferences.allowNetworkBypasses == true, "活动会话不能更换保护范围")
            _ = await model.refreshClaudeSafetyStatus()
            check(model.claudeSafetyProtection == true, "状态要求兼容策略证明")
            fixture.bypassMode = false
            _ = await model.refreshClaudeSafetyStatus()
            check(model.claudeSafetyProtection == nil, "模式不匹配不得确认保护")
            fixture.bypassMode = true
            await model.setClaudeSafetyEnabled(false)
            check(model.claudeSafetyEnabled && model.claudeSafetyPreferences.proxyPaused == true, "暂停保留保护会话")
            await model.setClaudeSafetyEnabled(true)
            check(model.state.usesClaudeBypasses, "暂停后重连保留用户选择")
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            check(!model.claudeSafetyEnabled && !model.state.usesClaudeBypasses, "明确解除后恢复原配置")
        case "filter-preflight":
            model.connection = .connected
            fixture.running = true
            fixture.supportsSafety = false
            await model.setClaudeSafetyEnabled(true)
            check(!model.claudeSafetyEnabled, "正式严格 PF发布门槛失败不能建立旧版 PF 会话")
            check(fixture.events.isEmpty, "严格 PF预检失败不能停止代理或改防火墙")
            check(model.connection == .connected && fixture.running, "严格 PF预检失败保留原连接")
            check(model.errorMessage?.contains("辅助服务") == true, "展示真实发布阻碍")
            check(!FileManager.default.fileExists(atPath: model.claudeSafetyRecordURL.path), "严格 PF预检失败不写入恢复点")

        case "old-helper":
            fixture.policyVersion = nil
            model.connection = .connected
            fixture.running = true
            await model.setClaudeSafetyEnabled(true)
            check(!model.claudeSafetyEnabled && fixture.events.isEmpty, "旧版仅地址限制的服务不能冒充端口及协议保护")
            check(model.connection == .connected && fixture.running, "旧版预检拒绝不影响原连接")

        case "happy":
            check(!model.claudeSafetyEnabled && model.claudeSafetyStatus.contains("未开启"), "默认关闭")
            model.connection = .connected
            fixture.running = true
            await model.setClaudeSafetyEnabled(true)
            check(model.claudeSafetyEnabled && model.state.protectsDisconnect, "一键开启并保存保护配置")
            check(model.state.captureMode == .compatible && model.state.mode == .global, "启用完整接管和全局代理")
            check(model.state.strictDNS == true && model.state.dnsPreference == .httpsProxy && !model.state.httpCompatibilityEnabled, "DNS 严格且关闭兼容模式")
            check(model.claudeSafetyStatus == "整机屏障已核验 · 代理链路待确认", "旧版 PF 不冒充应用级保护")
            fixture.helperBusy = true
            for _ in 0..<20 { await model.refreshClaudeSafetyStatus() }
            check(model.claudeSafetyStatus == "整机屏障已核验 · 代理链路待确认", "控制通道忙不伪造核验失败或造成状态横跳")
            fixture.helperBusy = false
            model.claudeSafetyVerifiedAt = Date(timeIntervalSinceNow: -20)
            check(model.claudeSafetyStatus.contains("证据已过期"), "持续无法核验不能无限保留安全状态")
            await model.refreshClaudeSafetyStatus()
            check(fixture.events == ["preflight", "stop", "start-protected"], "预检在变更之前完成")
            menu.refresh()
            check(menu.revision.contains(model.claudeSafetyStatus), "菜单投影包含与首页相同的完整保护状态")
            let record = try ClaudeSafetyStore.load(from: model.claudeSafetyRecordURL)
            check(record.session?.wasConnected == true && record.preferredNodeID == nodeID, "恢复点和安全节点已持久保存")
            let permissions = try FileManager.default.attributesOfItem(atPath: model.claudeSafetyRecordURL.path)[.posixPermissions] as! NSNumber
            check(permissions.intValue & 0o077 == 0, "恢复记录仅当前用户可读写")
            rejects({ try model.persist(model.state) }, "普通保存不能绕过安全模式")
            let tx = model.store!.prepareChange(model.state)
            do { try await model.apply(tx); check(false, "普通配置事务不能绕过保护") } catch { check(true, "配置事务被拒绝") }
            await model.selectPolicy(.automatic)
            check(model.state.activePolicy == .node(nodeID), "自动选节点不能改变安全出口")
            await model.setCaptureMode(.systemProxy)
            check(model.state.captureMode == .compatible, "不能降级为系统代理")
            model.coreFailed = true
            check(model.claudeSafetyStatus == "代理断线，已阻断公网", "核心退出时显示阻断")
            model.coreFailed = false
            model.networkWaiting = true
            check(model.claudeSafetyStatus.contains("已阻断公网"), "等待网络恢复时不显示正常")
            model.networkWaiting = false
            fixture.unavailable = true
            await model.refreshClaudeSafetyStatus()
            check(model.claudeSafetyProtection == nil && model.claudeSafetyStatus.contains("未确认"), "辅助服务失联不沿用旧的安全标记")
            fixture.unavailable = false
            fixture.strictProof = false
            await model.refreshClaudeSafetyStatus()
            check(model.claudeSafetyStatus.contains("未确认"), "旧会话宽泛规则不能冒充严格保护")
            fixture.strictProof = true
            fixture.armed = false
            await model.refreshClaudeSafetyStatus()
            check(model.claudeSafetyStatus.contains("保护未生效"), "手动解除后不显示已保护")
            fixture.armed = true
            await model.refreshClaudeSafetyStatus()
            await model.setClaudeSafetyEnabled(false)
            check(model.claudeSafetyEnabled && fixture.armed && !fixture.running, "关闭开关保留整机保护")
            check(!model.claudeSafetyProxyEnabled && model.claudeSafetyStatus.contains("保护保留"), "暂停状态首页菜单一致")
            check(try ClaudeSafetyStore.load(from: model.claudeSafetyRecordURL).proxyPaused == true, "暂停意图持久化")
            await model.setClaudeSafetyEnabled(true)
            check(model.claudeSafetyProxyEnabled && fixture.running && fixture.armed, "同一开关恢复固定代理")
            fixture.busyReleaseAttempts = 3
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            check(fixture.busyReleaseAttempts == 0, "关闭等待未完成的只读核验，不因通道忙留下阻断")
            check(!model.claudeSafetyEnabled && !fixture.armed, "一键关闭并解除防火墙")
            check(model.connection == .disconnected && !fixture.running && !model.state.autoConnect, "恢复后保持停止并关闭自动连接")
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            check(try encoder.encode(ClaudeSafetyNetworkSettings(model.state)) == encoder.encode(original), "逐项恢复原网络设置")
            check(try ClaudeSafetyStore.load(from: model.claudeSafetyRecordURL).session == nil, "关闭后清除恢复点并保留偏好")
            let restored = original.restoring(model.state)
            check(restored.nodes.count == model.state.nodes.count, "恢复不删除节点")
            var invalid = model.state
            invalid.nodes[0].server = "proxy.example.com"
            rejects({ _ = try ClaudeSafetyPolicy.configuration(invalid, nodeID: nodeID) }, "域名节点不能用于安全模式")
            invalid = model.state
            invalid.nodes[0].parameters["insecure"] = "1"
            check(ClaudeSafetyPolicy.candidates(in: invalid).isEmpty, "不使用关闭证书校验的节点")
            var protected = try ClaudeSafetyPolicy.configuration(model.state, nodeID: nodeID)
            let session = ClaudeSafetySession(state: model.state, profileID: model.currentProfileID, wasConnected: false, nodeID: nodeID)
            protected.strictDNS = false
            rejects({ try ClaudeSafetyPolicy.validateActive(protected, session: session) }, "严格 DNS 不能被关闭")
            protected = try ClaudeSafetyPolicy.configuration(model.state, nodeID: nodeID)
            let snapshot = NetworkSnapshot(primaryInterface: "en0", routes: [], resolvers: [DNSResolverScope(service: "fixture", interface: "en0", servers: ["192.168.1.1"], defaultResolver: true)])
            var plan = try CapturePlan.make(snapshot: snapshot, extraCIDRs: [], extraDomains: [])
            plan.protectedRoutes = [ProtectedRoute(destination: "198.51.100.0/24", gateway: "10.0.0.1", interface: "utun7")]
            let allowed = try DisconnectProtectionPolicy.allowedDestinations(state: protected, plan: plan)
            check(!allowed.contains("198.51.100.0/24") && allowed.contains("10.0.0.0/8"), "只保留内网例外，不放行公司公网出口")
            let rules = try DisconnectProtectionPolicy.rules(allowed: allowed, tunnel: nil)
            check(rules.contains("quick inet from") && rules.contains("quick inet6 from"), "断线时同时拒绝 IPv4 和 IPv6 公网")
            protected.disconnectProtection = false
            rejects({ try PolicyValidator.validate(protected) }, "安全模式标识不能与关闭断线保护组合保存")

        case "failures":
            fixture.supportsSafety = false
            await model.setClaudeSafetyEnabled(true)
            check(!model.claudeSafetyEnabled && fixture.events.isEmpty, "旧辅助服务不能被误判为支持严格安全模式")
            fixture.supportsSafety = true
            fixture.failPreflight = true
            await model.setClaudeSafetyEnabled(true)
            check(!model.claudeSafetyEnabled && model.state.captureMode == .systemProxy, "预检失败不改原配置")
            check(fixture.events == ["preflight"], "预检失败不停止原连接")
            fixture.failPreflight = false
            fixture.failStart = true
            await model.setClaudeSafetyEnabled(true)
            check(model.claudeSafetyEnabled && fixture.armed, "启动失败仍保留保护")
            check(!fixture.events.contains("start-original"), "保护后失败不回退普通出口")
            check(model.connection == .error && model.claudeSafetyStatus.contains("已阻断公网"), "连接失败显示公网阻断")
            check(try ClaudeSafetyStore.load(from: model.claudeSafetyRecordURL).session != nil, "失败后保留恢复点")
            fixture.failRelease = true
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            check(model.claudeSafetyEnabled && fixture.armed, "解除失败不能清除安全状态和记录")
            fixture.failRelease = false
            fixture.failStart = false
            fixture.unavailable = true
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            check(model.claudeSafetyEnabled, "状态不可读时不能宣称解除成功")
            fixture.unavailable = false
            fixture.supportsRecovery = false
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            check(model.claudeSafetyEnabled && fixture.armed, "旧维护能力不能冒充独立恢复")
            fixture.supportsRecovery = true
            fixture.failRecoveryAcknowledgment = true
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            check(!fixture.armed && !fixture.running && !model.state.autoConnect, "确认失败仍保持普通网络和停止状态")
            check(!model.claudeSafetyEnabled, "配置已提交后确认失败不重新进入保护")
            fixture.failRecoveryAcknowledgment = false
            try await model.finishNormalNetworkRecovery()
            check(!model.claudeSafetyEnabled && model.connection == .disconnected, "配置确认可安全重试")

        case "normal-recovery":
            await model.setClaudeSafetyEnabled(true)
            check(fixture.armed, "准备已启用保护的故障场景")
            model.runtimeState = model.state
            await model.recover()
            while model.recovering { await Task.yield() }
            check(!fixture.armed && !fixture.running, "恢复网络必须停止代理并解除公网阻断")
            check(!model.claudeSafetyEnabled && !model.state.autoConnect, "恢复网络清除保护会话并关闭自动连接")
            check(model.connection == .disconnected && !model.recoveryPending, "恢复核验通过后才完成")
            check(!fixture.events.contains("start-original"), "恢复网络不能启动另一条代理连接")
            check(model.runtimeState == nil && model.effectiveState.captureMode == .systemProxy, "恢复后清除旧运行配置，不再显示旧保护接管")

        case "normal-recovery-fallback":
            await model.setClaudeSafetyEnabled(true)
            fixture.unavailable = true
            fixture.allowRescue = true
            fixture.failRescueAcknowledgment = true
            await model.recover()
            while model.recovering { await Task.yield() }
            check(!fixture.armed && !fixture.running, "辅助服务失联仍可通过独立恢复器解除阻断")
            check(!model.claudeSafetyEnabled && !model.state.autoConnect, "独立恢复确认失败也不能再次接管网络")
            check(model.recoveryPending, "确认失败保留待处理状态")
            fixture.failRescueAcknowledgment = false
            await model.recover()
            while model.recovering { await Task.yield() }
            check(!model.recoveryPending && model.connection == .disconnected, "独立恢复与确认可重试")
            check(fixture.events.filter { $0 == "rescue" }.count == 2 && fixture.events.contains("rescue-acknowledge"), "失联恢复不依赖原通道")
            check(model.helperStatus.contains("停用"), "保留辅助服务停用的实际结果")

        case "normal-recovery-loading-failed":
            model.loadingFailed = true
            await model.recover()
            while model.recovering { await Task.yield() }
            check(model.connection == .disconnected && !model.recoveryPending, "配置界面故障不能阻塞网络清理入口")

        case "picker":
            var state = model.state
            let additional = Node(name: "另一个固定节点", kind: .hysteria2, server: "203.0.113.11", port: 443)
            try model.credentials.set("fixture", for: additional.credentialRef)
            state.nodes.append(additional)
            state.selectedPolicy = .automatic
            try model.persist(state)
            await model.setClaudeSafetyEnabled(true)
            check(model.claudeSafetyChoosingNode && !model.claudeSafetyEnabled && fixture.events.isEmpty, "无法确定节点时只选择一次")
            await model.setClaudeSafetyEnabled(true, nodeID: nodeID)
            check(model.claudeSafetyEnabled && !model.claudeSafetyChoosingNode, "选定后开启并关闭选择窗口")
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            await model.setClaudeSafetyEnabled(true)
            check(model.claudeSafetyEnabled && !model.claudeSafetyChoosingNode, "下次沿用已记住的安全节点")

        case "concurrent":
            fixture.pausePreflight = true
            let first = Task { await model.setClaudeSafetyEnabled(true) }
            while fixture.gate == nil { await Task.yield() }
            check(model.claudeSafetyControlDisabled && model.claudeSafetyStatus == "正在开启…", "应用中显示进度并锁定开关")
            await model.setClaudeSafetyEnabled(true)
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            check(fixture.events == ["preflight"], "快速重复点击不启动第二个事务")
            fixture.gate?.resume()
            await first.value
            check(model.claudeSafetyEnabled && !model.claudeSafetyChanging, "唯一事务完成后释放操作锁")

        case "restart-save":
            fixture.failStart = true
            await model.setClaudeSafetyEnabled(true)
            check(model.claudeSafetyEnabled && model.state.protectsDisconnect, "新进程可恢复的配置已落盘")

        case "restart-restore":
            fixture.armed = true
            check(model.claudeSafetyEnabled && model.state.protectsDisconnect, "重启后加载未完成会话")
            check(model.claudeSafetyProtection == nil, "重启不根据磁盘记录伪造保护生效")
            await model.refreshClaudeSafetyStatus()
            check(model.claudeSafetyStatus.contains("已阻断公网"), "重新核验内核保护状态")
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            check(!model.claudeSafetyEnabled && model.state.captureMode == .systemProxy && model.state.dnsPreference == .system, "新进程一键恢复原网络设置")

        case "corrupt":
            check(model.claudeSafetyLoadFailed && model.claudeSafetyControlDisabled, "损坏记录不静默覆盖")
            rejects({ try model.persist(model.state) }, "损坏记录时禁止修改网络配置")
            await model.connect()
            check(fixture.events.isEmpty && model.connection == .disconnected, "损坏记录时不建立普通连接")
            await model.recover()
            while model.recovering { await Task.yield() }
            check(!model.claudeSafetyLoadFailed && !model.claudeSafetyEnabled, "损坏保护记录不阻塞明确恢复网络")
            let files = try FileManager.default.contentsOfDirectory(atPath: model.directory.path)
            check(files.contains { $0.hasPrefix("claude-safety.corrupt-") }, "损坏保护记录在清理前归档")

        default: fatalError("未知隔离场景")
        }
        model.claudeSafetyMonitor?.cancel()
        print("PASS claude-safety \(scenario): \(checks) checks, kernelWrites=0")
    }
}
