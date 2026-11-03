import Foundation
import QingzhouKit

final class OptimizationFeatureTests:CheckCase {
    func testRotatingLogAndBounds() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("diagnostic.log"),log=DiagnosticLog(url:url)
        let line=String(repeating:"中",count:5000)+" password=synthetic"
        for _ in 0..<6 {try log.appendBatch(Array(repeating:line,count:100))}
        let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
        expectEqual(files.count,4)
        var size=0
        for file in files {
            let data=try Data(contentsOf:file);size+=data.count
            expectTrue(data.count<=DiagnosticLog.maximumFileBytes)
            expectTrue(String(data:data,encoding:.utf8) != nil)
            expectFalse(String(decoding:data,as:UTF8.self).contains("synthetic"))
            expectEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        }
        expectTrue(size<=2*1024*1024)
        try DiagnosticLog(url:url).append("重启继续写入")
        expectTrue(try String(contentsOf:url,encoding:.utf8).contains("重启继续写入"))
        let blocked=dir.appendingPathComponent("blocked");try FileManager.default.createDirectory(at:blocked,withIntermediateDirectories:true)
        expectThrows(try DiagnosticLog(url:blocked).append("保存应失败"))
    }
    func testMatchingAmbiguityAndMetadata() throws {
        let a=try NodeParser.parse("hy2://p@example.com?sni=one.example#旧一")
        let b=try NodeParser.parse("hy2://p@example.com?sni=two.example#旧二")
        let changed=try NodeParser.parse("hy2://new@example.com?sni=three.example#新")
        let exact=try NodeParser.parse("hy2://new@example.com?sni=one.example#改名")
        let ambiguous=SubscriptionMatching(old:[a.node,b.node],incoming:[changed.node])
        expectNil(ambiguous.previousByIncomingID[changed.node.id]);expectTrue(ambiguous.ambiguousIncomingIDs.contains(changed.node.id))
        let oneToMany=SubscriptionMatching(old:[a.node],incoming:[b.node,changed.node])
        expectEqual(oneToMany.ambiguousIncomingIDs.count,2)
        expectEqual(SubscriptionMatching(old:[a.node,b.node],incoming:[exact.node]).previousByIncomingID[exact.node.id]?.id,a.node.id)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:MemoryCredentials()),sub=Subscription(name:"合并")
        try store.importNodes([a,b],subscription:sub)
        var state=store.state;let original=state.nodes[0];state.notes[original.id.uuidString]="个人备注";state.favorites.insert(original.id);try store.commit(state)
        let preview=ImportPreview(candidates:[changed]);expectTrue(UpdateDiff.compare(old:state,preview:preview,subscriptionID:sub.id).requiresReview)
        let tx=try store.prepareImport([changed],subscription:sub)
        expectNil(tx.next.notes[changed.node.id.uuidString]);expectFalse(tx.next.favorites.contains(changed.node.id));store.abort(tx)
        expectEqual(store.state.nodes.count,2)
        let tx2=try store.prepareImport([exact,b],subscription:sub)
        expectEqual(tx2.next.nodes.first{$0.fingerprint==a.node.fingerprint}?.id,original.id);store.abort(tx2)
    }
    func testRuleTextRoundtripAndRejections() throws {
        var state=AppState();let a=try NodeParser.parse("hy2://p@a.example#同名"),b=try NodeParser.parse("hy2://p@b.example#同名");state.nodes=[a.node,b.node]
        let text="""
        # 测试保留动作与顺序
        DOMAIN,example.com,DIRECT
        DOMAIN-SUFFIX,example.org,REJECT
        DOMAIN-KEYWORD,word,PROXY
        IP-CIDR,192.0.2.0/24,AUTO,no-resolve
        IP-CIDR6,2001:db8::/32,\(PolicyReference.node(a.node.id).tag)
        MATCH,PROXY
        """
        let result=RuleTextCodec.parse(text,state:state);expectTrue(result.issues.isEmpty);expectEqual(result.rules.count,6)
        expectEqual(result.rules[0].target,.direct);expectEqual(result.rules[1].action,.reject);expectEqual(result.rules[3].noResolve,true)
        let encoded=try RuleTextCodec.encode(result.rules)
        let parsed=RuleTextCodec.parse(encoded,state:state,previous:result.rules)
        expectEqual(parsed.rules.map(\.id),result.rules.map(\.id));expectTrue(parsed.issues.isEmpty)
        let bad=RuleTextCodec.parse("DOMAIN,x.example,同名\nDOMAIN,x.example,missing\nIP-CIDR6,192.0.2.0/24,DIRECT\nDOMAIN,x.example,DIRECT,no-resolve\nSCRIPT,foo,PROXY",state:state)
        expectEqual(bad.issues.map(\.line),[1,2,3,4,5])
        expectThrows(try RuleTextCodec.encode([RoutingRule(kind:.userAgent,value:"test",action:.proxy)]))
        expectEqual(RuleTextCodec.parse("",state:state).rules.count,0)
        expectEqual(RuleTextCodec.parse(String(repeating:"x",count:2*1024*1024+1),state:state).issues.count,1)
    }
    func testClipboardPrivacyAndDeduplication() {
        var policy=ClipboardImportPolicy();var reads=0
        let read:()->String?={reads+=1;return "hy2://p@example.com"}
        expectNil(policy.inspect(enabled:false,foreground:true,change:1,read:read));expectEqual(reads,0)
        expectNil(policy.inspect(enabled:true,foreground:false,change:1,read:read));expectEqual(reads,0)
        expectTrue(policy.inspect(enabled:true,foreground:true,change:1,read:read) != nil);expectEqual(reads,1)
        expectNil(policy.inspect(enabled:true,foreground:true,change:1,read:read));expectEqual(reads,1)
        expectNil(policy.inspect(enabled:true,foreground:true,change:2,read:read));expectEqual(reads,2)
        expectNil(policy.inspect(enabled:true,foreground:true,change:3,read:{"vmess://unsupported"}))
        expectTrue(policy.inspect(enabled:true,foreground:true,change:4,read:{"https://example.com/sub"}) != nil)
        expectNil(policy.inspect(enabled:true,foreground:true,change:5,read:{String(repeating:"x",count:2*1024*1024+1)}))
    }
    func testHistoryCountersRetentionAndRestart() throws {
        func snapshot(_ u:Int64,_ d:Int64)->ConnectionSnapshot {try! JSONDecoder().decode(ConnectionSnapshot.self,from:Data("{\"uploadTotal\":\(u),\"downloadTotal\":\(d),\"connections\":[]}".utf8))}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let now=Date(timeIntervalSince1970:1800000000),profile=UUID();var accumulator=TrafficHistoryAccumulator()
        let first=accumulator.receive(snapshot(100,200),profileID:profile,now:now,calendar:calendar)
        expectEqual(first[0].upload,100)
        expectEqual(accumulator.receive(snapshot(100,200),profileID:profile,now:now.addingTimeInterval(1),calendar:calendar)[0].download,0)
        let gap=accumulator.receive(snapshot(150,300),profileID:profile,now:now.addingTimeInterval(60),calendar:calendar)
        expectEqual(gap[0].upload,50);expectTrue(gap[0].incomplete)
        let reset=accumulator.receive(snapshot(5,10),profileID:profile,now:now.addingTimeInterval(61),calendar:calendar)
        expectEqual(reset[0].upload,5);expectTrue(reset[0].incomplete)
        let nodeID=UUID(),connectionID=UUID().uuidString
        let connectionJSON="{\"uploadTotal\":160,\"downloadTotal\":400,\"connections\":[{\"id\":\"\(connectionID)\",\"upload\":7,\"download\":9,\"start\":\"2026-10-21T00:00:00Z\",\"metadata\":{},\"chains\":[\"node-\(nodeID.uuidString.lowercased())\"]}]}"
        let connectionSnapshot=try JSONDecoder().decode(ConnectionSnapshot.self,from:Data(connectionJSON.utf8))
        let nodes=accumulator.receive(connectionSnapshot,profileID:profile,now:now.addingTimeInterval(62),calendar:calendar)
        expectEqual(nodes.count,2);expectEqual(nodes.first{$0.nodeID != nil}?.upload,7)
        let same=accumulator.receive(connectionSnapshot,profileID:profile,now:now.addingTimeInterval(63),calendar:calendar)
        expectEqual(same.first{$0.nodeID != nil}?.download,0)
        let nextDay=accumulator.receive(snapshot(170,420),profileID:profile,now:now.addingTimeInterval(86400),calendar:calendar)
        expectTrue(nextDay[0].incomplete)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("history.sqlite")
        do {let store=try TrafficHistoryStore(url:url);try store.append(first+gap+reset,now:now,calendar:calendar)
            expectEqual(try store.rows().first?.upload,155)
            let old=TrafficHistoryRow(day:calendar.date(byAdding:.day,value:-30,to:now)!,profileID:profile.uuidString,upload:1000,download:0)
            try store.append([old],now:now,calendar:calendar);expectEqual(try store.rows().count,1)}
        let reopened=try TrafficHistoryStore(url:url);expectEqual(try reopened.rows().first?.download,310)
        expectEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try reopened.clear();expectTrue(try reopened.rows().isEmpty)
    }
    func testRealityShareRoundtrip() throws {
        let id="12345678-1234-1234-1234-123456789abc"
        for suffix in ["security=tls&flow=xtls-rprx-vision&sni=example.com","security=reality&pbk=\(String(repeating:"a",count:43))&sid=abcd&sni=example.com","security=reality&pbk=\(String(repeating:"a",count:43))&sid=abcd&sni=example.com&flow=xtls-rprx-vision"] {
            let candidate=try NodeParser.parse("vless://\(id)@example.com:443?"+suffix),credentials=MemoryCredentials();try credentials.set(candidate.secret,for:candidate.node.credentialRef)
            let link=try NodeShare.link(candidate.node,credentials:credentials),again=try NodeParser.parse(link)
            expectEqual(again.node.fingerprint,candidate.node.fingerprint);expectEqual(again.secret,candidate.secret)
            let outbound=try ConfigBuilder.outbound(candidate.node,credentials:credentials)
            expectEqual(outbound["flow"] as? String,candidate.node.parameters["flow"])
        }
        expectThrows(try NodeParser.parse("vless://\(id)@example.com:443?security=tls&type=ws&flow=xtls-rprx-vision"))
    }
}

func runPooledDownloadChecks() async {
    let client=ExternalDownloadClient(protocolClasses:[FixtureProtocol.self]);defer{client.shutdown()}
    do {
        async let first=client.fetchResponse(URL(string:"https://fixture.invalid/usage")!,limit:100)
        async let second=client.fetchResponse(URL(string:"https://fixture.invalid/nodes")!,limit:100)
        let responses=try await [first,second]
        expectTrue(responses[0].usageHeader != nil);expectNil(responses[1].usageHeader)
        expectEqual(client.activeRequestCount,0)
        client.networkEnvironmentChanged();expectEqual(client.generation,1)
        _=try await client.fetchResponse(URL(string:"https://fixture.invalid/nodes")!,limit:100)
        let cancelled=Task{try Task.checkCancellation();return try await client.fetchResponse(URL(string:"https://fixture.invalid/nodes")!,limit:100)}
        cancelled.cancel()
        do {_=try await cancelled.value;CheckHarness.failure("取消应立即生效",file:#filePath,line:#line)}catch{}
        client.shutdown()
        do {_=try await client.fetchResponse(URL(string:"https://fixture.invalid/nodes")!,limit:100);CheckHarness.failure("关闭的下载器应拒绝请求",file:#filePath,line:#line)}catch{}
        print("PASS PooledDownload.concurrentIsolationGenerationCancellation")
    }catch{CheckHarness.failure("共享下载检查异常",file:#filePath,line:#line)}
}

private final class HangingDownloadProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){}
    override func stopLoading(){}
}
func runDownloadCancellationChecks() async {
    let client=ExternalDownloadClient(protocolClasses:[HangingDownloadProtocol.self]);defer{client.shutdown()}
    let url=URL(string:"https://fixture.invalid/pending")!
    let first=Task{try await client.fetchResponse(url,limit:100)}
    let second=Task{try await client.fetchResponse(url,limit:100)}
    for _ in 0..<100 {if client.activeRequestCount==2{break};try? await Task.sleep(nanoseconds:1_000_000)}
    expectEqual(client.activeRequestCount,2)
    first.cancel()
    do{_=try await first.value;CheckHarness.failure("运行中的下载应被取消",file:#filePath,line:#line)}catch{expectEqual(SubscriptionFailure.classify(error),.cancelled)}
    expectEqual(client.activeRequestCount,1)
    client.networkEnvironmentChanged()
    do{_=try await second.value;CheckHarness.failure("环境变化应取消旧会话",file:#filePath,line:#line)}catch{expectEqual(SubscriptionFailure.classify(error),.cancelled)}
    expectEqual(client.activeRequestCount,0)
    print("PASS PooledDownload.inflightCancellationAndEnvironmentChange")
}

@MainActor func runHistoryTransactionChecks() async throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:directory)}
    let store=try NodeStore(file:directory.appendingPathComponent("state.json"),credentials:MemoryCredentials())
    var next=AppState();next.mode = .direct
    try store.commit(store.prepareChange(next))
    let tx=store.prepareChange(next)
    var starts:[String]=[]
    do {
        try await RuntimeTransaction.apply(tx,connected:true,validate:{},stop:{},start:{_ in starts.append("next");throw ProxyError("模拟启动失败")},commit:{},abort:{},restartPrevious:{_ in starts.append("previous")})
        CheckHarness.failure("模拟启动失败未传播",file:#filePath,line:#line)
    }catch{}
    expectEqual(starts,["next","previous"])
    print("PASS History.profileContextUsesSeparateRollbackStart")
}
