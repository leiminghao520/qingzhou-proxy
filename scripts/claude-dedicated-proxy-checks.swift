import Foundation
import QingzhouKit

@main struct Checks {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool) { checks += 1; precondition(condition) }
        let credentials = MemoryCredentials()
        var node = Node(name: "隔离", kind: .trojan, server: "203.0.113.10", port: 443)
        try credentials.set("fixture", for: node.credentialRef)
        var configurations: [Data] = []
        for kind in [ProxyKind.trojan, .hysteria2, .vless] {
            node.kind = kind
            node.parameters = kind == .vless ? ["security": "tls"] : [:]
            let data = try ClaudeDedicatedProxy.configuration(node: node, credentials: credentials)
            configurations.append(data)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let outbounds = object["outbounds"] as! [[String: Any]]
            check(outbounds.count == 1)
            check(outbounds[0]["server"] as? String == node.server)
            check(outbounds[0]["server_port"] as? Int == 443)
            check(outbounds[0]["tls"] != nil)
            let inbound = (object["inbounds"] as! [[String: Any]])[0]
            check(inbound["listen"] as? String == "127.0.0.1")
            check(inbound["listen_port"] as? Int == 17891)
            check(inbound["set_system_proxy"] as? Bool == false)
            let route = object["route"] as! [String: Any]
            check(route["final"] as? String == "claude-fixed")
            check(object["experimental"] == nil)
            let servers = (object["dns"] as! [String: Any])["servers"] as! [[String: Any]]
            check(servers.count == 1 && servers[0]["detour"] as? String == "claude-fixed")
        }
        func rejects(_ candidate: Node) {
            do { _ = try ClaudeDedicatedProxy.configuration(node: candidate, credentials: credentials); preconditionFailure("无效节点必须拒绝") }
            catch { checks += 1 }
        }
        node.parameters = [:]; rejects(node)
        node.parameters = ["security": "tls", "insecure": "1"]; rejects(node)
        node.kind = .shadowsocks; rejects(node)
        node.kind = .hysteria2; node.parameters = ["mport": "443,8443"]; rejects(node)
        node.parameters = [:]; node.server = "proxy.example.com"; rejects(node)
        node.server = "127.0.0.1"; rejects(node)
        for (index, data) in configurations.enumerated() {
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("config-\(index).json"))
        }
        print("RESULT dedicated_proxy_assertions=\(checks) failures=0 networkWrites=0")
    }
}
