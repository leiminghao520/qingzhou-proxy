import Foundation

// 指纹用于配置匹配，端点只能在两侧唯一时用于个人信息继承。
public struct SubscriptionMatching: Sendable {
    public let previousByIncomingID: [UUID: Node]
    public let ambiguousIncomingIDs: Set<UUID>
    public static func endpoint(_ node: Node) -> String {
        "\(node.kind.rawValue)|\(node.server.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))|\(node.port)"
    }
    public init(old: [Node], incoming: [Node]) {
        let oldEndpoints=Dictionary(grouping:old,by:Self.endpoint)
        let newEndpoints=Dictionary(grouping:incoming,by:Self.endpoint)
        let fingerprints=Dictionary(grouping:old,by:{$0.fingerprint})
        var matches:[UUID:Node]=[:],ambiguous=Set<UUID>()
        for node in incoming {
            if let exact=fingerprints[node.fingerprint],exact.count==1 {matches[node.id]=exact[0]}
            else if let before=oldEndpoints[Self.endpoint(node)],before.count==1,newEndpoints[Self.endpoint(node)]?.count==1 {matches[node.id]=before[0]}
            else if oldEndpoints[Self.endpoint(node)] != nil {ambiguous.insert(node.id)}
        }
        previousByIncomingID=matches;ambiguousIncomingIDs=ambiguous
    }
}
