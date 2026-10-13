import Foundation
import QingzhouKit

final class DailyTests:CheckCase {
    func testProfilesIsolationAndSharedCredentials() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let credentials=MemoryCredentials();let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:credentials)
        try store.importNodes([try NodeParser.parse("hy2://pass@example.com")]);let first=store.catalog.currentProfileID;let original=store.state.nodes[0];var config=store.state;config.notes[original.id.uuidString]="个人备注";config.favorites.insert(original.id);try store.commit(config)
        let copied=try ProfileStore.create(in:store.catalog,name:"办公",copyID:first,officeDomains:["intranet.example"]);try store.commit(store.prepareCatalog(copied));let second=store.catalog.profiles.last!.id;try store.commit(store.prepareCatalog(ProfileStore.switchTo(second,in:store.catalog)));expectEqual(store.state.rules.count,1);try store.commit(store.prepareDeleteNode(original.id));expectEqual(try credentials.get(original.credentialRef),"pass")
        try store.commit(store.prepareCatalog(ProfileStore.switchTo(first,in:store.catalog)));expectEqual(store.state.nodes.count,1);expectEqual(store.state.notes[original.id.uuidString],"个人备注");expectTrue(store.state.favorites.contains(original.id));expectEqual(store.state.rules.count,0)
        expectThrows(try ProfileStore.remove(first,in:store.catalog));expectThrows(try ProfileStore.create(in:store.catalog,name:" "));expectThrows(try ProfileStore.create(in:store.catalog,name:"办公",officeDomains:["http://bad"]))
        try store.commit(store.prepareCatalog(ProfileStore.remove(second,in:store.catalog)));expectEqual(store.catalog.profiles.count,1);expectEqual(try NodeStore(file:store.file,credentials:credentials).catalog.schemaVersion,3)
    }
    func testMigrationBackupAndFailure() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let candidate=try NodeParser.parse("hy2://pass@example.com");var state=AppState();state.nodes=[candidate.node];state.selectedID=candidate.node.id;state.favorites=[candidate.node.id];let file=dir.appendingPathComponent("state.json");let data=try JSONEncoder().encode(state);try SecureFile.write(data,to:file)
        let creds=MemoryCredentials();expectThrows(try NodeStore(file:file,credentials:creds));expectEqual(try Data(contentsOf:file),data);try creds.set(candidate.secret,for:candidate.node.credentialRef)
        let store=try NodeStore(file:file,credentials:creds);let ref=try String(contentsOf:dir.appendingPathComponent("migration-v3.keyref"),encoding:.utf8);let snapshot=try BackupService.decrypt(Data(contentsOf:dir.appendingPathComponent("migration-v3.qzb")),password:creds.get(ref));expectEqual(snapshot.catalog.active.nodes[0].id,candidate.node.id);expectEqual(snapshot.credentials[candidate.node.credentialRef],"pass");expectEqual(store.catalog.schemaVersion,3);expectEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testEncryptedBackupIntegrityAndAtomicRestore() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let creds=MemoryCredentials();let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:creds);try store.importNodes([try NodeParser.parse("hy2://auth@example.com?obfs=salamander&obfs-password=secret")]);let old=store.state.nodes[0]
        let snapshot=try BackupService.snapshot(store.catalog,credentials:creds);let encrypted=try BackupService.encrypt(snapshot,password:"测试口令");expectFalse(String(decoding:encrypted,as:UTF8.self).contains("secret"));expectThrows(try BackupService.decrypt(encrypted,password:"wrong"));var corrupted=encrypted;corrupted[corrupted.count/2]^=1;expectThrows(try BackupService.decrypt(corrupted,password:"测试口令"));expectThrows(try BackupService.decrypt(Data("{}".utf8),password:"p"));expectThrows(try BackupService.encrypt(snapshot,password:""))
        let decoded=try BackupService.decrypt(encrypted,password:"测试口令");let tx=try store.prepareRestore(decoded);let staged=tx.next.nodes[0];expectEqual(try creds.get(staged.credentialRef+".obfs"),"secret");expectEqual(try creds.get(old.credentialRef),"auth");store.abort(tx);expectThrows(try creds.get(staged.credentialRef));expectEqual(store.state.nodes[0],old)
        let committed=try store.prepareRestore(decoded);try store.commit(committed);expectEqual(try creds.get(store.state.nodes[0].credentialRef),"auth");expectThrows(try creds.get(old.credentialRef));expectEqual(store.state.nodes[0].id,old.id)
    }
    func testLegacyExportAndCredentialConflict() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let c=try NodeParser.parse("hy2://old@example.com");var state=AppState();state.nodes=[c.node];state.selectedPolicy = .node(c.node.id);let snapshot=BackupSnapshot(catalog:ProfileCatalog(state:state),credentials:[c.node.credentialRef:c.secret]);let creds=MemoryCredentials();let file=dir.appendingPathComponent("legacy.json")
        try BackupService.exportLegacy(snapshot,to:file,credentials:creds);expectEqual(try creds.get(c.node.credentialRef),"old");expectEqual(try JSONDecoder().decode(AppState.self,from:Data(contentsOf:file)).schemaVersion,2)
        try creds.set("different",for:c.node.credentialRef);let original=try Data(contentsOf:file);expectThrows(try BackupService.exportLegacy(snapshot,to:file,credentials:creds));expectEqual(try Data(contentsOf:file),original);expectEqual(try creds.get(c.node.credentialRef),"different")
        var unsupported=snapshot;unsupported.catalog.profiles[0].configuration.groups=[PolicyGroup(name:"回退",kind:.fallback,members:[.node(c.node.id)])];expectThrows(try BackupService.exportLegacy(unsupported,to:file,credentials:creds))
        expectTrue(NetworkInspection.samePrefix("2001:db8::/32","2001:db8:0::/32"));expectFalse(NetworkInspection.samePrefix("10.0.0.0/8","10.0.0.0/16"));expectEqual(NetworkInspection.routePrefix(destination:"10.0.0.0",mask:"255.0.0.0"),"10.0.0.0/8");expectNil(NetworkInspection.routePrefix(destination:"default",mask:"default"));expectNil(NetworkInspection.routePrefix(destination:"10.0.0.0",mask:"255.1.0.0"))
    }
    func testFallbackThresholdsAndUnavailable() throws {
        let a=UUID(),b=UUID();var controller=FallbackController();let t=Date(timeIntervalSince1970:100)
        expectEqual(controller.evaluate(priority:[a,b],current:a,results:[a:false,b:true],now:t).selected,a)
        expectEqual(controller.evaluate(priority:[a,b],current:a,results:[a:false,b:true],now:t.addingTimeInterval(60)).selected,b)
        expectEqual(controller.evaluate(priority:[a,b],current:b,results:[a:true,b:true],now:t.addingTimeInterval(120)).selected,b)
        expectEqual(controller.evaluate(priority:[a,b],current:b,results:[a:true,b:true],now:t.addingTimeInterval(180)).selected,a)
        expectEqual(controller.evaluate(priority:[a,b],current:a,results:[a:false,b:true],now:t.addingTimeInterval(181)).selected,a)
        expectEqual(controller.evaluate(priority:[a,b],current:a,results:[a:false,b:true],now:t.addingTimeInterval(200)).selected,a)
        expectEqual(controller.evaluate(priority:[a,b],current:a,results:[a:false,b:true],now:t.addingTimeInterval(240)).selected,b)
        expectFalse(controller.evaluate(priority:[a,b],current:b,results:[a:false,b:false],now:t.addingTimeInterval(300)).unavailable)
        expectTrue(controller.evaluate(priority:[a,b],current:b,results:[a:false,b:false],now:t.addingTimeInterval(360)).unavailable)
        expectTrue(controller.evaluate(priority:[],current:nil,results:[:]).unavailable)
    }
    func testRuleExplanationAndBoundaries() throws {
        var state=AppState();state.rules=[RoutingRule(kind:.suffix,value:"example.com",action:.reject),RoutingRule(kind:.keyword,value:"office",action:.direct)]
        expectEqual(try RuleEvaluator.explain("10.2.3.4",state:state).target,.direct);expectEqual(try RuleEvaluator.explain("fc00::123",state:state).target,.direct);expectEqual(try RuleEvaluator.explain("sub.example.com",state:state).target,.reject);expectEqual(try RuleEvaluator.explain("office.test",state:state).target,.direct)
        expectFalse(RuleEvaluator.matches(RoutingRule(kind:.suffix,value:"example.com",action:.direct),host:"badexample.com",ip:nil)==true)
        expectEqual(RuleEvaluator.matches(RoutingRule(kind:.cidr,value:"2001:db8::/32",action:.proxy),host:"2001:db8::1",ip:"2001:db8::1"),true);expectEqual(RuleEvaluator.matches(RoutingRule(kind:.cidr,value:"1.2.3.0/999",action:.proxy),host:"1.2.3.4",ip:"1.2.3.4"),false)
        state.rules.insert(RoutingRule(kind:.cidr,value:"8.8.8.0/24",action:.direct),at:0);expectNil(try RuleEvaluator.explain("example.com",state:state).target);expectThrows(try RuleEvaluator.explain("https://example.com",state:state));state.mode = .direct;expectEqual(try RuleEvaluator.explain("example.com",state:state).target,.direct)
    }
    func testUpdateDiffAndPersonalMetadata() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let creds=MemoryCredentials();let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:creds);let sub=Subscription(name:"测试");try store.importNodes([try NodeParser.parse("hy2://p@example.com#旧")],subscription:sub,source:"https://example.com/sub");let old=store.state.nodes[0];var state=store.state;state.selectedPolicy = .node(old.id);state.notes[old.id.uuidString]="个人";state.favorites.insert(old.id);try store.commit(state)
        let preview=try ProfileImporter.parse("hy2://p@example.com?insecure=1#新");let diff=UpdateDiff.compare(old:state,preview:preview,subscriptionID:sub.id);expectTrue(diff.requiresReview);expectEqual(diff.certificateChanges,["新"]);expectEqual(diff.changed,["新"])
        let tx=try store.prepareImport(preview.candidates,subscription:sub);expectEqual(tx.next.notes[tx.next.nodes[0].id.uuidString],"个人");expectTrue(tx.next.favorites.contains(tx.next.nodes[0].id));store.abort(tx)
    }
    func testShareRoundtripAndFallbackValidation() throws {
        let creds=MemoryCredentials();for uri in ["hy2://user%3Apass@[2001:db8::1]:443?obfs=salamander&obfs-password=o&sni=example.com#节点","ss://YWVzLTEyOC1nY206cGFzcw==@example.com:8388#SS","trojan://pa%40ss@example.com?sni=example.com","vless://11111111-1111-1111-1111-111111111111@example.com:443?type=ws&path=%2Fa&security=tls"]{let c=try NodeParser.parse(uri);try creds.set(c.secret,for:c.node.credentialRef);if let obfs=c.obfsSecret{try creds.set(obfs,for:c.node.credentialRef+".obfs")};let other=try NodeParser.parse(NodeShare.link(c.node,credentials:creds));expectEqual(other.node.fingerprint,c.node.fingerprint);expectEqual(other.secret,c.secret);expectEqual(other.obfsSecret,c.obfsSecret)}
        var state=AppState();state.nodes=[try NodeParser.parse("hy2://p@example.com").node];state.groups=[PolicyGroup(name:"回退",kind:.fallback,members:[.direct])];expectThrows(try PolicyValidator.validate(state));state.groups[0].members=[.node(state.nodes[0].id)];try PolicyValidator.validate(state)
    }
    func testTunModelAndConflictDetection() throws {
        expectTrue(NetworkInspection.conflicts(vpn:"* (Connected) VPN",routes:"",proxies:[:]) != nil);expectTrue(NetworkInspection.conflicts(vpn:"",routes:"0/1 10.0.0.1 UGSc utun3",proxies:[:]) != nil);expectNil(NetworkInspection.conflicts(vpn:"",routes:"fe80::%utun3 link#9 UcI utun3",proxies:[:]));expectTrue(NetworkInspection.conflicts(vpn:"",routes:"",proxies:["HTTPEnable":1]) != nil)
        let c=try NodeParser.parse("hy2://p@example.com");let creds=MemoryCredentials();try creds.set(c.secret,for:c.node.credentialRef);var state=AppState();state.nodes=[c.node];state.selectedPolicy = .node(c.node.id);state.captureMode = .tun;let context=try CoreControlContext.make();let data=try TunConfigBuilder.build(state:state,credentials:creds,control:context,address4:"100.64.1.1/30",address6:"fd71:717a:1::1/126",originalDNS:["8.8.8.8"],bypass:["1.1.1.1/32"])
        let object=try JSONSerialization.jsonObject(with:data) as! [String:Any];let inbound=(object["inbounds"] as! [[String:Any]]).last!;expectEqual(inbound["stack"] as? String,"gvisor");expectEqual(inbound["auto_route"] as? Bool,false);expectEqual(inbound["mtu"] as? Int,1500)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let file=dir.appendingPathComponent("tun.json");try SecureFile.write(data,to:file);let check=Process();check.executableURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/Vendor/sing-box");check.arguments=["check","-c",file.path];check.standardOutput=FileHandle.nullDevice;check.standardError=FileHandle.nullDevice;try check.run();check.waitUntilExit();expectEqual(check.terminationStatus,0,"固定核心 TUN 配置校验")
    }
}

@MainActor func runTransactionChecks() async throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let credentials=MemoryCredentials();let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:credentials);try store.importNodes([try NodeParser.parse("hy2://old@example.com")]);let old=store.state.nodes[0];let original=try Data(contentsOf:store.file)
    var events:[String]=[]
    let tx=try store.prepareImport([try NodeParser.parse("hy2://new@example.com")],replacingID:old.id)
    do{try await RuntimeTransaction.apply(tx,connected:true,validate:{events.append("validate");throw ProxyError("校验失败")},stop:{events.append("stop")},start:{_ in events.append("start")},commit:{try store.commit(tx)},abort:{store.abort(tx)});CheckHarness.failure("校验失败不能提交",file:#filePath,line:#line)}catch{}
    expectEqual(events,["validate"]);expectEqual(try Data(contentsOf:store.file),original);expectEqual(try credentials.get(old.credentialRef),"old");print("PASS TransactionTests.validationBeforeStop")
    events=[];let next=try store.prepareImport([try NodeParser.parse("hy2://new@example.com")],replacingID:old.id);next.next.selectedPolicy = .node(old.id);var starts=0
    do{try await RuntimeTransaction.apply(next,connected:true,validate:{events.append("validate")},stop:{events.append("stop")},start:{state in starts+=1;events.append(starts==1 ? "new":"old");if starts==1{throw ProxyError("启动失败")};expectEqual(state.nodes[0].credentialRef,old.credentialRef)},commit:{try store.commit(next)},abort:{store.abort(next)});CheckHarness.failure("应用失败不能提交",file:#filePath,line:#line)}catch{}
    expectEqual(events,["validate","stop","new","stop","old"]);expectEqual(try Data(contentsOf:store.file),original);expectThrows(try credentials.get(next.next.nodes[0].credentialRef));print("PASS TransactionTests.applicationRollback")
    let success=try store.prepareImport([try NodeParser.parse("hy2://success@example.com")],replacingID:old.id);success.next.selectedPolicy = .node(old.id);events=[]
    try await RuntimeTransaction.apply(success,connected:true,validate:{events.append("validate")},stop:{events.append("stop")},start:{_ in events.append("start");expectEqual(try credentials.get(old.credentialRef),"old")},commit:{events.append("commit");try store.commit(success)},abort:{store.abort(success)})
    expectEqual(events,["validate","stop","start","commit"]);expectThrows(try credentials.get(old.credentialRef));print("PASS TransactionTests.commitRetiresAfterActivation")
    let failure=store.prepareChange(store.state);var count=0
    do{try await RuntimeTransaction.apply(failure,connected:true,validate:{},stop:{},start:{_ in count+=1;throw ProxyError("失败")},commit:{},abort:{store.abort(failure)});CheckHarness.failure("双重失败不能成功",file:#filePath,line:#line)}catch{expectTrue(error.localizedDescription.contains("恢复失败"))};expectEqual(count,2);expectEqual(store.state.nodes[0].credentialRef,success.next.nodes[0].credentialRef);print("PASS TransactionTests.rollbackFailurePreservesMetadata")
}
