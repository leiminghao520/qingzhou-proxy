import Foundation
import CryptoKit

public enum ProxyKind: String, Codable, CaseIterable, Sendable { case hysteria2, shadowsocks, trojan, vless }
public struct ProxyError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct Node: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProxyKind
    public var server: String
    public var port: Int
    public var parameters: [String: String]
    public var credentialRef: String
    public var subscriptionID: UUID?
    public init(id: UUID = UUID(), name: String, kind: ProxyKind, server: String, port: Int, parameters: [String:String] = [:], credentialRef: String = UUID().uuidString, subscriptionID: UUID? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.server = server; self.port = port; self.parameters = parameters; self.credentialRef = credentialRef; self.subscriptionID = subscriptionID
    }
    public var fingerprint: String {
        let value = "\(kind.rawValue)|\(server.lowercased())|\(port)|" + parameters.sorted(by: {$0.key < $1.key}).map {"\($0.key)=\($0.value)"}.joined(separator: "&")
        return SHA256.hash(data: Data(value.utf8)).map {String(format: "%02x", $0)}.joined()
    }
    public var insecure: Bool { parameters["insecure"] == "1" }
}
public struct Candidate: Sendable {
    public var node: Node
    public var secret: String
    public var obfsSecret: String?
    public init(node: Node, secret: String, obfsSecret: String? = nil) { self.node = node; self.secret = secret; self.obfsSecret = obfsSecret }
}
public struct Subscription: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceRef: String
    public var updatedAt: Date
    public init(id: UUID = UUID(), name: String, sourceRef: String = UUID().uuidString, updatedAt: Date = Date()) { self.id = id; self.name = name; self.sourceRef = sourceRef; self.updatedAt = updatedAt }
}
public enum RuleKind: String, Codable, CaseIterable, Sendable { case domain, suffix, cidr }
public enum RuleAction: String, Codable, CaseIterable, Sendable { case direct, proxy, reject }
public struct RoutingRule: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: RuleKind
    public var value: String
    public var action: RuleAction
    public init(kind: RuleKind, value: String, action: RuleAction) { self.kind = kind; self.value = value; self.action = action }
}
public struct AppState: Codable, Sendable {
    public var schemaVersion = 1
    public var nodes: [Node] = []
    public var subscriptions: [Subscription] = []
    public var rules: [RoutingRule] = []
    public var rulesEnabled = true
    public var listenPort = 7890
    public var selectedID: UUID?
    public init() {}
}
public protocol CredentialStore: AnyObject {
    func get(_ ref: String) throws -> String
    func set(_ value: String, for ref: String) throws
    func remove(_ ref: String) throws
}
public final class MemoryCredentials: CredentialStore {
    private var values: [String:String] = [:]
    public init() {}
    public func get(_ ref: String) throws -> String { guard let v = values[ref] else { throw ProxyError("凭据不存在，请重新导入节点") }; return v }
    public func set(_ value: String, for ref: String) throws { values[ref] = value }
    public func remove(_ ref: String) throws { values.removeValue(forKey: ref) }
}
public enum Redactor {
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var value = text
        for secret in secrets.sorted(by: {$0.count > $1.count}) where !secret.isEmpty { value = value.replacingOccurrences(of: secret, with: "[已隐藏]") }
        let patterns = [#"(?i)(?:https?|hy2|hysteria2|ss|trojan|vless)://[^\s\"<>]+"#, #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, #"(?i)(password|token|authorization|auth)\s*[:=]\s*[^\s,]+"#]
        for p in patterns { value = value.replacingOccurrences(of: p, with: "[已隐藏]", options: .regularExpression) }
        return String(value.prefix(2048))
    }
}
