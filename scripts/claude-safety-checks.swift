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
    var supportsSafety = true
    var policyVersion: Int? = ClaudePFPolicy.version
    var strictProof = true
    var helperBusy = false
    var busyReleaseAttempts = 0
    var events: [String] = []
    var gate: CheckedContinuation<Void, Never>?
    var pausePreflight = false

    func request(_ request: TunRequest) async throws -> TunReply {
        if request.operation == "releaseDisconnectProtection", busyReleaseAttempts > 0 {
            busyReleaseAttempts -= 1
            throw HelperRequestBusy()
        }
        if helperBusy { throw HelperRequestBusy() }
        if unavailable { throw ProxyError("模拟辅助服务失联") }
        if request.operation == "checkDisconnectProtection" {
            events.append("preflight")
            if pausePreflight { await withCheckedContinuation { gate = $0 } }
            if failPreflight { throw ProxyError("模拟企业防火墙不兼容") }
        }
        if request.operation == "releaseDisconnectProtection" {
            events.append("release")
            if failRelease { throw ProxyError("模拟解除保护失败") }
            armed = false
        }
        var reply = TunReply(ok: true, message: "隔离辅助服务", running: running)
        reply.supportsDisconnectProtection = true
        reply.supportsClaudeSafetyMode = supportsSafety
        reply.claudePFPolicyVersion = policyVersion
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
        dependencies.safetyMonitoringEnabled = false
        dependencies.safetyHelperRequest = { try await self.request($0) }
        dependencies.safetyStop = { self.events.append("stop"); self.running = false }
        dependencies.safetyStart = { state in
            self.events.append(state.protectsDisconnect ? "start-protected" : "start-original")
            self.armed = state.protectsDisconnect
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
            check(model.connection == .connected && fixture.events.last == "start-original", "恢复原先已连接状态")
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
            await model.setClaudeSafetyEnabled(false, releaseProtection: true)
            check(!model.claudeSafetyEnabled && model.connection == .disconnected, "恢复原先未连接状态")

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

        default: fatalError("未知隔离场景")
        }
        model.claudeSafetyMonitor?.cancel()
        print("PASS claude-safety \(scenario): \(checks) checks, kernelWrites=0")
    }
}
