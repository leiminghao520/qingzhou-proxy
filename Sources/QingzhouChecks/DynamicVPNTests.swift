import Foundation
import QingzhouKit

final class DynamicVPNTests:CheckCase {
    func testMultiInterfaceRoutes() throws {
        let wifi=DNSResolverScope(service:"wifi",interface:"en0",servers:["192.0.2.53"],defaultResolver:true)
        let table="Internet:\n169.254 link#11 UCS en0\n169.254 link#23 UCSI en6\n192.168.66/24 link#11 UCS en0\n192.168.66/24 link#23 UCSI en6\n"
        let original=NetworkSnapshot.parseRoutes(table)
        for routes in [original,Array(original.reversed()),original.map{var r=$0;r.gateway=r.interface=="en6" ? "link#99":r.gateway;return r}] {
            let plan=try CapturePlan.make(snapshot:NetworkSnapshot(primaryInterface:"en0",routes:routes,resolvers:[wifi]),extraCIDRs:[],extraDomains:[])
            expectEqual(plan.snapshot.routes,routes)
            expectEqual(plan.protectedRoutes.count,2)
            expectTrue(plan.protectedRoutes.allSatisfy{$0.interface=="en0" && $0.scope==nil})
            let partition=try DynamicCaptureRules.partitionRoutes(plan.protectedRoutes)
            expectEqual(partition["en0"]?.count,2);expectNil(partition["en6"])
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer{try? FileManager.default.removeItem(at:folder)}
            _=try DynamicCaptureRules(directory:folder,plan:plan)
            expectEqual(try plan.domainRoute(address:"169.254.1.2",resolver:wifi).interface,"en0")
        }
        let scoped=[ProtectedRoute(destination:"10.20.0.0/16",gateway:"link#6",interface:"utun6",scope:"utun6"),ProtectedRoute(destination:"10.20.0.0/16",gateway:"link#7",interface:"utun7",scope:"utun7")]
        let dns6=DNSResolverScope(service:"corp6",interface:"utun6",servers:["10.20.0.53"],domains:["corp.test"])
        let dns7=DNSResolverScope(service:"corp7",interface:"utun7",servers:["10.20.0.54"],domains:["other.test"])
        for resolvers in [[wifi],[wifi,dns6],[wifi,dns6,dns7]] {
            let plan=try CapturePlan.make(snapshot:NetworkSnapshot(primaryInterface:"en0",routes:scoped,resolvers:resolvers),extraCIDRs:[],extraDomains:["corp.test"])
            expectEqual(plan.snapshot.routes,scoped)
            if resolvers.count==2 {
                expectEqual(plan.protectedRoutes,[scoped[0]])
                expectEqual(try plan.domainRoute(address:"10.20.1.2",resolver:dns6).interface,"utun6")
            } else {
                expectTrue(plan.protectedRoutes.isEmpty)
                expectThrows(try plan.domainRoute(address:"10.20.1.2",resolver:dns6))
            }
        }
        let global=ProtectedRoute(destination:"10.20.0.0/16",gateway:"192.0.2.1",interface:"en0")
        let mixed=try CapturePlan.make(snapshot:NetworkSnapshot(primaryInterface:"en0",routes:[global]+scoped,resolvers:[wifi,dns6]),extraCIDRs:[],extraDomains:[])
        expectEqual(mixed.protectedRoutes,[global]);expectThrows(try mixed.domainRoute(address:"10.20.1.2",resolver:dns6))
        expectEqual(try CapturePlan.effectiveRoutes([global,global],resolvers:[]),[global])
        for conflict in [ProtectedRoute(destination:global.destination,gateway:"192.0.2.2",interface:"en0"),ProtectedRoute(destination:global.destination,gateway:"192.0.2.1",interface:"en6")] {
            do {_=try CapturePlan.effectiveRoutes([global,conflict],resolvers:[]);expectTrue(false)}
            catch {expectTrue(error.localizedDescription.contains("scope=global"));expectTrue(error.localizedDescription.contains(conflict.gateway))}
        }
        expectTrue(NetworkInspection.conflicts(vpn:"",routes:"Internet:\ndefault link#22 UCSg utun7",proxies:[:])?.contains("另一个隧道") == true)
    }
    func snapshot(_ corporate:Bool)->NetworkSnapshot {
        var resolvers=[DNSResolverScope(service:"wifi",interface:"en0",servers:["192.0.2.53"],defaultResolver:true)]
        var routes=[ProtectedRoute(destination:"192.0.2.0/24",gateway:"link#11",interface:"en0")]
        if corporate {
            resolvers.append(DNSResolverScope(service:"corp",interface:"utun6",servers:["10.20.0.53"],domains:["corp.test"]))
            routes.append(ProtectedRoute(destination:"10.20.0.0/16",gateway:"link#26",interface:"utun6"))
        }
        return NetworkSnapshot(primaryInterface:"en0",routes:routes,resolvers:resolvers)
    }
    func query(_ name:String)->Data {
        var bytes:[UInt8]=[0x71,0x7a,1,0,0,1,0,0,0,0,0,0]
        for part in name.split(separator:".") {bytes.append(UInt8(part.utf8.count));bytes += part.utf8}
        bytes += [0,0,1,0,1];return Data(bytes)
    }
    func answer(_ request:Data)->Data {var result=request;result[2]|=0x80;return result}
    func testOptionalDNSAndGeneration() throws {
        var incomplete=snapshot(false)
        incomplete.unavailableDomains=["missing.corp"]
        let missing=try CapturePlan.make(snapshot:incomplete,extraCIDRs:[],extraDomains:[])
        expectTrue(missing.protects("api.missing.corp"));expectTrue(missing.resolvers(for:"api.missing.corp").isEmpty)
        var legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(incomplete)) as! [String:Any]
        legacy.removeValue(forKey:"unavailableDomains")
        let decoded=try JSONDecoder().decode(NetworkSnapshot.self,from:JSONSerialization.data(withJSONObject:legacy))
        expectTrue(decoded.unavailableDomains.isEmpty)
        let offline=try CapturePlan.make(snapshot:snapshot(false),extraCIDRs:[],extraDomains:["corp.test"])
        let online=try CapturePlan.make(snapshot:snapshot(true),extraCIDRs:[],extraDomains:["corp.test"])
        var sent:[String]=[],protections=0
        let forwarder=try ScopedDNSForwarder(plan:offline,transport:{request,server,_ in sent.append(server);return self.answer(request)},protectSnapshotAnswers:{_,_,_,_,_,_ in protections += 1})
        defer {forwarder.stop()}
        let request=query("api.corp.test")
        expectEqual(forwarder.resolve(request,name:"api.corp.test")[3]&15,2)
        expectTrue(sent.isEmpty)
        forwarder.updatePlan(online)
        expectEqual(forwarder.resolve(request,name:"api.corp.test")[3]&15,0)
        expectEqual(sent,["10.20.0.53"]);expectEqual(protections,1)
        // 响应到达前 VPN 断开；不能执行旧计划的保护回调或返回成功。
        let stale=forwarder.resolve(request,name:"api.corp.test",exchange:{request,_,_ in forwarder.updatePlan(offline);return self.answer(request)})
        expectEqual(stale[3]&15,2);expectEqual(protections,1)
        forwarder.updatePlan(online);forwarder.suspendProtectedQueries()
        let before=sent.count
        expectEqual(forwarder.resolve(request,name:"api.corp.test")[3]&15,2);expectEqual(sent.count,before)
        let publicRequest=query("public.test")
        expectEqual(forwarder.resolve(publicRequest,name:"public.test")[3]&15,0)
        forwarder.updatePlan(online)
        let refused=forwarder.resolve(request,name:"api.corp.test",exchange:{_,server,_ in sent.append(server);return nil})
        expectEqual(refused[3]&15,2);expectEqual(sent.last,"10.20.0.53")
    }
    func testStableWindowAndPartitions() throws {
        let offline=try CapturePlan.make(snapshot:snapshot(false),extraCIDRs:[],extraDomains:[])
        let online=try CapturePlan.make(snapshot:snapshot(true),extraCIDRs:[],extraDomains:[])
        var window=CaptureChangeWindow()
        expectFalse(window.observe(offline,now:0));expectFalse(window.observe(online,now:0.5))
        expectFalse(window.observe(online,now:1));expectTrue(window.observe(online,now:1.5))
        window.reset();expectFalse(window.expired(now:100))
        expectFalse(window.observe(offline,now:10));expectFalse(window.observe(online,now:20));expectTrue(window.expired(now:20))
        let routes=[ProtectedRoute(destination:"10.0.0.0/8",gateway:"link#1",interface:"en0"),ProtectedRoute(destination:"10.20.0.0/16",gateway:"link#2",interface:"utun6"),ProtectedRoute(destination:"10.20.30.0/24",gateway:"link#3",interface:"utun7"),ProtectedRoute(destination:"fd00::/8",gateway:"link#1",interface:"en0"),ProtectedRoute(destination:"fd12::/32",gateway:"link#2",interface:"utun6")]
        let partition=try DynamicCaptureRules.partitionRoutes(routes)
        func owners(_ ip:String)->[String] {partition.keys.filter{interface in partition[interface]!.contains{RuleEvaluator.matches(RoutingRule(kind:.cidr,value:$0,action:.direct),host:ip,ip:ip)==true}}}
        expectEqual(owners("10.1.1.1"),["en0"]);expectEqual(owners("10.20.1.1"),["utun6"]);expectEqual(owners("10.20.30.1"),["utun7"])
        expectEqual(owners("fd12::1"),["utun6"]);expectEqual(owners("fd13::1"),["en0"])
        expectThrows(try DynamicCaptureRules.partitionRoutes([routes[0],ProtectedRoute(destination:routes[0].destination,gateway:"link#9",interface:"utun9")]))
    }
}
