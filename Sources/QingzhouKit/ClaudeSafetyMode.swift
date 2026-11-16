import Foundation

// 只保存安全模式会改动的设置，恢复时不覆盖节点凭据和其他配置数据。
public struct ClaudeSafetyNetworkSettings: Codable, Sendable {
    public let captureMode: CaptureMode
    public let claudeSafetyMode: Bool?
    public let mode: ProxyMode
    public let dnsPreference: DNSPreference
    public let strictDNS: Bool?
    public let disconnectProtection: Bool?
    public let httpCompatibilityEnabled: Bool
    public let selectedID: UUID?
    public let selectedPolicy: PolicyReference?
    public let ruleFinal: PolicyReference?

    public init(_ state: AppState) {
        captureMode = state.captureMode
        claudeSafetyMode = state.claudeSafetyMode
        mode = state.mode
        dnsPreference = state.dnsPreference
        strictDNS = state.strictDNS
        disconnectProtection = state.disconnectProtection
        httpCompatibilityEnabled = state.httpCompatibilityEnabled
        selectedID = state.selectedID
        selectedPolicy = state.selectedPolicy
        ruleFinal = state.ruleFinal
    }

    public func restoring(_ state: AppState) -> AppState {
        var restored = state
        restored.captureMode = captureMode
        restored.claudeSafetyMode = claudeSafetyMode
        restored.mode = mode
        restored.dnsPreference = dnsPreference
        restored.strictDNS = strictDNS
        restored.disconnectProtection = disconnectProtection
        restored.httpCompatibilityEnabled = httpCompatibilityEnabled
        restored.selectedID = selectedID
        restored.selectedPolicy = selectedPolicy
        restored.ruleFinal = ruleFinal
        return restored
    }
}

public struct ClaudeSafetySession: Codable, Sendable {
    public let previous: ClaudeSafetyNetworkSettings
    public let profileID: UUID?
    public let wasConnected: Bool
    public let nodeID: UUID

    public init(state: AppState, profileID: UUID?, wasConnected: Bool, nodeID: UUID) {
        previous = ClaudeSafetyNetworkSettings(state)
        self.profileID = profileID
        self.wasConnected = wasConnected
        self.nodeID = nodeID
    }
}

public struct ClaudeSafetyPreferences: Codable, Sendable {
    public var preferredNodeID: UUID?
    public var session: ClaudeSafetySession?
    public var proxyPaused: Bool?
    public var policyVersion: Int?
    public var operationID: UUID?
    public var updatedAt: Date?
    public var lastFailure: String?
    public init() {}
}

public enum ClaudeSafetyPolicy {
    public static func candidates(in state: AppState) -> [Node] {
        state.nodes.filter { (try? ClaudePFPolicy.endpoint($0)) != nil }
    }

    public static func configuration(_ state: AppState, nodeID: UUID) throws -> AppState {
        guard candidates(in: state).contains(where: { $0.id == nodeID }) else {
            throw ProxyError("Claude 安全模式需要固定公网 IP 且证书校验未被关闭的节点")
        }
        var configured = state
        configured.selectedPolicy = .node(nodeID)
        configured.selectedID = nodeID
        configured.captureMode = .compatible
        configured.mode = .global
        configured.dnsPreference = .httpsProxy
        configured.strictDNS = true
        configured.disconnectProtection = true
        configured.claudeSafetyMode = true
        configured.httpCompatibilityEnabled = false
        configured.ruleFinal = .selected
        try PolicyValidator.validate(configured)
        return configured
    }

    public static func validateActive(_ state: AppState, session: ClaudeSafetySession) throws {
        guard state.protectsDisconnect, state.claudeSafetyMode == true, state.captureMode == .compatible,
              state.activePolicy == .node(session.nodeID),
              candidates(in: state).contains(where: { $0.id == session.nodeID }) else {
            throw ProxyError("Claude 安全模式设置尚未完成，请重试安全连接或明确解除保护；未建立普通连接")
        }
        try DisconnectProtectionPolicy.validate(state)
    }
}

public enum ClaudeSafetyStore {
    public static func load(from url: URL) throws -> ClaudeSafetyPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return ClaudeSafetyPreferences() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw ProxyError("Claude 安全模式恢复记录权限无效，未覆盖原记录")
        }
        return try JSONDecoder().decode(ClaudeSafetyPreferences.self, from: Data(contentsOf: url))
    }

    public static func save(_ preferences: ClaudeSafetyPreferences, to url: URL) throws {
        try SecureFile.write(JSONEncoder().encode(preferences), to: url, durable: true)
    }
}
