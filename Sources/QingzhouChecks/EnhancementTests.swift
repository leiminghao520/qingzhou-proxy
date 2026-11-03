import Foundation
import QingzhouKit

final class EnhancementTests:CheckCase {
    func testLegacyMigrationPreservesReferencesAndBackup() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let candidate=try NodeParser.parse("hy2://legacy-secret@example.com");let node=try JSONSerialization.jsonObject(with:JSONEncoder().encode(candidate.node))
        let data=try JSONSerialization.data(withJSONObject:["schemaVersion":1,"nodes":[node],"subscriptions":[],"rules":[],"rulesEnabled":false,"listenPort":7890,"selectedID":candidate.node.id.uuidString])
        let file=dir.appendingPathComponent("state.json");try SecureFile.write(data,to:file)
        let credentials=MemoryCredentials();try credentials.set(candidate.secret,for:candidate.node.credentialRef)
        let store=try NodeStore(file:file,credentials:credentials)
        expectEqual(store.state.schemaVersion,2);expectEqual(store.state.mode,.global);expectEqual(store.state.activePolicy,.node(candidate.node.id));expectEqual(store.state.nodes[0].credentialRef,candidate.node.credentialRef)
        expectFalse(store.state.autoConnect);expectFalse(store.state.loginAtStartup)
        expectEqual(try Data(contentsOf:dir.appendingPathComponent("state-v1-backup.json")),data)
        expectEqual((try FileManager.default.attributesOfItem(atPath:dir.appendingPathComponent("state-v1-backup.json").path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        expectEqual(try NodeStore(file:file,credentials:credentials).state.schemaVersion,2)
    }
    func testPreparedUpdateAbortAndCommit() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let credentials=MemoryCredentials();let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:credentials)
        let sub=Subscription(name:"订阅");try store.importNodes([try NodeParser.parse("hy2://old@example.com")],subscription:sub,source:"https://example.com/private-link")
        let old=store.state.nodes[0];let original=try Data(contentsOf:store.file)
        let tx=try store.prepareImport([try NodeParser.parse("hy2://new@example.com")],subscription:store.state.subscriptions[0])
        expectEqual(try credentials.get(old.credentialRef),"old");expectEqual(store.state.nodes[0],old);expectEqual(try Data(contentsOf:store.file),original)
        let staged=tx.next.nodes[0];expectEqual(try credentials.get(staged.credentialRef),"new");expectEqual(staged.id,old.id)
        store.abort(tx);expectThrows(try credentials.get(staged.credentialRef));expectEqual(try credentials.get(old.credentialRef),"old");expectThrows(try store.commit(tx))
        let success=try store.prepareImport([try NodeParser.parse("hy2://new@example.com")],subscription:store.state.subscriptions[0]);try store.commit(success)
        expectThrows(try credentials.get(old.credentialRef));expectEqual(try credentials.get(store.state.nodes[0].credentialRef),"new")
        expectFalse(try String(contentsOf:store.file,encoding:.utf8).contains("private-link"))
    }
    func testProfileYAMLAndBase64() throws {
        let uri="hysteria2://user%3Apassword@example.com:443/?sni=example.com#VPS"
        expectEqual(try ProfileImporter.parse(Data(uri.utf8).base64EncodedString()).candidates[0].secret,"user:password")
        expectEqual(try ProfileImporter.parse("#说明\nHY2://p@example.com").candidates.count,1)
        let yaml="""
        # 配置注释
        mixed-port: 9999
        external-controller: 0.0.0.0:9090
        proxies:
          - {name: VPS, type: hysteria2, server: example.com, port: 443, password: 'user:password', sni: example.com}
          - {name: SS, type: ss, server: example.org, port: 8388, cipher: aes-128-gcm, password: test}
        proxy-groups:
          - {name: AUTO, type: url-test, proxies: [VPS, SS], interval: 300}
          - {name: PROXY, type: select, proxies: [AUTO, VPS, DIRECT]}
        rules:
          - DOMAIN,blocked.example,REJECT
          - DOMAIN-SUFFIX,example.org,PROXY
          - DOMAIN-KEYWORD,tracking,REJECT
          - IP-CIDR6,2001:db8::/32,DIRECT,no-resolve
          - MATCH,PROXY
        """
        let preview=try ProfileImporter.parse(yaml)
        expectEqual(preview.candidates.count,2);expectEqual(preview.groups.count,2);expectEqual(preview.rules.count,4);expectTrue(preview.unsupported.isEmpty);expectTrue(preview.ignored.contains("未接管配置项：external-controller"));expectTrue(preview.final != nil)
    }
    func testYAMLUnsupportedContentAndCycles() throws {
        let yaml="""
        proxies:
          - {name: good, type: trojan, server: example.com, port: 443, password: p, skip-cert-verify: true}
          - {name: bad, type: vmess, server: example.com, port: 443, uuid: invalid}
        proxy-providers: {provider: {type: http}}
        proxy-groups:
          - {name: A, type: select, proxies: [B]}
          - {name: B, type: select, proxies: [A]}
        rules: ["GEOSITE,cn,DIRECT"]
        """
        let preview=try ProfileImporter.parse(yaml)
        expectEqual(preview.candidates.count,1);expectTrue(preview.candidates[0].node.insecure);expectTrue(preview.unsupported.count>=4)
        expectThrows(try ProfileImporter.parse("proxies: [&loop {name: x}]") )
        expectThrows(try ProfileImporter.parse("not: [valid"))
        expectThrows(try ProfileImporter.parse(String(repeating:"x",count:2*1024*1024+1)))
    }
    func testProfileImportStableGroupsAndRules() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:MemoryCredentials());let sub=Subscription(name:"配置")
        let text="""
        proxies: [{name: N, type: ss, server: example.com, port: 8388, cipher: aes-128-gcm, password: p}]
        proxy-groups: [{name: P, type: select, proxies: [N, DIRECT]}]
        rules: ["DOMAIN,x.example,P", "MATCH,P"]
        """
        let first=try ProfileImporter.parse(text);let tx=try store.prepareImport(first.candidates,subscription:sub,source:"https://example.com/sub",profile:first,scope:.profile);try store.commit(tx)
        let node=store.state.nodes[0].id,group=store.state.groups[0].id
        let second=try ProfileImporter.parse(text);let updated=try store.prepareImport(second.candidates,subscription:store.state.subscriptions[0],profile:second,scope:.profile);try store.commit(updated)
        expectEqual(store.state.nodes[0].id,node);expectEqual(store.state.groups[0].id,group);expectEqual(store.state.rules.count,1);expectEqual(store.state.rules[0].target,.group(group));expectEqual(store.state.groups[0].members[0],.node(node));expectEqual(store.state.ruleFinal,.group(group))
        try PolicyValidator.validate(store.state)
    }
    func testGroupValidationAndRepair() throws {
        let c=try NodeParser.parse("hy2://p@example.com");var state=AppState();state.nodes=[c.node];state.selectedID=c.node.id
        let a=UUID(),b=UUID();state.groups=[PolicyGroup(id:a,name:"A",kind:.select,members:[.group(b)]),PolicyGroup(id:b,name:"B",kind:.select,members:[.group(a)])]
        expectThrows(try PolicyValidator.validate(state))
        state.groups=[PolicyGroup(id:a,name:"A",kind:.select,members:[.node(c.node.id)])];state.rules=[RoutingRule(kind:.domain,value:"example.com",action:.proxy,target:.group(a))];state.ruleFinal = .group(a);state.selectedPolicy = .group(a)
        try PolicyValidator.validate(state);state.nodes=[];PolicyValidator.repair(&state)
        expectTrue(state.groups.isEmpty);expectEqual(state.rules[0].action,.reject);expectEqual(state.ruleFinal,.reject);expectNil(state.activePolicy)
    }
    func testRemoteRuleFormatsAndRejections() throws {
        expectEqual(try RemoteRulesParser.parse("# 注释\nexample.com\n+.example.org\n192.0.2.0/24\nDOMAIN-KEYWORD,tracker").count,4)
        expectEqual(try RemoteRulesParser.parse("payload:\n  - '+.example.com'\n  - '2001:db8::/32'\n").count,2)
        expectEqual(try RemoteRulesParser.parse(#"{"version":3,"rules":[{"domain":["a.example","b.example"]},{"ip_cidr":"192.0.2.0/24"}]}"#).count,3)
        expectEqual(try RemoteRulesParser.parse("MATCH,REJECT").first?.kind,.match)
        for text in ["MATCH,REJECT,extra", "GEOIP,CN", "{bad}", #"{"version":3,"rules":[{"domain":["a.example"],"ip_cidr":["192.0.2.0/24"]}]}"#, "payload:\n  - '[bad]'", "#empty"] {expectThrows(try RemoteRulesParser.parse(text))}
        expectThrows(try RemoteRulesParser.parse(Array(repeating:"a.example",count:50001).joined(separator:"\n")))
    }
    func testScheduleAndUsage() {
        let now=Date(timeIntervalSince1970:100000)
        expectTrue(UpdateSchedule.due(updatedAt:nil,enabled:true,now:now));expectFalse(UpdateSchedule.due(updatedAt:nil,enabled:false,now:now));expectFalse(UpdateSchedule.due(updatedAt:nil,enabled:true,pending:true,now:now))
        expectFalse(UpdateSchedule.due(updatedAt:now,enabled:true,now:now));expectTrue(UpdateSchedule.due(updatedAt:now.addingTimeInterval(-86400),enabled:true,now:now))
        expectFalse(UpdateSchedule.due(updatedAt:nil,enabled:true,retryCount:1,retryAfter:now.addingTimeInterval(60),now:now));expectTrue(UpdateSchedule.due(updatedAt:nil,enabled:true,retryCount:1,retryAfter:now,now:now))
        expectEqual(UpdateSchedule.nextRetry(1,now:now),now.addingTimeInterval(60));expectEqual(UpdateSchedule.nextRetry(3,now:now),now.addingTimeInterval(1800));expectEqual(UpdateSchedule.nextRetry(4,now:now),now.addingTimeInterval(3600))
        let usage=UsageInfo.parse("upload=100; download=200; total=1000; expire=200000")
        expectEqual(usage?.upload,100);expectEqual(usage?.total,1000);expectEqual(usage?.expire,200000);expectNil(UsageInfo.parse(nil));expectNil(UsageInfo.parse("nonsense"))
    }
    func testMultiConfigCoreValidationAndTokenSeparation() throws {
        expectEqual(try NodeParser.parse("hy2://a@example.com:65535").node.port,65535)
        expectThrows(try NodeParser.parse("hy2://a@example.com:65536"))
        let a=try NodeParser.parse("hy2://a@example.com"),b=try NodeParser.parse("ss://aes-128-gcm:b@example.org:8388")
        let credentials=MemoryCredentials();try credentials.set(a.secret,for:a.node.credentialRef);try credentials.set(b.secret,for:b.node.credentialRef)
        var state=AppState();state.nodes=[a.node,b.node];state.selectedPolicy = .automatic
        let group=PolicyGroup(name:"组",kind:.select,members:[.node(a.node.id),.automatic,.direct]);state.groups=[group];state.rules=[RoutingRule(kind:.keyword,value:"tracker",action:.reject),RoutingRule(kind:.domain,value:"group.example",action:.proxy,target:.group(group.id))]
        var remote=RemoteRuleSource(name:"规则");remote.rules=[RoutingRule(kind:.domain,value:"remote.example",action:.proxy)];state.remoteRules=[remote]
        let context=CoreControlContext(port:19090,secret:String(repeating:"f",count:64))
        let config=try ConfigBuilder.build(state:state,credentials:credentials,control:context);let root=try JSONSerialization.jsonObject(with:config) as! [String:Any]
        let automatic=(root["outbounds"] as! [[String:Any]]).first{($0["tag"] as? String)=="auto"}!
        expectEqual(automatic["interval"] as? String,"5m");expectEqual(automatic["tolerance"] as? Int,50);expectEqual(automatic["interrupt_exist_connections"] as? Bool,false)
        expectFalse((automatic["outbounds"] as! [String]).contains("direct"))
        let api=(root["experimental"] as! [String:Any])["clash_api"] as! [String:Any];expectEqual(api["external_controller"] as? String,"127.0.0.1:19090")
        expectFalse(try String(decoding:JSONEncoder().encode(state),as:UTF8.self).contains(context.secret));expectFalse(state.autoConnect)
        let binary=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/sing-box")
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json");defer{try? FileManager.default.removeItem(at:file)};try SecureFile.write(config,to:file)
        let p=Process();p.executableURL=binary;p.arguments=["check","-c",file.path];let output=Pipe();p.standardError=output;p.standardOutput=output;try p.run();p.waitUntilExit();let message=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        expectEqual(p.terminationStatus,0,Redactor.redact(message,secrets:[context.secret]))
        expectThrows(try ConfigBuilder.build(state:state,credentials:credentials,control:CoreControlContext(port:state.listenPort,secret:context.secret)))
    }
}
