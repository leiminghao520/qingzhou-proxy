import Foundation
import Darwin
import SystemConfiguration
import QingzhouKit

@main struct StabilityPerformanceChecks {
    static var assertions=0
    static func check(_ value:@autoclosure () -> Bool,_ message:String) {
        assertions+=1
        if !value() {fatalError(message)}
    }
    static func packet(_ type:Int32) -> Data {
        var header=rt_msghdr()
        header.rtm_msglen=UInt16(MemoryLayout<rt_msghdr>.size)
        header.rtm_version=UInt8(RTM_VERSION);header.rtm_type=UInt8(type)
        return withUnsafeBytes(of:&header){Data($0)}
    }
    static func main() throws {
        let query=packet(RTM_GET),change=packet(RTM_ADD)
        check(!RouteEventPump.requiresCheck(query),"完整查询报文不触发网络检查")
        for type in [RTM_ADD,RTM_DELETE,RTM_CHANGE,RTM_LOCK,RTM_REDIRECT,RTM_MISS,RTM_NEWADDR,RTM_DELADDR,RTM_IFINFO,RTM_NEWMADDR,RTM_DELMADDR,Int32(255)] {
            check(RouteEventPump.requiresCheck(packet(type)),"路由、接口、地址和未知通知均保守检查")
        }
        for length in 0..<query.count {
            var truncated=Data(query.prefix(length))
            if length>=2 {truncated.withUnsafeMutableBytes{$0.storeBytes(of:UInt16(length),as:UInt16.self)}}
            check(RouteEventPump.requiresCheck(truncated),"截断报文不能被误当纯查询")
        }
        var wrongVersion=query;wrongVersion[2]=0
        check(RouteEventPump.requiresCheck(wrongVersion),"未知协议版本需要检查")
        var wrongLength=query;wrongLength[0]=0
        check(RouteEventPump.requiresCheck(wrongLength),"长度错误需要检查")
        var requests=0,reads=0,events:[NetworkMonitorEvent:Int]=[:]
        let observe:(NetworkMonitorEvent)->Void={events[$0,default:0]+=1}
        let listening=RouteEventPump.drain(read:{reads+=1;return .packet(query)},observe:observe,request:{requests+=1})
        check(listening && reads==64 && requests==0 && events[.queryIgnored]==64 && events[.receiveLimit]==1,"查询风暴每批有界且不安排检查")
        reads=0;requests=0
        RouteEventPump.drain(read:{reads+=1;return .packet(reads%2==0 ? query:change)},request:{requests+=1})
        check(reads==64 && requests==1,"混合风暴单批只安排一次检查")
        reads=0
        let cancelled=RouteEventPump.drain(read:{reads+=1;return .packet(change)},cancelled:{true},request:{requests+=1})
        check(!cancelled && reads==0 && requests==1,"取消后不再接收或安排检查")
        var cancelNow=false;requests=0
        RouteEventPump.drain(read:{cancelNow=true;return .packet(change)},cancelled:{cancelNow},request:{requests+=1})
        check(requests==0,"接收期间取消也阻止迟到检查")
        for result:RouteEventPump.Read in [.closed,.failed] {
            requests=0
            check(!RouteEventPump.drain(read:{result},request:{requests+=1}) && requests==1,"关闭或读取失败只核验一次并停止监听")
        }
        reads=0;requests=0
        RouteEventPump.drain(read:{reads+=1;return .interrupted},request:{requests+=1})
        check(reads==64 && requests==0,"连续中断也受单批预算约束")
        check(RouteEventPump.drain(read:{.wouldBlock},request:{requests+=1}) && requests==0,"空队列不会安排检查")
        var descriptors:[Int32]=[0,0]
        guard socketpair(AF_UNIX,SOCK_DGRAM,0,&descriptors)==0 else {throw ProxyError("离线报文通道创建失败")}
        defer {close(descriptors[0]);close(descriptors[1])}
        check(RouteEventPump.drain(read:{RouteEventPump.receive(descriptors[1])},request:{requests+=1}),"正式非阻塞接收在空队列立即返回")
        for data in [query,change,Data([1,2])] {
            let sent=data.withUnsafeBytes{send(descriptors[0],$0.baseAddress,$0.count,0)}
            check(sent==data.count,"离线报文发送完整")
        }
        requests=0
        RouteEventPump.drain(read:{RouteEventPump.receive(descriptors[1])},request:{requests+=1})
        check(requests==1,"正式读取入口合并变化和异常报文")
        close(descriptors[1]);descriptors[1] = -1
        check(!RouteEventPump.drain(read:{RouteEventPump.receive(descriptors[1])},request:{requests+=1}),"无效描述符不会形成可读空转")

        let route=ProtectedRoute(destination:"192.0.2.0/24",gateway:"192.0.2.1",interface:"en0")
        var replacement=route;replacement.gateway="192.0.2.2"
        var scoped=route;scoped.scope="en0"
        let metrics=RouteOperationMetrics()
        let sample=NetworkRouteSample(records:[RouteRecord(route:route,flags:3)],metrics:metrics)
        for _ in 0..<20 {check(sample.identityIndex.state(route) == .owned,"同一采样索引重复读取身份一致")}
        check(metrics.samples.first{$0.stage=="routeIdentityIndex"}?.count==1,"单次采样只构建一次身份索引")
        let next=NetworkRouteSample(routes:[replacement])
        check(next.identityIndex.state(route) == .replaced,"新采样不得沿用旧索引")
        for actual in [[],[route],[replacement],[route,replacement],[scoped],[route,scoped]] {
            check(RouteIdentityIndex(actual).state(route)==CaptureOwnership.recoveryState(expected:route,actual:actual),"索引保留缺失、外部改写、歧义和作用域语义")
        }
        let store=SCDynamicStoreCreate(nil,"轻舟结构化只读夹具" as CFString,nil,nil)!
        // 不存在的主接口会在读取系统 DNS 后拒绝；仍能检验结构化输入是否惰性使用兼容文本。
        _=try? NetworkSnapshot.read(store:store,primary:"fixture-missing",routes:sample.table,structuredRoutes:sample.planningRoutes)
        check(!metrics.samples.contains{$0.stage=="routeTableText"},"结构化快照不会提前生成兼容文本")
        _=sample.table;_=sample.table
        check(metrics.samples.first{$0.stage=="routeTableText"}?.count==1,"确需兼容文本时只生成一次")
        let auditDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("qingzhou-stability-audit-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:auditDirectory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:auditDirectory)}
        let audit=RouteAuditLog(directory:auditDirectory),auditMetrics=RouteOperationMetrics()
        audit.metrics=auditMetrics
        _=try audit.operation(transaction:UUID(),stage:"preflight",kind:"snapshot",identity:"fixture"){7}
        let auditRows=try String(contentsOf:auditDirectory.appendingPathComponent("route-operations.jsonl"),encoding:.utf8).split(separator:"\n")
        check(auditRows.count==2 && auditMetrics.samples.first{$0.stage=="routeAuditAppend"}?.count==2,"审计仍同步保留开始和结束记录，独立统计两次落盘")
        try benchmark()
        if CommandLine.arguments.contains("--read-only-events") {try readOnlyEvents()}
        print("RESULT stability_performance_assertions=\(assertions) failures=0")
    }
    static func benchmark() throws {
        let routes=(0..<600).map {ProtectedRoute(destination:"10.\($0/256).\($0%256).0/24",gateway:"192.0.2.1",interface:"en0")}
        let expected=Array(routes.prefix(48))
        func legacy(_ route:ProtectedRoute) -> CaptureOwnership.RecoveryRouteState {
            let matches=routes.filter{NetworkInspection.samePrefix($0.destination,route.destination) && $0.scope==route.scope}
            guard !matches.isEmpty else{return .absent}
            guard matches.contains(where:{$0.interface==route.interface && $0.gateway==route.gateway}) else{return .replaced}
            return matches.count==1 ? .owned:.ambiguous
        }
        let started=DispatchTime.now().uptimeNanoseconds
        let old=(0..<3).flatMap {_ in expected.map{legacy($0)}}
        let oldUs=(DispatchTime.now().uptimeNanoseconds-started)/1000
        let began=DispatchTime.now().uptimeNanoseconds
        let sample=NetworkRouteSample(routes:routes)
        let current=(0..<3).flatMap {_ in expected.map{sample.identityIndex.state($0)}}
        let newUs=(DispatchTime.now().uptimeNanoseconds-began)/1000
        check(old==current,"六百项采样重复核验与旧扫描逐项等价")
        print("ROUTE_INDEX_BENCHMARK routes=600 lookups=144 baselineUs=\(oldUs) candidateUs=\(newUs) includesIndexBuild=true equivalent=true")
    }
    static func readOnlyEvents() throws {
        let descriptor=socket(PF_ROUTE,SOCK_RAW,0)
        guard descriptor>=0 else {throw ProxyError("只读路由通知无法打开")}
        defer{close(descriptor)}
        _=try NativeRouteBackend().lookup("127.0.0.1",ipv6:false)
        var item=pollfd(fd:descriptor,events:Int16(POLLIN),revents:0)
        guard poll(&item,1,500)>0 else {throw ProxyError("只读查询未产生可观察通知")}
        var ownQueries=0,scheduled=0
        RouteEventPump.drain(read:{
            let result=RouteEventPump.receive(descriptor)
            if case .packet(let packet)=result,packet.count>=MemoryLayout<rt_msghdr>.size {
                let header=packet.withUnsafeBytes{$0.loadUnaligned(as:rt_msghdr.self)}
                if header.rtm_pid==getpid() && header.rtm_type==RTM_GET {ownQueries+=1}
            }
            return result
        },request:{scheduled+=1})
        check(ownQueries>0,"实际原生只读查询会到达独立路由监听器")
        print("READ_ONLY_ROUTE_EVENTS queryResponses=\(ownQueries) changeChecks=\(scheduled) routeWrites=0")
    }
}
