import Foundation
import SystemConfiguration
import QingzhouKit

// 此夹具链接正式 NetworkMonitor.swift，只替换管理员服务的外部输入和写操作。
struct OwnedRoute { var destination: String; var gateway: String; var interface: String; var scope: String? = nil }
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
    var activatePrepared: (() throws -> Void)?
    var lastFailure: String?
    var stops = 0, starts = 0, proxyReads = 0
    var proxyIssues: [String] = []
    func addRoute(_ destination: String, _ gateway: String, _ interface: String, ipv6: Bool) throws { throw ProxyError("夹具禁止写路由") }
    func proxyOwnershipIssues() -> [String] { proxyReads += 1; return proxyIssues }
    func stop() throws { stops += 1; networkChecks?.cancel(); capturePlan = nil; activeRequest = nil }
    func start(_ request: TunRequest, fd: Int32) throws { starts += 1; activeRequest = request; activatePrepared = {} }
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
        for next in [100.0, 101, 103, 107] { time = next; exhausted.checkNetworkChange() }
        check(exhausted.stops == 1 && exhausted.phase == "networkProtectionFailed", "采样重试耗尽后恢复")

        let replanned = try fixture()
        var now = Date(timeIntervalSince1970: 100)
        replanned.networkClock = { now }
        replanned.networkSnapshotRead = { sample in NetworkSnapshot(primaryInterface: "en1", routes: NetworkSnapshot.parseRoutes(sample.table), resolvers: [resolver]) }
        replanned.checkNetworkChange()
        check(replanned.stops == 0, "变化先稳定一秒")
        now.addTimeInterval(1); replanned.checkNetworkChange()
        check(replanned.stops == 1 && replanned.starts == 1 && replanned.phase == "active", "稳定变化仍按原流程重规划")

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
