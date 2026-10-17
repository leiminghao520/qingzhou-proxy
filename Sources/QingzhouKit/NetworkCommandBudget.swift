import Foundation

// 普通系统命令只计算机器唤醒时的运行预算，和 Dispatch 超时计时器使用同一时钟。
// DNS 等调用方显式指定的截止时间仍按原来的总预算执行。
public struct NetworkCommandBudget {
    private let deadline: Date?
    private let uptimeDeadline: TimeInterval
    public init(deadline: Date?, uptime: TimeInterval) {
        self.deadline = deadline
        uptimeDeadline = uptime + 10
    }
    public func remaining(wallTime: Date, uptime: TimeInterval) -> TimeInterval {
        if let deadline { return max(0, deadline.timeIntervalSince(wallTime)) }
        return max(0, uptimeDeadline - uptime)
    }
}
