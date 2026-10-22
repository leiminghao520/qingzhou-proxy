import Foundation
import QingzhouKit

final class NetworkBypassTests:CheckCase {
    func testNormalizationAndValidation() throws {
        let cases=[("13.2.34.203","13.2.34.203/32"),("13.2.34.203/24","13.2.34.0/24"),("2001:DB8::1","2001:db8::1/128"),("2001:db8::abcd/64","2001:db8::/64")]
        for (raw,expected) in cases {expectEqual(try NetworkBypassPolicy.canonicalCIDR(raw),expected)}
        for raw in ["0.0.0.0/0","128.0.0.0/1","::/0","1.2.3.4/33","1.2.3.4/","invalid"] {expectThrows(try NetworkBypassPolicy.canonicalCIDR(raw))}
        var decodedState=AppState();decodedState.networkBypasses=[NetworkBypass(kind:.cidr,value:"203.0.113.7")]
        let canonicalState=try JSONDecoder().decode(AppState.self,from:JSONEncoder().encode(decodedState))
        expectEqual(canonicalState.effectiveBypasses.first?.value,"203.0.113.7/32","配置读取也必须规范化主机地址")
        let domain=try NetworkBypass(kind:.domain,value:" API.Example.COM. ").normalized()
        expectEqual(domain.value,"api.example.com");expectTrue(domain.matches(host:"api.example.com"));expectFalse(domain.matches(host:"sub.api.example.com"))
        let suffix=try NetworkBypass(kind:.suffix,value:"example.com").normalized()
        expectTrue(suffix.matches(host:"api.example.com"));expectFalse(suffix.matches(host:"badexample.com"))
        for value in ["https://example.com","example.com/path","*.example.com","example.com:443","1.2.3.4","bad_domain.test"] {expectThrows(try NetworkBypass(kind:.domain,value:value).normalized())}
        expectThrows(try NetworkBypass(kind:.domain,value:"example.com",note:String(repeating:"a",count:2049)).normalized())
        expectThrows(try NetworkBypass(kind:.domain,value:"example.com",exit:.pinned,serviceID:"service",gateway:"13.2.4.254").normalized())
        expectThrows(try NetworkBypass(kind:.cidr,value:"13.2.34.203",exit:.pinned).normalized())
        expectThrows(try NetworkBypass(kind:.cidr,value:"13.2.34.203",exit:.pinned,serviceID:"s",gateway:"2001:db8::1").normalized())
        expectThrows(try NetworkBypass(kind:.cidr,value:"13.2.34.203",exit:.pinned,serviceID:"s",gateway:"13.2.4.254/24").normalized())
        var pin=try NetworkBypass(kind:.cidr,value:"13.2.34.203",exit:.pinned,serviceID:"s",gateway:"13.2.4.254").normalized()
        expectEqual(pin.gateway,"13.2.4.254")
        var other=pin;other.id=UUID();other.value="13.2.34.0/24";other.gateway="13.2.4.253"
        expectThrows(try NetworkBypassPolicy.normalize([pin,other]))
        other.gateway=pin.gateway;expectEqual(try NetworkBypassPolicy.normalize([pin,other]).count,2)
        pin.exit = .system;expectNil(try pin.normalized().serviceID)
        expectThrows(try NetworkBypassPolicy.normalize([domain,domain]))
        var duplicate=domain;duplicate.id=UUID();expectThrows(try NetworkBypassPolicy.normalize([domain,duplicate]))
    }
    func testMigrationBackupAndDisabledItems() throws {
        let old=Data(#"{"protectedDomains":["CORP.TEST","corp.test"],"tunExcludedCIDRs":["13.2.34.203","13.2.34.203/32"],"rules":[{"id":"00000000-0000-0000-0000-000000000001","kind":"cidr","value":"13.2.34.203","action":"direct"}]}"#.utf8)
        var state=try JSONDecoder().decode(AppState.self,from:old)
        expectEqual(state.effectiveBypasses.count,2);expectEqual(state.rules.count,1)
        expectEqual(state.effectiveBypasses,try JSONDecoder().decode(AppState.self,from:old).effectiveBypasses)
        expectTrue(state.effectiveBypasses.allSatisfy{$0.legacyProtection==true})
        var items=state.effectiveBypasses;items[0].enabled=false;items[0].note="企业保护暂时停用";try state.setBypasses(items)
        expectEqual(state.bypassDomains,[]);expectEqual(state.bypassCIDRs,["13.2.34.203/32"])
        let restored=try JSONDecoder().decode(AppState.self,from:JSONEncoder().encode(state))
        expectEqual(restored.effectiveBypasses,items);expectEqual(restored.rules,state.rules)
        var empty=state;try empty.setBypasses([]);expectTrue(empty.effectiveBypasses.isEmpty)
        state.schemaVersion=2
        let credentials=MemoryCredentials()
        let snapshot=try BackupService.snapshot(ProfileCatalog(state:state),credentials:credentials)
        let unpacked=try JSONDecoder().decode(BackupSnapshot.self,from:JSONEncoder().encode(snapshot))
        expectEqual(unpacked.catalog.active.effectiveBypasses,items)
    }
    func testBatchAndConversion() throws {
        let result=NetworkBypassPolicy.parse("example.com,*.example.com\n13.2.34.203,13.2.34.203/32\n2001:db8::1\nhttps://bad.test,10.0.0.1/33\n# 注释")
        expectEqual(result.items.count,4);expectEqual(result.issues.count,2);expectTrue(result.warnings.contains{$0.contains("重复")});expectTrue(result.warnings.contains{$0.contains("覆盖")})
        expectEqual(result.items.filter{$0.kind == .domain}.count,1);expectEqual(result.items.filter{$0.kind == .suffix}.count,1)
        expectEqual(NetworkBypassPolicy.parse(String(repeating:"x",count:2*1024*1024+1)).issues.count,1)
        expectEqual(NetworkBypassPolicy.parse("example.com",existing:[NetworkBypass(kind:.domain,value:"example.com")]).items.count,0)
        expectEqual(NetworkBypassPolicy.parse(String(repeating:"bad value\n",count:500)).issues.count,100)
        let rules=[RoutingRule(kind:.domain,value:"api.test",action:.direct),RoutingRule(kind:.suffix,value:"corp.test",action:.direct),RoutingRule(kind:.cidr,value:"13.2.34.203",action:.direct)]
        for rule in rules {let item=try NetworkBypassPolicy.convert(rule);expectEqual(item.id,rule.id);expectTrue(item.enabled)}
        expectThrows(try NetworkBypassPolicy.convert(RoutingRule(kind:.keyword,value:"bank",action:.direct)))
        expectThrows(try NetworkBypassPolicy.convert(RoutingRule(kind:.domain,value:"bank.test",action:.proxy)))
        let narrow=try NetworkBypass(kind:.cidr,value:"10.0.0.0/24").normalized(),wide=try NetworkBypass(kind:.cidr,value:"10.0.0.0/8").normalized()
        let warnings=NetworkBypassPolicy.coverageWarnings([wide,narrow])
        expectEqual(warnings.count,1);expectTrue(warnings[0].hasPrefix(narrow.value))
    }
    func testProxyExceptionsAndOwnership() throws {
        var state=AppState();try state.setBypasses([NetworkBypass(kind:.domain,value:"exact.test"),NetworkBypass(kind:.suffix,value:"corp.test"),NetworkBypass(kind:.cidr,value:"13.2.34.203"),NetworkBypass(kind:.cidr,value:"2001:db8::1"),NetworkBypass(kind:.cidr,value:"10.0.0.0/8")])
        expectTrue(state.bypassProxyExceptions.contains("13.2.34.203"));expectFalse(state.bypassProxyExceptions.contains("13.2.34.203/32"))
        expectTrue(state.bypassProxyExceptions.contains("2001:db8::1"));expectFalse(state.bypassProxyExceptions.contains("*.exact.test"));expectTrue(state.bypassProxyExceptions.contains("*.corp.test"))
        let original:[String:Any]=["ExceptionsList":["external.test"],"HTTPEnable":0]
        let applied=try ProxyRecovery.applied(to:original,port:27890,protectedDomains:[],exceptions:state.bypassProxyExceptions)
        expectTrue((applied["ExceptionsList"] as! [String]).contains("external.test"))
        expectTrue(NSDictionary(dictionary:ProxyRecovery.restored(original:original,applied:applied,current:applied)!).isEqual(to:original))
        var external=applied;external["ExceptionsList"]=["external-changed.test"]
        expectNil(ProxyRecovery.restored(original:original,applied:applied,current:external))
        expectThrows(try ProxyRecovery.applied(to:["ExceptionsList":4],port:27890,protectedDomains:[],exceptions:state.bypassProxyExceptions))
    }
    func testAllCaptureModesAndCoreValidation() throws {
        let candidate=try NodeParser.parse("ss://aes-128-gcm:synthetic@127.0.0.1:20000")
        let credentials=MemoryCredentials();try credentials.set(candidate.secret,for:candidate.node.credentialRef)
        for mode in CaptureMode.allCases {
            var state=AppState();state.captureMode=mode;state.nodes=[candidate.node];state.selectedID=candidate.node.id;state.addressFamilyPolicy = .dualStack
            state.rules=[RoutingRule(kind:.suffix,value:"test",action:.proxy)]
            try state.setBypasses([NetworkBypass(kind:.domain,value:"exact.test"),NetworkBypass(kind:.suffix,value:"corp.test"),NetworkBypass(kind:.cidr,value:"13.2.34.203")])
            let snapshot=NetworkSnapshot(primaryInterface:"en0",routes:[ProtectedRoute(destination:"0.0.0.0/0",gateway:"192.168.1.1",interface:"en0"),ProtectedRoute(destination:"13.2.0.0/16",gateway:"13.2.4.254",interface:"en6")],resolvers:[DNSResolverScope(service:"wifi",interface:"en0",servers:["192.168.1.1"],defaultResolver:true)])
            let plan=try CapturePlan.make(snapshot:snapshot,state:state)
            expectTrue(plan.protects("exact.test"));expectFalse(plan.protects("sub.exact.test"));expectTrue(plan.protects("sub.corp.test"))
            expectEqual(plan.protectedRoutes.first{$0.destination=="13.2.34.203/32"}?.interface,"en6")
            let control=CoreControlContext(port:20001,secret:String(repeating:"a",count:64))
            var data=try ConfigBuilder.build(state:state,credentials:credentials,control:control)
            if mode.usesTunnel {data=try TunConfigBuilder.build(state:state,credentials:credentials,control:control,address4:"100.64.1.1/30",address6:"fd71:717a::1/126",originalDNS:["192.168.1.1"],bypass:[],plan:plan,dnsForwardPort:20002)}
            let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let rules=(object["route"] as! [String:Any])["rules"] as! [[String:Any]]
            let bypassIndex=rules.firstIndex{($0["domain"] as? [String])==["exact.test"]}!
            let proxyIndex=rules.firstIndex{($0["domain_suffix"] as? [String])==["test"]}!
            expectTrue(bypassIndex<proxyIndex)
            let file=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("qingzhou-bypass-test-"+UUID().uuidString+".json")
            defer {try? FileManager.default.removeItem(at:file)}
            try data.write(to:file)
            let check=Process();check.executableURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/sing-box");check.arguments=["check","-c",file.path];check.standardOutput=FileHandle.nullDevice;try check.run();check.waitUntilExit();expectEqual(check.terminationStatus,0)
            if mode.usesTunnel {
                let directory=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
                defer{try? FileManager.default.removeItem(at:directory)}
                let dynamic=try DynamicCaptureRules(directory:directory,plan:plan)
                var config=object;dynamic.apply(to:&config,plan:plan)
                try JSONSerialization.data(withJSONObject:config).write(to:file)
                let check=Process();check.executableURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/sing-box");check.arguments=["check","-c",file.path];check.standardOutput=FileHandle.nullDevice;try check.run();check.waitUntilExit();expectEqual(check.terminationStatus,0)
                let resolver=plan.snapshot.resolvers[0]
                expectEqual(try plan.domainRoute(address:"203.0.113.5",resolver:resolver,host:"exact.test").interface,"en0")
                expectThrows(try plan.domainRoute(address:"203.0.113.5",resolver:resolver,host:"sub.exact.test"))
            }
        }
    }
    func testPinnedSafetyAndServiceIdentity() throws {
        let item=try NetworkBypass(kind:.cidr,value:"13.2.34.203",exit:.pinned,serviceID:"ethernet-service",gateway:"13.2.4.254").normalized()
        let services=[BypassNetworkService(id:"ethernet-service",name:"银行有线网络",interface:"en6",active:true)]
        expectEqual(try PinnedBypassPolicy.routes([item],services:services).first?.interface,"en6")
        let moved=[BypassNetworkService(id:"ethernet-service",name:"银行有线网络",interface:"en8",active:false)]
        expectEqual(try PinnedBypassPolicy.routes([item],services:moved).first?.interface,"en8")
        expectThrows(try PinnedBypassPolicy.routes([item],services:[]))
        expectThrows(try PinnedBypassPolicy.routes([item],services:[BypassNetworkService(id:"ethernet-service",name:"VPN",interface:"utun7",active:true)]))
        expectThrows(try PinnedBypassPolicy.routes([item],services:[BypassNetworkService(id:"ethernet-service",name:"invalid",interface:"en6\npass",active:true)]))
        let rules=PinnedBypassPolicy.firewallRules(try PinnedBypassPolicy.routes([item],services:services))
        expectTrue(rules.contains("block drop out quick on ! en6 inet from any to 13.2.34.203/32"));expectTrue(rules.contains("no state"))
        try PinnedBypassPolicy.validateFirewallRoot("anchor \"com.apple/*\" all\n")
        for root in ["","anchor \"com.sangfor.atrust\" all","pass out quick all\nanchor \"com.apple/*\" all","anchor \"com.apple/*\" all\npass all"] {expectThrows(try PinnedBypassPolicy.validateFirewallRoot(root))}
        expectEqual(TunRequest(operation:"prepare").protocolVersion,5)
    }
    func testLargeListAndIdentity() throws {
        let source=(0..<4000).map{NetworkBypass(kind:.domain,value:"service\($0).example.test",note:"备注\($0)")}
        let started=Date()
        let normalized=try NetworkBypassPolicy.normalize(source)
        expectEqual(normalized.count,4000)
        let selected=normalized.filter{$0.value.contains("service39")}
        let remove=Set(selected.map(\.id))
        let remaining=normalized.filter{!remove.contains($0.id)}
        expectEqual(remaining.count,normalized.count-selected.count)
        expectFalse(remaining.contains{remove.contains($0.id)})
        let parsed=NetworkBypassPolicy.parse(source.map(\.value).joined(separator:"\n"))
        expectEqual(parsed.items.count,4000);expectTrue(parsed.issues.isEmpty)
        print("BYPASS_LARGE_LIST seconds=\(Date().timeIntervalSince(started)) items=4000")
    }
}
func runNetworkBypassChecks() {
    let test=NetworkBypassTests()
    run("Bypass.normalization",test){try test.testNormalizationAndValidation()}
    run("Bypass.migrationAndBackup",test){try test.testMigrationBackupAndDisabledItems()}
    run("Bypass.batchAndConversion",test){try test.testBatchAndConversion()}
    run("Bypass.proxyOwnership",test){try test.testProxyExceptionsAndOwnership()}
    run("Bypass.captureModes",test){try test.testAllCaptureModesAndCoreValidation()}
    run("Bypass.pinnedSafety",test){try test.testPinnedSafetyAndServiceIdentity()}
    run("Bypass.largeList",test){try test.testLargeListAndIdentity()}
}

@MainActor func runBypassProtocolChecks() async throws {
    let directory=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("qingzhou-bypass-protocol-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:directory)}
    var operations:[String]=[]
    let capture=CaptureController(core:CoreController(directory:directory),proxy:SystemProxyController(journal:directory.appendingPathComponent("proxy.json")),helperRequest:{request in
        operations.append(request.operation)
        var reply=TunReply(ok:true,message:"旧版隔离服务",running:false);reply.protocolVersion=4;return reply
    })
    for mode in CaptureMode.allCases {
        var state=AppState();state.captureMode=mode
        try state.setBypasses([NetworkBypass(kind:.cidr,value:"203.0.113.9",exit:.pinned,serviceID:"isolated",gateway:"192.0.2.1")])
        do {try await capture.start(state,credentials:MemoryCredentials(),control:CoreControlContext(port:18990,secret:String(repeating:"a",count:64)));expectTrue(false,"旧辅助服务不得启动指定出口")}
        catch {expectTrue(error.localizedDescription.contains("辅助服务"))}
        expectNil(capture.activeMode);expectFalse(capture.running)
    }
    expectFalse(operations.contains("prepare") || operations.contains("pinBypasses"),"版本不匹配不能发送会修改网络的启动命令")
    var state=AppState();try state.setBypasses([NetworkBypass(kind:.cidr,value:"127.0.0.1")])
    let observed=try BypassDiagnostics.inspect("127.0.0.1",state:state,active:false)
    expectTrue(observed.rows.contains{$0.contains("系统代理选择")})
    expectTrue(observed.rows.contains{$0.contains("未取得本次轻舟隧道身份")})
    for input in ["","https://example.com","example.com/path","example.com:443"] {expectThrows(try BypassDiagnostics.inspect(input,state:state,active:false))}
    print("PASS NetworkBypass.protocolMismatchAndReadonlyDiagnostics")
}
