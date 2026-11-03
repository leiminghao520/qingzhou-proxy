import Foundation

// 同一进程跨重试共享工作池；无法取消的系统解析仍占用原槽位，禁止超时后另起无限线程。
public final class NetworkPreparationPool {
    public static let shared = NetworkPreparationPool()
    private let queue: OperationQueue
    public init(concurrency: Int = 4) {
        queue = OperationQueue(); queue.name = "cn.qingzhou.network-preparation"
        queue.maxConcurrentOperationCount = max(1, min(4, concurrency))
    }
    public func map<Input, Output>(_ inputs: [Input], itemTimeout: TimeInterval? = nil,
                                   totalTimeout: TimeInterval? = nil,
                                   cancelled: @escaping () -> Bool = { false },
                                   prepare: () throws -> Void = {},
                                   operation: @escaping (Input) throws -> Output) throws -> [Output] {
        if cancelled() {throw CancellationError()}
        guard itemTimeout.map({$0>0 && $0.isFinite}) ?? true,
              totalTimeout.map({$0>0 && $0.isFinite}) ?? true else {throw ProxyError("网络准备时间预算无效")}
        guard !inputs.isEmpty else {try prepare();return []}
        let batch = PreparationBatch<Output>(itemTimeout: itemTimeout, totalTimeout: totalTimeout)
        let operations = inputs.enumerated().map { index, input in
            BlockOperation {
                guard !cancelled(),batch.start(index) else { return }
                let result = Result { try operation(input) }
                batch.complete(index, result)
            }
        }
        defer {
            batch.close()
            for operation in operations { operation.cancel() }
        }
        queue.addOperations(operations, waitUntilFinished: false)
        try prepare()
        return try batch.wait(count: inputs.count, cancelled: cancelled)
    }
    public func addresses(_ hosts: [String], itemTimeout: TimeInterval = 3, totalTimeout: TimeInterval = 6,
                          cancelled: @escaping () -> Bool = { false },
                          prepare: () throws -> Void = {},
                          resolver: @escaping (String) throws -> [String] = NetworkInspection.addresses) throws -> [String: [String]] {
        let unique = Array(Set(hosts)).sorted()
        let values = try map(unique, itemTimeout: itemTimeout, totalTimeout: totalTimeout,
                             cancelled: cancelled, prepare: prepare, operation: resolver)
        return Dictionary(uniqueKeysWithValues: zip(unique, values))
    }
}

private final class PreparationBatch<Output> {
    private let condition = NSCondition()
    private let itemTimeout: TimeInterval?
    private let deadline: TimeInterval?
    private var started: [Int: TimeInterval] = [:]
    private var results: [Int: Result<Output, Error>] = [:]
    private var closed = false
    private static var now: TimeInterval {TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000}
    init(itemTimeout: TimeInterval?, totalTimeout: TimeInterval?) {
        self.itemTimeout = itemTimeout
        deadline = totalTimeout.map { Self.now + $0 }
    }
    func start(_ index: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !closed, deadline.map({ Self.now < $0 }) ?? true else { return false }
        started[index] = Self.now; return true
    }
    func complete(_ index: Int, _ result: Result<Output, Error>) {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        if let itemTimeout, let start = started[index], Self.now - start >= itemTimeout {
            results[index] = .failure(ProxyError("网络准备单项超过时间预算，未接管网络"))
        } else { results[index] = result }
        condition.broadcast()
    }
    func close() { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
    func wait(count: Int, cancelled: () -> Bool) throws -> [Output] {
        condition.lock(); defer { condition.unlock() }
        while true {
            if cancelled() { throw CancellationError() }
            let now = Self.now
            if let deadline, now >= deadline { throw ProxyError("网络准备超过总时间预算，未接管网络") }
            if let itemTimeout, started.contains(where: { results[$0.key] == nil && now - $0.value >= itemTimeout }) {
                throw ProxyError("网络准备单项超过时间预算，未接管网络")
            }
            for result in results.values { if case .failure(let error) = result { throw error } }
            if results.count == count { return try (0..<count).map { try results[$0]!.get() } }
            // 短周期检查只用于取消与单调截止时间，不重开解析任务。
            _ = condition.wait(until: Date().addingTimeInterval(0.01))
        }
    }
}
