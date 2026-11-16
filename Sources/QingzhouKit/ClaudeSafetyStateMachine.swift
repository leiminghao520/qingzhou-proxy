import Foundation

public enum ClaudeSafetyPhase: String, Codable, Sendable {
    case off
    case enabling
    case verifying
    case protectedConnected
    case proxyBlocked
    case unconfirmed
    case disabling
    case disabledBlocked
}

// 运行时证据不写入恢复记录，防止重启后用旧的绿色状态替代重新核验。
public struct ClaudeSafetyEvidence: Sendable {
    public var operationID: UUID
    public var configurationVersion: Int
    public var verifiedAt: Date
    public var filterActive: Bool
    public var applicationsCovered: Bool
    public var descendantsCovered: Bool
    public var crashBlockingVerified: Bool
    public var existingConnectionsCovered: Bool
    public var dnsProtected: Bool
    public var ipv6Protected: Bool
    public var proxyReachable: Bool
    public var proxyEndpointOwned: Bool
    public var fixedExitVerified: Bool

    public init(operationID: UUID, configurationVersion: Int, verifiedAt: Date,
                filterActive: Bool, applicationsCovered: Bool, descendantsCovered: Bool,
                crashBlockingVerified: Bool, existingConnectionsCovered: Bool,
                dnsProtected: Bool, ipv6Protected: Bool, proxyReachable: Bool,
                proxyEndpointOwned: Bool, fixedExitVerified: Bool) {
        self.operationID = operationID
        self.configurationVersion = configurationVersion
        self.verifiedAt = verifiedAt
        self.filterActive = filterActive
        self.applicationsCovered = applicationsCovered
        self.descendantsCovered = descendantsCovered
        self.crashBlockingVerified = crashBlockingVerified
        self.existingConnectionsCovered = existingConnectionsCovered
        self.dnsProtected = dnsProtected
        self.ipv6Protected = ipv6Protected
        self.proxyReachable = proxyReachable
        self.proxyEndpointOwned = proxyEndpointOwned
        self.fixedExitVerified = fixedExitVerified
    }

    public func confirmsBarrier(now: Date) -> Bool {
        let age = now.timeIntervalSince(verifiedAt)
        return age >= 0 && age < 15 && filterActive && applicationsCovered && descendantsCovered
            && crashBlockingVerified && existingConnectionsCovered && dnsProtected && ipv6Protected && proxyEndpointOwned
    }
}

public struct ClaudeSafetyOperationRecord: Codable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public var operationID: UUID
    public var phase: ClaudeSafetyPhase
    public var updatedAt: Date
    public var configurationVersion: Int
    public var previous: ClaudeSafetySession
    public var endpoint: ClaudeNetworkEndpoint
    public var lastFailure: String?

    public init(operationID: UUID, updatedAt: Date, previous: ClaudeSafetySession,
                endpoint: ClaudeNetworkEndpoint, configurationVersion: Int) {
        self.operationID = operationID
        phase = .enabling
        self.updatedAt = updatedAt
        self.previous = previous
        self.endpoint = endpoint
        self.configurationVersion = configurationVersion
    }

    public func validate() throws {
        guard version == Self.currentVersion, configurationVersion == ClaudeApplicationPolicy.currentVersion,
              endpoint.port > 0, endpoint.transport != .unsupported,
              DisconnectProtectionPolicy.publicEndpoint(endpoint.address) else {
            throw ProxyError("应用级保护恢复记录版本或出口无效，未覆盖原记录")
        }
    }
}

public struct ClaudeSafetyStateMachine: Sendable {
    public private(set) var record: ClaudeSafetyOperationRecord?
    public private(set) var evidence: ClaudeSafetyEvidence?
    public private(set) var phase: ClaudeSafetyPhase
    private var changing = false

    public init(restoring record: ClaudeSafetyOperationRecord? = nil) throws {
        try record?.validate()
        self.record = record
        // 即使上次正常关闭，也必须重新核验持久拒绝规则，不能从磁盘推断已阻断。
        phase = record == nil ? .off : .unconfirmed
    }

    public mutating func beginEnable(_ next: ClaudeSafetyOperationRecord) throws {
        guard !changing, record == nil || phase == .disabledBlocked else {
            throw ProxyError("已有保护会话或操作正在执行")
        }
        try next.validate()
        // 保留第一份恢复快照，避免再次开启时用已经修改过的设置覆盖它。
        if let record {
            self.record = ClaudeSafetyOperationRecord(operationID: next.operationID, updatedAt: next.updatedAt,
                previous: record.previous, endpoint: next.endpoint, configurationVersion: next.configurationVersion)
        } else {
            record = next
        }
        evidence = nil
        phase = .enabling
        changing = true
    }

    public mutating func receive(_ next: ClaudeSafetyEvidence, now: Date) {
        guard let record, next.operationID == record.operationID,
              next.configurationVersion == record.configurationVersion,
              phase != .disabling, phase != .disabledBlocked else { return }
        if let evidence, next.verifiedAt < evidence.verifiedAt { return }
        evidence = next
        if next.confirmsBarrier(now: now) {
            phase = next.proxyReachable && next.fixedExitVerified ? .protectedConnected : .proxyBlocked
        } else {
            phase = .unconfirmed
        }
        self.record?.phase = phase
        self.record?.updatedAt = now
        changing = false
    }

    public mutating func fail(_ message: String, now: Date) {
        phase = evidence?.confirmsBarrier(now: now) == true ? .proxyBlocked : .unconfirmed
        record?.phase = phase
        record?.lastFailure = Redactor.redact(message)
        record?.updatedAt = now
        changing = false
    }

    public mutating func expire(now: Date) {
        guard evidence != nil, evidence?.confirmsBarrier(now: now) != true else { return }
        evidence = nil
        phase = .unconfirmed
        record?.phase = phase
        record?.updatedAt = now
    }

    public mutating func beginDisable(now: Date) throws {
        guard record != nil, !changing else { throw ProxyError("没有保护会话或操作正在执行") }
        changing = true
        phase = .disabling
        record?.phase = phase
        record?.updatedAt = now
    }

    public mutating func finishDisable(blockVerified: Bool, settingsRestored: Bool, now: Date) {
        guard phase == .disabling else { return }
        evidence = nil
        phase = blockVerified && settingsRestored ? .disabledBlocked : .unconfirmed
        record?.phase = phase
        record?.updatedAt = now
        changing = false
    }
}

public enum ClaudeSafetyOperationStore {
    public static func save(_ record: ClaudeSafetyOperationRecord, to url: URL) throws {
        try record.validate()
        try SecureFile.write(JSONEncoder().encode(record), to: url, durable: true)
    }

    public static func load(from url: URL) throws -> ClaudeSafetyOperationRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0,
              let size = attributes[.size] as? NSNumber, size.intValue <= 65_536 else {
            throw ProxyError("应用级保护恢复记录类型、大小或权限无效")
        }
        let record = try JSONDecoder().decode(ClaudeSafetyOperationRecord.self, from: Data(contentsOf: url))
        try record.validate()
        return record
    }
}
