import Foundation
import QingzhouKit
import Darwin

let args = CommandLine.arguments
if args.count >= 5 && args[1] == "config" {
    do {
        let input = try String(contentsOfFile:args[2],encoding:.utf8)
        let c = try NodeParser.parseList(input)[0]
        let credentials = MemoryCredentials();try credentials.set(c.secret,for:c.node.credentialRef)
        if let secret = c.obfsSecret {try credentials.set(secret,for:c.node.credentialRef + ".obfs")}
        var state = AppState();state.listenPort = Int(args[4]) ?? 0;state.rulesEnabled = false
        if args.count > 5 && args[5] == "rules" { state.rulesEnabled = true;state.rules = [RoutingRule(kind:.domain,value:"reject.test",action:.reject),RoutingRule(kind:.domain,value:"direct.test",action:.direct),RoutingRule(kind:.domain,value:"proxy.test",action:.proxy)] }
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
Task {
    await runAsyncChecks()
    do{try await runTransactionChecks()}catch{CheckHarness.failure("事务场景异常",file:#filePath,line:#line)}
    print("RESULT scenarios=\(scenarios + 12) assertions=\(CheckHarness.assertions) failures=\(CheckHarness.failures)")
    exit(CheckHarness.failures == 0 ? 0 : 1)
}
dispatchMain()
