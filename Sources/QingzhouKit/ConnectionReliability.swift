import Foundation

public enum SelectionVerification: Equatable, Sendable { case verified, unconfirmed, failed }

// 切换验收必须验证目标出口；启动时允许网站探测降级的策略不能用于确认切换成功。
public enum SelectionConnectivityPolicy {
    public static func evaluate(_ results: [ConnectivityResult], requiresNode: Bool) -> SelectionVerification {
        guard results.count == 3 else { return .unconfirmed }
        if results.contains(where: { $0.status == .failed && ["鉴权", "取消", "选择未生效"].contains($0.category) }) { return .failed }
        let target = results[requiresNode ? 1 : 0]
        if target.status == .passed { return .verified }
        if target.status == .pending || target.status == .notApplicable { return .unconfirmed }
        return ["超时", "无法确定", "控制接口", "控制接口响应格式", "控制接口缺少实际节点", "控制接口节点格式", "节点测速响应格式"].contains(target.category) ? .unconfirmed : .failed
    }
}

// 各出口分别累计明确失败，规则中的健康节点不能掩盖默认出口故障。
public struct ExitHealthTracker {
    private var counters: [UUID: HealthFailureCounter] = [:]
    public init() {}
    public mutating func update(_ id: UUID, status: ProbeStatus) -> Bool {
        var counter = counters[id] ?? HealthFailureCounter()
        let failed = counter.update([status])
        counters[id] = counter
        return failed
    }
    public mutating func retain(_ ids: Set<UUID>) { counters = counters.filter { ids.contains($0.key) } }
}
