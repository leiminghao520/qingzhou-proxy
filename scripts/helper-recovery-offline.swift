import Foundation
import Darwin
import QingzhouKit

final class RecoveryBackend:RouteBackend {
    var routes:[ProtectedRoute]=[]
    var lookupFailure=false,writeFailure=false,keepWrittenRoute=false
    var lookups=0,writes=0
    func snapshot() throws -> NetworkRouteSample {NetworkRouteSample(routes:routes)}
    func lookup(_ destination:String,ipv6:Bool,scope:String?,deadline:Date?) throws -> RouteRecord {
        lookups+=1
        if lookupFailure {throw RouteBackendError(ETIMEDOUT)}
        guard let route=routes.first(where:{$0.destination==destination && $0.scope==scope}) else {throw RouteBackendError(ESRCH)}
        return RouteRecord(route:route,flags:0x807)
    }
    func write(_ operation:NetworkInspection.RouteOperation,route:ProtectedRoute,legacy:Bool,deadline:Date?) throws -> RouteWriteResult {
        writes+=1
        if writeFailure {throw RouteBackendError(ETIMEDOUT,outcomeUnknown:true)}
        guard operation == .delete,!legacy else {throw ProxyError("恢复夹具禁止其他操作")}
        if keepWrittenRoute {return .applied}
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
            do {
                try service.stop(preserveExternal:true)
                check(scenario=="success" || scenario=="externalRewrite" || scenario=="restart","失败不得误报恢复完成")
                check(service.journal==nil && !FileManager.default.fileExists(atPath:root.appendingPathComponent("recovery.json").path),"成功后释放恢复记录")
                check(backend.routes.count==(scenario=="externalRewrite" ? 1:0),"只删除确认自有的路由")
                if scenario=="externalRewrite" {check(backend.routes[0].gateway=="127.0.0.2","外部路由改写保持原样")}
            } catch {
                check(["queryTimeout","unknownWrite","snapshotFailure","ambiguous","verifyFailure"].contains(scenario),"只接受注入的恢复失败")
                check(service.journal != nil && FileManager.default.fileExists(atPath:root.appendingPathComponent("recovery.json").path),"失败保留实际持久化恢复记录")
                check(backend.writes<=1 && backend.lookups<=1,"恢复出错后不重复数百次超时操作")
            }
            check(!child.isRunning && service.process==nil,"实际恢复实现的异常路径也停止本地夹具核心")
        }
        print("HELPER_RECOVERY_OFFLINE_OK assertions=\(count) privilegedCalls=0 routeSockets=0")
    }
}
