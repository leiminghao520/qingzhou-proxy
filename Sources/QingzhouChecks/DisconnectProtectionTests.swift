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
        if args.count==3,args.last=="-sr" {return rules}
        if args.count==4,args[2]=="-f" {rules=try String(contentsOfFile:args[3],encoding:.utf8);return ""}
        if args.count==4,args[2]=="-F" {rules="";return ""}
        throw ProxyError("未预期的管理员命令，夹具禁止执行真实命令")
    }
}

final class DisconnectProtectionTests:CheckCase {
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
        f.root="anchor \"com.sangfor.vpn\" all\n"
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
