import Foundation

// 只标记网络尚未就绪；配置错误、外部接管和所有权冲突不能据此重试。
public struct NetworkEnvironmentNotReady: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// 等待覆盖后台唤醒到用户唤醒的窗口；次数有限，不修改原来的安全前置条件。
public struct NetworkResumeBackoff {
    public private(set) var attempts = 0
    public init() {}
    // 已授权会话的恢复没有总次数上限，长断网后按三十秒低频复查；首次准备仍有独立有限预算。
    public mutating func nextRecoveryDelay() -> TimeInterval {
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30, 30]
        let delay = delays[min(attempts, delays.count - 1)]
        attempts = min(attempts + 1, 1_000_000)
        return delay
    }
    public mutating func nextDelay() -> TimeInterval? {
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30, 30]
        guard attempts < delays.count else { return nil }
        defer { attempts += 1 }
        return delays[attempts]
    }
}

@MainActor public enum NetworkPreparationRetry {
    // 操作自身必须完成回滚才抛出暂态错误；每次重试重新执行整条准备和验收流程。
    public static func run(operation:() async throws -> Void,shouldContinue:() -> Bool,
                           wait:(TimeInterval) async throws -> Void) async throws {
        var backoff=NetworkResumeBackoff()
        while true {
            try Task.checkCancellation()
            guard shouldContinue() else {throw CancellationError()}
            do {try await operation();return}
            catch let error as NetworkEnvironmentNotReady {
                guard let delay=backoff.nextDelay() else {throw error}
                try await wait(delay)
            }
        }
    }
}

// 企业客户端强制接管公网时退出竞争，和短暂网络未就绪分开处理。
public struct NetworkCaptureConflict:Error,LocalizedError,Sendable {
    public let message:String
    public init(_ message:String){self.message=message}
    public var errorDescription:String? {message}
}
