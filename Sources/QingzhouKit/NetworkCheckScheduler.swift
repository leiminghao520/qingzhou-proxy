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
    public let table: String
    public let ownershipRoutes: [ProtectedRoute]
    public init(read: () throws -> String = { try NetworkInspection.command("/usr/sbin/netstat", ["-rn"]) }) throws {
        table = try read()
        ownershipRoutes = NetworkSnapshot.parseRoutes(table, includeTransient: true)
    }
}
