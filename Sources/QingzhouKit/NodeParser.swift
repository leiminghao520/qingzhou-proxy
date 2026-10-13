import Foundation

public enum NodeParser {
    public static func parseList(_ text: String) throws -> [Candidate] {
        let lines = text.components(separatedBy: .newlines).map {$0.trimmingCharacters(in: .whitespacesAndNewlines)}.filter {!$0.isEmpty && !$0.hasPrefix("#")}
        guard !lines.isEmpty else { throw ProxyError("订阅没有节点") }
        guard lines.count <= 2000 else { throw ProxyError("节点数量超过 2000") }
        var result: [Candidate] = []
        for (i, line) in lines.enumerated() {
            do { result.append(try parse(line)) }
            catch { throw ProxyError("第 \(i+1) 行：\(error.localizedDescription)") }
        }
        return result
    }
    private static func decode64(_ text: String) -> String? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s).flatMap {String(data: $0, encoding: .utf8)}
    }
    public static func parse(_ text: String) throws -> Candidate {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 16384, let schemeEnd = raw.range(of: "://") else { throw ProxyError("需要节点分享链接，完整配置文件暂不支持") }
        let scheme = String(raw[..<schemeEnd.lowerBound]).lowercased()
        let kind: ProxyKind
        switch scheme { case "hy2", "hysteria2": kind = .hysteria2; case "ss": kind = .shadowsocks; case "trojan": kind = .trojan; case "vless": kind = .vless; default: throw ProxyError("该节点协议或完整配置格式暂不支持") }
        var uri = raw
        if kind == .shadowsocks {
            let remainder = String(raw[schemeEnd.upperBound...]); let body = String(remainder.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
            if !body.contains("@"), let decoded = decode64(body), decoded.contains("@") {
                let fragment = remainder.contains("#") ? "#" + remainder.components(separatedBy: "#").dropFirst().joined(separator: "#") : ""
                uri = "ss://" + decoded + fragment
            }
        }
        guard let c = URLComponents(string: uri), let host = c.host, !host.isEmpty else { throw ProxyError("节点服务器地址无效") }
        let server = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let port = c.port ?? (kind == .hysteria2 || kind == .trojan ? 443 : nil), (1...65535).contains(port) else { throw ProxyError("节点端口必须为 1–65535") }
        guard c.path.isEmpty || c.path == "/" else { throw ProxyError("节点路径应通过传输参数设置") }
        var p: [String:String] = [:]
        let allowed: Set<String>
        switch kind {
        case .hysteria2: allowed = ["sni","peer","insecure","allowInsecure","obfs","obfs-password","mport","upmbps","downmbps","alpn"]
        case .shadowsocks: allowed = []
        case .trojan: allowed = ["sni","peer","insecure","allowInsecure","security","type","alpn"]
        case .vless: allowed = ["sni","peer","insecure","allowInsecure","security","type","path","host","flow","pbk","sid","fp","alpn","encryption"]
        }
        var obfs: String?
        for item in c.queryItems ?? [] {
            guard allowed.contains(item.name) else { throw ProxyError("含有不支持的节点参数") }
            let key = item.name == "peer" ? "sni" : item.name == "allowInsecure" ? "insecure" : item.name
            guard p[key] == nil, !(key == "obfs-password" && obfs != nil) else { throw ProxyError("节点参数重复") }
            guard let value = item.value, !value.isEmpty else { throw ProxyError("节点参数不能为空") }
            if key == "obfs-password" { obfs = value } else { p[key] = value }
        }
        let user = c.percentEncodedUser?.removingPercentEncoding ?? ""
        let password = c.percentEncodedPassword?.removingPercentEncoding
        var secret = user + (password.map {":" + $0} ?? "")
        guard !secret.isEmpty else { throw ProxyError("节点缺少认证信息") }
        if kind == .shadowsocks {
            let auth = password != nil ? secret : (decode64(user) ?? "")
            guard let colon = auth.firstIndex(of: ":") else { throw ProxyError("SS 认证编码无效") }
            let method = String(auth[..<colon]); secret = String(auth[auth.index(after: colon)...])
            guard ["aes-128-gcm","aes-256-gcm","chacha20-ietf-poly1305"].contains(method), !secret.isEmpty else { throw ProxyError("SS 加密方法暂不支持或密码为空") }
            p["method"] = method
        }
        if let insecure = p["insecure"] {
            guard ["0","1","false","true"].contains(insecure.lowercased()) else { throw ProxyError("证书验证参数无效") }
            p["insecure"] = ["1","true"].contains(insecure.lowercased()) ? "1" : "0"
        }
        if kind == .hysteria2 {
            guard p["obfs"] == nil || p["obfs"] == "salamander" else { throw ProxyError("仅支持 salamander 混淆") }
            guard (p["obfs"] != nil) == (obfs != nil) else { throw ProxyError("混淆类型和密码必须同时提供") }
            if let range = p["mport"] { try validatePorts(range) }
            for key in ["upmbps","downmbps"] { if let value = p[key] { guard let n = Int(value), n > 0, n <= 100000 else { throw ProxyError("带宽参数无效") } } }
        }
        if kind == .trojan {
            guard p["type"] == nil || p["type"] == "tcp", p["security"] == nil || p["security"] == "tls" else { throw ProxyError("Trojan 首版仅支持 TCP/TLS") }
        }
        if kind == .vless {
            guard UUID(uuidString: secret) != nil else { throw ProxyError("VLESS UUID 无效") }
            guard ["tcp","ws"].contains(p["type"] ?? "tcp"), ["none","tls","reality"].contains(p["security"] ?? "none"), ["none"].contains(p["encryption"] ?? "none"), p["flow"] == nil || p["flow"] == "xtls-rprx-vision" else { throw ProxyError("VLESS 传输、加密或流控暂不支持") }
            if p["flow"] != nil && ((p["type"] ?? "tcp") != "tcp" || !["tls","reality"].contains(p["security"] ?? "none")) { throw ProxyError("Vision 需要 TCP 和 TLS/Reality") }
            if p["security"] == "reality" {
                guard let pk = p["pbk"], pk.count == 43, pk.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil, let sni = p["sni"], !sni.isEmpty else { throw ProxyError("Reality 公钥或 SNI 无效") }
                if let sid = p["sid"] { guard sid.count <= 16, sid.count % 2 == 0, sid.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil else { throw ProxyError("Reality short ID 无效") } }
            } else if p["pbk"] != nil || p["sid"] != nil { throw ProxyError("Reality 参数需要 security=reality") }
            if p["fp"] != nil && !["tls","reality"].contains(p["security"] ?? "none") { throw ProxyError("TLS 指纹需要启用 TLS") }
            if let fp = p["fp"], !["chrome","firefox","edge","safari","ios","android","random","randomized"].contains(fp) { throw ProxyError("TLS 指纹暂不支持") }
            if (p["path"] != nil || p["host"] != nil) && p["type"] != "ws" { throw ProxyError("WebSocket 参数需要 type=ws") }
        }
        let name = c.percentEncodedFragment?.removingPercentEncoding ?? server
        let node = Node(name: name.isEmpty ? server : name, kind: kind, server: server, port: port, parameters: p)
        return Candidate(node: node, secret: secret, obfsSecret: obfs)
    }
    public static func validatePorts(_ raw: String) throws {
        for segment in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = segment.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let first = Int(parts[0]), (1...65535).contains(first) else { throw ProxyError("端口范围无效") }
            if parts.count == 2 { guard let end = Int(parts[1]), (first...65535).contains(end) else { throw ProxyError("端口范围无效") } }
        }
    }
}
