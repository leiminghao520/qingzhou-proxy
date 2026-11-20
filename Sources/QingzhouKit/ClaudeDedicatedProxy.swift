import Foundation

// 专用入口不经过普通分流配置，避免订阅、策略组或 DIRECT 回退改变 Claude 出口。
public enum ClaudeDedicatedProxy {
    public static let port = 17891
    public static let executableName = "QingzhouClaudeCore"
    public static let signingIdentifier = "cn.qingzhou.proxy.claude-core"

    public static func endpoint(_ node: Node) throws -> ClaudeNetworkEndpoint {
        let endpoint = try ClaudePFPolicy.endpoint(node)
        guard node.parameters["mport"] == nil,
              node.kind != .vless || ["tls", "reality"].contains(node.parameters["security"] ?? "") else {
            throw ProxyError("Claude 专用代理要求单个固定端口和已启用的 TLS，不支持跳跃端口或明文 VLESS")
        }
        return endpoint
    }

    public static func configuration(node: Node, credentials: CredentialStore) throws -> Data {
        _ = try endpoint(node)
        var outbound = try ConfigBuilder.outbound(node, credentials: credentials)
        outbound["tag"] = "claude-fixed"
        let object: [String: Any] = [
            "log": ["disabled": true],
            "inbounds": [["type": "mixed", "tag": "claude-local", "listen": "127.0.0.1", "listen_port": port, "set_system_proxy": false]],
            "outbounds": [outbound],
            "dns": ["servers": [["type": "https", "tag": "claude-dns", "server": "1.1.1.1", "path": "/dns-query", "detour": "claude-fixed", "tls": ["enabled": true, "server_name": "cloudflare-dns.com"]]], "final": "claude-dns"],
            "route": ["default_domain_resolver": "claude-dns", "final": "claude-fixed", "rules": [["protocol": "dns", "action": "hijack-dns"]]]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }
}
