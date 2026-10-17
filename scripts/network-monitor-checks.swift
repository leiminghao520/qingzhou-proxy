import Foundation
import SystemConfiguration
import QingzhouKit

// 此夹具链接正式 NetworkMonitor.swift，只替换管理员服务的外部输入和写操作。
struct OwnedRoute { var destination: String; var gateway: String; var interface: String; var ipv6: Bool = false; var scope: String? = nil }
struct Journal { var expectedDNS: Data; var dnsKey = "fixture"; var routes: [OwnedRoute]; var preservedRoutes: [ProtectedRoute]? = []; var interface: String? = "utun42" }
final class Service {
    let queue = DispatchQueue(label: "cn.qingzhou.monitor.fixture")
    let dynamic = SCDynamicStoreCreate(nil, "只读监控夹具" as CFString, nil, nil)!
    var capturePlan: CapturePlan?
    var journal: Journal?
    var activeRequest: TunRequest? = TunRequest(operation: "prepare", state: AppState())
    var owner: Int32? = 1
    var phase = "active"
    var networkTimer: DispatchSourceTimer?
    var networkStore: SCDynamicStore?
    var routeEvents: DispatchSourceRead?
    var networkChecks: NetworkCheckScheduler?
    var routeSample: () throws -> NetworkRouteSample = { throw ProxyError("必须注入采样") }
    var networkDNSRead: ((String) -> NSDictionary?)?
    var networkSnapshotRead: ((NetworkRouteSample) throws -> NetworkSnapshot)?
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
    var proxyIssues: [String] = []
    var routeInfoHook: (() throws -> String)?
    var routeWrites = 0
    func routeInfo(_ destination:String,ipv6:Bool,scope:String?=nil,deadline:Date?=nil) throws -> String {
        guard let routeInfoHook else {throw ProxyError("夹具必须注入路由查询")}
        return try routeInfoHook()
    }
    func field(_ label:String,_ text:String)->String? {label == "gateway" ? NetworkInspection.routeGateway(text):NetworkInspection.routeField(label,text)}
    func prefix(_ info:String)->String? {NetworkInspection.routePrefix(destination:field("destination",info),mask:field("mask",info),host:info.contains("HOST"))}
    func save() throws {}
    func writeRoute(_ arguments:[String],deadline:Date?) throws -> String {routeWrites += 1;throw ProxyError("夹具禁止写系统路由")}

    func proxyOwnershipIssues() -> [String] { proxyReads += 1; return proxyIssues }
    func stop() throws { if !performingNetworkResume {cancelNetworkResume()}; stops += 1; try stopHook?(); networkChecks?.cancel(); capturePlan = nil; activeRequest = nil; owner = nil }
    func start(_ request: TunRequest, fd: Int32) throws { starts += 1; try startHook?(); activeRequest = request; owner = fd; activatePrepared = {try self.activateHook?()} }
}

@main struct MonitorChecks {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
    static func main() throws {
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
        let stable = try fixture()
        var samples = 0, dnsReads = 0, snapshots = 0
        stable.routeSample = { samples += 1; return try NetworkRouteSample(read: { table }) }
        stable.networkDNSRead = { _ in dnsReads += 1; return dns }
        stable.networkSnapshotRead = { sample in snapshots += 1; return NetworkSnapshot(primaryInterface: "en0", routes: NetworkSnapshot.parseRoutes(sample.table), resolvers: [resolver]) }
        let original = stable.capturePlan!
        stable.activeRequest?.systemProxyPort = 7890
        stable.checkNetworkChange(); stable.checkNetworkChange()
        check(samples == 2 && snapshots == 2 && dnsReads == 2 && stable.proxyReads == 2, "每轮只采一次路由，重新读取 DNS 和代理所有权")
        check(stable.stops == 0 && stable.starts == 0, "稳定网络不重启")
        check(stable.capturePlan == original, "采样复用不改变保护计划")

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
