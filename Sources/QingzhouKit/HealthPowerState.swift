import Foundation

public enum HealthPowerEvent: Sendable {
    case willSleep, didWake, screensSleep, screensWake
}

// 后台维护唤醒不能作为节点失效证据；只有系统和屏幕均恢复后才重新开始健康检查。
public struct HealthPowerState {
    public private(set) var systemSleeping = false
    public private(set) var screensSleeping = false
    public private(set) var generation = UUID()
    public private(set) var readyAt: TimeInterval = 0
    public init() {}
    public var suspended: Bool { systemSleeping || screensSleeping }
    @discardableResult public mutating func receive(_ event: HealthPowerEvent, uptime: TimeInterval) -> Bool {
        let before = (systemSleeping, screensSleeping)
        let wasSuspended = suspended
        switch event {
        case .willSleep: systemSleeping = true; screensSleeping = true
        case .didWake: systemSleeping = false
        case .screensSleep: screensSleeping = true
        case .screensWake: screensSleeping = false
        }
        guard before.0 != systemSleeping || before.1 != screensSleeping else { return false }
        generation = UUID()
        if wasSuspended && !suspended { readyAt = uptime + 15 }
        return true
    }
    public func canProbe(uptime: TimeInterval) -> Bool { !suspended && uptime >= readyAt }
    public func remaining(uptime: TimeInterval) -> TimeInterval { max(0, readyAt - uptime) }
}
