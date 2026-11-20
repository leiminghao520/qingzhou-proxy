import Foundation

// 独立恢复意图必须先落盘；后台启动只恢复此事务，不能重建断线保护。
public struct NormalNetworkRecovery: Codable, Sendable {
    public var id: UUID
    public var phase: String
    public var warning: String?
    public init(id: UUID = UUID(), phase: String, warning: String? = nil) {
        self.id = id
        self.phase = phase
        self.warning = warning
    }
}
