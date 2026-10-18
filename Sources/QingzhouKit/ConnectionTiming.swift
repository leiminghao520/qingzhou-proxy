import Foundation

public struct ConnectionStageTiming: Codable, Sendable, Equatable {
    public let stage: String
    public let milliseconds: Int
    public let succeeded: Bool
    public init(stage: String, milliseconds: Int, succeeded: Bool) {
        self.stage = stage; self.milliseconds = milliseconds; self.succeeded = succeeded
    }
    public var summary: String {"连接计时 stage=\(stage) elapsedMs=\(milliseconds) result=\(succeeded ? "通过" : "失败")"}
}

// 每个连接尝试独立计时，使用单调时钟，不受系统时间校准影响。
public final class ConnectionTiming {
    private var stage: String?
    private var began: UInt64 = 0
    public private(set) var samples: [ConnectionStageTiming] = []
    public init() {}
    public func begin(_ next: String) {
        finish()
        stage = next; began = DispatchTime.now().uptimeNanoseconds
    }
    public func finish(succeeded: Bool = true) {
        guard let stage else { return }
        let elapsed = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        samples.append(ConnectionStageTiming(stage: stage, milliseconds: Int(min(elapsed, UInt64(Int.max))), succeeded: succeeded))
        self.stage = nil
    }
}
