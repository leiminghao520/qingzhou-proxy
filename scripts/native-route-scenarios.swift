import Foundation
import Darwin
import CQingzhouRoute
import QingzhouKit

extension Checks {
    static func extended() throws {
        let oldJSON=Data(#"{"dnsKey":"fixture","version":2,"routes":[],"expectedDNS":"","address4":"100.64.1.1/30","address6":"fd71:717a::1/126"}"#.utf8)
        var record=try JSONDecoder().decode(Journal.self,from:oldJSON)
        check(record.captureRoutes==nil && record.routes.isEmpty,"旧恢复记录无需配置迁移")
        record.captureRoutes=["0.0.0.0/2","64.0.0.0/2","128.0.0.0/1"]
        let decoded=try JSONDecoder().decode(Journal.self,from:JSONEncoder().encode(record))
        check(decoded.captureRoutes==record.captureRoutes,"新捕获列表持久化往返")
        let r=ProtectedRoute(destination:"192.0.2.7/32",gateway:"127.0.0.1",interface:"lo0",scope:"lo0")
        let transport=Transport(),backend=NativeRouteBackend(transport:transport)
        var noncanonical=r;noncanonical.destination="192.0.2.77/24"
        check(try backend.write(.add,route:noncanonical) == .applied,"非规范 CIDR 在结构化边界规范化后编码")
        let normalized=transport.sent.last!.withUnsafeBytes{$0.loadUnaligned(as:rt_msghdr.self)}
        check(normalized.rtm_addrs & RTA_IFP==0,"新增路由不强制注入空 IFP")
        transport.failure=RouteBackendError(EACCES)
        check(try backend.write(.add,route:r) == .rejected(EACCES),"提交前明确拒绝不认领外部路由")
        transport.failure=nil
        transport.transform={input in var value=input;value.withUnsafeMutableBytes{$0.baseAddress!.assumingMemoryBound(to:rt_msghdr.self).pointee.rtm_seq += 1};return value}
        do {_=try backend.write(.add,route:r);check(false,"错误序列不能提交")}
        catch let error as RouteBackendError {check(error.outcomeUnknown,"写后响应不匹配仍保留恢复意图")}
        transport.transform=nil
        fails("过期预算不提交") {_=try backend.write(.delete,route:r,deadline:Date().addingTimeInterval(-1))}
        for (family,bits,address,interface,scoped) in [(AF_INET,-1,"192.0.2.1","lo0",0),(AF_INET,33,"192.0.2.1","lo0",0),(AF_INET6,129,"::1","lo0",0),(AF_UNIX,32,"::1","lo0",0),(AF_INET,32,"invalid","lo0",0),(AF_INET,32,"192.0.2.1","invalid-interface",0),(AF_INET,32,"192.0.2.1","",1)] {
            var bytes=Data(count:2048),length=0
            let code=bytes.withUnsafeMutableBytes{qz_route_encode(RTM_ADD,address,family,Int32(bits),"127.0.0.1",interface,Int32(scoped),0,1,1,$0.baseAddress,$0.count,&length)}
            check(code != 0,"编码拒绝非法地址、前缀和接口")
        }
        let header=MemoryLayout<rt_msghdr>.size
        var noncontiguous=try packet("192.0.2.0",bits:24)
        noncontiguous[header+32+4]=255;noncontiguous[header+32+5]=0;noncontiguous[header+32+6]=255
        fails("非连续网络掩码拒绝") {_=try NativeRouteBackend.decode(noncontiguous)}
        var shortAddress=try packet();shortAddress[header]=2
        fails("地址长度不足拒绝") {_=try NativeRouteBackend.decode(shortAddress)}
        var unknownGateway=try packet();unknownGateway[header+16+1]=UInt8(AF_UNIX)
        fails("未知网关族拒绝") {_=try NativeRouteBackend.decode(unknownGateway)}
        var both=try packet();both.append(try packet("192.0.2.8"))
        check(try NativeRouteBackend.decode(both).count==2,"整表逐项解析而非只取首条")
        var kernel:Int32=0
        let wrongType=try packet().withUnsafeBytes{qz_route_match($0.baseAddress,$0.count,RTM_DELETE,123,456,&kernel)}
        check(wrongType == -EPROTO,"同序列不同操作拒绝")
        let malformed=Data(repeating:0,count:3).withUnsafeBytes{qz_route_match($0.baseAddress,$0.count,RTM_ADD,123,456,&kernel)}
        check(malformed == -EPROTO,"截断响应拒绝")
        fails("异常零掩码只能用于旧记录删除") {_=try packet("2001:db8::7",bits:128,ipv6:true,legacy:true)}
        let command=LegacyRouteBackend(command:{path,args,_ in
            if path.contains("netstat") {return "Internet:\ndefault 127.0.0.1 UGS lo0"}
            if args.contains("get") {return "destination: default\nmask: default\ngateway: 127.0.0.1\ninterface: lo0\nflags: <UP,GATEWAY,STATIC>"}
            return args.contains("delete") ? "writing to routing socket: Permission denied":""
        })
        check(try command.snapshot().planningRoutes.count==1,"旧后端整表隔离注入")
        check(try command.lookup("default",ipv6:false,scope:nil,deadline:nil).route.destination=="0.0.0.0/0","旧命令默认掩码规范化")
        check(try command.write(.add,route:r,legacy:false,deadline:nil) == .applied,"旧后端成功可比较")
        check(try command.write(.delete,route:r,legacy:false,deadline:nil) == .rejected(EIO),"旧后端拒绝可比较")
        let default4=ProtectedRoute(destination:"0.0.0.0/0",gateway:"192.0.2.1",interface:"en0")
        let specific=ProtectedRoute(destination:"10.20.0.0/16",gateway:"10.20.0.1",interface:"utun6")
        let sibling=ProtectedRoute(destination:specific.destination,gateway:"10.20.0.2",interface:"utun7")
        check(try CaptureRoutePlan.systemPath("10.20.2.1",routes:[default4,specific])==specific,"原路径按最长前缀选取")
        fails("多网卡同前缀歧义不能选首条") {_=try CaptureRoutePlan.systemPath("10.20.2.1",routes:[default4,specific,sibling])}
        var scoped=specific;scoped.scope=scoped.interface
        check(try CaptureRoutePlan.systemPath("10.20.2.1",routes:[default4,scoped])==default4,"仅作用域路由不能冒充全局出口")
        let linkA=ProtectedRoute(destination:"fe80::/64",gateway:"link#11",interface:"en0",scope:"en0")
        let linkB=ProtectedRoute(destination:"fe80::/64",gateway:"link#23",interface:"en6",scope:"en6")
        let linkHost=ProtectedRoute(destination:"fe80::123/128",gateway:"link#11",interface:"en0",scope:"en0")
        let links=try BypassRoutePlan.capture(destinations:["fe80::/10"],existingPrefixes:[],hasIPv6:true,existingRoutes:[linkA,linkB,linkHost],lookup:{_,_ in throw ProxyError("链路本地不得查询单个默认出口")})
        check(links.routes.isEmpty && links.preservedRoutes.count==2 && links.preservedRoutes.contains(linkA) && links.preservedRoutes.contains(linkB),"链路本地保留多网卡作用域，不补全局 /10 或重复缓存")
        try links.validatePreservedRoutes([linkA,linkB])
        fails("链路本地原路径在激活前消失必须拒绝") {try links.validatePreservedRoutes([linkA])}
        fails("只有全局默认路由不能证明链路本地原出口") {_=try BypassRoutePlan.capture(destinations:["fe80::/10"],existingPrefixes:[],hasIPv6:true,existingRoutes:[default4],lookup:{_,_ in throw ProxyError("不应查询")})}
        let noV6=try BypassRoutePlan.capture(destinations:["fe80::/10"],existingPrefixes:[],hasIPv6:false,lookup:{_,_ in throw ProxyError("不应查询")})
        check(noV6.routes.isEmpty && noV6.preservedRoutes.isEmpty,"IPv6 不可用沿用现有跳过策略")
        check(CaptureOwnership.monitoredPreservedRoutes([linkA,linkB]).isEmpty,"系统链路本地作用域生命周期不冒充自有公网路由被覆盖")
        var globalLink=linkA;globalLink.scope=nil
        fails("无作用域链路本地项不能当作接口原路径") {_=try BypassRoutePlan.capture(destinations:["fe80::/10"],existingPrefixes:[],hasIPv6:true,existingRoutes:[globalLink],lookup:{_,_ in throw ProxyError("不应查询")})}
        check(CaptureOwnership.monitoredPreservedRoutes([globalLink])==[globalLink],"全局链路本地项不能豁免所有权检查")
        var queryPacket=Data(count:2048),queryLength=0
        let linkGet=queryPacket.withUnsafeMutableBytes{qz_route_encode(RTM_GET,"fe80::",AF_INET6,128,"","",0,0,1,2,$0.baseAddress,$0.count,&queryLength)}
        check(linkGet==0 && queryLength>0,"无作用域链路本地只读请求交由内核处理，与 route get 对齐")
        let resolver=DNSResolverScope(service:"wifi",interface:"en0",servers:["192.0.2.53"],defaultResolver:true)
        var plan=try CapturePlan.make(snapshot:NetworkSnapshot(primaryInterface:"en0",routes:[default4,scoped],resolvers:[resolver]),extraCIDRs:[],extraDomains:[])
        plan.protectedRoutes=[scoped];plan.exclusions=["10.20.0.0/16"]
        let sample=NetworkRouteSample(records:[RouteRecord(route:default4,flags:3),RouteRecord(route:scoped,flags:UInt32(RTF_UP|RTF_GATEWAY|RTF_IFSCOPE))])
        let bypass=try BypassRoutePlan.capture(destinations:["10.20.0.0/16"],existingPrefixes:[],hasIPv6:false,lookup:{_,_ in RouteRecord(route:scoped,flags:UInt32(RTF_UP|RTF_GATEWAY|RTF_IFSCOPE)).queryText})
        let protected=try CaptureRoutePlan.make(plan:plan,bypass:bypass,baseline:sample)
        check(protected.captures("10.20.2.1"),"仅作用域企业出口继续捕获并依赖保护路由")
        var emptyPlan=plan;emptyPlan.protectedRoutes=[];emptyPlan.exclusions=[]
        let localCapture=try CaptureRoutePlan.make(plan:emptyPlan,bypass:links,baseline:NetworkRouteSample(routes:sample.ownershipRoutes+[linkA,linkB]))
        check(localCapture.captures("fe80::1") && localCapture.captures("fe81::1"),"全局捕获不拆链路本地碎片，也不把已确认 /64 扩成 /10")
        check(localCapture.prefixes.compactMap(IPPrefix.init).allSatisfy{!$0.overlaps(IPPrefix("fe80::/64")!) || $0.bits<64},"实际作用域 /64 始终比全局捕获更具体")
        let node=try BypassRoutePlan.capture(destinations:["198.51.100.7/32"],existingPrefixes:[],hasIPv6:false,lookup:{_,_ in RouteRecord(route:default4,flags:3).queryText})
        let nodeCapture=try CaptureRoutePlan.make(plan:emptyPlan,bypass:node,baseline:sample)
        check(!nodeCapture.captures("198.51.100.7") && nodeCapture.captures("198.51.100.8"),"节点地址精确排除，邻接公网仍捕获")
        let enterprise=ProtectedRoute(destination:"198.51.100.0/24",gateway:"10.20.0.1",interface:"utun6")
        let physicalChild=ProtectedRoute(destination:"198.51.100.128/25",gateway:default4.gateway,interface:default4.interface)
        let fragmentSample=NetworkRouteSample(records:[default4,enterprise,physicalChild].map{RouteRecord(route:$0,flags:UInt32(RTF_UP|RTF_GATEWAY))})
        var fragmentPlan=plan;fragmentPlan.protectedRoutes=[enterprise]
        let fragmentBypass=try BypassRoutePlan.capture(destinations:[physicalChild.destination],existingPrefixes:[],hasIPv6:false,lookup:{_,_ in RouteRecord(route:physicalChild,flags:UInt32(RTF_UP|RTF_GATEWAY)).queryText})
        let fragments=try CaptureRoutePlan.make(plan:fragmentPlan,bypass:fragmentBypass,baseline:fragmentSample)
        check(!fragments.captures("198.51.100.1") && !fragments.captures("198.51.100.129"),"物理子网排除产生的更具体捕获碎片不能覆盖原企业路由")
        check(fragments.exclusions.contains(enterprise.destination),"相交时继续差集直到原企业出口优先")
        let exclusions=["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","2001:db8::/32","fc00::/7"]
        let capture=try CaptureRoutePlan(exclusions:exclusions)
        let excluded=exclusions.compactMap(IPPrefix.init)
        var seed:UInt64=17
        for _ in 0..<2000 {
            seed=seed &* 6364136223846793005 &+ 1
            let b=UInt32(truncatingIfNeeded:seed>>16)
            let address="\(b>>24).\((b>>16)&255).\((b>>8)&255).\(b&255)"
            let host=IPPrefix(address+"/32")!
            check(capture.captures(address) == !excluded.contains{$0.contains(host)},"差集无意外缺口或重叠")
        }
        let merged=try CaptureRoutePlan(exclusions:["192.0.2.0/25","192.0.2.128/25","192.0.2.64/26","192.0.2.0/24"])
        check(merged.prefixes == (try CaptureRoutePlan(exclusions:["192.0.2.0/24"])).prefixes,"嵌套和相邻排除合并")
        let fallback=try CaptureRoutePlan(exclusions:["198.51.100.7/32"],limit:4)
        check(fallback.prefixes==CaptureRoutePlan.legacyPrefixes && fallback.exclusions.isEmpty && fallback.fallbackReason != nil,"预算回退不声称已排除节点")
        check(IPPrefix("bad/24")==nil && IPPrefix("1.1.1.1/99")==nil && IPPrefix("2001:db8::7/64")?.text=="2001:db8::/64","CIDR 规范化与非法输入")
        let interfaces=try NativeInterfaces.addresses()
        check(interfaces["lo0"]?.contains("127.0.0.1")==true,"原生接口枚举保留回环地址")
        let readiness=NativeInterfaceReadiness(addresses:{interfaces},wait:{ms in usleep(UInt32(ms)*1000)})
        fails("接口等待取消") {_=try readiness.wait(previous:interfaces,address:"192.0.2.7",timeout:1,alive:{true},cancelled:{true})}
        fails("核心退出停止等待") {_=try readiness.wait(previous:interfaces,address:"192.0.2.7",timeout:1,alive:{false},cancelled:{false})}
        fails("接口就绪总预算") {_=try readiness.wait(previous:interfaces,address:"192.0.2.7",timeout:0.001,alive:{true},cancelled:{false})}
        let pool=NetworkPreparationPool(),started=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        var prepared=false
        let values=try pool.addresses(["fixture"],prepare:{check(started.wait(timeout:.now()+1) == .success,"纯读取与解析重叠执行");prepared=true;release.signal()},resolver:{_ in started.signal();release.wait();return ["192.0.2.7"]})
        check(prepared && values["fixture"]==["192.0.2.7"],"并行准备返回同一次解析结果")
    }
}
