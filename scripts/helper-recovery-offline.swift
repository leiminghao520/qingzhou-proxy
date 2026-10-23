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
        try wakeVerificationChecks()
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

extension RecoveryChecks {
    static func wakeVerificationChecks() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("qz-wake-verification-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let backend=RecoveryBackend()
        let service=Service(fixtureRoot:root,backend:backend)
        let expected=try DNSServiceTransaction.encode(["ServerAddresses":["127.0.0.1"]])
        var values:[String:NSDictionary]=["main":["ServerAddresses":["127.0.0.1"]],"corporate":["ServerAddresses":["127.0.0.1"]]]
        service.networkDNSRead={values[$0]}
        let tunnels=[ProtectedRoute(destination:"0.0.0.0/1",gateway:"100.64.0.1",interface:"utun42"),ProtectedRoute(destination:"128.0.0.0/1",gateway:"100.64.0.1",interface:"utun42")]
        let host=ProtectedRoute(destination:"10.20.30.40/32",gateway:"10.1.0.1",interface:"utun9")
        let parent=ProtectedRoute(destination:"10.0.0.0/8",gateway:host.gateway,interface:host.interface)
        let snapshot=NetworkSnapshot(primaryInterface:"en0",routes:[parent],resolvers:[DNSResolverScope(service:"fixture",interface:"en0",servers:["192.0.2.1"])])
        service.capturePlan=try CapturePlan.make(snapshot:snapshot,extraCIDRs:[],extraDomains:[])
        var record=Journal(captureRoutes:tunnels.map(\.destination),dnsServices:[DNSServiceRecord(key:"corporate",expected:expected,original:nil)],dnsKey:"main",previousDNS:nil,expectedDNS:expected,address4:"",address6:"")
        record.interface="utun42";record.routes=(tunnels+[host]).map{OwnedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface,ipv6:false)}
        service.journal=record
        func reply(_ routes:[ProtectedRoute],proxy:(issues:[String],verified:Bool)?=nil) throws -> TunReply {try service.wakeNetworkReply(record:record,sample:NetworkRouteSample(routes:routes),proxySample:proxy)}
        let live=tunnels+[parent]
        var status=try reply(live)
        check(status.wakeRecoveryReason==nil && status.routesVerified==true && status.protectionVerified==true,"同接口同网关的企业主机缓存回收后仍通过唤醒核验")
        let local=ProtectedRoute(destination:"192.168.10.0/24",gateway:"link#11",interface:"en0")
        var other=local;other.gateway="link#12";other.interface="en1"
        service.capturePlan!.protectedRoutes.append(local)
        check(try reply(live+[local,other]).protectionVerified==true,"原系统路径继续使用存在性核验，不认领未写入的系统路由")
        check(try reply(live+[local,other]).wakeRecoveryReason==nil,"未写入的原系统路径不扩大成自有路由所有权冲突")
        record.routes.append(OwnedRoute(destination:local.destination,gateway:local.gateway,interface:local.interface,ipv6:false))
        check(try reply(live+[local,other]).wakeRecoveryReason == .ownershipConflict,"同样的竞争发生在轻舟实际写入项时仍拒绝")
        record.routes.removeLast();service.capturePlan!.protectedRoutes.removeLast()
        let linkLocal=ProtectedRoute(destination:"fe80::/64",gateway:"link#11",interface:"en0",scope:"en0")
        let awdl=ProtectedRoute(destination:"fe80::f8ff:57ff:fe17:5707/128",gateway:"link#14",interface:"awdl0",scope:"awdl0")
        let bypass=try BypassRoutePlan.capture(destinations:["fe80::/10"],existingPrefixes:[],hasIPv6:true,existingRoutes:[linkLocal,awdl],lookup:{_,_ in throw ProxyError("夹具禁止系统查询")})
        check(bypass.preservedRoutes==[linkLocal],"广域链路本地绕过不冻结 AWDL 临时主机路由")
        try bypass.validatePreservedRoutes([linkLocal])
        check(bypass.routes.isEmpty,"AWDL 临时主机消失不生成任何全局绕过路由")
        let explicit=try BypassRoutePlan.capture(destinations:[awdl.destination],existingPrefixes:[],hasIPv6:true,existingRoutes:[awdl],lookup:{_,_ in throw ProxyError("夹具禁止系统查询")})
        check(explicit.preservedRoutes==[awdl],"显式主机目标仍保持原接口核验")
        check(NetworkRouteSample(routes:live).identityIndex.state(host) == .absent,"运行等价路径不能授予删除恢复的精确所有权")
        var foreign=host;foreign.interface="utun8"
        check(try reply(live+[foreign]).wakeRecoveryReason == .ownershipConflict,"同前缀被外部改写仍立即拒绝")
        check(try reply(live+[host,foreign]).wakeRecoveryReason == .ownershipConflict,"等长竞争不能用网段覆盖掩盖")
        check(try reply(tunnels).wakeRecoveryReason == .networkNotReady,"保护路由暂缺进入有限恢复而非伪造归属冲突")
        values.removeValue(forKey:"corporate");status=try reply(live)
        check(status.wakeRecoveryReason == .networkNotReady && status.dnsVerified==false,"主 DNS 仍在而补充 DNS 暂缺时不误判为外部改写")
        check(status.message.contains("DNS 服务暂缺") && !status.message.contains("corporate"),"记录具体失败类别但不输出企业 DNS 标识")
        values["corporate"]=["ServerAddresses":["192.0.2.2"]]
        check(try reply(live).wakeRecoveryReason == .ownershipConflict,"补充 DNS 被外部替换仍停止竞争")
        values["corporate"]=values["main"]
        record.dnsServices![0].expected=Data("invalid".utf8)
        check(try reply(live).wakeRecoveryReason == .unverified,"不可读快照只报告未验证，不能证明外部改写")
        record.dnsServices![0].expected=expected
        service.activeRequest=TunRequest(operation:"prepare",systemProxyPort:7890)
        status=try reply(live,proxy:([],false))
        check(status.wakeRecoveryReason == .networkNotReady && status.proxyVerified==false,"代理服务配置不变但汇总发布延迟时进入有限恢复")
        check(try reply(live,proxy:(["代理端口发生外部修改"],false)).wakeRecoveryReason == .ownershipConflict,"明确代理配置变化仍停止自动恢复")
        check(try reply(live,proxy:([],true)).wakeRecoveryReason==nil,"汇总代理重新发布后直接核验通过")
        check(backend.writes==0,"唤醒只读核验不写任何路由")
    }
}
