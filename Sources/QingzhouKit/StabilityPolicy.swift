import Foundation

// 调度器串行收尾旧探测，注入等待函数以便无真实延时地验证合并与取消。
@MainActor public final class HealthRefreshScheduler {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let sleep: (UInt64) async throws -> Void
    public init(sleep: @escaping (UInt64) async throws -> Void = {try await Task.sleep(nanoseconds:$0)}) {self.sleep=sleep}
    public func cancel() {generation=UUID();task?.cancel()}
    public func schedule(delay:UInt64=1_000_000_000,operation:@escaping @MainActor () async -> Void) {
        let previous=task
        previous?.cancel()
        let token=UUID();generation=token
        task=Task { [weak self] in
            await previous?.value
            guard let self else{return}
            do {try Task.checkCancellation();try await self.sleep(delay);try Task.checkCancellation()} catch {return}
            guard self.generation==token else{return}
            await operation()
            if self.generation==token {self.task=nil}
        }
    }
    public func wait() async {await task?.value}
}

// 仅网络快照暂不可用才重试；所有权冲突由调用方立即停止接管。
public struct NetworkSnapshotRetry {
    public private(set) var attempts=0
    public private(set) var retryAt:TimeInterval?
    public init() {}
    public func ready(now:TimeInterval)->Bool {retryAt.map{now >= $0} ?? true}
    public mutating func failed(now:TimeInterval)->Bool {
        guard attempts<3 else{return false}
        retryAt=now+[1.0,2,4][attempts];attempts+=1;return true
    }
    public mutating func reset() {self=Self()}
}

public enum LatencyPresentation {
    public static func current(_ result:LatencyResult?,invalidatedAt:Date,now:Date=Date())->Bool {
        guard let result else{return false}
        let age=now.timeIntervalSince(result.testedAt)
        return result.testedAt>=invalidatedAt && age>=0 && age<=300
    }
    public static func sortValue(_ result:LatencyResult?,invalidatedAt:Date,now:Date=Date())->Int {
        current(result,invalidatedAt:invalidatedAt,now:now) ? result?.milliseconds ?? Int.max:Int.max
    }
    public static func label(_ result:LatencyResult?,invalidatedAt:Date,now:Date=Date())->String {
        guard let result else{return "未检测"}
        let value=result.milliseconds.map{"\($0) ms"} ?? "检测失败"
        let stamp=result.testedAt.formatted(date:.abbreviated,time:.shortened)
        return value+" · "+(current(result,invalidatedAt:invalidatedAt,now:now) ? "测试于 ":"历史结果 · ")+stamp
    }
}
