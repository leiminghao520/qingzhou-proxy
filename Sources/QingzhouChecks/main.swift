import Foundation
import QingzhouKit
import Darwin
import SystemConfiguration

let args = CommandLine.arguments
if args.count == 2 && args[1] == "quit-recovery-checks" {
    Task {
        do {try await runQuitRecoveryChecks()} catch {CheckHarness.failure("退出恢复检查异常："+error.localizedDescription,file:#filePath,line:#line)}
        print("RESULT quit_recovery_assertions=\(CheckHarness.assertions) failures=\(CheckHarness.failures)")
        exit(CheckHarness.failures == 0 ? 0 : 1)
    }
    dispatchMain()
}
if args.count == 3 && args[1] == "startup-benchmark" {
    Task {
        do {try await runStartupBenchmark(output:URL(fileURLWithPath:args[2]));exit(0)}
        catch {print("启动隔离基准失败："+error.localizedDescription);exit(1)}
    }
    dispatchMain()
}
if args.count == 2 && args[1] == "startup-checks" {
    Task {
        do {try await runStartupOptimizationChecks()} catch {CheckHarness.failure("启动优化检查异常："+error.localizedDescription,file:#filePath,line:#line)}
        print("RESULT startup_assertions=\(CheckHarness.assertions) failures=\(CheckHarness.failures)")
        exit(CheckHarness.failures == 0 ? 0 : 1)
    }
    dispatchMain()
}
if args.count == 3 && args[1] == "traffic-transport-checks", let port = Int(args[2]), (1...65535).contains(port) {
    Task { @MainActor in
        await runTrafficTransportChecks(port: port)
        exit(CheckHarness.failures == 0 ? 0 : 1)
    }
    dispatchMain()
}
if args.count == 2 && args[1] == "optimization-checks" {
    Task { @MainActor in
        await runRuntimeOptimizationChecks()
        print("RESULT optimization_assertions=\(CheckHarness.assertions) failures=\(CheckHarness.failures)")
        exit(CheckHarness.failures == 0 ? 0 : 1)
    }
    dispatchMain()
}
if args.count>=2 && args[1]=="network-acceptance" {
    Task{@MainActor in do {try await runNetworkAcceptance(args);exit(0)}catch{print("实网检查失败："+Redactor.redact(error.localizedDescription));exit(1)}}
    dispatchMain()
}

if args.count==3 && args[1]=="original-route-check" {
    do {
        let cidrs=try JSONDecoder().decode([String].self,from:Data(args[2].utf8))
        let table=try NetworkInspection.command("/usr/sbin/netstat",["-rn"]),prefixes=TunAddressPlan.routePrefixes(table)
        for cidr in cidrs {
            try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:cidr,action:.direct))
            if TunAddressPlan.containsRoute(cidr,prefixes:prefixes) {print("EXISTING "+cidr);continue}
            let host=String(cidr.split(separator:"/")[0])
            let info=try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.get,destination:host,ipv6:host.contains(":")))
            guard let gateway=NetworkInspection.routeGateway(info),let interface=NetworkInspection.routeField("interface",info) else {throw ProxyError("原出口无法确认："+cidr)}
            print("PLANNED "+cidr+" → "+interface+" / "+gateway)
        }
        print("ORIGINAL_ROUTE_CHECK_OK（只读，未写路由）");exit(0)
    }catch{print("ORIGINAL_ROUTE_CHECK_FAILED "+error.localizedDescription);exit(1)}
}
if args.count==2 && args[1]=="capture-snapshot" {
    do {let store=SCDynamicStoreCreate(nil,"轻舟只读快照" as CFString,nil,nil)!;let global=SCDynamicStoreCopyValue(store,"State:/Network/Global/IPv4" as CFString) as! [String:Any];let routes=try NetworkInspection.command("/usr/sbin/netstat",["-rn"]);let snapshot=try NetworkSnapshot.read(store:store,primary:global["PrimaryInterface"] as! String,routes:routes);let plan=try CapturePlan.make(snapshot:snapshot,extraCIDRs:[],extraDomains:[]);print("SNAPSHOT_OK routes=\(snapshot.routes.count) protected=\(plan.protectedRoutes.count)");for resolver in snapshot.resolvers {print("DNS interface=\(resolver.interface) servers=\(resolver.servers.count) default=\(resolver.defaultResolver) domains=\(resolver.protectedDomains.count)")};exit(0)}catch{print("SNAPSHOT_FAILED "+error.localizedDescription);exit(1)}
}
if args.count==4 && args[1]=="full-capture-fixture" {
    do {
        let folder=URL(fileURLWithPath:args[2]),ports=try JSONDecoder().decode([String:Int].self,from:Data(args[3].utf8))
        let node=try NodeParser.parse("ss://aes-128-gcm:synthetic@127.0.0.1:\(ports["server"]!)")
        let credentials=MemoryCredentials();try credentials.set(node.secret,for:node.node.credentialRef)
        var state=AppState();state.nodes=[node.node];state.selectedPolicy = .node(node.node.id);state.captureMode = .compatible;state.listenPort=ports["core"]!;state.addressFamilyPolicy = .ipv4Only
        state.rules=[RoutingRule(kind:.domain,value:"override.test",action:.direct),RoutingRule(kind:.domain,value:"qq.com",action:.proxy)]
        let shadow=try JSONDecoder().decode(ShadowrocketConfiguration.self,from:Data(#"{"version":1,"name":"synthetic","sourceFile":"fixture","sourceMode":"Config","general":{},"hosts":{},"rules":[{"kind":"FINAL","value":"","policy":"PROXY","noResolve":false}],"rewrites":[],"assets":{},"assetHashes":{}}"#.utf8))
        state.shadowrocket=shadow;state.httpCompatibilityEnabled=true
        let control=CoreControlContext(port:ports["control"]!,secret:String(repeating:"a",count:64))
        let data=try ConfigBuilder.build(state:state,credentials:credentials,control:control,httpCompatibilityPort:ports["http"]!)
        try SecureFile.write(shadow.gatewayData(listenPort:ports["gateway"]!,corePort:ports["core"]!,httpPort:ports["http"]!,control:control,state:state),to:folder.appendingPathComponent("gateway.json"))
        var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        var dns=object["dns"] as! [String:Any];dns["servers"]=["local","remote"].map{["type":"udp","tag":$0,"server":"127.0.0.1","server_port":ports[$0+"DNS"]!] as [String:Any]};object["dns"]=dns
        try SecureFile.write(JSONSerialization.data(withJSONObject:object),to:folder.appendingPathComponent("core.json"));print("FULL_CAPTURE_FIXTURE_READY");exit(0)
    }catch{print(error.localizedDescription);exit(1)}
}
if args.count==4 && ["combined-fixture","tun-config-fixture"].contains(args[1]) {
    do {
        let folder=URL(fileURLWithPath:args[2])
        let ports=try JSONDecoder().decode([String:Int].self,from:Data(args[3].utf8))
        let raw="""
        {"version":1,"name":"synthetic","sourceFile":"fixture","sourceMode":"Config","general":{},"hosts":{},"rules":[{"kind":"USER-AGENT","value":"SyntheticDirect*","policy":"DIRECT","noResolve":false},{"kind":"IP-CIDR","value":"192.0.2.0/24","policy":"DIRECT","noResolve":false},{"kind":"FINAL","value":"","policy":"PROXY","noResolve":false}],"rewrites":[{"pattern":"^http://rewrite.test/","replacement":"https://target.test/","status":302}],"assets":{},"assetHashes":{}}
        """
        let shadow=try JSONDecoder().decode(ShadowrocketConfiguration.self,from:Data(raw.utf8))
        let candidate=try NodeParser.parse("ss://aes-128-gcm:synthetic@127.0.0.1:\(ports["server"]!)")
        let credentials=MemoryCredentials();try credentials.set(candidate.secret,for:candidate.node.credentialRef)
        var state=AppState();state.nodes=[candidate.node];state.selectedPolicy = .node(candidate.node.id)
        state=try shadow.applying(to:state);state.httpCompatibilityEnabled=true;state.listenPort=ports["core"]!;state.captureMode = .tun;state.addressFamilyPolicy = .ipv4Only;state.dnsPreference = .system
        let control=CoreControlContext(port:ports["control"]!,secret:String(repeating:"a",count:64))
        let data=try TunConfigBuilder.build(state:state,credentials:credentials,control:control,address4:"100.64.1.1/30",address6:"fd71:717a:1::1/126",originalDNS:["127.0.0.1"],bypass:[],httpCompatibilityPort:ports["http"]!)
        var config=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        // 隔离用例保留组合配置和策略入口，只移除需要管理员权限的内核接管部分。
        if args[1]=="combined-fixture" {
        config["inbounds"]=(config["inbounds"] as! [[String:Any]]).filter{$0["type"] as? String != "tun"}
        var route=config["route"] as! [String:Any];route["auto_detect_interface"]=false;config["route"]=route
        }
        var dns=config["dns"] as! [String:Any]
        dns["servers"]=["local","remote"].map{["type":"udp","tag":$0,"server":"127.0.0.1","server_port":ports["dns"]!] as [String:Any]};config["dns"]=dns
        try SecureFile.write(JSONSerialization.data(withJSONObject:config),to:folder.appendingPathComponent("core.json"))
        try SecureFile.write(shadow.gatewayData(listenPort:ports["gateway"]!,corePort:ports["core"]!,httpPort:ports["http"]!,control:control,state:state),to:folder.appendingPathComponent("gateway.json"))
        print("COMBINED_FIXTURE_READY");exit(0)
    }catch{print(error.localizedDescription);exit(1)}
}
if args.count==3 && args[1]=="tun-route-diagnosis" {
    do {
        let routes=try String(contentsOfFile:args[2],encoding:.utf8)
        let bypass=["100.64.0.0/10"]
        let prefixes=TunAddressPlan.occupiedPrefixes(routes:routes,bypassCIDRs:bypass,physicalInterface:"en0")
        for candidate in ["100.64.1.1/30","198.18.1.1/30","fd71:717a:1::1/126"] {
            print(candidate+" blockedBy="+TunAddressPlan.conflicts(candidate:candidate,occupied:prefixes).joined(separator:","))
        }
        let plan=try TunAddressPlan.make(routes:routes,bypassCIDRs:bypass,physicalInterface:"en0")
        print("SELECTED "+plan.address4+" "+plan.address6)
    }catch{print("FAILED "+error.localizedDescription);exit(1)}
    exit(0)
}
if args.count==2 && args[1]=="network-conflict-check" {
    do{try NetworkSafety.check();print("NETWORK_PREFLIGHT_CLEAR")}catch{print("NETWORK_PREFLIGHT_BLOCKED "+error.localizedDescription)}
    exit(0)
}
if args.count==4 && args[1]=="full-subscription-install" {
    do {
        let source=try String(contentsOfFile:args[3],encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        guard let url=URL(string:source),url.scheme=="https",url.lastPathComponent=="qingzhou.json" else{throw ProxyError("完整订阅地址无效")}
        let text=try String(contentsOfFile:args[2],encoding:.utf8)
        let preview=try ProfileImporter.parse(text)
        guard preview.fullConfiguration != nil else{throw ProxyError("需要轻舟完整订阅")}
        let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Qingzhou")
        let fd=open(directory.appendingPathComponent("session.lock").path,O_RDWR)
        guard fd>=0 else{throw ProxyError("配置锁缺失")};defer{close(fd)}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else{throw ProxyError("请先正常退出轻舟")}
        let credentials=KeychainStore()
        let store=try NodeStore(file:directory.appendingPathComponent("state.json"),credentials:credentials)
        // 变更前保存含凭据的加密快照，备份口令仅进入钥匙串。
        let snapshot=try BackupService.snapshot(store.catalog,credentials:credentials)
        let password=UUID().uuidString+UUID().uuidString
        let ref="full-subscription-backup-"+UUID().uuidString
        try credentials.set(password,for:ref)
        let backup=directory.appendingPathComponent(ref+".qzb")
        try SecureFile.write(BackupService.encrypt(snapshot,password:password),to:backup)
        try SecureFile.write(Data(ref.utf8),to:directory.appendingPathComponent("full-subscription-backup.keyref"))
        let sub=store.state.subscriptions.first(where:{$0.revision != nil}) ?? store.state.subscriptions.first(where:{sub in store.state.nodes.contains{node in node.subscriptionID==sub.id && preview.candidates.contains{$0.node.fingerprint==node.fingerprint}}}) ?? Subscription(name:preview.profileName ?? "VPS 完整配置")
        let localCount=store.state.rules.filter{$0.subscriptionID==nil}.count
        let tx=try store.prepareImport(preview.candidates,subscription:sub,source:source,profile:preview,scope:.profile)
        do{try store.commit(tx)}catch{store.abort(tx);throw error}
        print("FULL_SUBSCRIPTION_INSTALLED nodes=\(store.state.nodes.count) rules=\(store.state.rules.count) fullSubscriptions=\(store.state.subscriptions.filter{$0.revision != nil}.count) autoUpdate=\(store.state.subscriptions.first{$0.id==sub.id}?.autoUpdate == true) previousLocalRules=\(localCount)")
        exit(0)
    }catch{fputs("完整订阅接入失败："+Redactor.redact(error.localizedDescription)+"\n",stderr);exit(1)}
}

if args.count>=5 && args[1]=="shadowrocket-prepare" {
    do {
        let defaults=try JSONDecoder().decode(ShadowrocketConfiguration.self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
        try defaults.validate()
        var catalog=try JSONDecoder().decode(ProfileCatalog.self,from:Data(contentsOf:URL(fileURLWithPath:args[3])))
        let previous=catalog.active
        let next=try defaults.applying(to:previous)
        expectEqual(next.nodes,previous.nodes)
        expectEqual(defaults.rules.count,619)
        expectEqual(defaults.rewrites.count,2)
        expectTrue(next.rules.contains{$0.kind == .geoip})
        expectTrue(next.rules.contains{$0.kind == .asn})
        expectTrue(next.rules.contains{$0.kind == .userAgent})
        var test=next;test.nodes=[];test.groups=[];test.selectedID=nil;test.selectedPolicy=nil
        let control=CoreControlContext(port:19091,secret:String(repeating:"a",count:64))
        test.listenPort=19090
        let data=try ConfigBuilder.build(state:test,credentials:MemoryCredentials(),control:control,httpCompatibilityPort:19092)
        try SecureFile.write(data,to:URL(fileURLWithPath:args[4]+".core.json"))
        try SecureFile.write(defaults.gatewayData(listenPort:19089,corePort:19090,httpPort:19092,control:control,state:test),to:URL(fileURLWithPath:args[4]+".gateway.json"))
        catalog.updateActive(next)
        try catalog.validate()
        guard CheckHarness.failures==0 else{throw ProxyError("兼容配置断言失败")}
        try SecureFile.write(JSONEncoder().encode(catalog),to:URL(fileURLWithPath:args[4]))
        print("SHADOWROCKET_PREPARE_OK rules=\(next.rules.count) originalRules=\(defaults.rules.count) rewrites=\(defaults.rewrites.count) nodesPreserved=\(next.nodes.count)")
        exit(0)
    }catch{fputs("Shadowrocket 配置转换校验失败："+error.localizedDescription+"\n",stderr);exit(1)}
}

if args.count >= 5 && args[1] == "config" {
    do {
        let input = try String(contentsOfFile:args[2],encoding:.utf8)
        let c = try NodeParser.parseList(input)[0]
        let credentials = MemoryCredentials();try credentials.set(c.secret,for:c.node.credentialRef)
        if let secret = c.obfsSecret {try credentials.set(secret,for:c.node.credentialRef + ".obfs")}
        var state = AppState();state.listenPort = Int(args[4]) ?? 0;state.rulesEnabled = false
        if args.count > 5 && args[5] == "rules" { state.rulesEnabled = true;state.rules = [RoutingRule(kind:.domain,value:"reject.test",action:.reject),RoutingRule(kind:.domain,value:"direct.test",action:.direct),RoutingRule(kind:.domain,value:"proxy.test",action:.proxy),RoutingRule(kind:.suffix,value:"corp.test",action:.direct)] }
        if args.contains("https-dns") {state.dnsPreference = .httpsProxy}
        try SecureFile.write(ConfigBuilder.build(node:c.node,state:state,credentials:credentials),to:URL(fileURLWithPath:args[3]))
        print("CONFIG_OK");exit(0)
    } catch {print(Redactor.redact(error.localizedDescription));exit(1)}
}
if args.count >= 5 && args[1] == "subscription-config" {
    let input = try String(contentsOfFile:args[2],encoding:.utf8)
    Task {
        do {
            let preview = try await ImportService.preview(input)
            guard let c = preview.candidates.first else {throw ProxyError("订阅没有节点")}
            let credentials = MemoryCredentials();try credentials.set(c.secret,for:c.node.credentialRef)
            if let obfs = c.obfsSecret {try credentials.set(obfs,for:c.node.credentialRef + ".obfs")}
            var state = AppState();state.listenPort = Int(args[4]) ?? 0;state.rulesEnabled = false
            if args.contains("https-dns") {state.dnsPreference = .httpsProxy}
        try SecureFile.write(ConfigBuilder.build(node:c.node,state:state,credentials:credentials),to:URL(fileURLWithPath:args[3]))
            print("SUBSCRIPTION_CONFIG_OK nodes=\(preview.candidates.count)");exit(0)
        } catch {print(Redactor.redact(error.localizedDescription));exit(1)}
    }
    dispatchMain()
}
if args.count >= 5 && args[1] == "subscription-v02-config" {
    let input = try String(contentsOfFile:args[2],encoding:.utf8)
    Task {
        do {
            let preview = try await ImportService.preview(input)
            guard let c = preview.candidates.first else {throw ProxyError("订阅没有节点")}
            let credentials = MemoryCredentials();try credentials.set(c.secret,for:c.node.credentialRef)
            if let obfs = c.obfsSecret {try credentials.set(obfs,for:c.node.credentialRef + ".obfs")}
            var state = AppState();state.listenPort = Int(args[4]) ?? 0;state.mode = .global;state.nodes=preview.candidates.map(\.node);state.selectedPolicy = .node(c.node.id)
            for candidate in preview.candidates {try credentials.set(candidate.secret,for:candidate.node.credentialRef);if let obfs=candidate.obfsSecret{try credentials.set(obfs,for:candidate.node.credentialRef+".obfs")}}
            try SecureFile.write(ConfigBuilder.build(state:state,credentials:credentials,control:CoreControlContext.make()),to:URL(fileURLWithPath:args[3]))
            print("SUBSCRIPTION_V02_CONFIG_OK nodes=\(preview.candidates.count)");exit(0)
        } catch {print(Redactor.redact(error.localizedDescription));exit(1)}
    }
    dispatchMain()
}
if args.count>=5 && args[1]=="subscription-v03-config" {
    let input=try String(contentsOfFile:args[2],encoding:.utf8)
    Task{do{let preview=try await ImportService.preview(input);let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)};let credentials=MemoryCredentials();let store=try NodeStore(file:directory.appendingPathComponent("state.json"),credentials:credentials);try store.commit(store.prepareImport(preview.candidates,subscription:Subscription(name:"本轮验收"),source:preview.source));var state=store.state;state.listenPort=Int(args[4]) ?? 0;state.mode = .global;try store.commit(state);try SecureFile.write(ConfigBuilder.build(state:store.state,credentials:credentials,control:CoreControlContext.make()),to:URL(fileURLWithPath:args[3]));print("SUBSCRIPTION_V03_CONFIG_OK schema=\(store.catalog.schemaVersion) nodes=\(store.state.nodes.count)");exit(0)}catch{print(Redactor.redact(error.localizedDescription));exit(1)}};dispatchMain()
}
if args.count >= 3 && args[1] == "preview" {
    let input = try String(contentsOfFile:args[2],encoding:.utf8)
    Task {
        do {let result = try await ImportService.preview(input); print("PREVIEW_OK nodes=\(result.candidates.count)");exit(0)}
        catch {print(Redactor.redact(error.localizedDescription));exit(1)}
    }
    dispatchMain()
}
if args.count >= 3 && args[1] == "proxy-probe" {
    Task {
        let ok = await ConnectivityProbe.test(port:Int(args[2]) ?? 0)
        print(ok ? "NATIVE_HTTPS_PROXY_PROBE_OK" : "NATIVE_HTTPS_PROXY_PROBE_FAILED")
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}
if args.count >= 2 && args[1] == "system-proxy-checks" {
    guard geteuid() == 0 else {print("SKIP system-proxy-checks: 隔离 SCPreferences 写入也需要本机管理员权限；请使用 sudo 运行此测试");exit(77)}
    Task { @MainActor in
        do {try runSystemProxyChecks()} catch {CheckHarness.failure("隔离代理场景失败：" + error.localizedDescription,file:#filePath,line:#line)}
        print("RESULT system_proxy_failures=\(CheckHarness.failures)")
        exit(CheckHarness.failures == 0 ? 0 : 1)
    }
    dispatchMain()
}
if args.count >= 2 && args[1] == "runtime-checks" {
    Task { @MainActor in
        do {try await runRuntimeChecks()} catch {CheckHarness.failure("运行时场景失败：" + error.localizedDescription,file:#filePath,line:#line)}
        print("RESULT runtime_failures=\(CheckHarness.failures)")
        exit(CheckHarness.failures == 0 ? 0 : 1)
    }
    dispatchMain()
}
if args.count>=8 && args[1]=="v02-config" {
    do{try writeFeatureConfig(args);exit(0)}catch{print(Redactor.redact(error.localizedDescription));exit(1)}
}
if args.count>=4 && args[1]=="api-checks" {
    Task {
        do{try await runFeatureAPIChecks(args)}catch{CheckHarness.failure("核心 API 检查失败："+Redactor.redact(error.localizedDescription),file:#filePath,line:#line)}
        print("RESULT feature_api_failures=\(CheckHarness.failures)");exit(CheckHarness.failures==0 ? 0:1)
    }
    dispatchMain()
}
if args.count>=4 && args[1]=="fallback-checks"{Task{do{try await runFallbackChecks(args)}catch{CheckHarness.failure("回退 API 检查失败",file:#filePath,line:#line)};print("RESULT fallback_api_failures=\(CheckHarness.failures)");exit(CheckHarness.failures==0 ? 0:1)};dispatchMain()}
if args.count==2 && args[1]=="capture-preflight"{do{try NetworkInspection.checkConflicts();print("TUN_PREFLIGHT_NO_CONFLICT");exit(0)}catch{print("TUN_PREFLIGHT_BLOCKED: "+Redactor.redact(error.localizedDescription));exit(77)}}
var scenarios = 0
func run(_ name:String,_ instance:CheckCase,_ body:() throws -> Void) {
    let before = CheckHarness.failures
    do {try instance.setUpWithError();try body()} catch {CheckHarness.failure("场景抛出错误：" + Redactor.redact(error.localizedDescription),file:#filePath,line:#line)}
    do {try instance.tearDownWithError()} catch {CheckHarness.failure("测试清理失败",file:#filePath,line:#line)}
    scenarios += 1;print("\(CheckHarness.failures == before ? "PASS" : "FAIL") \(name)")
}
do {let t=RepairTests();run("Repair.compatibilityMigration",t){try t.testCompatibilityMigrationAndImport()};run("Repair.importTypes",t){try t.testImportTypesAndNoResolve()};run("Repair.orderedDNS",t){try t.testOrderedDNSAndMode()};run("Repair.unknownFallback",t){t.testUnknownFallbackAndHealth()};run("Repair.dnsCompression",t){t.testDNSPacketCompression()};run("Repair.searchDomainIsolation",t){try t.testSearchDomainIsolation()}}
do { let instance = ConfigTests(); run("ConfigTests.testHysteriaPreservesUserpassAndObfs",instance) { try instance.testHysteriaPreservesUserpassAndObfs() } }
do { let instance = ConfigTests(); run("ConfigTests.testProtocolConfigurations",instance) { try instance.testProtocolConfigurations() } }
do { let instance = ConfigTests(); run("ConfigTests.testRulesAndModes",instance) { try instance.testRulesAndModes() } }
do { let instance = ConfigTests(); run("ConfigTests.testRuleValidation",instance) { try instance.testRuleValidation() } }
do { let instance = ConfigTests(); run("ConfigTests.testCoreCheckAllSupportedConfigs",instance) { try instance.testCoreCheckAllSupportedConfigs() } }
do { let instance = ParserTests(); run("ParserTests.testHysteriaAuthenticationAndIPv6",instance) { try instance.testHysteriaAuthenticationAndIPv6() } }
do { let instance = ParserTests(); run("ParserTests.testShadowsocksEncoding",instance) { try instance.testShadowsocksEncoding() } }
do { let instance = ParserTests(); run("ParserTests.testTrojanAndVless",instance) { try instance.testTrojanAndVless() } }
do { let instance = ParserTests(); run("ParserTests.testInvalidInputsAreRejectedWithoutSecrets",instance) { try instance.testInvalidInputsAreRejectedWithoutSecrets() } }
do { let instance = ParserTests(); run("ParserTests.testListIsAtomicAndBounded",instance) { try instance.testListIsAtomicAndBounded() } }
do { let instance = ParserTests(); run("ParserTests.testPortRanges",instance) { try instance.testPortRanges() } }
do { let instance = ParserTests(); run("ParserTests.testRedaction",instance) { try instance.testRedaction() } }
do {let t=FullCaptureTests();run("FullCapture.domestic",t){try t.testDomesticPriorityAndDNS()};run("FullCapture.dynamicProtection",t){try t.testDynamicAddressProtectionAndFailure()};run("FullCapture.loopback",t){try t.testLoopbackAndCorporateFallback()};run("FullCapture.frozenPathsAndDiagnostics",t){try t.testFrozenBypassPlanAndDiagnostics()};run("FullCapture.ownershipView",t){try t.testOwnershipUsesCompleteRouteView()};run("FullCapture.multicastScope",t){try t.testMulticastPreservesSystemScope()}}
do {let instance=RepairTests();run("RepairTests.corporateProxyBypass",instance){try instance.testCorporateProxyBypass()}}
do {let instance=RepairTests();run("RepairTests.tongdunProtectionDraft",instance){try instance.testTongdunProtectionDraft()}}
do {let instance=FullCaptureTests();run("FullCapture.effectiveDNSPriority",instance){try instance.testEffectiveDNSPriority()};run("FullCapture.reclaimedCorporateHostRoute",instance){try instance.testReclaimedCorporateHostRoute()}}
do { let instance = RecoveryTests(); run("RecoveryTests.testOriginalPACAndProxyRestored",instance) { try instance.testOriginalPACAndProxyRestored() } }
do { let instance = RecoveryTests(); run("RecoveryTests.testUnrelatedExternalChangesPreserved",instance) { try instance.testUnrelatedExternalChangesPreserved() } }
do { let instance = RecoveryTests(); run("RecoveryTests.testOwnedFieldConflictDoesNotOverwrite",instance) { try instance.testOwnedFieldConflictDoesNotOverwrite() } }
do { let instance = StoreTests(); run("StoreTests.testManualDeduplicationAndSecretsNotPersisted",instance) { try instance.testManualDeduplicationAndSecretsNotPersisted() } }
do { let instance = StoreTests(); run("StoreTests.testSubscriptionUpdateKeepsIDAndManualNodes",instance) { try instance.testSubscriptionUpdateKeepsIDAndManualNodes() } }
do { let instance = StoreTests(); run("StoreTests.testFailureLeavesOldStateAndCredentials",instance) { try instance.testFailureLeavesOldStateAndCredentials() } }
do { let instance = StoreTests(); run("StoreTests.testEditAndConflict",instance) { try instance.testEditAndConflict() } }
do { let instance = StoreTests(); run("StoreTests.testUnsupportedStateIsNotOverwritten",instance) { try instance.testUnsupportedStateIsNotOverwritten() } }
do {let instance=EnhancementTests();run("EnhancementTests.testLegacyMigrationPreservesReferencesAndBackup",instance){try instance.testLegacyMigrationPreservesReferencesAndBackup()}}
do {let instance=EnhancementTests();run("EnhancementTests.testPreparedUpdateAbortAndCommit",instance){try instance.testPreparedUpdateAbortAndCommit()}}
do {let instance=EnhancementTests();run("EnhancementTests.testProfileYAMLAndBase64",instance){try instance.testProfileYAMLAndBase64()}}
do {let instance=EnhancementTests();run("EnhancementTests.testYAMLUnsupportedContentAndCycles",instance){try instance.testYAMLUnsupportedContentAndCycles()}}
do {let instance=EnhancementTests();run("EnhancementTests.testProfileImportStableGroupsAndRules",instance){try instance.testProfileImportStableGroupsAndRules()}}
do {let instance=EnhancementTests();run("EnhancementTests.testGroupValidationAndRepair",instance){try instance.testGroupValidationAndRepair()}}
do {let instance=EnhancementTests();run("EnhancementTests.testRemoteRuleFormatsAndRejections",instance){try instance.testRemoteRuleFormatsAndRejections()}}
do {let instance=EnhancementTests();run("EnhancementTests.testScheduleAndUsage",instance){try instance.testScheduleAndUsage()}}
do {let instance=EnhancementTests();run("EnhancementTests.testMultiConfigCoreValidationAndTokenSeparation",instance){try instance.testMultiConfigCoreValidationAndTokenSeparation()}}
do {let instance=DailyTests();run("DailyTests.testProfilesIsolationAndSharedCredentials",instance){try instance.testProfilesIsolationAndSharedCredentials()}}
do {let instance=DailyTests();run("DailyTests.testMigrationBackupAndFailure",instance){try instance.testMigrationBackupAndFailure()}}
do {let instance=DailyTests();run("DailyTests.testEncryptedBackupIntegrityAndAtomicRestore",instance){try instance.testEncryptedBackupIntegrityAndAtomicRestore()}}
do {let instance=DailyTests();run("DailyTests.testLegacyExportAndCredentialConflict",instance){try instance.testLegacyExportAndCredentialConflict()}}
do {let instance=DailyTests();run("DailyTests.testFallbackThresholdsAndUnavailable",instance){try instance.testFallbackThresholdsAndUnavailable()}}
do {let instance=DailyTests();run("DailyTests.testRuleExplanationAndBoundaries",instance){try instance.testRuleExplanationAndBoundaries()}}
do {let instance=DailyTests();run("DailyTests.testUpdateDiffAndPersonalMetadata",instance){try instance.testUpdateDiffAndPersonalMetadata()}}
do {let instance=DailyTests();run("DailyTests.testShareRoundtripAndFallbackValidation",instance){try instance.testShareRoundtripAndFallbackValidation()}}
do {let instance=DailyTests();run("DailyTests.testTunModelAndConflictDetection",instance){try instance.testTunModelAndConflictDetection()}}
do{let tests=FullSubscriptionTests();run("FullSubscriptionTests.localRulesAndRollback",tests){try tests.testFullSyncPreservesLocalRulesAndRollback()};run("FullSubscriptionTests.invalidDocuments",tests){try tests.testInvalidDocumentsPreserveOldData()}}
do{let t=NetworkSafetyTests();run("NetworkSafety.proxyOwnership",t){t.testPersistentProxyOwnership()};run("NetworkSafety.conflicts",t){t.testConflictDetection()};run("NetworkSafety.deadProxyOwnership",t){t.testDeadProxyRestorationAndOwnership()};run("NetworkSafety.unknownHealth",t){t.testUnknownHealthDoesNotMeanNodeFailure()};run("NetworkSafety.privateLog",t){try t.testBoundedPrivateLogAndRedaction()}}
do{let t=NetworkPolicyTests();run("NetworkPolicy.preparationRace",t){try t.testPreparationRaceAndDNSBudget()};run("NetworkPolicy.tunAddresses",t){try t.testTunAddressAllocation()};run("NetworkPolicy.corporateRoutes",t){t.testSpecificCorporateRoutesAndSystemTunnels()};run("NetworkPolicy.migration",t){try t.testMigrationAndImport()};run("NetworkPolicy.coreMatrix",t){try t.testCoreNetworkMatrix()}}
do {let t=DynamicVPNTests();run("DynamicVPN.optionalDNSAndGeneration",t){try t.testOptionalDNSAndGeneration()};run("DynamicVPN.stableWindowAndPartitions",t){try t.testStableWindowAndPartitions()}}
do{let t=CapturePlanTests();run("CapturePlan.protection",t){try t.testProtectionAndResolverSelection()};run("CapturePlan.loopback",t){try t.testLoopbackRelay()};run("CapturePlan.dnsRetries",t){try t.testDNSRetriesAndNoPublicFallback()};run("CapturePlan.routesOwnership",t){try t.testRouteParsingAndOwnership()};run("CapturePlan.core",t){try t.testCoreConfigurationProtectionPrecedence()}}
do{let t=KeychainUXTests();run("KeychainUX.authorization",t){try t.testAuthorizationRetryAndCache()};run("KeychainUX.errors",t){try t.testDistinctErrorsAndAtomicCache()}}
do{let t=StabilityTests();run("Stability.snapshotRetryAndLatency",t){t.testSnapshotRetryAndLatency()};run("Stability.dnsQueueBoundsBudgetAndStop",t){t.testDNSQueueBoundsBudgetAndStop()};run("Stability.subscriptionClassificationAndRetry",t){t.testSubscriptionClassificationAndRetry()}}
Task {
    do {try await runStartupOptimizationChecks()} catch {CheckHarness.failure("启动优化检查异常",file:#filePath,line:#line)}
    do {try await runQuitRecoveryChecks()} catch {CheckHarness.failure("退出恢复检查异常",file:#filePath,line:#line)}
    await runRuntimeOptimizationChecks()
    await runStabilityAsyncChecks()
    await runCaptureActivationChecks()
    await runRecoveryContinuationChecks()
    await runHelperRecoveryPolicyChecks()
    await runHelperReadinessChecks()
    try await runDNSResolutionPolicyChecks()
    await runPortReuseChecks()
    await runConnectivityChecks()
    await runRepairHealthChecks()
    await runNetworkProbeChecks()
    await runAsyncChecks()
    do{try await runTransactionChecks()}catch{CheckHarness.failure("事务场景异常",file:#filePath,line:#line)}
    print("RESULT scenarios=\(scenarios + 47) assertions=\(CheckHarness.assertions) failures=\(CheckHarness.failures)")
    exit(CheckHarness.failures == 0 ? 0 : 1)
}
dispatchMain()
