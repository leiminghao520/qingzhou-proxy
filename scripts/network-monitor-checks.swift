import Foundation
import SystemConfiguration
import QingzhouKit

// 此夹具链接正式 NetworkMonitor.swift，只替换管理员服务的外部输入和写操作。
struct OwnedRoute { var destination: String; var gateway: String; var interface: String; var ipv6: Bool = false; var scope: String? = nil }
struct Journal { var allDNSServices:[DNSServiceRecord] {[DNSServiceRecord(key:dnsKey,expected:expectedDNS,original:nil)]}; var captureRoutes:[String]?=nil; var address4="100.64.1.1/30"; var address6="fd71:717a::1/126"; var expectedDNS: Data; var dnsKey = "fixture"; var routes: [OwnedRoute]; var preservedRoutes: [ProtectedRoute]? = []; var interface: String? = "utun42" }
final class Service {
    var routeBackend:RouteBackend=LegacyRouteBackend(command:{_,_,_ in throw ProxyError("夹具禁止真实命令")})
    func checkRouteOwner() throws {}
    func measured<T>(_ name:String,_ body:() throws -> T) rethrows -> T {try body()}
    func sampledRoutes() throws -> NetworkRouteSample {try routeSample()}
    func verifyBypassFirewall() throws {}
    let queue = DispatchQueue(label: "cn.qingzhou.monitor.fixture")
    let dynamic = SCDynamicStoreCreate(nil, "只读监控夹具" as CFString, nil, nil)!
    var capturePlan: CapturePlan?
    var dynamicRules:DynamicCaptureRules?
    var changeWindow=CaptureChangeWindow()
    var protectedQueriesSuspended=false
    var captureNodeAddresses:[String:[String]]=[:]
    var captureNodeInterfaces:[String:String]=[:]
    var knownProtectedDomains:Set<String>=[]
    var dnsForwarder:ScopedDNSForwarder?
    var domainRouteSummary:[String]=[]
    var journal: Journal?
    var activeRequest: TunRequest? = TunRequest(operation: "prepare", state: AppState())
    var owner: Int32? = 1
    var phase = "active"
    var networkTimer: DispatchSourceTimer?
    var networkStore: SCDynamicStore?
    var routeEvents: DispatchSourceRead?
    var networkMonitorObservation: ((NetworkMonitorEvent) -> Void)?
    var networkChecks: NetworkCheckScheduler?
    var routeSample: () throws -> NetworkRouteSample = { throw ProxyError("必须注入采样") }
    var networkDNSRead: ((String) -> NSDictionary?)?
    var networkSnapshotRead: ((NetworkRouteSample) throws -> NetworkSnapshot)?
    var bypassServicesRead:()->[BypassNetworkService]={[]}
    var networkClock: () -> Date = { Date(timeIntervalSince1970: 100) }
    var networkUptime: () -> TimeInterval = { 100 }
    var pendingNetworkChange: Date?
    var snapshotRetry = NetworkSnapshotRetry()
    var networkResumeSession: NetworkResumeSession?
    var networkResumeWork: DispatchWorkItem?
    var performingNetworkResume = false
    var networkResumeSchedule: ((TimeInterval, @escaping () -> Void) -> Void)?
    var startHook: (() throws -> Void)?
    var stopHook: (() throws -> Void)?
    var activateHook: (() throws -> Void)?
    var activatePrepared: (() throws -> Void)?
    var lastFailure: String?
    var stops = 0, starts = 0, proxyReads = 0
    var preservedExternal=false
    var proxyIssues: [String] = []
    var proxyMismatchSince:TimeInterval?
    var proxyVerificationClock:()->TimeInterval={100}
    var proxyVerificationWait:(TimeInterval)->Void={_ in fatalError("监控夹具禁止阻塞等待")}
    func proxyLiveSample()->ProxyLiveSample? {ProxyLiveSample(expected:[:],current:[:])}
    var routeLookupHook:((String,Bool,String?) throws -> String)?
    var routeInfoHook: (() throws -> String)?
    var writeRouteHook: (([String]) throws -> String)?
    var routeWrites = 0
    func routeInfo(_ destination:String,ipv6:Bool,scope:String?=nil,deadline:Date?=nil) throws -> String {
        networkMonitorObservation?(.routeQuery)
        if let routeLookupHook {return try routeLookupHook(destination,ipv6,scope)}
        guard let routeInfoHook else {throw ProxyError("夹具必须注入路由查询")}
        return try routeInfoHook()
    }
    func field(_ label:String,_ text:String)->String? {label == "gateway" ? NetworkInspection.routeGateway(text):NetworkInspection.routeField(label,text)}
    func prefix(_ info:String)->String? {NetworkInspection.routePrefix(destination:field("destination",info),mask:field("mask",info),host:info.contains("HOST"))}
    func save() throws {}
    func dnsServiceIssues()->[String] {
        guard let journal else {return ["记录缺失"]}
        return DNSServiceTransaction.issues(journal.allDNSServices,read:{self.networkDNSRead?($0)})
    }
    // 此夹具验证路由监控；DNS 发布事务由企业 DNS 夹具链接正式实现验证。
    func publishCorporateDNS(_ plan:CapturePlan) throws {}
    func writeRoute(_ arguments:[String],deadline:Date?) throws -> String {routeWrites += 1;if let writeRouteHook {return try writeRouteHook(arguments)};throw ProxyError("夹具禁止写系统路由")}

    func proxyConfigurationIssues() -> [String] { proxyReads += 1; return proxyIssues }
    func stop(preserveExternal:Bool=false) throws { preservedExternal=preserveExternal; if !performingNetworkResume {cancelNetworkResume()}; stops += 1; try stopHook?(); networkChecks?.cancel(); capturePlan = nil; activeRequest = nil; owner = nil }
    func start(_ request: TunRequest, fd: Int32) throws { starts += 1; try startHook?(); activeRequest = request; owner = fd; activatePrepared = {try self.activateHook?()} }
}

@main struct MonitorChecks {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        if CommandLine.arguments.count==4 && CommandLine.arguments[1]=="--dynamic-fixture" {
            try runDynamicFixture(URL(fileURLWithPath:CommandLine.arguments[2]),ports:JSONDecoder().decode([String:Int].self,from:Data(CommandLine.arguments[3].utf8)));return
        }
        let dns: NSDictionary = ["ServerAddresses": ["100.64.1.1"]]
        let dnsData = try PropertyListSerialization.data(fromPropertyList: dns, format: .binary, options: 0)
        let table = "Internet:\nDestination Gateway Flags Netif\ndefault 192.168.1.1 UGSc en0\n10/8 192.168.1.1 UGSc en0\n0/1 link#42 USc utun42\n172.20/16 172.20.0.1 UGSc utun88\n"
        let resolver = DNSResolverScope(service: "fixture", interface: "en0", servers: ["192.168.1.1"], defaultResolver: true)
        func fixture() throws -> Service {
            let service = Service()
            service.journal = Journal(expectedDNS: dnsData, routes: [OwnedRoute(destination: "0.0.0.0/1", gateway: "link#42", interface: "utun42")])
            service.networkDNSRead = { _ in dns }
            service.networkSnapshotRead = { sample in NetworkSnapshot(primaryInterface: "en0", routes: NetworkSnapshot.parseRoutes(sample.table), resolvers: [resolver]) }
            service.routeSample = { try NetworkRouteSample(read: { table }) }
            service.capturePlan = try CapturePlan.make(snapshot: service.currentSnapshot(), extraCIDRs: [], extraDomains: [])
            return service
        }
        let pinned=try fixture()
        var pinState=AppState()
        try pinState.setBypasses([NetworkBypass(kind:.cidr,value:"203.0.113.9",exit:.pinned,serviceID:"isolated",gateway:"192.0.2.1")])
        pinned.activeRequest?.state=pinState
        pinned.checkNetworkChange()
        check(pinned.stops==0 && pinned.starts==0 && pinned.phase=="networkRetry","指定网卡掉线保留拒绝保护，不自动撤销会话")
        pinned.beginNetworkResume(pinned.activeRequest!,fd:1)
        check(pinned.stops==0 && pinned.starts==0 && pinned.lastFailure?.contains("保护仍保留")==true,"指定出口主网络变化不进入存在放行间隙的重建")

        let stable = try fixture()
        var samples = 0, dnsReads = 0, snapshots = 0
        stable.routeSample = { samples += 1; return try NetworkRouteSample(read: { table }) }
        stable.networkDNSRead = { _ in dnsReads += 1; return dns }
        stable.networkSnapshotRead = { sample in snapshots += 1; return NetworkSnapshot(primaryInterface: "en0", routes: NetworkSnapshot.parseRoutes(sample.table), resolvers: [resolver]) }
        let original = stable.capturePlan!
        stable.activeRequest?.systemProxyPort = 7890
        stable.checkNetworkChange(); stable.checkNetworkChange()
        check(samples == 2 && snapshots == 2 && dnsReads == 4 && stable.proxyReads == 2, "每轮只采一次路由，重新读取 DNS 和代理所有权")
        check(stable.stops == 0 && stable.starts == 0, "稳定网络不重启")
        check(stable.capturePlan == original, "采样复用不改变保护计划")

        let dualNIC=try fixture()
        var secondary=""
        dualNIC.routeSample={try NetworkRouteSample(read:{table+"169.254 link#11 UCS en0\n"+secondary})}
        dualNIC.capturePlan=try CapturePlan.make(snapshot:dualNIC.currentSnapshot(),extraCIDRs:[],extraDomains:[])
        for row in ["169.254 link#23 UCSI en6\n","169.254 link#99 UCSI en6\n",""] {
            secondary=row;dualNIC.checkNetworkChange()
            check(dualNIC.stops == 0 && dualNIC.starts == 0 && dualNIC.routeWrites == 0,"次网卡同前缀接入、编号变化和退出不提升全局保护、不重启核心")
            check(dualNIC.capturePlan!.protectedRoutes.filter{$0.destination=="169.254.0.0/16"}.map(\.interface)==["en0"],"核心保持唯一全局出口")
        }

        // 复现系统撤回、重建组播路由及接口编号变化；整个监控周期不能停掉普通代理。
        let multicast=try fixture()
        multicast.journal!.preservedRoutes=[ProtectedRoute(destination:"ff02::/32",gateway:"link#14",interface:"awdl0",scope:"awdl0")]
        var multicastTable="Internet6:\nff02::%awdl0/32 link#14 UmCI awdl0\nff02::%en0/32 link#11 UmCI en0\n"
        multicast.routeSample={try NetworkRouteSample(read:{table+multicastTable})}
        var multicastQueries=0
        multicast.routeInfoHook={multicastQueries += 1;throw ProxyError("系统组播不应补查旧接口")}
        for current in [multicastTable,"Internet6:\nff02::%en0/32 link#11 UmCI en0\n","Internet6:\nff02::%awdl0/32 link#27 UmCI awdl0\n",multicastTable] {
            multicastTable=current
            multicast.checkNetworkChange()
            check(multicast.stops == 0 && multicast.starts == 0 && multicast.phase == "active","系统组播变化不能停止或重启核心")
        }
        check(multicastQueries == 0 && multicast.routeWrites == 0,"动态组播不补查旧快照，也不写系统路由")
        multicast.routeSample={try NetworkRouteSample(read:{table.replacingOccurrences(of:"link#42",with:"link#99")+multicastTable})}
        multicast.checkNetworkChange()
        check(multicast.stops == 1 && multicast.preservedExternal,"组播变化不能掩盖真实接管冲突")

        let ipv6Info="destination: 240e:1c:200::1\ngateway: fe80::1%en0\ninterface: en0\nflags: <UP,GATEWAY,HOST,STATIC>"
        let omitted = try fixture()
        omitted.journal!.routes.append(OwnedRoute(destination:"240e:1c:200::1/128",gateway:"fe80::1%en0",interface:"en0",ipv6:true))
        omitted.routeInfoHook = {ipv6Info}
        omitted.checkNetworkChange()
        check(omitted.stops == 0, "表采样遗漏但精确查询身份一致时保持连接")
        for changed in [ipv6Info.replacingOccurrences(of:"HOST,",with:"")+"\nmask: ::",ipv6Info.replacingOccurrences(of:"fe80::1",with:"fe80::2"),ipv6Info.replacingOccurrences(of:"STATIC",with:"STATIC,IFSCOPE")] {
            let invalid=try fixture()
            invalid.journal!.routes=omitted.journal!.routes
            invalid.routeInfoHook={changed}
            invalid.checkNetworkChange()
            check(invalid.stops == 1, "前缀、网关或作用域不一致不能通过补查放行")
        }
        let conflict=try fixture()
        conflict.routeInfoHook={"destination: default\nmask: 128.0.0.0\ninterface: utun42\nflags: <UP,STATIC>"}
        conflict.routeSample={try NetworkRouteSample(read:{table.replacingOccurrences(of:"link#42",with:"link#99")})}
        conflict.checkNetworkChange()
        check(conflict.stops == 1, "已有同前缀冲突不得用查询结果覆盖")
        for valid in [true,false] {
            let writer=try fixture()
            var reads=0
            writer.routeInfoHook={reads += 1;return reads == 1 ? "destination: default\nmask: ::\ngateway: fe80::1%en0\ninterface: en0\nflags: <UP,GATEWAY>" : (valid ? ipv6Info : ipv6Info.replacingOccurrences(of:"HOST,",with:"")+"\nmask: ::")}
            writer.writeRouteHook={arguments in
                check(arguments.contains("-host") && !arguments.contains("-net"), "写入真实主机命令")
                return "已写入"
            }
            do {
                try writer.addRoute("240e:1c:200::1/128","fe80::1%en0","en0",ipv6:true)
                check(valid,"错误掩码必须在激活前拒绝")
            } catch {check(!valid,"正确主机路由应写入成功")}
            check(writer.routeWrites == 1 && reads == 2,"写后必须重新核验")
            check(writer.journal!.routes.last!.destination == "240e:1c:200::1/128", "失败不把错误前缀认领到恢复记录")
        }

        let dnsChanged = try fixture()
        dnsChanged.networkDNSRead = { _ in nil }
        dnsChanged.checkNetworkChange()
        check(dnsChanged.stops == 1 && dnsChanged.phase == "networkProtectionFailed", "DNS 消失立即恢复，不使用旧缓存")
        let routeChanged = try fixture()
        routeChanged.routeSample = { try NetworkRouteSample(read: { table.replacingOccurrences(of: "link#42", with: "link#99") }) }
        routeChanged.checkNetworkChange()
        check(routeChanged.stops == 1 && routeChanged.lastFailure?.contains("核验未通过") == true, "外部路由改写立即恢复")
        let proxyChanged = try fixture()
        proxyChanged.activeRequest?.systemProxyPort = 7890; proxyChanged.proxyIssues = ["代理被修改"]
        proxyChanged.checkNetworkChange()
        check(proxyChanged.stops == 1 && proxyChanged.proxyReads == 1, "代理冲突仍立即恢复")

        let retry = try fixture()
        var time = 100.0, retrySamples = 0, retrySnapshots = 0
        retry.networkUptime = { time }
        retry.routeSample = { retrySamples += 1; return try NetworkRouteSample(read: { table }) }
        retry.networkSnapshotRead = { _ in retrySnapshots += 1; throw ProxyError("快照暂不可用") }
        retry.checkNetworkChange(); retry.checkNetworkChange()
        check(retrySamples == 2 && retrySnapshots == 1 && retry.phase == "networkRetry", "退避合并快照重试，但每轮仍核验所有权")
        retry.networkDNSRead = { _ in nil }; retry.checkNetworkChange()
        check(retry.stops == 1, "退避期间 DNS 冲突不能被忽略")
        let exhausted = try fixture()
        exhausted.networkUptime = { time }
        exhausted.routeSample = { throw ProxyError("路由暂不可读") }
        var exhaustedCallbacks: [() -> Void] = []
        exhausted.networkResumeSchedule = { _, callback in exhaustedCallbacks.append(callback) }
        exhausted.startHook = {throw NetworkEnvironmentNotReady("原网络仍未就绪")}
        for next in [100.0, 101, 103, 107] { time = next; exhausted.checkNetworkChange() }
        check(exhausted.stops == 2 && exhausted.phase == "networkReconnecting", "采样重试耗尽后安全恢复旧接管，再等待网络就绪")
        check(exhaustedCallbacks.count == 1 && exhausted.networkResumeSession != nil, "采样失败的重建仍保留受限连接意图")
        try exhausted.stop()
        exhaustedCallbacks.removeFirst()()
        check(exhausted.starts == 1, "快照重建等待也能由用户取消")

        let replanned = try fixture()
        var now = Date(timeIntervalSince1970: 100)
        replanned.networkClock = { now }
        replanned.networkUptime = {now.timeIntervalSince1970}
        replanned.networkSnapshotRead = { sample in NetworkSnapshot(primaryInterface: "en1", routes: NetworkSnapshot.parseRoutes(sample.table), resolvers: [resolver]) }
        replanned.checkNetworkChange()
        check(replanned.stops == 0, "变化先稳定一秒")
        now.addTimeInterval(1); replanned.checkNetworkChange()
        check(replanned.stops == 1 && replanned.starts == 1 && replanned.phase == "active", "稳定变化仍按原流程重规划")

        // 模拟后台唤醒：第一次重建时 IPv6 出口未就绪，旧设置恢复后等待下一轮。
        let resume = try fixture()
        var waits: [Double] = [], callbacks: [() -> Void] = [], transient = true
        resume.networkResumeSchedule = { delay, callback in waits.append(delay);callbacks.append(callback) }
        resume.startHook = { if transient { throw NetworkEnvironmentNotReady("IPv6 默认路由属于其他接口，未启用 TUN") } }
        let request = resume.activeRequest!
        resume.beginNetworkResume(request, fd: 7)
        check(resume.phase == "networkReconnecting" && resume.starts == 1, "网络未就绪进入重连态，不能报告核心崩溃")
        check(resume.owner == 7 && resume.networkResumeSession != nil && waits == [1], "保留同一控制通道的连接意图，等待一秒")
        transient = false;callbacks.removeFirst()()
        check(resume.phase == "active" && resume.starts == 2 && resume.networkResumeSession == nil, "网络恢复后自动完成准备和激活")
        check(resume.activeRequest?.operation == request.operation && resume.owner == 7, "恢复原连接模型和所有者")
        check(resume.lastFailure == nil, "自动恢复成功清除暂态错误")

        let darkWake = try fixture()
        var darkCallbacks: [() -> Void] = [], elapsed = 0.0
        darkWake.networkResumeSchedule = { delay, callback in
            darkCallbacks.append {elapsed += delay;callback()}
        }
        darkWake.startHook = {if elapsed < 56 {throw NetworkEnvironmentNotReady("后台唤醒 IPv6 尚未恢复")} }
        darkWake.beginNetworkResume(request, fd: 15)
        while !darkCallbacks.isEmpty {darkCallbacks.removeFirst()()}
        check(darkWake.phase == "active" && elapsed == 60, "复现后台唤醒至用户唤醒五十六秒的窗口后自动连接")
        check(darkWake.starts == 7 && darkWake.networkResumeSession == nil, "后台唤醒不会清空连接意图，成功后释放重试记录")

        let cancelled = try fixture()
        var staleCallbacks: [() -> Void] = []
        cancelled.networkResumeSchedule = { _, callback in staleCallbacks.append(callback) }
        cancelled.startHook = { throw NetworkEnvironmentNotReady("Wi-Fi 尚未就绪") }
        cancelled.beginNetworkResume(request, fd: 8)
        let staleSession = cancelled.networkResumeSession!
        try cancelled.stop()
        staleCallbacks.removeFirst()()
        check(cancelled.starts == 1 && cancelled.networkResumeSession == nil, "手动停止和控制通道关闭后，旧回调不能重新接管")
        check(cancelled.owner == nil && staleSession.owner == 8, "停止时释放待重连所有权")

        let permanent = try fixture()
        permanent.startHook = { throw ProxyError("另一个隧道正在接管默认路由，未启用 TUN") }
        permanent.beginNetworkResume(request, fd: 9)
        check(permanent.phase == "networkProtectionFailed" && permanent.networkResumeSession == nil, "真实 VPN 冲突立即停止，不自动忽略安全条件")

        let restoreConflict = try fixture()
        restoreConflict.stopHook = { throw ProxyError("恢复记录存在外部修改") }
        restoreConflict.beginNetworkResume(request, fd: 10)
        check(restoreConflict.starts == 0 && restoreConflict.networkResumeSession == nil, "旧设置恢复失败时不得启动核心")
        check(restoreConflict.lastFailure?.contains("恢复冲突") == true, "恢复失败保留真实原因")

        let limit = try fixture()
        var limitCallbacks: [() -> Void] = [], delays: [Double] = []
        limit.networkResumeSchedule = { delay, callback in delays.append(delay);limitCallbacks.append(callback) }
        limit.startHook = { throw NetworkEnvironmentNotReady("IPv6 网络持续不可用") }
        limit.beginNetworkResume(request, fd: 11)
        while !limitCallbacks.isEmpty { limitCallbacks.removeFirst()() }
        check(delays == [1, 2, 4, 8, 15, 30, 30] && limit.starts == 8, "重试有次数和退避上限，事件风暴不能无限重连")
        check(limit.phase == "networkProtectionFailed" && limit.networkResumeSession == nil, "预算耗尽后恢复并报告停止")

        // 企业 VPN 在绕过计划冻结后补上网段：链接正式写入逻辑，确认不覆盖、不认领。
        let corporate = try fixture()
        let corporateInfo="destination: 172.16.0.0\nmask: 255.240.0.0\ngateway: 10.251.1.1\ninterface: utun6\nflags: <UP,GATEWAY,STATIC>"
        corporate.routeInfoHook = {corporateInfo}
        let originalRouteCount=corporate.journal!.routes.count
        var corporateCallbacks:[() -> Void]=[]
        corporate.networkResumeSchedule = {_, callback in corporateCallbacks.append(callback)}
        corporate.activateHook = {
            try corporate.addRoute("172.16.0.0/12","192.168.1.1","en0",ipv6:false,preparationBypass:true)
        }
        corporate.beginNetworkResume(request,fd:16)
        check(corporate.phase == "networkReconnecting", "企业 VPN 后到路由触发回滚重采样，不终止连接意图")
        check(corporate.routeWrites == 0 && corporate.journal!.routes.count == originalRouteCount, "不得删除、覆盖或认领企业 VPN 已有路由")
        corporate.activateHook = {
            let original=ProtectedRoute(destination:"172.16.0.0/12",gateway:"10.251.1.1",interface:"utun6")
            let snapshot=NetworkSnapshot(primaryInterface:"en0",routes:[original],resolvers:[resolver])
            let fresh=try CapturePlan.make(snapshot:snapshot,extraCIDRs:[],extraDomains:[])
            let bypass=try BypassRoutePlan.capture(destinations:fresh.exclusions,existingPrefixes:[original.destination],hasIPv6:false,existingRoutes:[original],lookup:{_,_ in "gateway: 192.168.1.1\ninterface: en0\nflags: <UP,GATEWAY,STATIC>"})
            check(fresh.protectedRoutes.contains(original), "重新采样保留企业网段出口")
            check(!bypass.routes.contains{$0.destination == original.destination}, "新绕过计划不再写入已存在的企业网段")
        }
        corporateCallbacks.removeFirst()()
        check(corporate.phase == "active" && corporate.starts == 2, "同一连接重新规划后自动恢复："+(corporate.lastFailure ?? corporate.phase))
        do {
            try corporate.addRoute("172.16.0.0/12","192.168.1.1","en0",ipv6:false)
            check(false,"普通保护冲突必须拒绝")
        } catch {check(!(error is NetworkEnvironmentNotReady), "非绕过写入的冲突不能误分类为暂态")}
        corporate.routeInfoHook = {"destination: default\nmask: 128.0.0.0\ngateway: 10.251.1.1\ninterface: utun6\nflags: <UP,GATEWAY,STATIC>"}
        do {
            try corporate.addRoute("0.0.0.0/1","192.168.1.1","en0",ipv6:false)
            check(false,"默认路由接管冲突必须拒绝")
        } catch {check(!(error is NetworkEnvironmentNotReady), "默认路由冲突仍立即停止")}
        check(corporate.routeWrites == 0, "所有冲突测试均未调用系统路由写入")

        let rejected=try fixture()
        rejected.routeInfoHook={"destination: default\nmask: ::\ngateway: fe80::1%en0\ninterface: en0\nflags: <UP,GATEWAY>"}
        rejected.writeRouteHook={_ in "route: writing to routing socket: File exists\nadd host: File exists"}
        let beforeReject=rejected.journal!.routes.count
        do {try rejected.addRoute("240e:1c:200::1/128","fe80::1%en0","en0",ipv6:true);check(false,"零退出码的路由错误必须拒绝")}
        catch {check(rejected.journal!.routes.count == beforeReject,"明确未写入时不能留下外部路由所有权记录")}
        let legacyBlocked=try fixture()
        legacyBlocked.routeInfoHook={ipv6Info.replacingOccurrences(of:"STATIC",with:"STATIC,IFSCOPE")}
        legacyBlocked.routeSample={try NetworkRouteSample(read:{"Internet6:\n240e:1c:200::1/0 fe80::1%en0 UGSc en0"})}
        let beforeLegacy=legacyBlocked.journal!.routes.count
        do {try legacyBlocked.addRoute("240e:1c:200::1/128","fe80::1%en0","en0",ipv6:true);check(false,"未知归属的异常项不能自动覆盖")}
        catch {check(legacyBlocked.routeWrites == 0 && legacyBlocked.journal!.routes.count == beforeLegacy,"缓存存在时仍识别残留，且不认领外部异常路由")}
        let preexisting=try fixture()
        preexisting.routeInfoHook={ipv6Info.replacingOccurrences(of:"STATIC",with:"STATIC,IFSCOPE")}
        preexisting.routeSample={try NetworkRouteSample(read:{"Internet6:\n240e:1c:200::1 fe80::1%en0 UGHS en0"})}
        let beforeExisting=preexisting.journal!.routes.count
        try preexisting.addRoute("240e:1c:200::1/128","fe80::1%en0","en0",ipv6:true)
        check(preexisting.routeWrites == 0 && preexisting.journal!.routes.count == beforeExisting,"全局既有路由不能被缓存查询掩盖后重新写入并认领")

        let cached=try fixture()
        let physical=ProtectedRoute(destination:"202.101.172.35/32",gateway:"192.168.72.1",interface:"en0")
        let cachedInfo="destination: 202.101.172.35\ngateway: 192.168.72.1\ninterface: en0\nflags: <UP,GATEWAY,HOST,WASCLONED,IFSCOPE>"
        cached.routeSample={try NetworkRouteSample(read:{"Internet:\n202.101.172.35 192.168.72.1 UGHS en0\n202.101.172.35 192.168.72.1 UGHWI en0"})}
        let cachedValid=try cached.verifiedRoute(physical,info:cachedInfo)
        check(cachedValid,"接口缓存不能掩盖完整表中的全局静态路由")
        cached.routeSample={try NetworkRouteSample(read:{"Internet:\n202.101.172.35 192.168.72.2 UGHS en0"})}
        let cachedInvalid=try cached.verifiedRoute(physical,info:cachedInfo)
        check(!cachedInvalid,"全局网关错误不能因接口缓存相同而放行")

        let activation = try fixture()
        var activateCallbacks: [() -> Void] = [], notReady = true
        activation.networkResumeSchedule = { _, callback in activateCallbacks.append(callback) }
        activation.activateHook = { if notReady {throw NetworkEnvironmentNotReady("准备期间物理网络已变化")} }
        activation.beginNetworkResume(request, fd: 12)
        check(activation.phase == "networkReconnecting", "激活期间的暂态变化先回滚再等待")
        notReady = false;activateCallbacks.removeFirst()()
        check(activation.phase == "active" && activation.starts == 2, "激活重试仍完成全部安全核验流程")
        check(TunReply(ok: true, message: "等待", running: false, phase: "networkReconnecting").networkReconnecting, "真实运行态与待重连态分别表达")
        check(!TunReply(ok: true, message: "失败", running: false, phase: "networkProtectionFailed").networkReconnecting, "终止失败不能伪装为等待")

        // 完整监听流程：先连接轻舟，再分批添加企业 DNS 与路由，最后退出并重新接入。
        let hot=try fixture()
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("qz-hot-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        hot.dynamicRules=try DynamicCaptureRules(directory:directory,plan:hot.capturePlan!)
        var tick=100.0
        hot.networkUptime={tick}
        var corporateResolvers=[resolver]
        var corporateRoutes:[ProtectedRoute]=[]
        hot.routeSample={try NetworkRouteSample(read:{table+corporateRoutes.map{$0.destination+" "+$0.gateway+" UGSc "+$0.interface+"\n"}.joined()})}
        hot.networkSnapshotRead={sample in NetworkSnapshot(primaryInterface:"en0",routes:NetworkSnapshot.parseRoutes(sample.table),resolvers:corporateResolvers)}
        let corpDNS=DNSResolverScope(service:"corp",interface:"utun6",servers:["10.20.0.53"],domains:["corp.test"])
        let corpRoute=ProtectedRoute(destination:"10.20.0.0/16",gateway:"10.20.0.1",interface:"utun6")
        corporateResolvers.append(corpDNS);hot.checkNetworkChange()
        check(hot.protectedQueriesSuspended && hot.starts == 0,"DNS 先到时只暂停企业查询，不重启公网核心")
        tick += 0.5;corporateRoutes=[corpRoute];hot.checkNetworkChange()
        tick += 0.5;hot.checkNetworkChange()
        check(hot.protectedQueriesSuspended,"路由后到必须重新等待一致采样")
        tick += 0.5;hot.checkNetworkChange()
        check(!hot.protectedQueriesSuspended && hot.capturePlan!.domains.contains("corp.test") && hot.starts == 0 && hot.stops == 0,"分批接入完成热更新，核心不重启")
        corporateResolvers=[resolver];corporateRoutes=[];tick += 1;hot.checkNetworkChange();tick += 1;hot.checkNetworkChange()
        check(hot.capturePlan!.resolvers(for:"api.corp.test").isEmpty && hot.capturePlan!.domains.contains("corp.test"),"企业退出后仍保护域名，不转公共 DNS")
        corporateRoutes=[corpRoute];tick += 1;hot.checkNetworkChange();tick += 1;hot.checkNetworkChange()
        corporateResolvers.append(corpDNS);tick += 1;hot.checkNetworkChange();tick += 1;hot.checkNetworkChange()
        check(hot.capturePlan!.resolvers(for:"api.corp.test").first?.interface == "utun6" && hot.starts == 0 && hot.stops == 0,"路由先到及重新连接仍不重启核心")
        for index in 0..<15 {corporateResolvers=[resolver,DNSResolverScope(service:"corp",interface:"utun6",servers:["10.20.0."+String(54+index%2)],domains:["corp.test"])];tick += 1;hot.checkNetworkChange()}
        check(hot.protectedQueriesSuspended && hot.stops == 0 && hot.lastFailure?.contains("普通代理继续") == true,"持续抖动超过十秒只暂停企业能力")
        try hot.stop();check(hot.activeRequest == nil,"用户停止取消当前连接意图")

        let takeover=try fixture()
        takeover.networkSnapshotRead={sample in NetworkSnapshot(primaryInterface:"en0",routes:NetworkSnapshot.parseRoutes(sample.table)+[ProtectedRoute(destination:"0.0.0.0/0",gateway:"10.1.0.1",interface:"utun99")],resolvers:[resolver])}
        takeover.checkNetworkChange()
        check(takeover.stops == 1 && takeover.preservedExternal && takeover.lastFailure?.contains("公网大范围") == true,"全隧道企业接管立即退出竞争并保留外部配置")
        let withdrawn=try fixture()
        let withdrawalDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("qz-withdraw-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:withdrawalDirectory)}
        withdrawn.dynamicRules=try DynamicCaptureRules(directory:withdrawalDirectory,plan:withdrawn.capturePlan!)
        withdrawn.journal!.routes.append(OwnedRoute(destination:"10.22.0.0/16",gateway:"10.22.0.1",interface:"utun6"))
        withdrawn.routeSample={try NetworkRouteSample(read:{table})}
        let withdrawalPlan=withdrawn.capturePlan!
        let retired=ProtectedRoute(destination:"192.168.66.0/24",gateway:"link#23",interface:"en6",scope:"en6")
        for state in ["owned","absent","replaced"] {
            let physical=try fixture()
            let folder=directory.appendingPathComponent("retire-"+state)
            physical.dynamicRules=try DynamicCaptureRules(directory:folder,plan:physical.capturePlan!)
            physical.capturePlan!.protectedRoutes.append(retired)
            physical.journal!.routes.append(OwnedRoute(destination:retired.destination,gateway:retired.gateway,interface:retired.interface))
            var row=state=="absent" ? "":("192.168.66/24 "+(state=="owned" ? "link#23":"link#99")+" UGS en6\n")
            physical.routeSample={try NetworkRouteSample(read:{table+row})}
            physical.writeRouteHook={args in check(args.contains("delete") && args.contains("en6"),"撤回仅删除轻舟拥有的旧物理保护项");row="";return "已删除"}
            if state=="replaced" {
                let issues=try physical.reconciledNetworkIssues(withdrawalPlan,sample:physical.routeSample())
                check(!issues.isEmpty,"外部改写不能伪装为正常旧出口撤回")
            }
            let applied=try physical.applyCorporatePlan(withdrawalPlan,sample:physical.routeSample())
            check(applied && physical.routeWrites==(state=="owned" ? 1:0),"旧出口消失或被替换时不删除外部路径")
            check(!physical.journal!.routes.contains{$0.interface=="en6"},"成功撤回后清理轻舟旧记录")
        }
        let withdrawnOK=try withdrawn.applyCorporatePlan(withdrawalPlan,sample:withdrawn.routeSample())
        check(withdrawnOK && !withdrawn.journal!.routes.contains{$0.interface == "utun6"} && withdrawn.routeWrites == 0,"企业退出且原保护项已消失时直接撤销记录，不删除外部路由")
        withdrawn.journal!.routes.append(OwnedRoute(destination:"10.22.0.0/16",gateway:"10.22.0.1",interface:"utun6"))
        withdrawn.routeSample={try NetworkRouteSample(read:{table+"10.22/16 10.22.0.2 UGSc utun8\n"})}
        let replacedOK=try withdrawn.applyCorporatePlan(withdrawalPlan,sample:withdrawn.routeSample())
        check(replacedOK && withdrawn.routeWrites == 0,"企业保护项已被其他 VPN 替换时只放弃认领，不能删除新出口")

        var unstable=withdrawalPlan
        unstable.protectedRoutes.append(ProtectedRoute(destination:"10.44.0.0/16",gateway:"10.44.0.1",interface:"utun6"))
        let beforeUnstable=withdrawn.capturePlan
        do {_=try withdrawn.applyCorporatePlan(unstable,sample:withdrawn.routeSample());check(false,"发布企业计划前必须复核实际路径")}
        catch {check(error is NetworkEnvironmentNotReady && withdrawn.capturePlan == beforeUnstable && withdrawn.stops == 0,"路径尚未到达只保持企业暂停，不能发布不可用计划或重启公网核心")}

        // 新记录启用动态捕获差集；夹具将正式写入调用映射为内存表，并核验先增后删。
        for refuseNew in [false,true] {
            let live=try fixture()
            let initial=live.capturePlan!
            live.dynamicRules=try DynamicCaptureRules(directory:directory.appendingPathComponent("capture-\(refuseNew)"),plan:initial)
            let prefixes=CaptureRoutePlan.legacyPrefixes
            live.journal!.captureRoutes=prefixes
            live.journal!.routes=prefixes.map{OwnedRoute(destination:$0,gateway:$0.contains(":") ? "fd71:717a::1":"100.64.1.1",interface:"utun42",ipv6:$0.contains(":"))}
            let physical=ProtectedRoute(destination:"0.0.0.0/0",gateway:"192.168.1.1",interface:"en0")
            var actual=[physical]+live.journal!.routes.map{ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface)}
            live.routeSample={NetworkRouteSample(routes:actual)}
            live.routeLookupHook={target,ipv6,scope in
                let path=try CaptureRoutePlan.systemPath(target=="default" ? (ipv6 ? "::/0":"0.0.0.0/0"):target,routes:actual.filter{$0.scope==scope})
                return RouteRecord(route:path,flags:3).queryText
            }
            var operations:[String]=[]
            live.writeRouteHook={args in
                guard let route=live.journal!.routes.last(where:{route in
                    let parts=route.destination.split(separator:"/").map(String.init)
                    let prefixIndex=args.firstIndex(of:"-prefixlen")
                    let matches=args.contains(route.destination) || (parts.count==2 && args.contains(parts[0]) && ((args.contains("-host") && parts[1]==(route.ipv6 ? "128":"32")) || prefixIndex.map{$0+1<args.count && args[$0+1]==parts[1]}==true))
                    return matches && (args.contains(route.gateway) || args.contains(route.interface))
                }) else {throw ProxyError("夹具没有写前恢复意图："+args.joined(separator:" "))}
                let deleting=args.contains("delete")
                operations.append(deleting ? "delete":"add")
                if refuseNew && !deleting {return "writing to routing socket: Permission denied"}
                if deleting {actual.removeAll{$0.destination==route.destination && $0.gateway==route.gateway && $0.interface==route.interface && $0.scope==route.scope}}
                else {actual.append(ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope))}
                return ""
            }
            var next=initial;next.snapshot.routes=[physical];next.protectedRoutes=[];next.exclusions=["198.51.100.7/32"]
            do {
                let result=try live.applyCorporatePlan(next,sample:live.routeSample())
                check(!refuseNew && result,"动态捕获重规划成功")
                if let firstDelete=operations.firstIndex(of:"delete") {check(!operations.dropFirst(firstDelete).contains("add"),"新捕获全部核验后才撤回旧项")}
                check(live.journal!.captureRoutes != prefixes && !live.journal!.captureRoutes!.contains("0.0.0.0/1"),"捕获列表按实际差集提交")
                check(!live.journal!.routes.contains{$0.destination=="0.0.0.0/1"},"旧捕获拥有记录仅在删除后撤回")
            } catch {
                if !refuseNew {FileHandle.standardError.write(Data("动态夹具失败：\(error)\n".utf8))}
                check(refuseNew && !operations.contains("delete"),"新捕获写入失败不撤回旧保护")
                check(live.journal!.captureRoutes==prefixes && actual.contains{$0.destination=="0.0.0.0/1"},"失败保留旧捕获与恢复意图")
            }
        }

        // 使用正式网络检查生成查询响应，比较旧入口和过滤入口是否会自行补查。
        func packet(_ type:Int32) -> Data {
            var header=rt_msghdr();header.rtm_msglen=UInt16(MemoryLayout<rt_msghdr>.size)
            header.rtm_version=UInt8(RTM_VERSION);header.rtm_type=UInt8(type)
            return withUnsafeBytes(of:&header){Data($0)}
        }
        func feedback(filtered:Bool) throws -> (Int,Int) {
            let service=try fixture()
            var jobs:[()->Void]=[],packets=[packet(RTM_ADD)],runs=0,queries=0
            service.networkMonitorObservation={event in if event == .checkExecuted {runs+=1};if event == .routeQuery {queries+=1}}
            service.routeInfoHook={packets.append(packet(RTM_GET));return ""}
            service.networkSnapshotRead={sample in
                _=try service.routeInfo("192.0.2.53",ipv6:false)
                return NetworkSnapshot(primaryInterface:"en0",routes:NetworkSnapshot.parseRoutes(sample.table),resolvers:[resolver])
            }
            let scheduler=NetworkCheckScheduler(enqueue:{jobs.append($0)},operation:{service.checkNetworkChange()})
            for _ in 0..<20 {
                if filtered {
                    RouteEventPump.drain(read:{packets.isEmpty ? .wouldBlock:.packet(packets.removeFirst())},request:{scheduler.request()})
                } else if !packets.isEmpty {packets=[];scheduler.request()}
                if !jobs.isEmpty {jobs.removeFirst()()}
                if packets.isEmpty && jobs.isEmpty {break}
            }
            scheduler.cancel()
            return (runs,queries)
        }
        let baselineFeedback=try feedback(filtered:false),candidateFeedback=try feedback(filtered:true)
        check(baselineFeedback.0==20 && baselineFeedback.1==20,"旧入口可在无外部变化时由查询响应持续触发检查")
        check(candidateFeedback.0==1 && candidateFeedback.1==1,"过滤入口只核验真实变化，查询响应不触发下一轮")
        print("ROUTE_FEEDBACK baselineChecks=\(baselineFeedback.0) baselineQueries=\(baselineFeedback.1) candidateChecks=\(candidateFeedback.0) candidateQueries=\(candidateFeedback.1)")

        var queued: [() -> Void] = [], cycles = 0
        let burst = try fixture()
        let checks = NetworkCheckScheduler(enqueue: { queued.append($0) }, operation: { cycles += 1; burst.checkNetworkChange() })
        for _ in 0..<100 { checks.request() }
        check(queued.count == 1, "事件风暴只安排一次检查")
        queued.removeFirst()()
        burst.networkDNSRead = { _ in nil }
        for _ in 0..<100 { checks.request() }
        queued.removeFirst()()
        check(cycles == 2 && burst.stops == 1, "下一轮重新读取 DNS，合并事件不能隐藏冲突")
        print("RESULT helper_monitor_assertions=\(assertions) failures=0")
    }
}
