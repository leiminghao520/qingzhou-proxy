import Foundation
import Darwin
import QingzhouKit

final class RecoveryBackend:RouteBackend {
    var routes:[ProtectedRoute]=[]
    var lookupFailure=false,writeFailure=false,keepWrittenRoute=false
    var records:[RouteRecord]?
    var failedDestination:String?
    var replaceDuringDelete=false
    var keepSystemCache=false
    var lookups=0,writes=0
    func snapshot() throws -> NetworkRouteSample {records.map{NetworkRouteSample(records:$0)} ?? NetworkRouteSample(routes:routes)}
    func lookup(_ destination:String,ipv6:Bool,scope:String?,deadline:Date?) throws -> RouteRecord {
        lookups+=1
        if lookupFailure {throw RouteBackendError(ETIMEDOUT)}
        guard let route=routes.first(where:{$0.destination==destination && $0.scope==scope}) else {throw RouteBackendError(ESRCH)}
        return RouteRecord(route:route,flags:0x807)
    }
    func write(_ operation:NetworkInspection.RouteOperation,route:ProtectedRoute,legacy:Bool,deadline:Date?) throws -> RouteWriteResult {
        writes+=1
        if route.destination==failedDestination {throw RouteBackendError(EBUSY)}
        if replaceDuringDelete {routes.removeAll{$0.destination==route.destination};var foreign=route;foreign.interface="utun7";foreign.gateway="link#22";routes.append(foreign);return .rejected(ESRCH)}
        if writeFailure {throw RouteBackendError(ETIMEDOUT,outcomeUnknown:true)}
        guard operation == .delete,!legacy else {throw ProxyError("恢复夹具禁止其他操作")}
        if keepWrittenRoute {return .applied}
        records?.removeAll{$0.route.destination==route.destination && $0.route.gateway==route.gateway && $0.route.interface==route.interface && $0.route.scope==route.scope && (!keepSystemCache || !$0.isTransient)}
        routes.removeAll{$0.destination==route.destination && $0.gateway==route.gateway && $0.interface==route.interface && $0.scope==route.scope}
        return .applied
    }
}
@main struct RecoveryChecks {
    static var count=0
    static func check(_ condition:Bool,_ message:String){count+=1;if !condition{fatalError(message)}}
    static func main() throws {
        guard geteuid() != 0 else {throw ProxyError("离线恢复夹具禁止管理员身份")}
        for scenario in ["success","queryTimeout","unknownWrite","snapshotFailure","externalRewrite","ambiguous","verifyFailure","restart"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("qz-recovery-offline-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            let backend=RecoveryBackend()
            backend.routes=(1...3).map{ProtectedRoute(destination:"192.0.2.\($0)/32",gateway:"127.0.0.1",interface:"lo0")}
            let service=Service(fixtureRoot:root,backend:backend)
            let key="State:/Network/Service/"+UUID().uuidString+"/DNS"
            let expected=try PropertyListSerialization.data(fromPropertyList:[:],format:.binary,options:0)
            service.journal=Journal(dnsKey:key,previousDNS:nil,expectedDNS:expected,address4:"",address6:"")
            service.journal!.routes=backend.routes.map{OwnedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface,ipv6:false,scope:$0.scope)}
            try service.save()
            if scenario=="restart" {
                service.journal=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:root.appendingPathComponent("recovery.json")))
            }
            let child=Process();child.executableURL=URL(fileURLWithPath:"/bin/sleep");child.arguments=["30"];try child.run();service.process=child
            backend.keepWrittenRoute=scenario=="verifyFailure"
            if scenario=="ambiguous" {var duplicate=backend.routes[2];duplicate.gateway="127.0.0.2";backend.routes.append(duplicate)}
            backend.lookupFailure=scenario=="queryTimeout";backend.writeFailure=scenario=="unknownWrite"
            if scenario=="snapshotFailure" {service.routeSample={throw RouteBackendError(EIO)}}
            if scenario=="externalRewrite" {backend.routes[0].gateway="127.0.0.2"}
            if ["success","externalRewrite","ambiguous"].contains(scenario) {
                let status=service.handle(TunRequest(operation:"status",verifyNetwork:true),fd:42)
                check(status.wakeRecoveryReason == (scenario=="success" ? .networkNotReady:.ownershipConflict),"结构化区分唤醒缺失网络与外部路由竞争")
            }
            do {
                try service.stop(preserveExternal:true)
                check(scenario=="success" || scenario=="externalRewrite" || scenario=="restart","失败不得误报恢复完成")
                check(service.journal==nil && !FileManager.default.fileExists(atPath:root.appendingPathComponent("recovery.json").path),"成功后释放恢复记录")
                check(backend.routes.count==(scenario=="externalRewrite" ? 1:0),"只删除确认自有的路由")
                if scenario=="externalRewrite" {check(backend.routes[0].gateway=="127.0.0.2","外部路由改写保持原样")}
            } catch {
                check(["queryTimeout","unknownWrite","snapshotFailure","ambiguous","verifyFailure"].contains(scenario),"只接受注入的恢复失败")
                check(service.journal != nil && FileManager.default.fileExists(atPath:root.appendingPathComponent("recovery.json").path),"失败保留实际持久化恢复记录")
                check(backend.writes<=3 && backend.lookups<=3,"每条独立路由至多尝试一次，不因一项失败反复重试")
                if scenario=="ambiguous" {check(backend.routes.count==2 && backend.writes==2,"冲突保留，其他明确自有路由仍清理")}
            }
            check(!child.isRunning && service.process==nil,"实际恢复实现的异常路径也停止本地夹具核心")
        }
        for scenario in ["multicast","nativeCacheRemains","cacheCompetitor","partialFailure","deleteRace","interrupted"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("qz-wake-recovery-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            let backend=RecoveryBackend()
            let service=Service(fixtureRoot:root,backend:backend)
            let parent=ProtectedRoute(destination:"239.255.255.250/32",gateway:"link#11",interface:"en0")
            let cache=ProtectedRoute(destination:parent.destination,gateway:"1:0:5e:7f:ff:fa",interface:scenario=="cacheCompetitor" ? "en1":"en0")
            let own=ProtectedRoute(destination:"192.0.2.20/32",gateway:"127.0.0.1",interface:"lo0")
            backend.routes=[own,parent]
            backend.records=[RouteRecord(route:own,flags:UInt32(RTF_UP|RTF_HOST|RTF_STATIC)),RouteRecord(route:parent,flags:UInt32(RTF_UP|RTF_MULTICAST|RTF_CLONING)),RouteRecord(route:cache,flags:UInt32(RTF_UP|RTF_HOST|RTF_MULTICAST|RTF_LLINFO|RTF_STATIC))]
            if scenario=="nativeCacheRemains" {
                backend.keepSystemCache=true
                backend.records![2].route.gateway=parent.gateway
                backend.records![2].linkLayerAddress="1:0:5e:7f:ff:fa"
                var broad=parent;broad.destination="224.0.0.0/4"
                backend.records!.append(RouteRecord(route:broad,flags:UInt32(RTF_UP|RTF_MULTICAST|RTF_CLONING)))
            }
            let expected=try PropertyListSerialization.data(fromPropertyList:[:],format:.binary,options:0)
            service.journal=Journal(dnsKey:"State:/Network/Service/"+UUID().uuidString+"/DNS",previousDNS:nil,expectedDNS:expected,address4:"",address6:"")
            service.journal!.routes=backend.routes.map{OwnedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface,ipv6:false,scope:$0.scope)}
            if scenario=="partialFailure" {backend.failedDestination=parent.destination}
            if scenario=="deleteRace" {backend.records=nil;backend.replaceDuringDelete=true}
            if scenario=="interrupted" {backend.records=nil;backend.writeFailure=true}
            try service.save()
            do {
                try service.stop(preserveExternal:true)
                check(scenario=="multicast" || scenario=="nativeCacheRemains","有冲突或中断不能报告成功")
                if scenario=="nativeCacheRemains" {check(backend.records?.count==2 && backend.records!.contains{$0.isTransient},"原生同网关缓存保留且恢复记录完成清理")}
                check(backend.routes.isEmpty,"缓存共存不妨碍自有父项和独立路由清理")
            }catch {
                check(scenario != "multicast" && scenario != "nativeCacheRemains","完整组播现场夹具必须可恢复")
                check(service.journal != nil,"失败保留事务记录")
                if scenario=="cacheCompetitor" || scenario=="partialFailure" {check(backend.routes==[parent],"一条冲突不阻止另一条独立路由清理")}
                if scenario=="deleteRace" {check(backend.routes.allSatisfy{$0.interface=="utun7"},"删除竞争保留外部接管，不伪报成功")}
                if scenario=="interrupted" {backend.writeFailure=false;try service.stop(preserveExternal:true);check(service.journal==nil && backend.routes.isEmpty,"中断后同一事务记录可安全继续")}
            }
        }
        do {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("qz-resume-owner-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            let backend=RecoveryBackend()
            let service=Service(fixtureRoot:root,backend:backend)
            let session=NetworkResumeSession(request:TunRequest(operation:"prepare"),owner:42)
            service.networkResumeSession=session
            var request=TunRequest(operation:"recover",preserveExternal:true);request.deferToNetworkResume=true
            let reply=service.handle(request,fd:42)
            check(reply.networkReconnecting && service.networkResumeSession === session,"辅助服务串行队列内原子让行已有重建任务")
            check(reply.supportsWakeRecovery==true && backend.writes==0,"能力协商向后兼容且让行不写网络")
            let explicit=service.handle(TunRequest(operation:"recover",preserveExternal:true),fd:42)
            check(explicit.ok && service.networkResumeSession==nil,"显式用户恢复仍可取消辅助服务重建")
        }
        print("HELPER_RECOVERY_OFFLINE_OK assertions=\(count) privilegedCalls=0 routeSockets=0")
    }
}
