import Foundation
import QingzhouKit

final class DynamicVPNTests:CheckCase {
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
