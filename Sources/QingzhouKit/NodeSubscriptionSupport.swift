import Foundation

public struct ManualNodeMatch: Identifiable, Sendable {
    public let manual: Node
    public let incoming: Node
    public var id: UUID { manual.id }
}

public enum NodeSubscriptionSupport {
    // 端点匹配只生成建议，必须由用户逐项确认，歧义项不允许自动迁移。
    public static func matches(state: AppState, incoming: [Node]) -> [ManualNodeMatch] {
        let manual = Dictionary(grouping: state.nodes.filter { $0.subscriptionID == nil }, by: SubscriptionMatching.endpoint)
        let fresh = Dictionary(grouping: incoming, by: SubscriptionMatching.endpoint)
        return incoming.compactMap { node in
            let key = SubscriptionMatching.endpoint(node)
            guard let candidates = manual[key], candidates.count == 1, fresh[key]?.count == 1 else { return nil }
            return ManualNodeMatch(manual: candidates[0], incoming: node)
        }
    }
    public static func source(_ node: Node, state: AppState) -> String {
        guard let id = node.subscriptionID else { return "手动添加" }
        return "订阅：" + (state.subscriptions.first { $0.id == id }?.name ?? "来源不可用")
    }
    public static func guidance(_ node: Node, state: AppState) -> String? {
        guard node.subscriptionID == nil, state.nodes.contains(where: {
            $0.subscriptionID != nil && SubscriptionMatching.endpoint($0) == SubscriptionMatching.endpoint(node)
        }) else { return nil }
        return "存在同端点的订阅节点，请检查此手动节点是否仍使用旧凭据；可更新订阅并在预览中确认替换。"
    }
}

public enum NodeDetectionFailure: String, Codable, Sendable {
    case timeout, tls, http, unknown
    public static func classify(_ categories: [String]) -> Self {
        if categories.contains("超时") { return .timeout }
        if categories.contains("TLS") { return .tls }
        if categories.contains("HTTP 响应") { return .http }
        return .unknown
    }
    public var label: String {
        switch self {
        case .timeout: return "连接超时"
        case .tls: return "TLS 检测失败"
        case .http: return "目标 HTTP 响应异常"
        case .unknown: return "检测失败（原因未明）"
        }
    }
}
