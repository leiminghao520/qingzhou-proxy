import Foundation
import Darwin

public enum ConfigBuilder {
    public static func validate(_ rule: RoutingRule) throws {
        if rule.kind == .geoip {guard rule.value.range(of:"^[A-Z]{2}$",options:.regularExpression) != nil else{throw ProxyError("GEOIP 需要两位国家代码")};return}
        if rule.kind == .asn {guard let number=UInt32(rule.value),number>0 else{throw ProxyError("ASN 编号无效")};return}
        if rule.kind == .userAgent {guard !rule.value.isEmpty,rule.value.utf8.count<=512,!rule.value.contains(where:{$0.isNewline}) else{throw ProxyError("User-Agent 规则无效")};return}
        if rule.kind == .match {guard rule.value.isEmpty else {throw ProxyError("MATCH 不接受匹配内容")};return}
        guard !rule.value.isEmpty, rule.value == rule.value.trimmingCharacters(in: .whitespacesAndNewlines) else { throw ProxyError("规则内容不能为空或含首尾空格") }
        if rule.kind == .cidr {
            let parts = rule.value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= 2, let address = parts.first else { throw ProxyError("IP/CIDR 无效") }
            var bytes = [UInt8](repeating: 0, count: 16)
            let family = String(address).withCString {inet_pton(AF_INET, $0, &bytes) == 1 ? AF_INET : inet_pton(AF_INET6, $0, &bytes) == 1 ? AF_INET6 : 0}
            guard family != 0 else { throw ProxyError("IP 地址无效") }
            if parts.count == 2 { guard let n = Int(parts[1]), (0...(family == AF_INET ? 32 : 128)).contains(n) else { throw ProxyError("CIDR 前缀无效") } }
        } else if rule.kind == .keyword {
            guard rule.value.utf8.count<=253,!rule.value.contains(where:{$0.isWhitespace}),rule.value.unicodeScalars.allSatisfy({$0.value>=33 && $0.value<=126}) else {throw ProxyError("域名关键词无效")}
        } else {
            guard rule.value.range(of: #"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil else { throw ProxyError("域名规则无效，请使用 ASCII 域名") }
        }
    }
    public static func coreCondition(_ rule:RoutingRule,state:AppState) throws -> [String:Any] {
        if rule.kind == .geoip || rule.kind == .asn {
            let key=(rule.kind == .geoip ? "GEOIP:":"IP-ASN:")+rule.value
            guard let entries=state.shadowrocket?.assets[key],!entries.isEmpty else{throw ProxyError("地理或 ASN 规则资产缺失")}
            return ["ip_cidr":entries]
        }
        guard rule.kind != .userAgent else{throw ProxyError("User-Agent 必须由 HTTP 兼容层处理")}
        return RuleEvaluator.condition(rule)
    }
    public static func outbound(_ node: Node, credentials: CredentialStore) throws -> [String: Any] {
        let secret = try credentials.get(node.credentialRef)
        let p = node.parameters
        var o: [String:Any] = ["type":node.kind.rawValue,"tag":"proxy","server":node.server,"server_port":node.port]
        switch node.kind {
        case .hysteria2:
            o["password"] = secret
            if let ports = p["mport"] { o.removeValue(forKey: "server_port"); o["server_ports"] = ports.components(separatedBy: ",").map { $0.contains("-") ? $0.replacingOccurrences(of: "-", with: ":") : $0 + ":" + $0 } }
            if p["obfs"] != nil { o["obfs"] = ["type":"salamander","password":try credentials.get(node.credentialRef + ".obfs")] }
            for (key,target) in [("upmbps","up_mbps"),("downmbps","down_mbps")] { if let value = p[key], let n = Int(value) { o[target] = n } }
        case .shadowsocks: o["method"] = p["method"]; o["password"] = secret
        case .trojan: o["password"] = secret
        case .vless:
            o["uuid"] = secret; if let flow = p["flow"] { o["flow"] = flow }
            if p["type"] == "ws" { var ws: [String:Any] = ["type":"ws","path":p["path"] ?? "/"]; if let host = p["host"] { ws["headers"] = ["Host":host] }; o["transport"] = ws }
        }
        let security = p["security"] ?? "none"
        if node.kind == .trojan || node.kind == .hysteria2 || security == "tls" || security == "reality" {
            var tls: [String:Any] = ["enabled":true,"server_name":p["sni"] ?? node.server,"insecure":node.insecure]
            if let alpn = p["alpn"] { tls["alpn"] = alpn.components(separatedBy: ",") }
            if let fp = p["fp"] { tls["utls"] = ["enabled":true,"fingerprint":fp] }
            if security == "reality" { tls["reality"] = ["enabled":true,"public_key":p["pbk"] ?? "","short_id":p["sid"] ?? ""]; if p["fp"] == nil { tls["utls"] = ["enabled":true,"fingerprint":"chrome"] } }
            o["tls"] = tls
        }
        return o
    }
    public static func build(node: Node, state: AppState, credentials: CredentialStore) throws -> Data {
        guard (1024...65535).contains(state.listenPort) else { throw ProxyError("监听端口必须为 1024–65535") }
        var rules: [[String:Any]] = []
        if state.rulesEnabled {
            rules.append(["ip_is_private":true,"action":"route","outbound":"direct"])
            rules.append(["domain":["localhost"],"action":"route","outbound":"direct"])
            for r in state.rules {
                try validate(r)
                if r.kind == .userAgent {continue}
                let key = r.kind == .domain ? "domain" : r.kind == .suffix ? "domain_suffix" : r.kind == .keyword ? "domain_keyword" : "ip_cidr"
                var value: [String:Any] = try coreCondition(r,state:state)
                if r.action == .reject { value["action"] = "reject" } else { value["action"] = "route"; value["outbound"] = r.action.rawValue }
                rules.append(value)
            }
        }
        var config: [String:Any] = ["log":["level":"info","timestamp":true],"inbounds":[["type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":state.listenPort,"set_system_proxy":false]],"outbounds":[try outbound(node, credentials: credentials),["type":"direct","tag":"direct"]],"route":["rules":rules,"final":"proxy","default_domain_resolver":"local"],"dns":["servers":[["type":"local","tag":"local"]],"final":"local"]]
        NetworkPolicy.apply(&config,state:state)
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted,.sortedKeys])
    }
}
