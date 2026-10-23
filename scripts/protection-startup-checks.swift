import Foundation
import Darwin
import QingzhouKit

// 链接正式路由写入扩展；路由、落盘和取消全部使用内存夹具，不触碰当前网络。
struct OwnedRoute {var destination:String;var gateway:String;var interface:String;var ipv6:Bool;var scope:String?}
struct Journal {
    var interface:String?=nil
    var routes:[OwnedRoute]=[]}
final class Service {
    var journal:Journal?=Journal()
    var table:[ProtectedRoute]=[]
    var routeMetrics:RouteOperationMetrics?=RouteOperationMetrics()
    var owner:Int32?
    private var ownedDescriptors:[Int32]=[]
    init(){
        var pair:[Int32]=[-1,-1];precondition(socketpair(AF_UNIX,SOCK_STREAM,0,&pair)==0)
        ownedDescriptors=pair;owner=pair[0]
    }
    deinit{for fd in ownedDescriptors {close(fd)}}
    var saves=0,writes=0,queries=0,samples=0
    var persisted:[OwnedRoute]=[]
    var beforeQuery:(() throws -> Void)?
    var beforeSave:(() throws -> Void)?
    var beforeWrite:(() throws -> Void)?
    var afterWrite:(()->Void)?
    var rawTable:String?
    var lookupFailure=false
    var rejected=false
    func save() throws {try measured("routeJournalSave") {try beforeSave?();saves+=1;persisted=journal?.routes ?? []}}
    func field(_ label:String,_ text:String)->String? {label=="gateway" ? NetworkInspection.routeGateway(text):NetworkInspection.routeField(label,text)}
    func prefix(_ info:String)->String? {NetworkInspection.routePrefix(destination:field("destination",info),mask:field("mask",info),host:info.contains("HOST"))}
    func routeInfo(_ destination:String,ipv6:Bool,scope:String?=nil,deadline:Date?=nil) throws -> String {
        try measured("routeQuery") {
            try beforeQuery?()
            queries+=1
            if lookupFailure {throw ProxyError("注入查询失败")}

            let r=table.first{NetworkInspection.samePrefix($0.destination,destination) && $0.scope==scope}
            return "destination: \(r.map{String($0.destination.split(separator:"/")[0])} ?? "default")\ngateway: \(r?.gateway ?? "192.0.2.1")\ninterface: \(r?.interface ?? "en0")\nflags: <UP,GATEWAY\(r == nil ? "":",HOST")\(scope == nil ? "":",IFSCOPE")>"
        }
    }
    func routeSample() throws -> NetworkRouteSample {
        samples+=1
        if let rawTable {return try NetworkRouteSample(read:{rawTable})}
        return try sample(table)
    }
    func writeRoute(_ args:[String],deadline:Date?) throws -> String {
        try measured("routeWrite") {
            try beforeWrite?();writes+=1
            guard saves>0,let r=journal?.routes.last else {throw ProxyError("缺少已保存意图")}
            if rejected {return "route: writing to routing socket: File exists"}
            table.append(ProtectedRoute(destination:r.destination,gateway:r.gateway,interface:r.interface,scope:r.scope));afterWrite?()
            return "add host: fixture"
        }
    }
}
func sample(_ routes:[ProtectedRoute]) throws -> NetworkRouteSample {
    try NetworkRouteSample(read:{routes.map {r in r.destination+" "+r.gateway+" UGHS"+(r.scope == nil ? "":"I")+" "+r.interface}.joined(separator:"\n")})
}
@main struct Checks {
    static var assertions=0
    static func check(_ value:@autoclosure()->Bool,_ message:String) {assertions+=1;if !value(){fatalError(message)}}
    static func fails(_ message:String,_ body:() throws -> Void) {
        do {try body();check(false,message)}catch{check(true,message)}
    }
    static func main() throws {
        let competitor=Service();competitor.journal?.interface="utun42"
        competitor.table=[ProtectedRoute(destination:"0.0.0.0/1",gateway:"link#99",interface:"utun99")]
        fails("连接中其他隧道接管时停止铺设捕获路由") {try competitor.addRoute("203.0.113.0/24","100.64.1.1","utun42",ipv6:false)}
        check(competitor.writes==0 && competitor.saves==0,"竞争接管不能产生新恢复意图或路由写入")
        let a=ProtectedRoute(destination:"10.23.42.7/24",gateway:"192.0.2.1",interface:"en0")
        let b=ProtectedRoute(destination:"10.23.42.0/24",gateway:"192.0.2.1",interface:"en0")
        check(RouteIdentityIndex([a]).state(b) == .owned,"规范化 IPv4 前缀")
        let v6=ProtectedRoute(destination:"2001:db8:1::ff/64",gateway:"2001:db8::1",interface:"en6",scope:"en6")
        var v6b=v6;v6b.destination="2001:0db8:0001::/64"
        check(RouteIdentityIndex([v6]).state(v6b) == .owned,"规范化 IPv6 前缀")
        var alternate=b;alternate.interface="en6"
        check(RouteIdentityIndex([b,alternate]).state(b) == .ambiguous,"同前缀不同接口不混淆")
        alternate.scope="en6"
        check(RouteIdentityIndex([alternate]).state(b) == .absent,"作用域隔离")
        alternate=b;alternate.gateway="192.0.2.2"
        check(RouteIdentityIndex([alternate]).state(b) == .replaced,"网关变化")
        check(RouteIdentityIndex([b]).contains(a),"完整身份匹配")
        check(!RouteIdentityIndex([alternate]).contains(b),"完整身份拒绝替换")
        for bad in ["bad","bad/24","1.1.1.1/x","1.1.1.1/33","::/129"] {
            var r=b;r.destination=bad
            check(RouteIdentityIndex([r]).state(r) == .absent,"非法前缀不能证明所有权")
        }
        for prefix in ["0.0.0.0/0","0.0.0.1/1","255.255.255.255/32","::/0","8000::1/1","2001:db8::1/128"] {
            var r=b;r.destination=prefix
            check(RouteIdentityIndex([r]).state(r) == CaptureOwnership.recoveryState(expected:r,actual:[r]),"索引与原规则一致")
        }
        let existing=(0..<600).map {ProtectedRoute(destination:"10.\($0/256).\($0%256).0/24",gateway:"192.0.2.1",interface:"en0",source:"用户网络绕过")}
        let service=Service();service.table=existing
        let began=ProcessInfo.processInfo.systemUptime
        try RouteProtectionBatch.run(protected:existing,bypass:[],baseline:service.sampledRoutes(),read:service.sampledRoutes,check:{},add:{_,_ in check(false,"已有路由不得写入或认领")})
        check(service.samples==2 && service.writes==0 && service.queries==0,"六百条现有保护只需两次新鲜整表采样")
        print("BENCHMARK routes=600 tableSamples=\(service.samples) queries=\(service.queries) writes=\(service.writes) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))")
        let baseline=try sample([b])
        fails("外部修改不能被基线掩盖") {
            try RouteProtectionBatch.run(protected:[b],bypass:[],baseline:baseline,read:{try sample([alternate])},check:{},add:{_,_ in})
        }
        fails("最终快照读取失败必须阻止提交") {
            try RouteProtectionBatch.run(protected:[b],bypass:[],baseline:baseline,read:{throw ProxyError("读取失败")},check:{},add:{_,_ in})
        }
        var scoped=b;scoped.scope="en0"
        fails("补充的全局保护也必须核验") {
            try RouteProtectionBatch.run(protected:[scoped],bypass:[],baseline:try sample([scoped]),read:{try sample([scoped])},check:{},add:{_,_ in})
        }
        let writer=Service()
        let host=ProtectedRoute(destination:"192.0.2.19/32",gateway:"192.0.2.1",interface:"en0",source:"用户网络绕过")
        try RouteProtectionBatch.run(protected:[host],bypass:[],baseline:writer.sampledRoutes(),read:writer.sampledRoutes,check:{},add:{r,bypass in try writer.addRoute(r.destination,r.gateway,r.interface,ipv6:r.ipv6,scope:r.scope,preparationBypass:bypass)})
        check(writer.writes==1 && writer.saves==2 && writer.journal?.routes.count==1,"写前保存与写后核验仍保留")
        for queryAvailable in [true,false] {
            let moving=Service()
            let expected=ProtectedRoute(destination:queryAvailable ? "172.16.0.1/32":"172.16.0.0/12",gateway:"192.168.1.1",interface:"en0",source:"用户网络绕过")
            var vpn=expected;vpn.gateway="10.251.1.1";vpn.interface="utun5"
            let prepared=try sample([])
            moving.table=[vpn];moving.lookupFailure = !queryAvailable
            do {
                try RouteProtectionBatch.run(protected:[expected],bypass:[],baseline:prepared,read:moving.sampledRoutes,check:{},add:{r,resample in
                    try moving.addRoute(r.destination,r.gateway,r.interface,ipv6:r.ipv6,scope:r.scope,preparationBypass:resample)
                })
                check(false,"准备期间被 VPN 接管必须撤销旧计划")
            } catch {check(error is NetworkEnvironmentNotReady,"查询和整表两条入口都返回可重采样类别")}
            check(moving.writes==0 && moving.saves==0 && moving.journal?.routes.isEmpty==true,"发生竞争时不写入、不认领、不覆盖企业 VPN")
            try RouteProtectionBatch.run(protected:[vpn],bypass:[],baseline:moving.sampledRoutes(),read:moving.sampledRoutes,check:{},add:{_,_ in check(false,"重采样应复用 VPN 原路由")})
            check(moving.table==[vpn],"重新规划后保持 VPN 路由及出口")
            do {
                try RouteProtectionBatch.run(protected:[expected],bypass:[],baseline:try sample([expected]),read:{try sample([vpn])},check:{},add:{_,_ in check(false,"最终核验不能补写竞争路由")})
                check(false,"最终核验期间出口变化仍须回滚")
            } catch {check(error is NetworkEnvironmentNotReady,"最终核验的路由变化同样进入回滚重采样")}
        }
        // 每个位置模拟进程退出后，仅使用已落盘意图重建恢复视图。
        for failure in ["intent","write","submitted","verify","commit"] {
            for position in 1...4 {
                let partial=Service();var saveCalls=0,writeCalls=0
                partial.beforeSave={
                    saveCalls+=1
                    if (failure=="intent" && saveCalls==position*2-1) || (failure=="commit" && saveCalls==position*2) {throw ProxyError("模拟落盘中断")}
                }
                partial.beforeWrite={writeCalls+=1;if failure=="write" && writeCalls==position {throw RouteBackendError(ETIMEDOUT,outcomeUnknown:true)}}
                partial.afterWrite={
                    if writeCalls==position {
                        if failure=="submitted" {partial.lookupFailure=true}
                        if failure=="verify" {partial.table[partial.table.count-1].gateway="192.0.2.99"}
                    }
                }
                var failed=false
                for n in 1...4 {
                    do {try partial.addRoute("192.0.2.\(20+n)/32","192.0.2.1","en0",ipv6:false)}
                    catch{failed=true;break}
                }
                check(failed && writeCalls<=position,"失败位置之后不继续提交")
                check(partial.table.count<=partial.persisted.count,"已写入内容始终有持久化恢复意图")
                let unrelated=ProtectedRoute(destination:"198.51.100.7/32",gateway:"192.0.2.99",interface:"en6")
                var actual=partial.table+[unrelated]
                let replaced=actual.filter{$0.gateway=="192.0.2.99"}
                for record in partial.persisted.reversed() {
                    let route=ProtectedRoute(destination:record.destination,gateway:record.gateway,interface:record.interface,scope:record.scope)
                    if CaptureOwnership.recoveryState(expected:route,actual:actual) == .owned {actual.removeAll{$0.destination==route.destination && $0.gateway==route.gateway && $0.interface==route.interface && $0.scope==route.scope}}
                }
                check(actual==replaced,"重启恢复模型只清理自有内容，保留外部改写")
            }
        }
        let original=writer.table
        try writer.addRoute(host.destination,host.gateway,host.interface,ipv6:false)
        check(writer.writes==1 && writer.table==original,"重复保护不额外写入")
        let rejected=Service();rejected.rejected=true
        fails("内核拒绝写入") {try rejected.addRoute(host.destination,host.gateway,host.interface,ipv6:false)}
        check(rejected.journal?.routes.isEmpty==true,"明确失败不认领外部路由")
        let timeout=Service();timeout.beforeWrite={throw ProxyError("超时")}
        fails("超时保留恢复意图") {try timeout.addRoute(host.destination,host.gateway,host.interface,ipv6:false)}
        check(timeout.journal?.routes.count==1,"未知写入结果保留恢复记录")
        let disk=Service();disk.beforeSave={throw ProxyError("磁盘失败")}
        fails("意图落盘失败") {try disk.addRoute(host.destination,host.gateway,host.interface,ipv6:false)}
        check(disk.writes==0,"没有恢复记录不能写路由")
        let changed=Service();changed.afterWrite={changed.table[0].gateway="192.0.2.99"}
        fails("写后路径变化") {try changed.addRoute(host.destination,host.gateway,host.interface,ipv6:false)}
        check(changed.journal?.routes.count==1,"写后异常保留恢复意图")
        var cancelled=false,added=0
        fails("中途取消不再写后续路由") {
            try RouteProtectionBatch.run(protected:[host,host],bypass:[],baseline:try sample([]),read:{check(false,"取消后不能提交");return try sample([])},check:{if cancelled {throw CancellationError()}},add:{_,_ in added+=1;cancelled=true})
        }
        check(added==1,"仅写入取消之前的项目")
        let ipv6Writer=Service()
        let ipv6Host=ProtectedRoute(destination:"2001:db8::19/128",gateway:"2001:db8::1",interface:"en0")
        try ipv6Writer.addRoute(ipv6Host.destination,ipv6Host.gateway,ipv6Host.interface,ipv6:true)
        check(ipv6Writer.writes==1 && ipv6Writer.journal?.routes.count==1,"IPv6 写入保留独立身份")
        let bypassWriter=Service()
        try RouteProtectionBatch.run(protected:[],bypass:[host],baseline:bypassWriter.sampledRoutes(),read:bypassWriter.sampledRoutes,check:{},add:{r,isBypass in
            check(isBypass,"绕过写入保留网络变化重试策略")
            try bypassWriter.addRoute(r.destination,r.gateway,r.interface,ipv6:r.ipv6,scope:r.scope,preparationBypass:isBypass)
        })
        try RouteProtectionBatch.run(protected:[],bypass:[host],baseline:bypassWriter.sampledRoutes(),read:bypassWriter.sampledRoutes,check:{},add:{_,_ in check(false,"已有绕过不重复写入")})
        check(bypassWriter.writes==1,"绕过重复批次不额外写入")
        var global=scoped;global.scope=nil
        try RouteProtectionBatch.run(protected:[scoped],bypass:[],baseline:try sample([scoped,global]),read:{try sample([scoped,global])},check:{},add:{_,_ in check(false,"已有全局保护不再写入")})
        check(true,"多作用域保护核验通过")
        let competing=Service();var conflict=host;conflict.gateway="192.0.2.99";competing.table=[conflict]
        fails("新增绕过前发现外部替换要求重规划") {try competing.addRoute(host.destination,host.gateway,host.interface,ipv6:false,preparationBypass:true)}
        check(competing.writes==0 && competing.journal?.routes.isEmpty==true,"外部路由不认领不覆盖")
        fails("普通保护遇到替换立即失败") {try competing.addRoute(host.destination,host.gateway,host.interface,ipv6:false)}
        let cached=Service();cached.table=[host];cached.lookupFailure=true
        try cached.addRoute(host.destination,host.gateway,host.interface,ipv6:false)
        check(cached.writes==0 && cached.journal?.routes.isEmpty==true,"查询失效时整表已有路径不认领")
        cached.table=[conflict]
        fails("查询失效不能覆盖完整表的外部路径") {try cached.addRoute(host.destination,host.gateway,host.interface,ipv6:false)}
        cached.table=[host,host]
        fails("查询失效且完整表歧义时阻止写入") {try cached.addRoute(host.destination,host.gateway,host.interface,ipv6:false)}
        let legacyRoute=Service();legacyRoute.rawTable="Internet6:\n2001:db8::19/0 2001:db8::1 US en0\n"
        fails("旧版 IPv6 异常残留不得被认领") {try legacyRoute.addRoute(ipv6Host.destination,ipv6Host.gateway,ipv6Host.interface,ipv6:true)}
        check(legacyRoute.writes==0,"遗留异常仅报错不更改网络")
        let ownerCheck=Service();ownerCheck.owner=nil
        fails("没有客户端不开始路由写入") {try ownerCheck.checkRouteOwner()}
        var pair:[Int32]=[-1,-1]
        check(socketpair(AF_UNIX,SOCK_STREAM,0,&pair)==0,"回环内存通道创建")
        defer {close(pair[0]);close(pair[1])}
        ownerCheck.owner=pair[0];try ownerCheck.checkRouteOwner()
        var progress=TunReply(ok:true,message:"",phase:"protection");progress.isProgress=true
        try UnixChannel.send(JSONEncoder().encode(progress),fd:pair[1])
        try UnixChannel.send(JSONEncoder().encode(TunReply(ok:true,message:"完成")),fd:pair[1])
        let wire=try HelperProgress.receive(read:{try JSONDecoder().decode(TunReply.self,from:UnixChannel.receive(fd:pair[0]))},progress:{check($0=="protection","实际控制帧进度")})
        check(wire.message=="完成","控制通道消费到最终帧")
        shutdown(pair[1],SHUT_RDWR)
        fails("对端退出触发取消") {try ownerCheck.checkRouteOwner()}
        let legacy=Data(#"{"stage":"old","milliseconds":12,"succeeded":true}"#.utf8)
        let legacyTiming=try JSONDecoder().decode(ConnectionStageTiming.self,from:legacy)
        check(legacyTiming.count==nil,"兼容旧计时格式")
        let clock=ConnectionTiming();clock.finish();clock.begin("prepare");clock.begin("activate");clock.finish(succeeded:false);clock.finish()
        check(clock.samples.count==2 && clock.samples[0].succeeded && !clock.samples[1].succeeded,"阶段切换与失败计时")
        check(clock.samples[0].summary.contains("通过") && !clock.samples[0].summary.contains("count="),"兼容旧版摘要")
        ownerCheck.routeMetrics=nil
        check(ownerCheck.measured("off"){17}==17,"关闭指标不改变操作结果")
        let finalMetrics=RouteOperationMetrics()
        try RouteProtectionBatch.run(protected:[b],bypass:[],baseline:baseline,read:{baseline},check:{},add:{_,_ in},metrics:finalMetrics)
        check(finalMetrics.samples.first?.stage=="protectionFinalVerification","完整最终核验计时")
        fails("拒绝失败进度帧") {var p=TunReply(ok:false,message:"",phase:"protection");p.isProgress=true;_=try HelperProgress.receive(read:{p},progress:{_ in})}
        let metrics=RouteOperationMetrics()
        _=metrics.measure("read"){42};fails("记录失败耗时") {try metrics.measure("read"){throw ProxyError("失败")}}
        check(metrics.samples[0].count==2 && !metrics.samples[0].succeeded,"操作次数和失败合并")
        check(metrics.samples[0].summary.contains("count=2"),"摘要包含操作次数")
        var frames=[TunReply(ok:true,message:"进度",phase:"protection"),TunReply(ok:true,message:"完成")];frames[0].isProgress=true
        var phases:[String]=[]
        let reply=try HelperProgress.receive(read:{frames.removeFirst()},progress:{phases.append($0)})
        check(reply.message=="完成" && phases==["protection"],"进度不能当作成功结果")
        let old=try HelperProgress.receive(read:{TunReply(ok:true,message:"旧服务")},progress:{_ in check(false,"旧服务不产生进度")})
        check(old.message=="旧服务","兼容旧版最终响应")
        fails("拒绝无阶段进度") {var invalid=TunReply(ok:true,message:"");invalid.isProgress=true;_=try HelperProgress.receive(read:{invalid},progress:{_ in})}
        fails("进度后断连不能当成功") {var count=0;_=try HelperProgress.receive(read:{count+=1;if count>1 {throw ProxyError("断连")};var p=TunReply(ok:true,message:"",phase:"protection");p.isProgress=true;return p},progress:{_ in})}
        check(HelperProgress.elapsed(start:nil,now:10)==0 && HelperProgress.elapsed(start:12,now:10)==0 && HelperProgress.elapsed(start:10,now:14.9)==4,"等待时间使用单调时钟且不为负")
        for phase in ["preflight","bootstrapDNS","networkRecheck","bypassSnapshot","addressPlan","dnsBaseline","prepared","coreValidation","coreStartup","activation","protection","dnsActivation","proxyActivation","active","recovery","unknown"] {check(!HelperProgress.label(phase).isEmpty,"阶段有中文说明")}
        check(writer.routeMetrics?.samples.contains{$0.stage=="routeWrite" && $0.count==1}==true,"正式写入操作计数")
        print("PROTECTION_STARTUP_CHECKS_OK assertions=\(assertions)")
    }
}
