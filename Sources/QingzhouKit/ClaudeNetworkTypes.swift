import Foundation
import Darwin

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
