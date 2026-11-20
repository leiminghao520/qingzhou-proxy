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

    public static func rules(endpoint: ClaudeNetworkEndpoint, tunnel: String?, exceptions: [ClaudeBypassException] = []) throws -> String {
        guard DisconnectProtectionPolicy.publicEndpoint(endpoint.address), endpoint.port > 0,
              endpoint.transport == .tcp || endpoint.transport == .udp else {
            throw ProxyError("整机保护出口无效")
        }
        if let tunnel {
            guard tunnel.range(of: "^utun[0-9]{1,5}$", options: .regularExpression) != nil else {
                throw ProxyError("整机保护隧道接口无效")
            }
        }
        let exceptions = try ClaudeBypassPolicy.normalized(exceptions)
        let scope = tunnel.map { " on ! " + $0 } ?? ""
        let family = endpoint.address.contains(":") ? "inet6" : "inet"
        let proto = endpoint.transport.rawValue
        let otherProtocols = (1...255).filter { $0 != (proto == "tcp" ? 6 : 17) && $0 != (family == "inet" ? 58 : 1) }.map(String.init).joined(separator: ", ")
        let nonUDP = (1...255).filter { $0 != 17 && $0 != 58 }.map(String.init).joined(separator: ", ")
        let nonICMP6 = (1...255).filter { $0 != 58 && $0 != 1 }.map(String.init).joined(separator: ", ")
        let otherICMP6 = (0...255).filter { ![133, 134, 135, 136].contains($0) }.map(String.init).joined(separator: ", ")
        let linkPrefixes = [IPPrefix("fe80::/10")!, IPPrefix("ff02::/16")!]
        let linkExceptions = exceptions.filter { item in linkPrefixes.contains { $0.overlaps(IPPrefix(item.destination)!) } }
        var linkTargets = "{ fe80::/10, ff02::/16 }"
        var linkTable = ""
        if !linkExceptions.isEmpty {
            let remainder = try CaptureRoutePlan(exclusions: linkExceptions.map(\.destination))
            guard remainder.fallbackReason == nil else { throw ProxyError("链路例外切分超过预算") }
            let fragments = remainder.prefixes.compactMap(IPPrefix.init).flatMap { prefix in
                linkPrefixes.compactMap { base -> String? in
                    if base.contains(prefix) { return prefix.text }
                    if prefix.contains(base) { return base.text }
                    return nil
                }
            }
            linkTargets = fragments.isEmpty ? "" : "<qz_restricted_link>"
            if !fragments.isEmpty { linkTable = "table <qz_restricted_link> { " + fragments.joined(separator: ", ") + " }\n" }
        }
        let broadcastException = exceptions.contains { IPPrefix($0.destination)!.contains(IPPrefix("255.255.255.255/32")!) }
        // 全部规则均为拒绝规则，必要基础流量不会绕过其他防火墙的限制。
        var rules = "table <qz_disconnect_allowed> { 127.0.0.0/8, ::1/128, 255.255.255.255/32, fe80::/10, ff02::/16, \(endpoint.address)/\(family == "inet" ? 32 : 128) }\n"
        if !exceptions.isEmpty {
            rules = rules.replacingOccurrences(of: " }\n", with: ", " + Array(Set(exceptions.map(\.destination))).sorted().joined(separator: ", ") + " }\n")
        }
        rules += linkTable
        for af in ["inet", "inet6"] {
            rules += "block drop out quick\(scope) \(af) from any to ! <qz_disconnect_allowed>\n"
        }
        rules += "block drop out quick\(scope) \(family) proto { \(otherProtocols) } from any to \(endpoint.address)\n"
        rules += "block drop out quick\(scope) \(family) proto \(proto) from any to \(endpoint.address) port != \(endpoint.port)\n"
        // DHCP 仅允许客户端到广播地址的请求，不放行内网 DNS 或网关代理。
        if !broadcastException {
            rules += "block drop out quick\(scope) inet proto { \(nonUDP) } from any to 255.255.255.255\n"
            rules += "block drop out quick\(scope) inet proto udp from any port != 68 to 255.255.255.255\n"
            rules += "block drop out quick\(scope) inet proto udp from any to 255.255.255.255 port != 67\n"
        }
        // 已声明例外由下方接口和端口约束处理，其余链路地址仍仅允许基础发现。
        if !linkTargets.isEmpty {
            rules += "block drop out quick\(scope) inet6 proto { \(nonICMP6) } from any to \(linkTargets)\n"
            rules += "block drop out quick\(scope) inet6 proto ipv6-icmp from any to \(linkTargets) icmp6-type { \(otherICMP6) }\n"
        }
        for item in exceptions {
            let af = item.destination.contains(":") ? "inet6" : "inet"
            rules += "block drop out quick on ! \(item.interface) \(af) from any to \(item.destination)\n"
        }
        // 同地址多个控制端口取并集，不能让其中一条拒绝规则覆盖另一条合法连接。
        let restricted = Dictionary(grouping: exceptions.filter { $0.dnsOnly || $0.vpnControl == true }, by: \.destination)
        for destination in restricted.keys.sorted() {
            let group = restricted[destination]!
            if exceptions.contains(where: { !$0.dnsOnly && $0.vpnControl != true && IPPrefix($0.destination)!.contains(IPPrefix(destination)!) }) { continue }
            let af = destination.contains(":") ? "inet6" : "inet"
            let others = (1...255).filter { ![6, 17, af == "inet" ? 58 : 1].contains($0) }.map(String.init).joined(separator: ", ")
            rules += "block drop out quick \(af) proto { \(others) } from any to \(destination)\n"
            for transport in [ClaudeFlowTransport.tcp, .udp] {
                let ports = Set(group.compactMap { item -> UInt16? in
                    if item.dnsOnly { return 53 }
                    return item.controlTransport == transport ? item.controlPort : nil
                }).sorted()
                if ports.isEmpty {
                    rules += "block drop out quick \(af) proto \(transport.rawValue) from any to \(destination)\n"
                } else {
                    if ports.count == 1 {
                        rules += "block drop out quick \(af) proto \(transport.rawValue) from any to \(destination) port != \(ports[0])\n"
                    } else {
                        // PF 对端口列表逐项展开，不能用多个不等式表达并集的补集。
                        var denied: [String] = []
                        var start = 0
                        for port in ports.map(Int.init) {
                            if start < port { denied.append(start == port - 1 ? String(start) : "\(start):\(port - 1)") }
                            start = port + 1
                        }
                        if start <= 65535 { denied.append(start == 65535 ? "65535" : "\(start):65535") }
                        if !denied.isEmpty {
                            rules += "block drop out quick \(af) proto \(transport.rawValue) from any to \(destination) port { " + denied.joined(separator: ", ") + " }\n"
                        }
                    }
                }
            }
        }
        return rules
    }
}
