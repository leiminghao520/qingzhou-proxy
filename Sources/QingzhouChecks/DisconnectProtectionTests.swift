import Foundation
import QingzhouKit

final class DisconnectFirewallFixture {
    var root="anchor \"com.apple/*\" all\n"
    var children=""
    var rules=""
    var enabled=false
    var token="1234"
    var fail:[String]?
    var commands:[[String]]=[]
    func execute(_ args:[String]) throws -> String {
        commands.append(args)
        if args==fail {throw ProxyError("模拟防火墙命令失败")}
        if args==["-sr"] {return root}
        if args==["-a","com.apple","-s","Anchors"] {return children}
        if args==["-si"] {return enabled ? "Status: Enabled":"Status: Disabled"}
        if args==["-E"] {enabled=true;return "Token : "+token}
        if args.first=="-X" {enabled=false;return ""}
        if args.first=="-k" {return ""}
        if args.first=="-n" {return ""}
        if args.count==3,args[0]=="-R",args[1]=="-f" {root=try String(contentsOfFile:args[2],encoding:.utf8);return ""}
        if args.count==3,args.last=="-sr" {return rules}
        if args.count==4,args[2]=="-f" {rules=try String(contentsOfFile:args[3],encoding:.utf8);return ""}
        if args.count==4,args[2]=="-F" {rules="";return ""}
        throw ProxyError("未预期的管理员命令，夹具禁止执行真实命令")
    }
}

final class DisconnectProtectionTests:CheckCase {
    func testCorporateCoexistence() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let f=DisconnectFirewallFixture()
        let original=["atrust","atrust1","vpn","app01","app02","byod"].map{"anchor \"com.sangfor."+$0+"\" all"}.joined(separator:"\n")+"\n"
        f.root=original
        let firewall=DisconnectProtectionFirewall(directory:dir,command:f.execute)
        try firewall.preflight()
        expectFalse(f.commands.contains{$0.contains("-f")},"预检不写过滤规则")
        let allowed=try DisconnectProtectionPolicy.strictAllowedDestinations(endpoint:"43.163.70.144")
        try firewall.arm(allowed:allowed)
        expectTrue(f.root.hasSuffix(original),"企业锚点与顺序完整保留")
        expectTrue(f.root.hasPrefix("anchor \"qingzhou-lock-"),"独立保护引用位于最前")
        expectTrue(f.root.components(separatedBy:.newlines)[0].hasSuffix("quick all"))
        expectFalse(try firewall.verifyClaudeSafety(endpoint:"43.163.70.144"))
        try firewall.attach(tunnel:"utun8")
        try firewall.suspend()
        expectFalse(f.rules.contains("on !"),"核心退出后阻断全部物理出口")
        let protectedRoot=f.root
        f.root=original
        expectThrows(try firewall.verify(),"企业软件移除保护引用时不伪报安全")
        let restarted=DisconnectProtectionFirewall(directory:dir,command:f.execute)
        try restarted.restoreAfterRestart()
        expectEqual(f.root,protectedRoot,"辅助服务重启可恢复自己的引用")
        f.root=protectedRoot+"pass out all\n"
        let writes=f.commands.filter{$0.contains("-f") || $0.contains("-F")}.count
        expectThrows(try restarted.release())
        expectEqual(f.commands.filter{$0.contains("-f") || $0.contains("-F")}.count,writes,"不覆盖外部并发规则改动")
        f.root=protectedRoot
        try restarted.release()
        expectEqual(f.root,original,"关闭后恢复原根引用")
        expectFalse(restarted.armed)
        expectFalse(f.commands.contains{$0.contains("-N") || $0.contains("-F") && !$0.contains(where:{$0.hasPrefix("qingzhou-lock-")})},"不清空企业锚点或 NAT")
        f.root="anchor \"unknown.vendor\" all\n"
        expectThrows(try restarted.preflight())
        f.root=original
        let failRoot=["-R","-f",dir.appendingPathComponent("disconnect-protection-root.conf").path]
        f.fail=failRoot
        expectThrows(try restarted.arm(allowed:allowed))
        expectEqual(f.root,original,"根规则安装失败时企业规则保持原样")
        expectTrue(restarted.armed,"失败保留恢复记录")
        f.fail=nil
        try restarted.release()
        expectFalse(restarted.armed,"未挂接的局部失败可以安全清理")
    }
    func testClaudeSafetyProof() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DisconnectFirewallFixture()
        let firewall = DisconnectProtectionFirewall(directory: dir, command: fixture.execute)
        expectFalse(try firewall.verifyClaudeSafety(endpoint: "43.163.70.144"))
        var lookedUp:[String]=[]
        let cloud=try YunshuControlPolicy.resolve(installed:true,lookup:{host in lookedUp.append(host);return host == "sp.eagleyun.cn" ? ["47.76.248.34"]:["8.211.6.156"]})
        expectEqual(lookedUp,YunshuControlPolicy.hosts)
        expectTrue(try YunshuControlPolicy.resolve(installed:false,lookup:{_ in throw ProxyError("不应解析")}).isEmpty)
        expectThrows(try YunshuControlPolicy.resolve(installed:true,lookup:{_ in ["0.0.0.0/0"]}))
        expectThrows(try YunshuControlPolicy.resolve(installed:true,lookup:{_ in []}))
        let allowed = try DisconnectProtectionPolicy.strictAllowedDestinations(endpoint: "43.163.70.144")
        try firewall.arm(allowed: allowed)
        expectFalse(try firewall.verifyClaudeSafety(endpoint: "43.163.70.144"))
        expectFalse(try firewall.verifyClaudeSafety(endpoint: "43.163.70.145"))
        let restarted = DisconnectProtectionFirewall(directory: dir, command: fixture.execute)
        expectFalse(try restarted.verifyClaudeSafety(endpoint: "43.163.70.144"))
        try firewall.release()
        try firewall.arm(allowed:allowed,yunshuAddresses:cloud)
        expectFalse(try firewall.verifyClaudeSafety(endpoint:"43.163.70.144"))
        expectTrue(fixture.rules.contains("47.76.248.34/32"))
        expectFalse(fixture.rules.contains("47.76.0.0/16"))
        try firewall.arm(allowed:allowed,yunshuAddresses:["47.238.73.189"])
        expectFalse(fixture.rules.contains("47.238.73.189/32"),"活跃会话不能因 DNS 变化扩大例外")
        try firewall.release()
        try firewall.arm(allowed: allowed + ["198.51.100.0/24"])
        expectFalse(try firewall.verifyClaudeSafety(endpoint: "43.163.70.144"))
        fixture.rules = "external rules"
        expectThrows(try firewall.verifyClaudeSafety(endpoint: "43.163.70.144"))
    }


    func testStrictPF() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DisconnectFirewallFixture()
        let firewall = DisconnectProtectionFirewall(directory: dir, command: fixture.execute)
        let endpoint = ClaudeNetworkEndpoint(address: "43.163.70.144", port: 443, transport: .tcp)
        let allowed = try DisconnectProtectionPolicy.strictAllowedDestinations(endpoint: endpoint.address)
        try firewall.arm(allowed: allowed, yunshuAddresses: ["47.76.248.34"])
        expectFalse(try firewall.verifyClaudeSafety(endpoint: endpoint.address), "旧版记录不满足新屏障")
        fixture.fail = ["-k", "::/0"]
        expectThrows(try firewall.armStrict(endpoint: endpoint))
        expectFalse(try firewall.verifyStrict(endpoint: endpoint), "连接状态清理失败不得发布严格保护证明")
        fixture.fail = nil
        try firewall.restoreAfterRestart()
        let enablesBefore = fixture.commands.filter { $0 == ["-E"] }.count
        try firewall.armStrict(endpoint: endpoint)
        expectEqual(fixture.commands.filter { $0 == ["-E"] }.count, enablesBefore, "重连不重复领取 PF 启用引用")
        expectTrue(try firewall.verifyStrict(endpoint: endpoint))
        expectFalse(fixture.rules.contains("47.76.248.34"))
        expectFalse(fixture.rules.contains("10.0.0.0/8"))
        expectTrue(fixture.rules.contains("port != 443"))
        expectTrue(fixture.rules.contains("port != 68"))
        expectTrue(fixture.rules.contains("port != 67"))
        expectTrue(fixture.rules.contains("icmp6-type"))
        expectFalse(fixture.rules.contains("proto !"), "不生成 PF 不支持的协议否定语法")
        expectFalse(fixture.rules.contains("pass "), "规则不绕过企业软件的拒绝")
        try firewall.attach(tunnel: "utun42")
        expectTrue(fixture.rules.contains("on ! utun42"))
        try firewall.suspend()
        expectFalse(fixture.rules.contains("on ! utun"))
        expectTrue(try firewall.verifyStrict(endpoint: endpoint))
        let restarted = DisconnectProtectionFirewall(directory: dir, command: fixture.execute)
        try restarted.restoreAfterRestart()
        expectTrue(try restarted.verifyStrict(endpoint: endpoint))
        var other = endpoint
        other.port = 80
        expectFalse(try restarted.verifyStrict(endpoint: other))
        expectThrows(try restarted.armStrict(endpoint: other))
        try restarted.release()
        expectFalse(restarted.armed)
        for invalid in [ClaudeNetworkEndpoint(address: "127.0.0.1", port: 443, transport: .tcp),
                        .init(address: "43.163.70.144", port: 0, transport: .tcp),
                        .init(address: "43.163.70.144", port: 443, transport: .unsupported)] {
            expectThrows(try ClaudePFPolicy.rules(endpoint: invalid, tunnel: nil))
        }
        expectThrows(try ClaudePFPolicy.rules(endpoint: endpoint, tunnel: "en0"))
        let udp = try ClaudePFPolicy.endpoint(Node(name: "UDP", kind: .hysteria2, server: "43.163.70.144", port: 443))
        expectEqual(udp.transport, .udp)
        expectTrue(try ClaudePFPolicy.rules(endpoint: udp, tunnel: nil).contains("proto udp from any to 43.163.70.144 port != 443"))
        expectThrows(try ClaudePFPolicy.endpoint(Node(name: "SS", kind: .shadowsocks, server: "43.163.70.144", port: 443)))
        let ipv6 = ClaudeNetworkEndpoint(address: "2606:4700:4700::1111", port: 443, transport: .tcp)
        expectTrue(try ClaudePFPolicy.rules(endpoint: ipv6, tunnel: nil).contains("inet6 proto tcp"))

        var protected = state()
        protected.claudeSafetyMode = true
        let credentials = MemoryCredentials()
        try credentials.set("fixture-password", for: protected.nodes[0].credentialRef)
        let snapshot = NetworkSnapshot(primaryInterface: "en0", routes: [], resolvers: [DNSResolverScope(service: "fixture", interface: "en0", servers: ["192.168.1.1"], defaultResolver: true)])
        var plan = try CapturePlan.make(snapshot: snapshot, extraCIDRs: [], extraDomains: [])
        plan.protectedRoutes = [ProtectedRoute(destination: "198.51.100.0/24", gateway: "10.0.0.1", interface: "utun7")]
        let object = try TunConfigBuilder.object(state: protected, credentials: credentials,
            control: CoreControlContext(port: 35444, secret: String(repeating: "a", count: 64)),
            address4: "172.19.0.1/30", address6: "fdfe:dcba:9876::1/126", originalDNS: ["192.168.1.1"],
            bypass: [], plan: plan, dnsForwardPort: 35445)
        let outbounds = object["outbounds"] as! [[String: Any]]
        expectFalse(outbounds.contains { $0["type"] as? String == "direct" })
        let dns = object["dns"] as! [String: Any]
        expectEqual((dns["servers"] as! [[String: Any]]).count, 1)
        expectTrue((dns["rules"] as! [[String: Any]]).isEmpty)
        expectEqual(dns["final"] as? String, "remote")
        let route = object["route"] as! [String: Any]
        expectTrue((route["rules"] as! [[String: Any]]).allSatisfy { ["sniff", "hijack-dns"].contains($0["action"] as? String ?? "") })
        let config = dir.appendingPathComponent("strict-tun.json")
        try JSONSerialization.data(withJSONObject: object).write(to: config)
        let core = Process()
        core.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Vendor/sing-box")
        core.arguments = ["check", "-c", config.path]
        core.standardOutput = FileHandle.nullDevice
        try core.run()
        core.waitUntilExit()
        expectEqual(core.terminationStatus, 0, "严格 DNS 配置必须通过实际核心校验")

        if let output = ProcessInfo.processInfo.environment["QZ_PF_RULE_FIXTURE"] {
            try ClaudePFPolicy.rules(endpoint: endpoint, tunnel: nil).write(toFile: output, atomically: true, encoding: .utf8)
            try ClaudePFPolicy.rules(endpoint: udp, tunnel: "utun42").write(toFile: output + ".udp", atomically: true, encoding: .utf8)
            try ClaudePFPolicy.rules(endpoint: ipv6, tunnel: nil).write(toFile: output + ".ipv6", atomically: true, encoding: .utf8)
        }
    }

    func state()->AppState {
        var state=AppState();state.captureMode = .compatible;state.mode = .global;state.dnsPreference = .httpsProxy;state.strictDNS=true;state.disconnectProtection=true
        let node=Node(name:"固定节点",kind:.hysteria2,server:"43.163.70.144",port:443)
        state.nodes=[node];state.selectedPolicy = .node(node.id)
        return state
    }
    func testPolicy() throws {
        var s=state()
        try PolicyValidator.validate(s)
        expectFalse(AppState().protectsDisconnect)
        let old=try JSONDecoder().decode(AppState.self,from:Data("{}".utf8));expectFalse(old.protectsDisconnect)
        expectTrue(try JSONDecoder().decode(AppState.self,from:JSONEncoder().encode(s)).protectsDisconnect)
        for change:(inout AppState)->Void in [{$0.captureMode = .systemProxy},{$0.mode = .direct},{$0.mode = .rule},{$0.dnsPreference = .system},{$0.strictDNS=false},{$0.httpCompatibilityEnabled=true},{$0.selectedPolicy = .automatic},{$0.selectedPolicy=nil},{$0.nodes=[]}] {
            var invalid=s;change(&invalid);expectThrows(try PolicyValidator.validate(invalid))
        }
        for address in ["proxy.lmh1103.icu","127.0.0.1","::1","0.0.0.0","::","10.0.0.1","172.16.0.1","192.168.1.1","169.254.1.1","224.0.0.1","100.64.0.1","fc00::1","fe80::1","::ffff:43.163.70.144","43.163.70.144/32","43.163.70.144\npass out all"] {
            var invalid=s;invalid.nodes[0].server=address;expectThrows(try PolicyValidator.validate(invalid))
        }
        expectTrue(DisconnectProtectionPolicy.publicEndpoint("2606:4700:4700::1111"))
        expectTrue(DisconnectProtectionPolicy.publicEndpoint("172.32.0.1"))
        s.nodes.append(Node(name:"其他节点",kind:.hysteria2,server:"8.8.8.8",port:443))
        s.rules=[RoutingRule(kind:.suffix,value:"example.com",action:.direct)]
        let isolated=try DisconnectProtectionPolicy.runtime(s)
        expectEqual(isolated.nodes.count,1);expectTrue(isolated.rules.isEmpty);expectEqual(s.nodes.count,2)
        let credentials=MemoryCredentials();for node in s.nodes {try credentials.set("fixture",for:node.credentialRef)}
        let object=try ConfigBuilder.object(state:s,credentials:credentials,control:CoreControlContext(port:35444,secret:String(repeating:"a",count:64)))
        let outbounds=object["outbounds"] as! [[String:Any]]
        expectFalse(outbounds.contains{$0["type"] as? String == "urltest"})
        expectEqual(outbounds.first{$0["tag"] as? String == "proxy"}?["outbounds"] as? [String],[s.activePolicy!.tag])
        expectFalse(outbounds.contains{$0["server"] as? String == "8.8.8.8"})
        s.disconnectProtection=false;expectEqual(try DisconnectProtectionPolicy.runtime(s).nodes.count,2)
        let snapshot=NetworkSnapshot(primaryInterface:"en0",routes:[],resolvers:[DNSResolverScope(service:"fixture",interface:"en0",servers:["192.168.1.1"],defaultResolver:true)])
        var plan=try CapturePlan.make(snapshot:snapshot,extraCIDRs:[],extraDomains:[])
        s=state()
        let allowed=try DisconnectProtectionPolicy.allowedDestinations(state:s,plan:plan)
        expectTrue(allowed.contains("43.163.70.144/32"));expectFalse(allowed.contains("1.1.1.1/32"))
        expectTrue(allowed.contains("::1/128"));expectTrue(allowed.contains("10.0.0.0/8"))
        plan.protectedRoutes=[ProtectedRoute(destination:"0.0.0.0/1",gateway:"10.0.0.1",interface:"utun7")]
        expectThrows(try DisconnectProtectionPolicy.allowedDestinations(state:s,plan:plan))
        expectThrows(try DisconnectProtectionPolicy.rules(allowed:[],tunnel:nil))
        expectThrows(try DisconnectProtectionPolicy.rules(allowed:["0.0.0.0/0"],tunnel:nil))
        expectThrows(try DisconnectProtectionPolicy.rules(allowed:["1.1.1.1"],tunnel:nil))
        expectThrows(try DisconnectProtectionPolicy.rules(allowed:["1.1.1.1/32"],tunnel:"en0"))
        let waiting=try DisconnectProtectionPolicy.rules(allowed:allowed,tunnel:nil)
        let connected=try DisconnectProtectionPolicy.rules(allowed:allowed,tunnel:"utun42")
        expectTrue(waiting.contains("quick inet6"));expectTrue(waiting.contains("quick inet"));expectFalse(waiting.contains("pass "))
        expectTrue(connected.contains("on ! utun42 inet6"));expectTrue(connected.contains("on ! utun42 inet"))
    }
    func testLifecycle() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let f=DisconnectFirewallFixture(),allowed=["43.163.70.144/32","127.0.0.0/8","::1/128"]
        let firewall=DisconnectProtectionFirewall(directory:dir,command:f.execute)
        try firewall.preflight();expectFalse(firewall.armed)
        try firewall.suspend();try firewall.attach(tunnel:"utun8");try firewall.release();try firewall.restoreAfterRestart()
        try firewall.arm(allowed:allowed)
        expectTrue(firewall.armed);expectTrue(f.enabled)
        expectTrue(f.commands.contains(["-k","0.0.0.0/0"]));expectTrue(f.commands.contains(["-k","::/0"]))
        try firewall.attach(tunnel:"utun8");expectTrue(f.rules.contains("on ! utun8"))
        try firewall.suspend();expectFalse(f.rules.contains("on !"));expectTrue(firewall.armed)
        let kills=f.commands.filter{$0.first=="-k"}.count
        try firewall.arm(allowed:allowed.reversed());expectEqual(f.commands.filter{$0.first=="-k"}.count,kills)
        expectThrows(try firewall.arm(allowed:["8.8.8.8/32"]))
        try firewall.attach(tunnel:"utun9")
        let restarted=DisconnectProtectionFirewall(directory:dir,command:f.execute)
        try restarted.restoreAfterRestart();expectFalse(f.rules.contains("on !"));expectTrue(restarted.armed)
        f.rules="external rules";expectThrows(try restarted.suspend());expectThrows(try restarted.release());expectTrue(restarted.armed)
        f.rules=try String(contentsOf:dir.appendingPathComponent("disconnect-protection.conf"),encoding:.utf8)
        try restarted.release();expectFalse(restarted.armed);expectFalse(f.enabled);expectEqual(f.rules,"")
        expectFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent("disconnect-protection.json").path))
        f.root="anchor \"unknown.vendor\" all\n"
        let fresh=DisconnectProtectionFirewall(directory:dir,command:f.execute)
        let before=f.commands.count;expectThrows(try fresh.arm(allowed:allowed))
        expectFalse(f.commands.dropFirst(before).contains{$0.contains("-f") || $0.contains("-F") || $0.contains("-E")})
        f.root="anchor \"com.apple/*\" all\n";f.children="another-component";expectThrows(try firewall.preflight())
    }
    func testFailureAndRestart() throws {
        for fail in [["-E"],["-k","0.0.0.0/0"],["-k","::/0"]] {
            let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
            let f=DisconnectFirewallFixture();f.fail=fail
            let p=DisconnectProtectionFirewall(directory:dir,command:f.execute)
            expectThrows(try p.arm(allowed:["1.1.1.1/32"]))
            expectTrue(p.armed)
            f.fail=nil;try p.restoreAfterRestart();try p.release();expectFalse(p.armed)
        }
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let f=DisconnectFirewallFixture(),p=DisconnectProtectionFirewall(directory:dir,command:f.execute)
        try p.arm(allowed:["43.163.70.144/32"])
        f.enabled=false;expectThrows(try p.verify());try p.restoreAfterRestart();expectTrue(f.enabled)
        f.rules="";f.enabled=false;try p.restoreAfterRestart();expectTrue(f.enabled);expectFalse(f.rules.isEmpty)
        try p.release()
        let record=dir.appendingPathComponent("disconnect-protection.json")
        try Data("{}".utf8).write(to:record);try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:record.path)
        let broken=DisconnectProtectionFirewall(directory:dir,command:f.execute);expectThrows(try broken.preflight());expectTrue(broken.armed)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:record.path);expectThrows(try broken.preflight())
    }
}
