import Foundation
import QingzhouKit

final class YunshuConnectionTests: CheckCase {
    func run() throws {
        expectTrue(YunshuConnectionPolicy.matches("sp.eagleyun.cn"))
        expectTrue(YunshuConnectionPolicy.matches("customer.portal.eagleyun.com"))
        expectFalse(YunshuConnectionPolicy.matches("eagleyun.cn.attacker.example"))
        expectFalse(YunshuConnectionPolicy.matches("fakeeagleyun.com"))
        expectEqual(try YunshuConnectionPolicy.controlEndpoints(host: "sp.eagleyun.cn", address: "203.0.113.7").count, 2)
        expectTrue(try YunshuConnectionPolicy.controlEndpoints(host: "mqtt.cs.eagleyun.cn", address: "203.0.113.7").contains(.init(address: "203.0.113.7", port: 8883, transport: .tcp)))
        expectThrows(try YunshuConnectionPolicy.controlEndpoints(host: "outside.example", address: "203.0.113.7"))

        for address in ["198.19.0.1", "127.0.0.1", "10.1.1.1", "::1"] {
            expectThrows(try YunshuConnectionPolicy.validate(.init(address: address, port: 443, transport: .tcp)))
        }
        expectThrows(try YunshuConnectionPolicy.validate(.init(address: "203.0.113.7", port: 0, transport: .tcp)))
        expectThrows(try YunshuConnectionPolicy.validate(.init(address: "203.0.113.7", port: 443, transport: .unsupported)))
        let text = """
        p42
        f1
        PTCP
        n192.168.5.2:50000->203.0.113.7:443
        f2
        PUDP
        n192.168.5.2:50001->203.0.113.8:8443
        f3
        PTCP
        n127.0.0.1:50000->127.0.0.1:49152
        f4
        PTCP
        n*:443
        f5
        PTCP
        n[2001:db8::1]:50001->[2001:db8::7]:443
        p43
        f1
        PTCP
        n192.168.5.2:50002->203.0.113.9:443
        """
        let endpoints = try YunshuConnectionPolicy.endpoints(text, trustedPIDs: [42])
        expectEqual(endpoints.count, 3)
        expectTrue(endpoints.contains(.init(address: "203.0.113.8", port: 8443, transport: .udp)))
        expectFalse(endpoints.contains { $0.address == "203.0.113.9" })
        expectTrue(try YunshuConnectionPolicy.endpoints(text, trustedPIDs: []).isEmpty)
        expectThrows(try YunshuConnectionPolicy.endpoints(String(repeating: "x", count: 262145), trustedPIDs: [42]))
        var state = AppState()
        try state.setBypasses([.init(kind: .suffix, value: "tongdun.cn")])
        expectEqual(try YunshuConnectionPolicy.runtime(state, installed: true).enabledBypasses.count, 1)
        state.claudeSafetyMode = true
        state.claudeAllowsBypasses = true
        let runtime = try YunshuConnectionPolicy.runtime(state, installed: true)
        expectEqual(runtime.enabledBypasses.count, 3)
        expectEqual(state.enabledBypasses.count, 1, "不修改用户保存的绕过配置")
        expectEqual(try YunshuConnectionPolicy.runtime(state, installed: false).enabledBypasses.count, 1)
        let physical = DNSResolverScope(service: "wifi", interface: "en0", servers: ["192.168.5.1"], defaultResolver: true)
        let corporate = DNSResolverScope(service: "vpn", interface: "utun6", servers: ["10.1.0.1"], domains: ["tongdun.cn", "eagleyun.cn"])
        let routes = [ProtectedRoute(destination: "0.0.0.0/0", gateway: "192.168.5.1", interface: "en0"),
                      ProtectedRoute(destination: "203.0.113.7/32", gateway: "10.1.0.1", interface: "utun6")]
        var plan = try CapturePlan.make(snapshot: .init(primaryInterface: "en0", routes: routes, resolvers: [physical, corporate]), state: runtime)
        plan.yunshuControlDomains = YunshuConnectionPolicy.domains
        expectEqual(try plan.selectResolvers(for: "sp.eagleyun.cn"), [physical], "控制域名不经云枢自身解析")
        expectEqual(try plan.selectResolvers(for: "fort-d.tongdun.cn"), [corporate])
        expectEqual(try plan.domainRoute(address: "203.0.113.7", resolver: physical, host: "sp.eagleyun.cn").interface, "en0", "控制连接不绕回 VPN")
        var missingDNS = plan
        missingDNS.snapshot.resolvers = [corporate]
        expectThrows(try missingDNS.selectResolvers(for: "sp.eagleyun.cn"))
        var noVPN = plan
        noVPN.snapshot.resolvers = [physical]
        noVPN.requiresScopedDNSDomains = ["tongdun.cn"]
        expectThrows(try noVPN.selectResolvers(for: "fort-d.tongdun.cn"), "VPN 未连接时企业域名不能退回原公网 DNS")
        expectEqual(try noVPN.selectResolvers(for: "sp.eagleyun.cn"), [physical])

        let control = try YunshuConnectionPolicy.exception(.init(address: "203.0.113.7", port: 443, transport: .tcp), interface: "en0")
        let mqtt = try YunshuConnectionPolicy.exception(.init(address: "203.0.113.7", port: 8883, transport: .tcp), interface: "en0")
        let udp = try YunshuConnectionPolicy.exception(.init(address: "203.0.113.8", port: 8443, transport: .udp), interface: "en0")
        let node = ClaudeNetworkEndpoint(address: "43.163.70.144", port: 443, transport: .tcp)
        let rules = try ClaudePFPolicy.rules(endpoint: node, tunnel: "utun42", exceptions: [control, mqtt, udp])
        expectTrue(rules.contains("to 203.0.113.7/32 port { 0:442, 444:8882, 8884:65535 }"))
        expectTrue(rules.contains("proto udp from any to 203.0.113.7/32\n"))
        expectTrue(rules.contains("to 203.0.113.8/32 port != 8443"))
        expectTrue(rules.contains("on ! en0 inet from any to 203.0.113.7/32"))
        expectFalse(rules.contains("pass "))
        if let output = ProcessInfo.processInfo.environment["QZ_BYPASS_RULE_FIXTURE"] {
            try rules.write(toFile: output + ".yunshu", atomically: true, encoding: .utf8)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = DisconnectFirewallFixture()
        let firewall = DisconnectProtectionFirewall(directory: directory, command: fixture.execute)
        var dns = ClaudeBypassException(destination: "192.168.5.1/32", interface: "en0", dnsOnly: true)
        dns.vpnControl = true
        try firewall.armStrict(endpoint: node, exceptions: [control, mqtt, udp, dns, .init(destination: "10.0.0.0/8", interface: "utun6")])
        let killsBefore = fixture.commands.filter { $0.first == "-k" }.count
        try firewall.revokeBypassExceptions()
        expectEqual(firewall.vpnControlExceptions.count, 4)
        expectFalse(fixture.rules.contains("10.0.0.0/8"))
        expectTrue(fixture.rules.contains("203.0.113.7/32"))
        expectTrue(try firewall.verifyStrict(endpoint: node, allowsBypasses: true))
        try firewall.suspend()
        expectEqual(firewall.vpnControlExceptions.count, 4, "暂停代理保留控制重连")
        expectTrue(fixture.commands.dropFirst(killsBefore).allSatisfy { $0 != ["-k", "203.0.113.7/32"] })
        try firewall.revokeBypassExceptions(preservingVPN: false)
        expectEqual(firewall.bypassExceptionCount, 0, "证据丢失时可全部撤销控制例外")
        try firewall.stageVPNResolvers([dns])
        expectEqual(firewall.vpnControlExceptions, [dns])
        expectThrows(try firewall.stageVPNResolvers([control]))
        fixture.rules = ""
        expectThrows(try firewall.verifyStrict(endpoint: node, allowsBypasses: true), "只读状态不能掩盖空锚点")
        try firewall.suspend()
        expectTrue(try firewall.verifyStrict(endpoint: node, allowsBypasses: true), "自有根引用完整时写恢复可重载空锚点")
        fixture.discardLoads = 1
        try firewall.attach(tunnel: "utun42")
        expectTrue(try firewall.verifyStrict(endpoint: node, allowsBypasses: true))
        fixture.rules = ""
        fixture.ownedChildren = "foreign-child"
        expectThrows(try firewall.suspend(), "空锚点下存在未知子项时拒绝覆盖")
        fixture.ownedChildren = ""
        fixture.rules = "foreign nonempty rules"
        expectThrows(try firewall.suspend(), "非空外部修改不能作为空锚点重载")
        let missingDirectory = directory.appendingPathComponent("missing-anchor")
        try FileManager.default.createDirectory(at: missingDirectory, withIntermediateDirectories: true)
        let missing = DisconnectFirewallFixture()
        missing.root = "anchor \"com.sangfor.atrust\" all\n"
        let missingFirewall = DisconnectProtectionFirewall(directory: missingDirectory, command: missing.execute)
        try missingFirewall.armStrict(endpoint: node, exceptions: [control])
        let capturedRoot = missing.root
        missing.rules = ""
        missing.inventory = ""
        missing.missingDiagnostic = true
        missing.root = "anchor \"com.sangfor.atrust\" all\n"
        try missingFirewall.suspend()
        expectTrue(try missingFirewall.verifyStrict(endpoint: node, allowsBypasses: true), "清单证明不存在时允许重建自有锚点")
        expectEqual(missing.root, capturedRoot)
        missing.rules = ""
        expectThrows(try missingFirewall.suspend(), "锚点清单仍存在时不能把查询诊断当作缺失")

        expectTrue(ClaudeBypassPolicy.covers(control, with: [control, mqtt]))
        expectFalse(ClaudeBypassPolicy.covers(mqtt, with: [control]))
        var renamedDNS = dns
        renamedDNS.vpnControl = nil
        expectTrue(ClaudeBypassPolicy.covers(dns, with: [renamedDNS]), "更改来源标签不应中断相同 DNS 权限")
    }
}
