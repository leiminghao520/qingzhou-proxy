import Foundation
import QingzhouKit

final class ClaudeBypassTests: CheckCase {
    func run() throws {
        var state = AppState()
        expectFalse(state.usesClaudeBypasses)
        state.claudeSafetyMode = true
        expectFalse(state.usesClaudeBypasses, "旧会话不自动放行")
        state.claudeAllowsBypasses = true
        try state.setBypasses([
            NetworkBypass(kind: .suffix, value: "tongdun.cn"),
            NetworkBypass(kind: .domain, value: "only.example"),
            NetworkBypass(kind: .cidr, value: "198.18.0.0/15"),
            NetworkBypass(kind: .cidr, value: "fd12::/64"),
            NetworkBypass(kind: .domain, value: "disabled.example", enabled: false)
        ])
        try ClaudeBypassPolicy.validate(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        expectTrue(decoded.usesClaudeBypasses)
        let settings = ClaudeSafetyNetworkSettings(state)
        var changed = state
        changed.claudeAllowsBypasses = false
        expectTrue(settings.restoring(changed).usesClaudeBypasses)
        var invalid = state
        invalid.networkBypasses = [NetworkBypass(kind: .cidr, value: "0.0.0.0/0")]
        expectThrows(try ClaudeBypassPolicy.validate(invalid))
        invalid.networkBypasses = [NetworkBypass(kind: .cidr, value: "0.0.0.0/4")]
        invalid.networkBypasses! += (1..<8).map { NetworkBypass(kind: .cidr, value: "\($0 * 16).0.0.0/4") }
        expectThrows(try ClaudeBypassPolicy.validate(invalid), "不能拼接为大范围公网例外")
        let routes = [
            ProtectedRoute(destination: "0.0.0.0/0", gateway: "192.168.5.1", interface: "en0"),
            ProtectedRoute(destination: "198.18.0.0/15", gateway: "10.251.1.1", interface: "utun6"),
            ProtectedRoute(destination: "fd12::/64", gateway: "fe80::1", interface: "utun6"),
            ProtectedRoute(destination: "10.1.0.0/24", gateway: "10.251.1.1", interface: "utun6")
        ]
        let resolver = DNSResolverScope(service: "corp", interface: "utun6", servers: ["10.1.0.1"], domains: ["tongdun.cn", "only.example"])
        let snapshot = NetworkSnapshot(primaryInterface: "en0", routes: routes, resolvers: [resolver])
        let plan = try CapturePlan.make(snapshot: snapshot, state: state)
        expectEqual(plan.domains, ["tongdun.cn"])
        expectEqual(plan.exactDomains, ["only.example"])
        expectEqual(try plan.selectResolvers(for: "fort-d.tongdun.cn"), [resolver])
        let host = try plan.domainRoute(address: "198.19.0.1", resolver: resolver, host: "fort-d.tongdun.cn")
        expectEqual(host.interface, "utun6", "企业合成地址保留 VPN 出口")
        let exceptions = try ClaudeBypassPolicy.initialExceptions(state: state, plan: plan)
        expectTrue(exceptions.contains { $0.destination == "198.18.0.0/15" && $0.interface == "utun6" })
        expectTrue(exceptions.contains { $0.destination == "10.1.0.1/32" && $0.dnsOnly })
        expectFalse(exceptions.contains { $0.destination == "0.0.0.0/0" })
        var rawIP = state
        rawIP.networkBypasses?.append(NetworkBypass(kind: .cidr, value: "192.168.5.1"))
        expectTrue(try ClaudeBypassPolicy.initialExceptions(state: rawIP, plan: plan).contains { $0.destination == "192.168.5.1/32" })
        var loopbackDNS = plan
        loopbackDNS.snapshot.resolvers.append(DNSResolverScope(service: "local", interface: "lo0", servers: ["127.0.0.1"]))
        expectFalse(try ClaudeBypassPolicy.initialExceptions(state: state, plan: loopbackDNS).contains { $0.dnsOnly && $0.destination == "127.0.0.1/32" }, "不误封同一回环地址上的本地代理")

        expectThrows(try ClaudeBypassPolicy.normalized([.init(destination: "10.0.0.0/8", interface: "en0"), .init(destination: "10.1.0.1/32", interface: "utun6")]))
        expectThrows(try ClaudeBypassPolicy.normalized([.init(destination: "10.1.0.0/24", interface: "utun6", dnsOnly: true)]))
        expectThrows(try ClaudeBypassPolicy.normalized([.init(destination: "10.1.0.1/32", interface: "en0\npass all")]))
        let endpoint = ClaudeNetworkEndpoint(address: "43.163.70.144", port: 443, transport: .tcp)
        let rules = try ClaudePFPolicy.rules(endpoint: endpoint, tunnel: "utun42", exceptions: exceptions)
        expectTrue(rules.contains("on ! utun6 inet from any to 198.18.0.0/15"))
        expectTrue(rules.contains("port != 53"))
        expectTrue(rules.contains("port != 443"))
        expectFalse(rules.contains("pass "))
        let linkRules = try ClaudePFPolicy.rules(endpoint: endpoint, tunnel: nil, exceptions: [
            .init(destination: "ff02::fb/128", interface: "en0"),
            .init(destination: "fe80::1/128", interface: "en0", dnsOnly: true),
            .init(destination: "255.255.255.255/32", interface: "en0")
        ])
        expectFalse(linkRules.contains("from any port != 68"), "显式广播绕过不被默认 DHCP 限制覆盖")
        expectFalse(linkRules.contains("to { fe80::/10, ff02::/16 }"), "链路例外从默认发现限制中扣除")
        expectTrue(linkRules.contains("on ! en0 inet6 from any to ff02::fb/128"))
        expectTrue(linkRules.contains("to fe80::1/128 port != 53"))
        if let output = ProcessInfo.processInfo.environment["QZ_BYPASS_RULE_FIXTURE"] {
            try linkRules.write(toFile: output + ".link", atomically: true, encoding: .utf8)
        }

        if let output = ProcessInfo.processInfo.environment["QZ_BYPASS_RULE_FIXTURE"] {
            try rules.write(toFile: output, atomically: true, encoding: .utf8)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DisconnectFirewallFixture()
        let firewall = DisconnectProtectionFirewall(directory: dir, command: fixture.execute)
        try firewall.armStrict(endpoint: endpoint, exceptions: exceptions)
        expectTrue(try firewall.verifyStrict(endpoint: endpoint, allowsBypasses: true))
        expectFalse(try firewall.verifyStrict(endpoint: endpoint), "兼容模式不能冒充整机严格模式")
        expectThrows(try firewall.armStrict(endpoint: endpoint), "活动会话不能静默变更保护范围")
        try firewall.attach(tunnel: "utun42")
        try firewall.updateBypassExceptions(exceptions + [.init(destination: "203.0.113.7/32", interface: "en0")])
        expectTrue(fixture.rules.contains("203.0.113.7/32"))
        try firewall.updateBypassExceptions(exceptions)
        expectFalse(fixture.rules.contains("203.0.113.7/32"), "撤销域名旧答案")
        expectTrue(fixture.commands.contains(["-k", "0.0.0.0/0", "-k", "203.0.113.7/32"]), "撤销时清理目标已有状态")
        let restarted = DisconnectProtectionFirewall(directory: dir, command: fixture.execute)
        try restarted.restoreAfterRestart()
        expectEqual(restarted.bypassExceptionCount, 0, "重启不信任旧接口")
        expectTrue(try restarted.verifyStrict(endpoint: endpoint, allowsBypasses: true))
        try restarted.armStrict(endpoint: endpoint, exceptions: exceptions)
        try restarted.revokeBypassExceptions()
        expectEqual(restarted.bypassExceptionCount, 0)
        fixture.rules = "external rules"
        expectThrows(try restarted.updateBypassExceptions(exceptions))
        var config: [String: Any] = ["outbounds": [["type": "direct", "tag": "direct"], ["type": "trojan", "tag": "proxy", "server": endpoint.address]], "dns": ["servers": [["tag": "remote"], ["tag": "local"]]], "route": ["rules": [["action": "sniff"], ["action": "route", "outbound": "direct"]]]]
        CaptureConfiguration.apply(&config, state: state, plan: plan, dnsForwardPort: 29998)
        let json = String(data: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), encoding: .utf8)!
        expectFalse(json.contains("disabled.example"))
        expectFalse(json.contains("protected-utun"), "不按自动发现网段扩大核心直连")
        let dns = config["dns"] as! [String: Any]
        expectEqual(dns["final"] as? String, "remote")
        let route = config["route"] as! [String: Any]
        expectEqual(route["final"] as? String, "proxy")
        let outbounds = config["outbounds"] as! [[String: Any]]
        expectFalse(outbounds.first { $0["tag"] as? String == "claude-bypass" }!.keys.contains("bind_interface"), "企业答案按原路由选择网卡")
        let credentials = MemoryCredentials()
        let candidate = try NodeParser.parse("trojan://synthetic@43.163.70.144:443?sni=example.com")
        try credentials.set(candidate.secret, for: candidate.node.credentialRef)
        state.nodes = [candidate.node]
        state.selectedPolicy = .node(candidate.node.id)
        state.selectedID = candidate.node.id
        state = try ClaudeSafetyPolicy.configuration(state, nodeID: candidate.node.id, allowNetworkBypasses: true)
        let data = try TunConfigBuilder.build(state: state, credentials: credentials,
            control: CoreControlContext(port: 29999, secret: String(repeating: "a", count: 64)),
            address4: "100.64.1.1/30", address6: "fd71:717a:1::1/126", originalDNS: ["10.1.0.1"], bypass: [], plan: plan, dnsForwardPort: 29998)
        if let output = ProcessInfo.processInfo.environment["QZ_BYPASS_CORE_FIXTURE"] { try data.write(to: URL(fileURLWithPath: output)) }
        let old = try JSONDecoder().decode(AppState.self, from: Data("{\"claudeSafetyMode\":true}".utf8))
        expectFalse(old.usesClaudeBypasses)
        let oldPreferences = try JSONDecoder().decode(ClaudeSafetyPreferences.self, from: Data("{}".utf8))
        expectNil(oldPreferences.allowNetworkBypasses)
        var physical = snapshot
        physical.resolvers = [DNSResolverScope(service: "wifi", interface: "en0", servers: ["192.168.5.1"], defaultResolver: true)]
        let physicalPlan = try CapturePlan.make(snapshot: physical, state: state)
        expectEqual(try physicalPlan.selectResolvers(for: "only.example").first?.interface, "en0")
        physical.resolvers[0].defaultResolver = false
        let unavailable = try CapturePlan.make(snapshot: physical, state: state)
        expectThrows(try unavailable.selectResolvers(for: "only.example"), "没有原默认解析器时不能猜测公网 DNS")

    }
}
