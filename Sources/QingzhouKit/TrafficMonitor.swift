import Foundation

public struct RuntimeMonitorState: Equatable, Sendable {
    public enum Channel: Sendable { case pending, available, unavailable }
    public var active = false
    public var traffic: Channel = .pending
    public var connections: Channel = .pending
    public var health: String?
    public init() {}
    public var summary: String {
        guard active else { return "未连接" }
        var issues: [String] = []
        if traffic == .unavailable { issues.append("流量通道暂不可用，正在重连") }
        if connections == .unavailable { issues.append("连接列表暂不可用") }
        if let health { issues.append(health) }
        if !issues.isEmpty { return issues.joined(separator: "；") }
        return traffic == .pending || connections == .pending ? "监控连接中" : "实时监控"
    }
    public func rateLabel(_ value: Int64, paused: Bool, format: (Int64) -> String) -> String {
        if active && (traffic != .available || paused) { return "不可用" }
        return format(value)
    }
}

// 重连属于调用任务；取消等待或消费流时不会创建脱离连接生命周期的新任务。
@MainActor public enum TrafficMonitor {
    public static func run(
        connect: () async throws -> AsyncThrowingStream<TransferRate, Error>,
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        receive: (TransferRate) -> Void,
        disconnected: () -> Void
    ) async {
        var attempt = 0
        let delays: [UInt64] = [1, 2, 4, 8, 16, 30]
        while !Task.isCancelled {
            do {
                let stream = try await connect()
                for try await rate in stream {
                    try Task.checkCancellation()
                    attempt = 0
                    receive(rate)
                }
            } catch {
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled else { return }
            disconnected()
            let delay = delays[min(attempt, delays.count - 1)]
            attempt = min(attempt + 1, delays.count - 1)
            do {
                try await sleep(delay * 1_000_000_000)
                try Task.checkCancellation()
            } catch { return }
        }
    }
}
