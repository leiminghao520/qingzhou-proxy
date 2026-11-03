import Foundation
import CFNetwork
import QingzhouKit

final class RepairTests:CheckCase {
    func testTongdunProtectionDraft() throws {
        var state=AppState();state.protectedDomains=["tongdun.me","custom.example"]
        expectEqual(try ProtectedDomainPolicy.missingTongdunDomains(in:state.protectedDomains),["tongdun.cn","tongdun.net"])
        let draft=try ProtectedDomainPolicy.completingTongdunDomains(state.protectedDomains)
        expectEqual(draft,["tongdun.me","custom.example","tongdun.cn","tongdun.net"])
        expectEqual(state.protectedDomains,["tongdun.me","custom.example"])
        expectEqual(try ProtectedDomainPolicy.missingTongdunDomains(in:draft),[])
        expectEqual(try ProtectedDomainPolicy.completingTongdunDomains(draft),draft)
        expectEqual(try ProtectedDomainPolicy.missingTongdunDomains(in:[" TONGDUN.CN. ","tongdun.cn"]),["tongdun.me","tongdun.net"])
        expectEqual(try ProtectedDomainPolicy.missingTongdunDomains(in:[]),[])
        expectEqual(try ProtectedDomainPolicy.missingTongdunDomains(in:["custom.example","tongdun.me.attacker.test","login-inner.tongdun.cn"]),[])
        expectEqual(try ProtectedDomainPolicy.completingTongdunDomains(["CUSTOM.EXAMPLE.","custom.example","TONGDUN.CN"]),["custom.example","tongdun.cn","tongdun.me","tongdun.net"])
        expectThrows(try ProtectedDomainPolicy.completingTongdunDomains(["https://tongdun.cn"]))
        expectThrows(try ProtectedDomainPolicy.missingTongdunDomains(in:["*.tongdun.cn"]))

        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("state.json"),credentials=MemoryCredentials()
        let store=try NodeStore(file:file,credentials:credentials)
        try store.commit(state)
        let saved=try Data(contentsOf:file)
        var next=store.state;next.protectedDomains=draft
        let pending=store.prepareChange(next)
        expectEqual(try Data(contentsOf:file),saved)
        expectEqual(store.state.protectedDomains,state.protectedDomains)
        store.abort(pending)
        expectEqual(try NodeStore(file:file,credentials:credentials).state.protectedDomains,state.protectedDomains)
        try store.commit(store.prepareChange(next))
        expectEqual(try NodeStore(file:file,credentials:credentials).state.protectedDomains,draft)

        let applied=try ProxyRecovery.applied(to:["ExceptionsList":["localhost"]],port:27890,protectedDomains:draft)
        let plan=try CapturePlan.make(snapshot:CapturePlanTests().fixture(),extraCIDRs:[],extraDomains:draft)
        for root in ProtectedDomainPolicy.tongdunDomains {
            for host in [root,"login-inner."+root,"a.b."+root] {
                let proxies=CFNetworkCopyProxiesForURL(URL(string:"https://"+host)! as CFURL,applied as CFDictionary).takeRetainedValue() as! [[String:Any]]
                expectEqual(proxies.first?[kCFProxyTypeKey as String] as? String,kCFProxyTypeNone as String)
                expectTrue(plan.protects(host))
                expectTrue(plan.resolvers(for:host).allSatisfy{CapturePlan.isVPN($0.interface)})
            }
            for host in ["evil"+root,root+".attacker.test"] {
                let proxies=CFNetworkCopyProxiesForURL(URL(string:"https://"+host)! as CFURL,applied as CFDictionary).takeRetainedValue() as! [[String:Any]]
                expectEqual(proxies.first?[kCFProxyTypeKey as String] as? String,kCFProxyTypeHTTPS as String)
                expectFalse(plan.protects(host))
            }
        }
    }

    func testCorporateProxyBypass() throws {
        expectEqual(try ProtectedDomainPolicy.normalize([" Corp.Example. ","corp.example","dev.corp.example"]),["corp.example","dev.corp.example"])
        for value in ["https://corp.example","corp.example:443","corp.example/path","*.corp.example","a..example","-a.example","127.0.0.1",""] {expectThrows(try ProtectedDomainPolicy.normalize([value]))}
        let original:[String:Any]=["ExceptionsList":["localhost","corp.example"],"ExcludeSimpleHostnames":0]
        let applied=try ProxyRecovery.applied(to:original,port:27890,protectedDomains:["CORP.EXAMPLE."])
        expectEqual(applied["ExceptionsList"] as? [String],["localhost","corp.example","*.corp.example"])
        expectEqual(applied["ExcludeSimpleHostnames"] as? Int,0)
        for host in ["corp.example","a.corp.example","a.b.corp.example"] {
            let proxies=CFNetworkCopyProxiesForURL(URL(string:"https://"+host)! as CFURL,applied as CFDictionary).takeRetainedValue() as! [[String:Any]]
            expectEqual(proxies.first?[kCFProxyTypeKey as String] as? String,kCFProxyTypeNone as String)
        }
        for host in ["evilcorp.example","corp.example.attacker.test","public.example"] {
            let proxies=CFNetworkCopyProxiesForURL(URL(string:"https://"+host)! as CFURL,applied as CFDictionary).takeRetainedValue() as! [[String:Any]]
            expectEqual(proxies.first?[kCFProxyTypeKey as String] as? String,kCFProxyTypeHTTPS as String)
        }
        expectThrows(try ProxyRecovery.applied(to:["ExceptionsList":42],port:27890,protectedDomains:["corp.example"]))
        expectTrue(NSDictionary(dictionary:ProxyRecovery.restored(original:original,applied:applied,current:applied)!).isEqual(to:original))
        var partial=applied
        for key in ["HTTPEnable","HTTPProxy","HTTPPort","HTTPSEnable","HTTPSProxy","HTTPSPort","SOCKSEnable","SOCKSProxy","SOCKSPort"] {
            partial[key]=original[key]
        }
        partial["UnrelatedSetting"]="external-preserved"
        var fullyRestored=original;fullyRestored["UnrelatedSetting"]="external-preserved"
        expectTrue(NSDictionary(dictionary:ProxyRecovery.restored(original:original,applied:applied,current:partial)!).isEqual(to:fullyRestored))
        expectTrue(NSDictionary(dictionary:ProxyRecovery.restored(original:original,applied:applied,current:fullyRestored)!).isEqual(to:fullyRestored))
        var foreignPort=partial;foreignPort["HTTPSPort"]=1082
        expectNil(ProxyRecovery.restored(original:original,applied:applied,current:foreignPort))
        expectTrue(ProxyRecovery.pointsToOwnedEndpoint(current:applied,applied:applied))
        expectFalse(ProxyRecovery.pointsToOwnedEndpoint(current:original,applied:applied))
        expectFalse(ProxyRecovery.pointsToOwnedEndpoint(current:partial,applied:applied))
        expectFalse(ProxyRecovery.pointsToOwnedEndpoint(current:["HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":1082],applied:applied))
        expectFalse(ProxyRecovery.pointsToOwnedEndpoint(current:["HTTPEnable":1,"HTTPProxy":"127.0.0.1"],applied:[:]))
        var external=applied;external["ExceptionsList"]=["other.example"]
        expectNil(ProxyRecovery.restored(original:original,applied:applied,current:external))
        expectEqual(ProxyRecovery.changedOwnedKeys(expected:applied,current:external,protectsExceptions:true),["ExceptionsList"])
        let legacy=ProxyRecovery.applied(to:original,port:27890)
        var changed=legacy;changed["ExceptionsList"]=["external.example"]
        expectEqual(ProxyRecovery.changedOwnedKeys(expected:legacy,current:changed),[])
        expectEqual(ProxyRecovery.restored(original:original,applied:legacy,current:changed)?["ExceptionsList"] as? [String],["external.example"])
        for mode in ProxyMode.allCases {
            var state=AppState();state.mode=mode;state.protectedDomains=["corp.example"]
            expectEqual(try ProxyRecovery.applied(to:[:],port:27890,protectedDomains:state.protectedDomains)["ExceptionsList"] as? [String],["corp.example","*.corp.example"])
        }
        let shadow=try JSONDecoder().decode(ShadowrocketConfiguration.self,from:Data(contentsOf:URL(fileURLWithPath:"Resources/shadowrocket-default.json")))
        var state=AppState();state.protectedDomains=["corp.example"]
        expectEqual(try shadow.applying(to:state).protectedDomains,state.protectedDomains)
    }

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
        expectThrows(try plan.selectResolvers(for:"short"))
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
