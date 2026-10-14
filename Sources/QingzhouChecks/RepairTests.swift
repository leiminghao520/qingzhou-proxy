import Foundation
import QingzhouKit

final class RepairTests:CheckCase {
    func testCompatibilityMigrationAndImport() throws {
        let old=try JSONDecoder().decode(AppState.self,from:Data("{}".utf8));expectFalse(old.httpCompatibilityEnabled)
        let file=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/Resources/shadowrocket-default.json")
        let shadow=try JSONDecoder().decode(ShadowrocketConfiguration.self,from:Data(contentsOf:file))
        var next=try shadow.applying(to:old);expectFalse(next.usesHTTPCompatibility);expectTrue(shadow.requiresHTTPCompatibility)
        next.httpCompatibilityEnabled=true
        expectTrue(try JSONDecoder().decode(AppState.self,from:JSONEncoder().encode(next)).usesHTTPCompatibility)
        expectTrue(try shadow.applying(to:next).httpCompatibilityEnabled)
        var changed=shadow;changed.rewrites=[]
        let diff=UpdateDiff.compare(old:next,preview:ImportPreview(candidates:[],fullConfiguration:changed),subscriptionID:nil)
        expectTrue(diff.compatibilityChanges);expectTrue(diff.requiresReview)
        let creds=MemoryCredentials();let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:creds)
        var configured=store.state;configured.shadowrocket=shadow;configured.httpCompatibilityEnabled=true
        try store.commit(configured)
        let preview=ImportPreview(candidates:[try NodeParser.parse("ss://aes-128-gcm:synthetic@example.com:8388")],fullConfiguration:shadow)
        let tx=try store.prepareImport(preview.candidates,subscription:Subscription(name:"synthetic"),source:"https://example.test/synthetic",profile:preview,scope:.profile)
        expectTrue(tx.next.httpCompatibilityEnabled);store.abort(tx)
    }
    func testImportTypesAndNoResolve() throws {
        let base="proxies:\n  - {name: n, type: ss, server: example.com, port: 8388, cipher: aes-128-gcm, password: synthetic%s}\nrules:\n  - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve\n  - MATCH,n\n"
        let good=try ProfileImporter.parse(base.replacingOccurrences(of:"%s",with:""))
        expectEqual(try RemoteRulesParser.parse("IP-CIDR,192.0.2.0/24,PROXY,no-resolve").first?.noResolve,true)
        expectTrue(good.unsupported.isEmpty);expectEqual(good.rules.first?.noResolve,true)
        for extra in [", udp: false",", udp: 'true'"] {
            expectFalse(try ProfileImporter.parse(base.replacingOccurrences(of:"%s",with:extra)).unsupported.isEmpty)
        }
        expectFalse(try ProfileImporter.parse(base.replacingOccurrences(of:"port: 8388",with:"port: 8388.5").replacingOccurrences(of:"%s",with:"")).unsupported.isEmpty)
        for field in ["skip-cert-verify: 'true'","alpn: h2","tls: 1","ws-opts: {headers: {Host: 42}}","reality-opts: {public-key: key, short-id: 42}"] {
            let yaml="proxies:\n  - {name: n, type: vless, server: example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, "+field+"}"
            expectFalse(try ProfileImporter.parse(yaml).unsupported.isEmpty)
        }
    }
    func testOrderedDNSAndMode() throws {
        let preview=try ProfileImporter.parse("proxies:\n  - {name: n, type: ss, server: example.com, port: 8388, cipher: aes-128-gcm, password: synthetic}\nrules:\n  - DOMAIN,first.example,DIRECT\n  - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve\n  - IP-CIDR,198.51.100.0/24,DIRECT\n  - MATCH,n")
        let creds=MemoryCredentials();let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:creds)
        try store.commit(store.prepareImport(preview.candidates,subscription:Subscription(name:"synthetic"),source:"https://example.test/synthetic",profile:preview,scope:.profile))
        for mode in ProxyMode.allCases {
            var state=store.state;state.mode=mode;state.addressFamilyPolicy = .preferIPv4
            let data=try ConfigBuilder.build(state:state,credentials:creds,control:CoreControlContext(port:28999,secret:String(repeating:"a",count:64)))
            let config=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let rules=(config["route"] as! [String:Any])["rules"] as! [[String:Any]]
            let domain=rules.firstIndex{$0["domain"] as? [String]==["first.example"]}!
            let resolves=rules.indices.filter{rules[$0]["action"] as? String=="resolve"}
            let contextual=resolves.filter{rules[$0]["clash_mode"]==nil && $0+1<rules.count}
            expectEqual(contextual.count,1);expectTrue(contextual[0]>domain)
            expectEqual(rules[contextual[0]+1]["ip_cidr"] as? [String],["198.51.100.0/24"])
            expectEqual((config["dns"] as! [String:Any])["final"] as? String,mode == .direct ? "local":"remote")
            let url=dir.appendingPathComponent("config.json");try SecureFile.write(data,to:url)
            let binary=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/sing-box")
            let process=Process();process.executableURL=binary;process.arguments=["check","-c",url.path];process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            try process.run();process.waitUntilExit();expectEqual(process.terminationStatus,0)
        }
    }
    func testUnknownFallbackAndHealth() {
        let a=UUID(),b=UUID();let now=Date();var fallback=FallbackController()
        _=fallback.evaluate(priority:[a,b],current:a,results:[a:false,b:true],now:now)
        let unknown=fallback.evaluate(priority:[a,b],current:a,results:[b:true],now:now.addingTimeInterval(61))
        expectEqual(unknown.selected,a);expectFalse(unknown.unavailable)
        let failed=fallback.evaluate(priority:[a,b],current:a,results:[a:false,b:true],now:now.addingTimeInterval(62))
        expectEqual(failed.selected,a)
        let confirmed=fallback.evaluate(priority:[a,b],current:a,results:[a:false,b:true],now:now.addingTimeInterval(63));expectEqual(confirmed.selected,b)
        expectEqual(ConnectivityHealth.evaluate([]),.unknown)
        expectEqual(ConnectivityHealth.evaluate(ConnectivityResult.pending),.checking)
        expectEqual(ConnectivityHealth.evaluate([ConnectivityResult("入口",.failed,"DNS")]),.unhealthy)
        expectEqual(ConnectivityHealth.evaluate([ConnectivityResult("入口",.passed,"")]),.healthy)
    }
    func testDNSPacketCompression() {
        let compressed=Data([0x71,0x7a,1,0,0,1,0,0,0,0,0,0,0xc0,18,0,1,0,1,1,97,0])
        expectEqual(DNSPacket.name(compressed),"a")
        var response=compressed;response[2]|=0x80
        expectTrue(DNSPacket.acceptable(response,query:compressed))
        response[19]=98;expectFalse(DNSPacket.acceptable(response,query:compressed))
        var loop=compressed;loop[13]=12;expectNil(DNSPacket.name(loop))
    }
    func testSearchDomainIsolation() throws {
        let snapshot=NetworkSnapshot(primaryInterface:"en0",routes:[],resolvers:[DNSResolverScope(service:"wifi",interface:"en0",servers:["192.168.1.1"],defaultResolver:true),DNSResolverScope(service:"a",interface:"utun6",servers:["10.1.0.53"],searchDomains:["corp.example"],order:100),DNSResolverScope(service:"b",interface:"utun7",servers:["10.2.0.53"],searchDomains:["dev.corp.example"],order:10)])
        let plan=try CapturePlan.make(snapshot:snapshot,extraCIDRs:[],extraDomains:[])
        expectEqual(plan.resolvers(for:"a.corp.example").map(\.service),["a"])
        expectEqual(plan.resolvers(for:"a.dev.corp.example").map(\.service),["b"])
        expectEqual(plan.resolvers(for:"public.example").map(\.service),["wifi"])
        expectEqual(plan.resolvers(for:"short").map(\.service),["b"])
    }
}

final class HealthFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let url=request.url!,port=url.port!;let isControl=url.path=="/proxies"
        let second=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first{$0.name=="url"}?.value==ConfigBuilder.secondaryTestURL
        let success=port==18501 || (port==18502 && second) || (port==18506 && !url.path.contains("00000000-0000-0000-0000-000000000001"))
        let code=isControl ? (port==18504 ? 401:200):port==18505 ? 401:success ? 200:503
        let body=isControl ? "{\"proxies\":{}}":"{\"delay\":42}"
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:code,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func runRepairHealthChecks() async {
    for (port,expected) in [(18501,"available"),(18502,"available"),(18503,"unavailable"),(18504,"unknown"),(18505,"unknown")] {
        let client=CoreAPIClient(context:CoreControlContext(port:port,secret:"synthetic"),protocolClasses:[HealthFixtureProtocol.self])
        let value=await client.probe(UUID());let actual:String
        switch value {case .available:actual="available";case .unavailable:actual="unavailable";case .unknown:actual="unknown"}
        expectEqual(actual,expected);await client.shutdown()
    }
    let fallbackClient=CoreAPIClient(context:CoreControlContext(port:18506,secret:"synthetic"),protocolClasses:[HealthFixtureProtocol.self])
    let dead=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,healthy=UUID()
    do {let chosen=try await fallbackClient.initializeFallback(PolicyGroup(name:"synthetic",kind:.fallback,members:[.node(dead),.node(healthy)]));expectEqual(chosen,healthy)}catch{CheckHarness.failure("回退组应跳过失效默认成员",file:#filePath,line:#line)}
    await fallbackClient.shutdown()
    print("PASS Repair.twoTargetsAndControlClassification")
}
