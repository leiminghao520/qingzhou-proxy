import Foundation
import QingzhouKit

final class CorporateDNSTests:CheckCase {
    func plan(_ resolvers:[DNSResolverScope]) throws -> CapturePlan {
        try CapturePlan.make(snapshot:NetworkSnapshot(primaryInterface:"en0",routes:[ProtectedRoute(destination:"10.20.0.0/16",gateway:"link#15",interface:"utun6")],resolvers:[DNSResolverScope(service:"wifi",interface:"en0",servers:["192.0.2.53"],defaultResolver:true)]+resolvers),extraCIDRs:[],extraDomains:["private.example"])
    }
    func testSelection() throws {
        let first=DNSResolverScope(service:"a",interface:"utun6",servers:["10.20.0.53"],domains:["test","dev.test"],order:1,matchOrders:[10,90])
        let second=DNSResolverScope(service:"b",interface:"utun7",servers:["10.21.0.53"],domains:["dev.test"],order:500,matchOrders:[20])
        let broad=DNSResolverScope(service:"broad",interface:"utun8",servers:["10.22.0.53"],domains:["test"],order:0)
        expectEqual(try plan([broad,first,second]).selectResolvers(for:"api.dev.test").map(\.service),["b"])
        expectEqual(try plan([first,second]).selectResolvers(for:"api.test").map(\.service),["a"])
        expectThrows(try plan([first,second]).selectResolvers(for:"private.example"))
        expectEqual(try plan([first]).selectResolvers(for:"private.example").map(\.interface),["utun6"])
        expectThrows(try plan([]).selectResolvers(for:"private.example"))
        var tied=second;tied.matchOrders=[90]
        expectThrows(try plan([first,tied]).selectResolvers(for:"api.dev.test"))
        let duplicate=DNSResolverScope(service:"duplicate",interface:first.interface,servers:first.servers)
        expectEqual(try plan([first,duplicate]).selectResolvers(for:"private.example").count,1)
        var offline=try plan([first]);offline.snapshot.unavailableDomains=["private.example"]
        expectThrows(try offline.selectResolvers(for:"private.example"))
        var exact=try plan([]);exact.exactDomains=["only.example"]
        expectThrows(try exact.selectResolvers(for:"only.example"))
        expectEqual(try exact.selectResolvers(for:"child.only.example").first?.interface,"en0")
        let settings:[String:Any]=["SupplementalMatchDomains":["","test","dev.test"],"SupplementalMatchOrders":[1,10,90],"SearchOrder":500]
        expectEqual(CaptureDNSPolicy.matchOrder(settings,index:0),1)
        expectEqual(CaptureDNSPolicy.matchOrder(settings,index:2),90)
        expectEqual(CaptureDNSPolicy.matchOrder(settings,index:3),500)
        expectEqual(CaptureDNSPolicy.matchOrder([:],index:0),200000)
        var missing=try plan([first]);missing.snapshot.unavailableDomains=["dev.test"]
        expectThrows(try missing.selectResolvers(for:"api.dev.test"))
        let scope="resolver #1\n domain : private.example\n nameserver[0] : 127.0.0.1\n port : 5301\n order : 1\n"
        expectTrue(CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:scope,domain:"private.example",port:5301))
        expectFalse(CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:scope,domain:"private.example",port:5302))
        expectFalse(CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:scope,domain:"other.example",port:5301))
        let zeroScope="resolver #1\n domain : private.example\n nameserver[0] : 127.0.0.1\n port : 5301\n flags : Supplemental, Request A records\n"
        expectTrue(CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:zeroScope,domain:"private.example",port:5301),"系统省略零优先级字段时仍正确核验企业 DNS")
        expectFalse(CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:zeroScope,domain:"private.example",port:5302),"省略优先级不能放宽端口核验")
        expectFalse(CaptureDNSPolicy.isPreferred(server:"127.0.0.2",in:zeroScope,domain:"private.example",port:5301),"省略优先级不能放宽服务器核验")
        expectTrue(CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:zeroScope+scope.replacingOccurrences(of:"resolver #1",with:"resolver #2").replacingOccurrences(of:"127.0.0.1",with:"192.0.2.53"),domain:"private.example",port:5301),"零优先级应优先于显式正数优先级")
        expectFalse(CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:zeroScope+zeroScope.replacingOccurrences(of:"resolver #1",with:"resolver #2").replacingOccurrences(of:"127.0.0.1",with:"192.0.2.53"),domain:"private.example",port:5301),"同为零优先级的其他服务器必须阻止认领")
        expectFalse(CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:zeroScope+" order : malformed\n",domain:"private.example",port:5301),"显式损坏优先级不能按缺省零处理")
        let scoped=zeroScope+"DNS configuration (for scoped queries)\n"+zeroScope.replacingOccurrences(of:"127.0.0.1",with:"192.0.2.53")
        expectTrue(CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:scoped,domain:"private.example",port:5301),"限定接口的解析器不冒充全局域名匹配竞争者")
        let decoded=try JSONDecoder().decode(DNSResolverScope.self,from:JSONEncoder().encode(first))
        expectEqual(decoded.matchOrders,[10,90])
        expectEqual(CaptureDNSPolicy.corporateSettings(domains:["private.example"],port:5301)["ServerPort"] as? Int,5301)
    }
    func testResponses() throws {
        let corporate=DNSResolverScope(service:"corp",interface:"utun6",servers:["10.20.0.53"],domains:["corp.test"])
        let current=try plan([corporate])
        let relay=try ScopedDNSForwarder(plan:current);defer{relay.stop()}
        let helper=CapturePlanTests()
        let request=helper.query("api.corp.test")
        func answer(_ query:Data,_ code:UInt8=0,_ withAddress:Bool=false)->Data {
            var data=query;data[2]|=0x80;data[3]=code
            if withAddress {data[7]=1;data.append(contentsOf:[0xc0,12,0,1,0,1,0,0,0,1,0,4,10,20,1,2])}
            return data
        }
        for (code,outcome) in [(UInt8(0),CorporateDNSOutcome.noRecords),(3,.nxdomain),(2,.servfail),(5,.refused)] {
            var contacted:[String]=[]
            _=relay.resolve(request,name:"api.corp.test",exchange:{data,server,interface in contacted.append(server+"@"+interface);return answer(data,code)})
            expectEqual(relay.diagnosticResults.last?.outcome,outcome)
            expectEqual(contacted,["10.20.0.53@utun6"])
        }
        _=relay.resolve(request,name:"api.corp.test",exchange:{data,_,_ in answer(data,0,true)})
        expectEqual(relay.diagnosticResults.last?.outcome,.answered)
        var aaaa=request;aaaa[aaaa.count-3]=28
        _=relay.resolve(aaaa,name:"api.corp.test",exchange:{data,_,_ in answer(data)})
        expectEqual(relay.diagnosticResults.count,2)
        expectEqual(relay.diagnosticResults.first?.outcome,.answered)
        expectEqual(relay.diagnosticResults.last?.outcome,.noRecords)
        expectEqual(relay.diagnosticResults.last?.result.errorCategory,.corporateDNS)
        _=relay.resolve(request,name:"api.corp.test",exchange:{_,_,_ in nil})
        expectEqual(relay.diagnosticResults.last?.outcome,.timeout)
        _=relay.resolve(request,name:"api.corp.test",exchange:{_,_,_ in Data([1,2])})
        expectEqual(relay.diagnosticResults.last?.outcome,.invalidResponse)
        let protected=try ScopedDNSForwarder(plan:current,protectAnswers:{_,_,_,_ in throw ProxyError("注入保护失败")});defer{protected.stop()}
        expectEqual(protected.resolve(request,name:"api.corp.test",exchange:{data,_,_ in answer(data,0,true)})[3]&15,2)
        expectEqual(protected.diagnosticResults.last?.outcome,.answerProtectionFailed)
        let late=relay.resolve(request,name:"api.corp.test",exchange:{data,_,_ in relay.updatePlan(current);return answer(data,0,true)})
        expectEqual(late[3]&15,2);expectTrue(relay.diagnosticResults.isEmpty)
        relay.updatePlan(try plan([corporate,DNSResolverScope(service:"other",interface:"utun9",servers:["10.30.0.53"])]))
        _=relay.resolve(helper.query("private.example"),name:"private.example",exchange:{_,_,_ in expectTrue(false);return nil})
        expectEqual(relay.diagnosticResults.last?.outcome,.resolverAmbiguous)
        relay.updatePlan(try plan([]));_=relay.resolve(helper.query("private.example"),name:"private.example")
        expectEqual(relay.diagnosticResults.last?.outcome,.resolverUnavailable)
        relay.updatePlan(current,suspended:true);_=relay.resolve(request,name:"api.corp.test")
        expectEqual(relay.diagnosticResults.last?.outcome,.resolverUnavailable)
    }
    func testTransactions() throws {
        let original:NSDictionary=["ServerAddresses":["192.0.2.53"]]
        let expected:NSDictionary=["ServerAddresses":["127.0.0.1"],"ServerPort":54321]
        let records=try ["a","b","c"].map{DNSServiceRecord(key:$0,expected:try DNSServiceTransaction.encode(expected),original:$0=="a" ? try DNSServiceTransaction.encode(original):nil)}
        var values:[String:NSDictionary]=["a":original],saved=false,writes=0
        func read(_ key:String)->NSDictionary? {values[key]}
        func write(_ key:String,_ value:NSDictionary?) throws {expectTrue(saved);writes+=1;if key=="b" {throw ProxyError("注入写入失败")};values[key]=value}
        expectThrows(try DNSServiceTransaction.apply(records,persist:{saved=true},read:read,write:write))
        expectEqual(values["a"],expected);expectNil(values["b"]);expectEqual(writes,2)
        // 模拟崩溃后重读持久化意图，不依赖内存中的写入进度。
        let restored=try JSONDecoder().decode([DNSServiceRecord].self,from:JSONEncoder().encode(records))
        expectTrue(DNSServiceTransaction.restore(restored,read:read,write:{values[$0]=$1}).isEmpty)
        expectEqual(values["a"],original)
        expectThrows(try DNSServiceTransaction.apply(records,persist:{throw ProxyError("保存失败")},read:read,write:{_,_ in expectTrue(false)}))
        values=["a":expected,"b":expected,"c":expected]
        let external:NSDictionary=["ServerAddresses":["203.0.113.53"]];values["b"]=external
        let issues=DNSServiceTransaction.restore(records,read:read,write:{key,value in if key=="c" {throw ProxyError("恢复失败")};values[key]=value})
        expectEqual(issues.count,2);expectEqual(values["a"],original);expectEqual(values["b"],external);expectEqual(values["c"],expected)
        expectEqual(DNSServiceTransaction.issues(records,read:read).count,2)
        values["a"]=external
        expectThrows(try DNSServiceTransaction.apply(records,persist:{},read:read,write:{_,_ in expectTrue(false)}))
        values=["a":original]
        expectThrows(try DNSServiceTransaction.apply(records,persist:{},read:read,write:{_,_ in }))
        values=["a":expected]
        expectEqual(DNSServiceTransaction.restore([records[0]],read:read,write:{_,_ in }).count,1)
        expectThrows(try DNSServiceTransaction.decode(Data("invalid".utf8)))
        expectThrows(try DNSServiceTransaction.decode(PropertyListSerialization.data(fromPropertyList:["wrong"],format:.binary,options:0)))
        expectEqual(DNSServiceTransaction.issues(records,read:{_ in throw ProxyError("读取失败")}).count,3)
        expectEqual(DNSServiceTransaction.restore(records,read:{_ in throw ProxyError("读取失败")},write:{_,_ in expectTrue(false)}).count,3)
    }
}

extension CorporateDNSTests {
    func testOfficeWiFi() throws {
        let wifi=DNSResolverScope(service:"office-wifi",interface:"en0",servers:["10.57.82.100","10.57.82.101"],defaultResolver:true)
        let vpn=DNSResolverScope(service:"security",interface:"utun6",servers:["10.251.1.1"],defaultResolver:true)
        let physical=ProtectedRoute(destination:"10.0.0.0/8",gateway:"10.57.240.1",interface:"en0")
        var snapshot=NetworkSnapshot(primaryInterface:"en0",routes:[physical,ProtectedRoute(destination:"0.0.0.0/0",gateway:"10.57.240.1",interface:"en0")],resolvers:[wifi,vpn])
        snapshot.primaryService=wifi.service
        var state=AppState();state.protectedDomains=["tongdun.me"];state.tunExcludedCIDRs=["10.0.0.0/8"]
        let trusted=TrustedCorporateDNS(name:"公司 Wi-Fi",serviceID:wifi.service,servers:wifi.servers,domains:["tongdun.me"])
        let name="teamwork.tongdun.me"
        let baseline=try CapturePlan.make(snapshot:snapshot,state:state)
        expectEqual(try baseline.selectResolvers(for:name).first?.interface,"utun6")
        expectEqual(try baseline.domainRoute(address:"10.63.100.149",resolver:vpn,host:name).interface,"en0","企业 DNS 与业务出口可以不同")
        state.trustedCorporateDNS=[trusted]
        let office=try CapturePlan.make(snapshot:snapshot,state:state)
        expectEqual(try office.selectResolvers(for:name).first?.service,wifi.service)
        expectEqual(try office.domainRoute(address:"10.63.100.149",resolver:wifi,host:name).interface,"en0")
        expectThrows(try office.domainRoute(address:"8.8.8.8",resolver:wifi,host:name))
        var alone=snapshot;alone.resolvers=[wifi]
        expectEqual(try CapturePlan.make(snapshot:alone,state:state).selectResolvers(for:name).first?.service,wifi.service)
        var unknown=alone;unknown.resolvers[0].servers=["192.168.1.1"]
        expectThrows(try CapturePlan.make(snapshot:unknown,state:state).selectResolvers(for:name))
        unknown.resolvers[0].servers=wifi.servers;unknown.resolvers[0].service="other-service"
        expectThrows(try CapturePlan.make(snapshot:unknown,state:state).selectResolvers(for:name))
        unknown.resolvers[0]=wifi;unknown.primaryService="other-primary"
        expectThrows(try CapturePlan.make(snapshot:unknown,state:state).selectResolvers(for:name))
        unknown.primaryService=wifi.service
        unknown.resolvers[0]=wifi;unknown.resolvers[0].servers=[]
        expectThrows(try CapturePlan.make(snapshot:unknown,state:state).selectResolvers(for:name))
        unknown.resolvers[0]=wifi;unknown.resolvers[0].servers=[wifi.servers[0],"192.168.1.1"]
        expectThrows(try CapturePlan.make(snapshot:unknown,state:state).selectResolvers(for:name))
        unknown.resolvers[0]=wifi;unknown.resolvers[0].servers=[wifi.servers[0]]
        expectEqual(try CapturePlan.make(snapshot:unknown,state:state).selectResolvers(for:name).first?.servers,[wifi.servers[0]])
        var scoped=snapshot;scoped.resolvers[1].domains=["tongdun.me"]
        expectEqual(try CapturePlan.make(snapshot:scoped,state:state).selectResolvers(for:name).first?.service,vpn.service)
        expectTrue(office.trustedResolvers(for:"tongdun.me.attacker.test").isEmpty)
        var conflict=office;conflict.snapshot.routes.append(ProtectedRoute(destination:physical.destination,gateway:"10.57.240.2",interface:"en1"))
        expectThrows(try conflict.domainRoute(address:"10.63.100.149",resolver:vpn,host:name))
        var specific=office;specific.snapshot.routes.append(ProtectedRoute(destination:"10.63.0.0/16",gateway:"link#15",interface:"utun6"));specific.protectedRoutes.append(specific.snapshot.routes.last!)
        expectEqual(try specific.domainRoute(address:"10.63.100.149",resolver:wifi,host:name).interface,"utun6")
        var pinned=office;pinned.pinnedDomainRoutes=[ProtectedRoute(destination:"10.63.0.0/16",gateway:"10.10.1.1",interface:"en1")]
        expectEqual(try pinned.domainRoute(address:"10.63.100.149",resolver:wifi,host:name).interface,"en1")
        let relay=try ScopedDNSForwarder(plan:baseline,protectAnswers:{host,addresses,resolver,_ in
            for address in addresses {_ = try baseline.domainRoute(address:address,resolver:resolver,host:host)}
        });defer{relay.stop()}
        let query=DNSPacket.query(name,type:1)
        var answer=query;answer[2]|=0x80;answer[7]=1;answer.append(contentsOf:[0xc0,12,0,1,0,1,0,0,0,1,0,4,10,63,100,149])
        let response=relay.resolve(query,name:name,exchange:{_,server,interface in
            expectEqual(server,vpn.servers[0]);expectEqual(interface,"utun6");return answer
        })
        expectEqual(response[3]&15,0)
        expectEqual(relay.diagnosticResults.last?.businessInterfaces,["en0"])
        let rejected=try ScopedDNSForwarder(plan:office,protectAnswers:{_,_,_,_ in throw CorporateDNSRouteError.conflict});defer{rejected.stop()}
        _=rejected.resolve(query,name:name,exchange:{_,_,_ in answer})
        expectEqual(rejected.diagnosticResults.last?.outcome,.answerRouteConflict)
        var noTrust=state;noTrust.trustedCorporateDNS=nil
        expectThrows(try CapturePlan.make(snapshot:alone,state:noTrust).selectResolvers(for:name))
        let encoded=try JSONEncoder().encode(state)
        expectEqual(try JSONDecoder().decode(AppState.self,from:encoded).trustedCorporateDNS,[trusted])
        expectNil(try JSONDecoder().decode(AppState.self,from:Data("{}".utf8)).trustedCorporateDNS)
        expectThrows(try TrustedCorporateDNS.normalize([TrustedCorporateDNS(name:"",serviceID:"wifi",servers:wifi.servers,domains:trusted.domains)]))
        expectThrows(try TrustedCorporateDNS.normalize([TrustedCorporateDNS(name:"公司",serviceID:"wifi",servers:["10.0.0.0/8"],domains:trusted.domains)]))
        expectThrows(try TrustedCorporateDNS.normalize([TrustedCorporateDNS(name:"公司",serviceID:"wifi",servers:wifi.servers,domains:[])]))
        expectThrows(try TrustedCorporateDNS.normalize([trusted,trusted]))
    }
}
