import Foundation
import QingzhouKit

final class ClaudeBypassFixtureBackend: RouteBackend {
    func snapshot() throws -> NetworkRouteSample { fatalError("夹具不读取真实网络") }
    func lookup(_ destination: String, ipv6: Bool, scope: String?, deadline: Date?) throws -> RouteRecord { fatalError("夹具不读取真实网络") }
    func write(_ operation: NetworkInspection.RouteOperation, route: ProtectedRoute, legacy: Bool, deadline: Date?) throws -> RouteWriteResult { fatalError("夹具禁止写系统路由") }
}

@main struct ClaudeBypassHelperChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool) rethrows {
            count += 1
            if try !condition() { fatalError("网络绕过辅助服务断言失败：\(count)") }
        }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); fatalError("必须拒绝该操作") } catch { count += 1 }
        }
        if CommandLine.arguments.contains("--inspect-local-yunshu") {
            let endpoints = try YunshuConnections.endpoints()
            print("READONLY_YUNSHU_SIGNATURE_AND_SOCKET_CHECK endpoints=\(endpoints.count) networkWrites=0")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = Service(fixtureRoot: root, backend: ClaudeBypassFixtureBackend())
        service.yunshuPathValidate = { _ in false }
        var loadedRules = ""
        var failLoad = false
        var commands: [[String]] = []
        service.firewallCommand = { args in
            commands.append(args)
            if args == ["-sr"] { return "anchor \"com.apple/*\" all\n" }
            if args == ["-a", "com.apple", "-s", "Anchors"] { return "" }
            if args == ["-si"] { return "Status: Enabled" }
            if args == ["-E"] { return "Token : 1234" }
            if args.first == "-n" || args.first == "-k" { return "" }
            if args.count == 3 && args.last == "-sr" { return loadedRules }
            if args.count == 4 && args[2] == "-f" {
                if failLoad { throw ProxyError("注入 PF 加载失败") }
                loadedRules = try String(contentsOfFile: args[3], encoding: .utf8)
                return ""
            }
            throw ProxyError("夹具拒绝其他命令")
        }
        let node = Node(name: "隔离节点", kind: .trojan, server: "43.163.70.144", port: 443)
        var state = AppState()
        state.nodes = [node]
        try state.setBypasses([NetworkBypass(kind: .suffix, value: "tongdun.cn")])
        state = try ClaudeSafetyPolicy.configuration(state, nodeID: node.id, allowNetworkBypasses: true)
        let resolver = DNSResolverScope(service: "corp", interface: "utun6", servers: ["10.1.0.1"], domains: ["tongdun.cn"])
        let routes = [ProtectedRoute(destination: "0.0.0.0/0", gateway: "192.168.5.1", interface: "en0"),
                      ProtectedRoute(destination: "198.19.0.0/16", gateway: "10.251.1.1", interface: "utun6")]
        let plan = try CapturePlan.make(snapshot: NetworkSnapshot(primaryInterface: "en0", routes: routes, resolvers: [resolver]), state: state)
        try service.disconnectFirewall.armStrict(endpoint: ClaudePFPolicy.endpoint(node), exceptions: ClaudeBypassPolicy.initialExceptions(state: state, plan: plan))
        func publish(_ name: String, _ addresses: [String], deadline: Date = Date().addingTimeInterval(5)) throws {
            try service.publishClaudeBypassAnswers(state: state, plan: plan, name: name, addresses: addresses, resolver: resolver, deadline: deadline)
        }
        try publish("fort-d.tongdun.cn", ["198.19.0.1"])
        check(loadedRules.contains("198.19.0.1/32"))
        check(service.claudeAnswerExceptions["fort-d.tongdun.cn|1"]?.count == 1)
        try publish("fort-d.tongdun.cn", ["198.19.0.2"])
        check(!loadedRules.contains("198.19.0.1/32"))
        check(commands.contains(["-k", "0.0.0.0/0", "-k", "198.19.0.1/32"]))
        try publish("other.tongdun.cn", ["198.19.0.3"])
        check(loadedRules.contains("198.19.0.2/32") && loadedRules.contains("198.19.0.3/32"))
        rejects { try publish("outside.example", ["203.0.113.1"]) }
        rejects { try publish("fort-d.tongdun.cn", ["198.19.0.4"], deadline: Date.distantPast) }
        try service.publishClaudeBypassAnswers(state: state, plan: plan, name: "fort-d.tongdun.cn", addresses: [], resolver: resolver, deadline: Date().addingTimeInterval(5), queryType: 28)
        check(loadedRules.contains("198.19.0.2/32"))
        failLoad = true
        rejects { try publish("fort-d.tongdun.cn", ["198.19.0.4"]) }
        check(service.claudeAnswerExceptions["fort-d.tongdun.cn|1"]?.first?.destination == "198.19.0.2/32")
        try check(!service.disconnectFirewall.verifyStrict(endpoint: ClaudePFPolicy.endpoint(node), allowsBypasses: true))
        failLoad = false
        try service.publishClaudeBypassAnswers(state: state, plan: plan, name: "fort-d.tongdun.cn", addresses: [], resolver: resolver, deadline: Date().addingTimeInterval(5), queryType: 28, nameExists: false)
        check(!loadedRules.contains("198.19.0.2/32") && loadedRules.contains("198.19.0.3/32"))
        try service.disconnectFirewall.revokeBypassExceptions()
        check(service.disconnectFirewall.bypassExceptionCount == 0)
        var dummyConfig: [String: Any] = ["route": ["rules": [["action": "sniff"]]], "outbounds": [] as [[String: Any]]]
        let runtime = try YunshuConnectionPolicy.runtime(state, installed: true)
        var cloudPlan = try CapturePlan.make(snapshot: NetworkSnapshot(primaryInterface: "en0", routes: routes,
            resolvers: [resolver, DNSResolverScope(service: "wifi", interface: "en0", servers: ["192.168.5.1"], defaultResolver: true)]), state: runtime)
        cloudPlan.yunshuControlDomains = YunshuConnectionPolicy.domains
        service.yunshuEndpointsRead = { [.init(address: "203.0.113.20", port: 8443, transport: .udp)] }
        var resolutions: [String] = []
        service.yunshuBootstrapResolve = { name, type, _ in
            resolutions.append(name)
            if type == 28 { return [] }
            return [name.hasPrefix("mqtt.") ? "203.0.113.22" : "203.0.113.21"]
        }
        let controls = try service.prepareYunshuConnections(state: runtime, plan: cloudPlan)
        check(resolutions.count == 6)
        check(controls.contains { $0.destination == "203.0.113.20/32" && $0.controlPort == 8443 && $0.controlTransport == .udp })
        check(controls.contains { $0.destination == "192.168.5.1/32" && $0.dnsOnly && $0.vpnControl == true })
        check(controls.allSatisfy { $0.interface == "en0" })
        service.yunshuControlExceptions = controls
        try service.disconnectFirewall.updateBypassExceptions(controls)
        try service.disconnectFirewall.revokeBypassExceptions()
        check(service.disconnectFirewall.vpnControlExceptions == controls)
        try service.configureYunshuControlRules(&dummyConfig, exceptions: controls, interface: "en0")
        let controlFile = root.appendingPathComponent("yunshu-control-rules.json")
        let controlJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: controlFile)) as! [String: Any]
        check((controlJSON["rules"] as! [[String: Any]]).allSatisfy { $0["port"] != nil && $0["network"] != nil })
        service.yunshuBootstrapResolve = { _, _, _ in throw ProxyError("注入原 DNS 超时") }
        rejects { _ = try service.prepareYunshuConnections(state: runtime, plan: cloudPlan) }
        service.yunshuRuntimeState = runtime
        service.yunshuSnapshotRead = { throw ProxyError("注入网卡消失") }
        service.refreshYunshuConnections()
        check(service.disconnectFirewall.vpnControlExceptions.isEmpty)
        check(service.disconnectFirewall.armed)
        check(service.lastFailure?.contains("云枢控制面") == true)
        service.yunshuSnapshotRead = { cloudPlan.snapshot }
        service.yunshuBootstrapResolve = { _, type, _ in type == 1 ? ["203.0.113.21"] : [] }
        service.refreshYunshuConnections()
        check(!service.disconnectFirewall.vpnControlExceptions.isEmpty)
        service.yunshuBootstrapResolve = nil
        var originalInterfaceQueries = 0
        service.yunshuBootstrapTransport = { query, server, interface in
            if server != "192.168.5.1" || interface != "en0" { fatalError("引导不能使用企业隧道 DNS") }
            originalInterfaceQueries += 1
            var response = query
            response[2] |= 0x80
            if DNSPacket.queryType(query) == 1 {
                response[7] = 1
                response.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 25])
            }
            return response
        }
        _ = try service.prepareYunshuConnections(state: runtime, plan: cloudPlan)
        check(originalInterfaceQueries == 6)
        try service.saveYunshuContext(runtime)
        service.yunshuRuntimeState = nil
        try service.restoreYunshuMonitor()
        check(service.yunshuRuntimeState?.usesClaudeBypasses == true)
        check(service.yunshuRuntimeState?.nodes.isEmpty == true)
        service.yunshuMonitor?.cancel()
        service.yunshuMonitor = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("yunshu-control-context.json").path)
        rejects { try service.restoreYunshuMonitor() }
        service.yunshuPathValidate = { _ in true }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var firstQuery = true
        service.yunshuBootstrapResolve = { _, type, _ in
            if firstQuery { firstQuery = false; started.signal(); release.wait() }
            return type == 1 ? ["203.0.113.30"] : []
        }
        service.queue.sync { service.refreshYunshuConnections(background: true) }
        check(started.wait(timeout: .now() + 2) == .success)
        let statusResponsive = DispatchSemaphore(value: 0)
        service.queue.async { statusResponsive.signal() }
        check(statusResponsive.wait(timeout: .now() + 1) == .success)
        service.queue.sync { service.captureGeneration = UUID() }
        release.signal()
        let completionDeadline = Date().addingTimeInterval(3)
        while service.queue.sync(execute: { service.yunshuRefreshInFlight }) && Date() < completionDeadline { Thread.sleep(forTimeInterval: 0.01) }
        check(!service.queue.sync(execute: { service.yunshuRefreshInFlight }))
        check(!loadedRules.contains("203.0.113.30/32"))
        let controlsBeforeTimeout = service.disconnectFirewall.vpnControlExceptions
        service.failYunshuRefresh(ProxyError("注入解析超时，原路径仍有效"))
        check(service.disconnectFirewall.vpnControlExceptions == controlsBeforeTimeout)
        service.yunshuBootstrapResolve = { _, type, _ in type == 1 ? ["203.0.113.31"] : ["2001:db8::31"] }
        let ipv4Only = try service.prepareYunshuConnections(state: runtime, plan: cloudPlan)
        check(!ipv4Only.contains { $0.destination.contains("2001:db8") })
        check(ipv4Only.contains { $0.destination == "203.0.113.31/32" })
        let originalRules = loadedRules
        loadedRules = "foreign rule"
        service.recoverResidentStartup()
        check(service.phase == "networkProtectionFailed")
        check(service.lastFailure?.contains("恢复未完成") == true)
        let unavailableStatus = service.handle(TunRequest(operation: "status"), fd: -1)
        check(!unavailableStatus.ok)
        check(unavailableStatus.supportsDisconnectProtection == true)
        loadedRules = originalRules
        if let output = ProcessInfo.processInfo.environment["QZ_YUNSHU_CORE_FIXTURE"] {
            let configPath = URL(fileURLWithPath: output)
            let credentials = MemoryCredentials()
            let parsed = try NodeParser.parse("trojan://synthetic@43.163.70.144:443?sni=example.com")
            try credentials.set(parsed.secret, for: parsed.node.credentialRef)
            var configState = runtime
            configState.nodes = [parsed.node]
            configState.selectedID = parsed.node.id
            configState.selectedPolicy = .node(parsed.node.id)
            var object = try TunConfigBuilder.object(state: configState, credentials: credentials,
                control: CoreControlContext(port: 29999, secret: String(repeating: "a", count: 64)),
                address4: "100.64.1.1/30", address6: "fd71:717a:1::1/126", originalDNS: ["192.168.5.1"], bypass: [], plan: cloudPlan, dnsForwardPort: 29998)
            try service.configureYunshuControlRules(&object, exceptions: controls, interface: "en0")
            let rulesPath = configPath.deletingLastPathComponent().appendingPathComponent("yunshu-control-fixture.rules.json")
            try Data(contentsOf: controlFile).write(to: rulesPath)
            var route = object["route"] as! [String: Any]
            var sets = route["rule_set"] as! [[String: Any]]
            for index in sets.indices where sets[index]["tag"] as? String == "yunshu-control" { sets[index]["path"] = rulesPath.path }
            route["rule_set"] = sets
            object["route"] = route
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: configPath)
        }
        // 独立恢复不依赖保护核验，且重启不会重新施加阻断。
        let rescueRoot = root.appendingPathComponent("rescue")
        try FileManager.default.createDirectory(at: rescueRoot, withIntermediateDirectories: true)
        let rescue = Service(fixtureRoot: rescueRoot, backend: ClaudeBypassFixtureBackend())
        var rescueRules = ""
        var rescueCommands: [[String]] = []
        var rejectRoot = false
        let rescuePF: ([String]) throws -> String = { args in
            rescueCommands.append(args)
            if args == ["-sr"] { return rejectRoot ? "block all\n" : "anchor \"com.apple/*\" all\n" }
            if args == ["-s", "References"] { throw ProxyError("旧凭据读取失败") }
            if args == ["-s", "Anchors"] || args.last == "Anchors" { return "" }
            if args == ["-si"] { return "Status: Enabled" }
            if args == ["-E"] { return "Token : 4321" }
            if args.first == "-n" || args.first == "-k" { return "" }
            if args.last == "-sr" { return rescueRules }
            if args.count == 4, args[2] == "-f" { rescueRules = try String(contentsOfFile: args[3], encoding: .utf8); return "" }
            if args.count == 4, args[2] == "-F" { rescueRules = ""; return "" }
            throw ProxyError("恢复夹具拒绝未预期命令")
        }
        rescue.firewallCommand = rescuePF
        try rescue.disconnectFirewall.arm(allowed: ["43.163.70.144/32"])
        rescueRules = ""
        let maintenance = rescue.handle(TunRequest(operation: "maintenanceStatus"), fd: -1)
        check(maintenance.ok && maintenance.supportsNormalNetworkRecovery == true)
        check(!rescue.handle(TunRequest(operation: "status"), fd: -1).ok)
        rescueCommands = []
        rejectRoot = true
        check(!rescue.handle(TunRequest(operation: "restoreNormalNetwork"), fd: -1).ok)
        check(rescue.normalRecoveryActive)
        check(!rescue.handle(TunRequest(operation: "acknowledgeNormalRecovery"), fd: -1).ok)
        check(!rescue.handle(TunRequest(operation: "prepare"), fd: -1).ok)
        rejectRoot = false
        let recovered = rescue.handle(TunRequest(operation: "restoreNormalNetwork"), fd: -1)
        check(recovered.ok && recovered.disconnectProtectionArmed == false)
        check(recovered.normalNetworkRecoveryPhase == "normalRecoveryCompleted")
        check(recovered.recoveryWarning != nil)
        check(!rescueCommands.contains { $0.first == "-k" || $0.contains("-f") || $0.first == "-E" })
        let restartedRescue = Service(fixtureRoot: rescueRoot, backend: ClaudeBypassFixtureBackend())
        restartedRescue.firewallCommand = rescuePF
        restartedRescue.recoverResidentStartup()
        check(restartedRescue.phase == "normalRecoveryCompleted")
        check(!restartedRescue.handle(TunRequest(operation: "systemProxy"), fd: -1).ok)
        check(restartedRescue.handle(TunRequest(operation: "acknowledgeNormalRecovery"), fd: -1).ok)
        check(!restartedRescue.normalRecoveryActive)
        // 接管记录损坏时仍应尝试解除独立的公网屏障，且不能谎报整体恢复完成。
        try restartedRescue.disconnectFirewall.arm(allowed: ["43.163.70.144/32"])
        try Data("{broken".utf8).write(to: rescueRoot.appendingPathComponent("recovery.json"))
        let partial = restartedRescue.handle(TunRequest(operation: "restoreNormalNetwork"), fd: -1)
        check(!partial.ok)
        check(!restartedRescue.disconnectFirewall.armed && rescueRules.isEmpty)
        check(restartedRescue.normalRecoveryActive)
        check(FileManager.default.fileExists(atPath: rescueRoot.appendingPathComponent("recovery.json").path))
        check(!restartedRescue.handle(TunRequest(operation: "acknowledgeNormalRecovery"), fd: -1).ok)
        try FileManager.default.removeItem(at: rescueRoot.appendingPathComponent("recovery.json"))
        try Data("{broken".utf8).write(to: restartedRescue.normalRecoveryFile)
        let repaired = restartedRescue.handle(TunRequest(operation: "restoreNormalNetwork"), fd: -1)
        check(repaired.ok)
        try check(FileManager.default.contentsOfDirectory(atPath: rescueRoot.path).contains { $0.hasPrefix("normal-network-recovery.corrupt-") })
        check(restartedRescue.handle(TunRequest(operation: "acknowledgeNormalRecovery"), fd: -1).ok)
        check(restartedRescue.handle(TunRequest(operation: "acknowledgeNormalRecovery"), fd: -1).ok)
        print("RESULT claude_bypass_helper_assertions=\(count) failures=0 kernelWrites=0")
    }
}
