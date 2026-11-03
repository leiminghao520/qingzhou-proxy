import Foundation

// 所有入口必须在同一串行队列调用；一批事件只安排一次检查，执行中新增事件补查一次。
public final class NetworkCheckScheduler {
    private let enqueue: (@escaping () -> Void) -> Void
    private let operation: () -> Void
    private var scheduled = false
    private var running = false
    private var pending = false
    private var cancelled = false
    public init(enqueue: @escaping (@escaping () -> Void) -> Void, operation: @escaping () -> Void) {
        self.enqueue = enqueue
        self.operation = operation
    }
    public func request() {
        guard !cancelled else { return }
        pending = true
        guard !scheduled, !running else { return }
        scheduled = true
        enqueue { [weak self] in self?.run() }
    }
    private func run() {
        guard !cancelled else { return }
        scheduled = false; running = true; pending = false
        operation()
        running = false
        if pending { request() }
    }
    public func cancel() { cancelled = true; pending = false }
}

// 同一轮所有权核验和重规划共用原始采样，各自保留原有的瞬态路由过滤规则。
public struct NetworkRouteSample {
    private let tableValue:RouteTableText
    private let identityValue:RouteIdentityValue
    public var identityIndex:RouteIdentityIndex {identityValue.value}
    public var table:String {tableValue.value}
    public let ownershipRoutes: [ProtectedRoute]
    public let planningRoutes: [ProtectedRoute]
    public init(routes:[ProtectedRoute]) {
        self.init(records:routes.map{RouteRecord(route:$0,flags:UInt32(1 | ($0.gateway.hasPrefix("link#") ? 0:2) | ($0.scope==nil ? 0:0x1000000)))})
    }
    public init(records:[RouteRecord],metrics:RouteOperationMetrics?=nil) {
        tableValue=RouteTableText {
            func build() -> String {
                let v4=records.filter{!$0.route.ipv6},v6=records.filter{$0.route.ipv6}
                return "Internet:\n"+v4.map(\.tableLine).joined(separator:"\n")+"\nInternet6:\n"+v6.map(\.tableLine).joined(separator:"\n")
            }
            if let metrics {return metrics.measure("routeTableText",build)}
            return build()
        }
        // 旧版异常零掩码主机保留在原始表中用于恢复，不伪装成有效默认路由。
        let valid=records.filter{!$0.route.destination.hasSuffix("/0") || ["0.0.0.0/0","::/0"].contains($0.route.destination)}
        ownershipRoutes=valid.map(\.route)
        identityValue=RouteIdentityValue(ownershipRoutes,records:valid,metrics:metrics)
        planningRoutes=valid.filter{!$0.isTransient || CapturePlan.isVPN($0.route.interface)}.map(\.route)
    }
    public init(read: () throws -> String = { try NetworkInspection.command("/usr/sbin/netstat", ["-rn"]) }) throws {
        let table=try read();tableValue=RouteTableText{table}
        ownershipRoutes = NetworkSnapshot.parseRoutes(table, includeTransient: true)
        identityValue=RouteIdentityValue(ownershipRoutes)
        planningRoutes = NetworkSnapshot.parseRoutes(table)
    }
}

// 结构化写前、写后采样无需构建兼容文本；旧异常识别需要时才生成，快照内容仍保持不可变。
private final class RouteTableText {
    private let build:()->String
    private let lock=NSLock()
    private var cached:String?
    init(_ build:@escaping ()->String){self.build=build}
    var value:String {lock.lock();defer{lock.unlock()};if let cached {return cached};let text=build();cached=text;return text}
}

// 索引只绑定不可变的本轮采样；下一次采样一定创建新索引，不跨写入复用旧身份。
private final class RouteIdentityValue {
    private let routes:[ProtectedRoute]
    private let records:[RouteRecord]?
    private let metrics:RouteOperationMetrics?
    private let lock=NSLock()
    private var cached:RouteIdentityIndex?
    init(_ routes:[ProtectedRoute],records:[RouteRecord]?=nil,metrics:RouteOperationMetrics?=nil) {self.routes=routes;self.records=records;self.metrics=metrics}
    var value:RouteIdentityIndex {
        lock.lock();defer{lock.unlock()}
        if let cached {return cached}
        let result:RouteIdentityIndex
        if let metrics {result=metrics.measure("routeIdentityIndex") {records.map{RouteIdentityIndex(records:$0)} ?? RouteIdentityIndex(routes)}}
        else {result=records.map{RouteIdentityIndex(records:$0)} ?? RouteIdentityIndex(routes)}
        cached=result;return result
    }
}
