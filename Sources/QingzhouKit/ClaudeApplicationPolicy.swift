import Foundation
import Darwin

public enum ClaudeFlowOwner: String, Codable, Sendable {
    case protectedApplication
    case dedicatedProxy
    case unrelatedApplication
    case unresolved
}

public enum ClaudeFlowTransport: String, Codable, Sendable {
    case tcp
    case udp
    case unsupported
}

public struct ClaudeNetworkEndpoint: Codable, Equatable, Sendable {
    public var address: String
    public var port: UInt16
    public var transport: ClaudeFlowTransport

    public init(address: String, port: UInt16, transport: ClaudeFlowTransport) {
        self.address = address
        self.port = port
        self.transport = transport
    }

    private static func bytes(_ address: String) -> Data? {
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: ipv4) { Data($0) }
        }
        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: ipv6) { Data($0) }
        }
        return nil
    }

    public func matches(_ other: Self) -> Bool {
        guard port != 0, port == other.port, transport == other.transport,
              let left = Self.bytes(address), let right = Self.bytes(other.address) else { return false }
        return left == right
    }

    public var isExplicitLoopback: Bool {
        ["127.0.0.1", "::1"].contains { Self.bytes($0) == Self.bytes(address) }
    }
}

public struct ClaudeSignedApplication: Codable, Equatable, Sendable {
    public var identifier: String
    public var designatedRequirement: String
    public var owner: ClaudeFlowOwner

    public init(identifier: String, designatedRequirement: String, owner: ClaudeFlowOwner) {
        self.identifier = identifier
        self.designatedRequirement = designatedRequirement
        self.owner = owner
    }
}

// 此策略只决定流量裁决，不把进程发现、子进程覆盖或系统扩展存活当成已验证事实。
public struct ClaudeApplicationPolicy: Codable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var applications: [ClaudeSignedApplication]
    public var localProxyPort: UInt16
    public var upstream: ClaudeNetworkEndpoint
    public var proxyAccessEnabled: Bool

    public init(applications: [ClaudeSignedApplication], localProxyPort: UInt16,
                upstream: ClaudeNetworkEndpoint, proxyAccessEnabled: Bool = false) {
        version = Self.currentVersion
        self.applications = applications
        self.localProxyPort = localProxyPort
        self.upstream = upstream
        self.proxyAccessEnabled = proxyAccessEnabled
    }

    public func validate() throws {
        guard version == Self.currentVersion, localProxyPort > 0, upstream.port > 0,
              upstream.transport != .unsupported,
              DisconnectProtectionPolicy.publicEndpoint(upstream.address) else {
            throw ProxyError("应用过滤策略版本、端口或固定公网出口无效")
        }
        guard !applications.isEmpty, applications.count <= 128,
              applications.contains(where: { $0.owner == .protectedApplication }),
              applications.filter({ $0.owner == .dedicatedProxy }).count == 1,
              Set(applications.map(\.identifier)).count == applications.count,
              applications.allSatisfy({ !$0.identifier.isEmpty && !$0.designatedRequirement.isEmpty
                  && ($0.owner == .protectedApplication || $0.owner == .dedicatedProxy) }) else {
            throw ProxyError("应用过滤策略缺少明确的签名身份或专用代理身份")
        }
    }

    public func permits(owner: ClaudeFlowOwner, destination: ClaudeNetworkEndpoint?) -> Bool {
        guard (try? validate()) != nil else { return false }
        switch owner {
        case .unrelatedApplication:
            return true
        case .unresolved:
            return false
        case .protectedApplication:
            guard proxyAccessEnabled, let destination else { return false }
            return destination.transport == .tcp && destination.port == localProxyPort
                && destination.isExplicitLoopback
        case .dedicatedProxy:
            guard proxyAccessEnabled, let destination else { return false }
            return upstream.matches(destination)
        }
    }
}
