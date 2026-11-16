import Foundation

// 整机保护不依赖系统扩展；仅接受能够明确固定传输协议的节点。
public enum ClaudePFPolicy {
    public static let version = 2

    public static func endpoint(_ node: Node) throws -> ClaudeNetworkEndpoint {
        guard DisconnectProtectionPolicy.publicEndpoint(node.server), !node.insecure,
              (1...65535).contains(node.port), node.kind != .shadowsocks else {
            throw ProxyError("整机保护需要固定公网 IP、有效端口及已核验的 TLS 节点；暂不支持 Shadowsocks")
        }
        return ClaudeNetworkEndpoint(address: node.server, port: UInt16(node.port),
            transport: node.kind == .hysteria2 ? .udp : .tcp)
    }

    public static func rules(endpoint: ClaudeNetworkEndpoint, tunnel: String?) throws -> String {
        guard DisconnectProtectionPolicy.publicEndpoint(endpoint.address), endpoint.port > 0,
              endpoint.transport == .tcp || endpoint.transport == .udp else {
            throw ProxyError("整机保护出口无效")
        }
        if let tunnel {
            guard tunnel.range(of: "^utun[0-9]{1,5}$", options: .regularExpression) != nil else {
                throw ProxyError("整机保护隧道接口无效")
            }
        }
        let scope = tunnel.map { " on ! " + $0 } ?? ""
        let family = endpoint.address.contains(":") ? "inet6" : "inet"
        let proto = endpoint.transport.rawValue
        let otherProtocols = (1...255).filter { $0 != (proto == "tcp" ? 6 : 17) && $0 != (family == "inet" ? 58 : 1) }.map(String.init).joined(separator: ", ")
        let nonUDP = (1...255).filter { $0 != 17 && $0 != 58 }.map(String.init).joined(separator: ", ")
        let nonICMP6 = (1...255).filter { $0 != 58 && $0 != 1 }.map(String.init).joined(separator: ", ")
        let otherICMP6 = (0...255).filter { ![133, 134, 135, 136].contains($0) }.map(String.init).joined(separator: ", ")
        // 全部规则均为拒绝规则，必要基础流量不会绕过其他防火墙的限制。
        var rules = "table <qz_disconnect_allowed> { 127.0.0.0/8, ::1/128, 255.255.255.255/32, fe80::/10, ff02::/16, \(endpoint.address)/\(family == "inet" ? 32 : 128) }\n"
        for af in ["inet", "inet6"] {
            rules += "block drop out quick\(scope) \(af) from any to ! <qz_disconnect_allowed>\n"
        }
        rules += "block drop out quick\(scope) \(family) proto { \(otherProtocols) } from any to \(endpoint.address)\n"
        rules += "block drop out quick\(scope) \(family) proto \(proto) from any to \(endpoint.address) port != \(endpoint.port)\n"
        // DHCP 仅允许客户端到广播地址的请求，不放行内网 DNS 或网关代理。
        rules += "block drop out quick\(scope) inet proto { \(nonUDP) } from any to 255.255.255.255\n"
        rules += "block drop out quick\(scope) inet proto udp from any port != 68 to 255.255.255.255\n"
        rules += "block drop out quick\(scope) inet proto udp from any to 255.255.255.255 port != 67\n"
        // IPv6 链路只允许邻居发现与路由发现；不开放 UDP、DNS 或链路本地转发服务。
        rules += "block drop out quick\(scope) inet6 proto { \(nonICMP6) } from any to { fe80::/10, ff02::/16 }\n"
        rules += "block drop out quick\(scope) inet6 proto ipv6-icmp from any to { fe80::/10, ff02::/16 } icmp6-type { \(otherICMP6) }\n"
        return rules
    }
}
