import Foundation
import QingzhouKit

final class FullCaptureTests:CheckCase {
    func testReclaimedCorporateHostRoute() throws {
        let host=ProtectedRoute(destination:"198.19.0.37/32",gateway:"10.251.1.1",interface:"utun6")
        let parent=ProtectedRoute(destination:"198.19.0.0/16",gateway:host.gateway,interface:host.interface)
        let other=ProtectedRoute(destination:"198.19.0.0/24",gateway:"192.168.5.1",interface:"en0")
        expectTrue(CaptureOwnership.protectionIssues(owned:[host],preserved:[],actual:[parent]).isEmpty)
        expectTrue(CaptureOwnership.protectionIssues(owned:[host],preserved:[],actual:[host,parent]).isEmpty)
        expectFalse(CaptureOwnership.protectionIssues(owned:[host],preserved:[],actual:[]).isEmpty)
        // 更具体的外部出口、等长竞争、网关和作用域变化均不能放行。
        for changed in [other,ProtectedRoute(destination:parent.destination,gateway:"10.251.1.2",interface:parent.interface),ProtectedRoute(destination:host.destination,gateway:other.gateway,interface:other.interface)] {
            expectFalse(CaptureOwnership.hasEquivalentHostPath(host,actual:[parent,changed]))
        }
        var scoped=parent;scoped.scope=parent.interface
        expectFalse(CaptureOwnership.hasEquivalentHostPath(host,actual:[scoped]))
        expectFalse(CaptureOwnership.hasEquivalentHostPath(host,actual:[ProtectedRoute(destination:"0.0.0.0/0",gateway:host.gateway,interface:host.interface)]))
        expectFalse(CaptureOwnership.protectionIssues(owned:[parent],preserved:[],actual:[host]).isEmpty)
        expectFalse(CaptureOwnership.protectionIssues(owned:[],preserved:[host],actual:[parent]).isEmpty)
        // 恢复所有权不因上级企业路由仍可达而放宽，不能删除别人的路由。
        expectEqual(CaptureOwnership.recoveryState(expected:host,actual:[parent]),.absent)
        let v6=ProtectedRoute(destination:"fd00:abcd::37/128",gateway:"fe80::1%utun6",interface:"utun6")
        expectTrue(CaptureOwnership.hasEquivalentHostPath(v6,actual:[ProtectedRoute(destination:"fd00:abcd::/64",gateway:v6.gateway,interface:v6.interface)]))
        expectFalse(CaptureOwnership.hasEquivalentHostPath(v6,actual:[ProtectedRoute(destination:"fd00:abcd::/64",gateway:v6.gateway,interface:"utun9")]))
    }

    func testEffectiveDNSPriority() throws {
        let previous="""
        DNS configuration
        resolver #1
          nameserver[0] : 10.251.1.1
          flags : Supplemental, Request A records
          order : 103000
        resolver #2
          nameserver[0] : 192.168.1.1
          flags : Supplemental, Request A records
          order : 103400
        """
        expectFalse(CaptureDNSPolicy.isPreferred(server:"192.168.1.1",in:previous))
        let applied=previous.replacingOccurrences(of:"order : 103400",with:"order : 3401")
        expectTrue(CaptureDNSPolicy.isPreferred(server:"192.168.1.1",in:applied))
        let specific="""
        resolver #3
          domain : corp.example
          nameserver[0] : 10.251.1.1
          order : 1
        resolver #4
          domain : local
          options : mdns
          nameserver[0] : 224.0.0.251
          order : 1
        DNS configuration (for scoped queries)
        resolver #1
          nameserver[0] : 172.20.10.1
          order : 1
        """
        expectTrue(CaptureDNSPolicy.isPreferred(server:"192.168.1.1",in:applied+"\n"+specific))
        expectFalse(CaptureDNSPolicy.isPreferred(server:"192.168.1.1",in:applied.replacingOccurrences(of:"order : 103000",with:"order : 3401")))
        expectFalse(CaptureDNSPolicy.isPreferred(server:"192.168.1.1",in:""))
        expectFalse(CaptureDNSPolicy.isPreferred(server:"192.168.1.1",in:"resolver #1\nnameserver[0] : 192.168.1.1"))
        expectFalse(CaptureDNSPolicy.isPreferred(server:"192.168.1.1",in:applied.replacingOccurrences(of:"nameserver[0] : 192.168.1.1",with:"nameserver[0] : 192.168.1.1\nnameserver[1] : 10.251.1.1")))
        let expected=CaptureDNSPolicy.settings(server:"192.168.1.1")
        // macOS 会移除独立补充服务的 SearchOrder；匹配顺序必须仍在数组中。
        var supplemental=expected
        supplemental.removeValue(forKey:"SearchOrder")
        expectEqual(supplemental["SupplementalMatchDomains"] as? [String],[""])
        expectEqual(supplemental["SupplementalMatchOrders"] as? [Int],[1])
        expectEqual((supplemental["SupplementalMatchOrders"] as? [Int])?.count,(supplemental["SupplementalMatchDomains"] as? [String])?.count)
        let data=try PropertyListSerialization.data(fromPropertyList:expected,format:.binary,options:0)
        expectTrue((try PropertyListSerialization.propertyList(from:data,format:nil) as! NSDictionary).isEqual(to:expected))
        // 默认查询归核心处理，企业域名仍由原作用域解析器服务，不改企业 DNS 字典。
        let original=try plan()
        expectEqual(original.resolvers(for:"api.corp.example").first?.interface,"utun6")
        expectEqual(original.resolvers(for:"api.corp.example").first?.servers,["10.20.0.53","10.20.0.54"])
    }

    func testDomesticPriorityAndDNS() throws {
        try DomesticRouting.validate()
        expectTrue(DomesticRouting.isDomestic("www.baidu.com"));expectTrue(DomesticRouting.isDomestic("www.qq.com"))
        expectFalse(DomesticRouting.isDomestic("baidu.com.attacker.test"));expectFalse(DomesticRouting.isDomestic("oauth2.googleapis.com"))
        let creds=MemoryCredentials(),candidate=try NodeParser.parse("ss://aes-128-gcm:synthetic@192.0.2.1:8388")
        try creds.set(candidate.secret,for:candidate.node.credentialRef)
        var state=AppState();state.captureMode = .compatible;state.nodes=[candidate.node];state.selectedPolicy = .node(candidate.node.id)
        state.rules=[RoutingRule(kind:.domain,value:"qq.com",action:.proxy)]
        let config=try JSONSerialization.jsonObject(with:ConfigBuilder.build(state:state,credentials:creds,control:CoreControlContext(port:29999,secret:String(repeating:"a",count:64)))) as! [String:Any]
        let route=config["route"] as! [String:Any],rules=route["rules"] as! [[String:Any]]
        let user=rules.firstIndex{($0["domain"] as? [String])==["qq.com"] && $0["outbound"] as? String=="proxy"}!
        let domestic=rules.firstIndex{($0["domain_suffix"] as? [String])?.count ?? 0 > 8000 && $0["outbound"] as? String=="direct"}!
        expectTrue(user<domestic);expectEqual(route["final"] as? String,"proxy")
        expectEqual(DomesticRouting.conflictingRules(state).count,1)
        let dns=config["dns"] as! [String:Any],dnsRules=dns["rules"] as! [[String:Any]]
        expectTrue(dnsRules.contains{$0["server"] as? String=="local" && (($0["domain_suffix"] as? [String])?.count ?? 0)>8000})
        expectEqual(try RuleEvaluator.explain("www.baidu.com",state:state).target,.direct)
        expectEqual(try RuleEvaluator.explain("www.baidu.com.attacker.test",state:state).target,nil)
        state.protectedDomains=["corp.example"];state.mode = .global
        expectEqual(try RuleEvaluator.explain("api.corp.example",state:state).target,.direct)
        state.mode = .rule
        state.captureMode = .systemProxy
        var normal:[[String:Any]]=[];try DomesticRouting.appendRules(to:&normal,state:state);expectTrue(normal.isEmpty)
    }
    func plan() throws -> CapturePlan {
        var snapshot=CapturePlanTests().fixture()
        snapshot.routes.append(ProtectedRoute(destination:"198.19.0.0/16",gateway:"10.251.1.1",interface:"utun6"))
        return try CapturePlan.make(snapshot:snapshot,extraCIDRs:[],extraDomains:["corp.example"])
    }
    func response(_ query:Data)->Data {
        var data=query;data[2]=0x81;data[3]=0x80;data[6]=0;data[7]=1
        data.append(contentsOf:[0xc0,0x0c,0,1,0,1,0,0,0,60,0,4,198,19,0,32]);return data
    }
    func testDynamicAddressProtectionAndFailure() throws {
        let plan=try plan(),query=CapturePlanTests().query("api.corp.example"),answer=response(query)
        expectEqual(try DNSPacket.addresses(answer),["198.19.0.32"])
        expectThrows(try DNSPacket.addresses(answer.dropLast()))
        var ipv6=query;ipv6[2]=0x81;ipv6[3]=0x80;ipv6[7]=1
        ipv6.append(contentsOf:[0xc0,0x0c,0,28,0,1,0,0,0,60,0,16,0x20,0x01,0x0d,0xb8,0,0,0,0,0,0,0,0,0,0,0,1])
        expectEqual(try DNSPacket.addresses(ipv6),["2001:db8::1"])
        var cyclic=query;cyclic[12]=0xc0;cyclic[13]=0x0c
        expectThrows(try DNSPacket.addresses(cyclic))
        var unrelated=answer;unrelated[7]=2
        unrelated.append(contentsOf:[5]);unrelated.append(contentsOf:Data("other".utf8));unrelated.append(contentsOf:[0,0,1,0,1,0,0,0,60,0,4,8,8,8,8])
        expectEqual(try DNSPacket.addresses(unrelated),["198.19.0.32"])
        let started=Date()
        expectThrows(try NetworkInspection.command("/bin/sleep",["2"],deadline:Date().addingTimeInterval(0.1)))
        expectTrue(Date().timeIntervalSince(started)<1.5)
        expectTrue(plan.protects("api.corp.example"));expectFalse(plan.protects("corp.example.attacker.test"))
        let resolver=plan.resolvers(for:"api.corp.example")[0]
        let route=try plan.domainRoute(address:"198.19.0.32",resolver:resolver)
        expectEqual(route.interface,"utun6");expectEqual(route.destination,"198.19.0.32/32")
        expectThrows(try plan.domainRoute(address:"8.8.8.8",resolver:resolver))
        let wifi=plan.snapshot.resolvers.first{$0.interface=="en0"}!
        expectEqual(try plan.domainRoute(address:"192.168.66.20",resolver:wifi).interface,"en0")
        expectThrows(try plan.domainRoute(address:"8.8.8.8",resolver:wifi))
        var localSnapshot=plan.snapshot;localSnapshot.routes.append(ProtectedRoute(destination:"127.0.0.0/8",gateway:"link#1",interface:"lo0"))
        let localPlan=try CapturePlan.make(snapshot:localSnapshot,extraCIDRs:[],extraDomains:["corp.example"])
        expectEqual(try localPlan.domainRoute(address:"127.0.0.1",resolver:wifi).interface,"lo0")
        var protected=false
        let forwarder=try ScopedDNSForwarder(plan:plan,transport:{_,_,_ in answer},protectAnswers:{name,addresses,scope,deadline in
            guard name=="api.corp.example",addresses==["198.19.0.32"],scope.interface=="utun6",deadline>Date() else {throw ProxyError("保护参数错误")};protected=true
        })
        expectEqual(forwarder.resolve(query,name:"api.corp.example"),answer);expectTrue(protected)
        let rejected=try ScopedDNSForwarder(plan:plan,transport:{_,_,_ in answer},protectAnswers:{_,_,_,_ in throw ProxyError("模拟路由保护失败")})
        expectEqual(rejected.resolve(query,name:"api.corp.example")[3]&15,2)
        let records=NetworkSnapshot.parseRoutes("Internet:\n198.19.0.32 10.251.1.1 UGHW utun6\n8.8.8.8 192.168.1.1 UGHW en0")
        expectEqual(records.count,1);expectEqual(records.first?.interface,"utun6")
        var updated=plan.snapshot;updated.routes += records
        let fresh=try CapturePlan.make(snapshot:updated,extraCIDRs:[],extraDomains:["corp.example"])
        expectEqual(fresh.protectedRoutes,plan.protectedRoutes)
    }
    func testLoopbackAndCorporateFallback() throws {
        let plan=try plan(),creds=MemoryCredentials(),candidate=try NodeParser.parse("ss://aes-128-gcm:synthetic@192.0.2.1:8388")
        try creds.set(candidate.secret,for:candidate.node.credentialRef)
        var state=AppState();state.captureMode = .compatible;state.nodes=[candidate.node];state.selectedPolicy = .node(candidate.node.id)
        let data=try TunConfigBuilder.build(state:state,credentials:creds,control:CoreControlContext(port:29999,secret:String(repeating:"a",count:64)),address4:"100.64.1.1/30",address6:"fd71:717a:1::1/126",originalDNS:["192.168.66.1"],bypass:[],plan:plan,dnsForwardPort:29998)
        let config=try JSONSerialization.jsonObject(with:data) as! [String:Any],rules=(config["route"] as! [String:Any])["rules"] as! [[String:Any]]
        expectTrue(rules.contains{$0["outbound"] as? String=="protected-lo0"})
        expectTrue(rules.contains{$0["action"] as? String=="reject" && ($0["domain_suffix"] as? [String])==plan.domains})
        let protection=rules.firstIndex{($0["ip_cidr"] as? [String])==["198.19.0.0/16"]}!
        let global=rules.firstIndex{$0["clash_mode"] as? String=="global"}!
        expectTrue(protection<global)
    }
    func testFrozenBypassPlanAndDiagnostics() throws {
        expectEqual(NetworkInspection.routeArguments(.get,destination:"10.0.0.0"),["-n","get","-host","10.0.0.0"])
        expectEqual(NetworkInspection.routeArguments(.get,destination:"192.0.0.0",scope:"en0"),["-n","get","-ifscope","en0","-host","192.0.0.0"])
        expectEqual(NetworkInspection.routeArguments(.get,destination:"default"),["-n","get","default"])
        expectEqual(NetworkInspection.routeArguments(.get,destination:"10.0.0.0/8"),["-n","get","10.0.0.0/8"])
        expectEqual(NetworkInspection.routeArguments(.get,destination:"fc00::",ipv6:true),["-n","get","-inet6","-host","fc00::"])
        let gateway="gateway: 192.0.2.1\ninterface: en0\nflags: <UP,GATEWAY,DONE>"
        var queried:[String]=[]
        let plan=try BypassRoutePlan.capture(destinations:["10.0.0.0/8","192.168.0.0/16","10.0.0.0/8","::1/128"],existingPrefixes:["::1/128"],hasIPv6:true,lookup:{host,_ in queried.append(host);return gateway})
        expectEqual(queried,["10.0.0.0","192.168.0.0"]);expectEqual(plan.routes.count,2)
        try plan.validate(lookup:{_,_ in gateway})
        expectThrows(try plan.validate(lookup:{_,_ in gateway.replacingOccurrences(of:"192.0.2.1",with:"192.0.2.2")}))
        expectThrows(try BypassRoutePlan.capture(destinations:["10.0.0.0/8"],existingPrefixes:[],hasIPv6:true,lookup:{_,_ in "interface: en0\nflags: <REJECT>"}))
        let empty=try BypassRoutePlan.capture(destinations:["fc00::/7"],existingPrefixes:[],hasIPv6:false,lookup:{_,_ in throw ProxyError("不应查询无原 IPv6 默认路径的公网项")})
        expectTrue(empty.routes.isEmpty)
        let buffer=CoreDiagnosticBuffer(secrets:["split-secret-value"])
        buffer.receive(Data("info normal\nERROR split-secret-".utf8));buffer.receive(Data("value\n".utf8))
        expectEqual(buffer.recent.count,1);expectFalse(buffer.recent.joined().contains("split-secret-value"));expectFalse(buffer.recent.joined().contains("info normal"))
        for i in 0..<200 {buffer.receive(Data(("WARN "+String(i)+" "+String(repeating:"x",count:2000)+"\n").utf8))}
        expectEqual(buffer.recent.count,20);expectTrue(buffer.recent.allSatisfy{$0.count<=1024})
        let legacy=try JSONDecoder().decode(TunReply.self,from:Data(#"{"ok":true,"message":"old","running":false}"#.utf8))
        expectNil(legacy.coreDiagnostics)
    }

    func testOwnershipUsesCompleteRouteView() throws {
        let owned=ProtectedRoute(destination:"128.0.0.0/1",gateway:"192.168.1.1",interface:"utun7")
        expectEqual(CaptureOwnership.recoveryState(expected:owned,actual:[]),.absent)
        expectEqual(CaptureOwnership.recoveryState(expected:owned,actual:[owned]),.owned)
        expectEqual(CaptureOwnership.recoveryState(expected:owned,actual:[ProtectedRoute(destination:"128.0.0.0/1",gateway:"link#22",interface:"utun7")]),.replaced)
        expectEqual(CaptureOwnership.recoveryState(expected:owned,actual:[ProtectedRoute(destination:"128.0.0.0/1",gateway:owned.gateway,interface:owned.interface,scope:"utun7")]),.absent)
        expectEqual(CaptureOwnership.recoveryState(expected:owned,actual:[owned,ProtectedRoute(destination:"128.0.0.0/1",gateway:"link#22",interface:"utun7")]),.ambiguous)
        let table="Internet:\n239.255.255.250 link#11 UHmLW en0\n203.0.113.5 192.0.2.1 UGHW en0\n198.19.0.32 10.251.1.1 UGHW utun6"
        let planning=NetworkSnapshot.parseRoutes(table)
        let ownership=NetworkSnapshot.parseRoutes(table,includeTransient:true)
        expectEqual(planning.count,1);expectEqual(ownership.count,3)
        let expected=ownership.filter{$0.interface=="en0"}
        expectFalse(CaptureOwnership.routeIssues(expected:expected,actual:planning).isEmpty)
        expectTrue(CaptureOwnership.routeIssues(expected:expected,actual:ownership).isEmpty)
        for change in ["gateway","interface","scope","remove"] {
            var actual=ownership
            if change=="remove" {actual.removeFirst()}else if change=="gateway" {actual[0].gateway="192.0.2.99"}else if change=="interface" {actual[0].interface="utun9"}else {actual[0].scope="en0"}
            let issues=CaptureOwnership.routeIssues(expected:expected,actual:actual)
            expectFalse(issues.isEmpty);expectTrue(issues[0].contains("239.255.255.250/32"))
        }
        expectTrue(CaptureOwnership.routeIssues(expected:[],actual:ownership).isEmpty)
    }

    func testMulticastPreservesSystemScope() throws {
        let table="Internet6:\nff00::/8 link#11 UmCI en0\nff02::%en0/32 link#11 UmCI en0\nff02::%lo0/32 ::1 UmCI lo0\nff02::%utun6/32 link#21 UmCI utun6"
        let original=NetworkSnapshot.parseRoutes(table,includeTransient:true)
        expectEqual(original.count,4)
        var lookups=0
        let plan=try BypassRoutePlan.capture(destinations:["ff02::fb/128","ff02::1/128"],existingPrefixes:TunAddressPlan.routePrefixes(table),hasIPv6:false,existingRoutes:original,lookup:{_,_ in lookups+=1;throw ProxyError("组播不应查询全局出口")})
        expectTrue(plan.routes.isEmpty);expectEqual(lookups,0);expectEqual(plan.preservedRoutes.count,3)
        expectTrue(plan.preservedRoutes.allSatisfy{$0.scope==$0.interface && $0.destination=="ff02::/32"})
        try plan.validatePreservedRoutes(original)
        for change in ["remove","interface","gateway","scope"] {
            var altered=original
            if change=="remove" {altered.remove(at:1)}else if change=="interface" {altered[1].interface="utun9"}else if change=="gateway" {altered[1].gateway="link#99"}else {altered[1].scope=nil}
            expectThrows(try plan.validatePreservedRoutes(altered))
        }
        expectThrows(try BypassRoutePlan.capture(destinations:["ff02::fb/128"],existingPrefixes:["ff02::fb/128"],hasIPv6:true,existingRoutes:[],lookup:{_,_ in ""}))
        // 同前缀的全局路由不能替代系统原有的接口作用域路由。
        let global=[ProtectedRoute(destination:"ff02::/32",gateway:"link#11",interface:"en0")]
        expectThrows(try plan.validatePreservedRoutes(global))
        let nodeLocal=NetworkSnapshot.parseRoutes("Internet6:\nff01::%lo0/32 ::1 UmCI lo0",includeTransient:true)
        let local=try BypassRoutePlan.capture(destinations:["ff01::1/128"],existingPrefixes:[],hasIPv6:true,existingRoutes:nodeLocal,lookup:{_,_ in ""})
        expectEqual(local.preservedRoutes.count,1);expectTrue(local.routes.isEmpty)
    }

}
