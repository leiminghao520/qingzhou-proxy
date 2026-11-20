import Foundation

// 云枢控制面仅开放厂商域名与已核验进程的精确端点，不放行整个公网或 VPN 网段。
public enum YunshuConnectionPolicy {
    public static let version = 1
    public static let domains = ["eagleyun.cn", "eagleyun.com"]
    public static let bootstrapHosts = ["sp.eagleyun.cn", "idp.eagleyun.cn", "mqtt.cs.eagleyun.cn"]
    public static func matches(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { name == $0 || name.hasSuffix("." + $0) }
    }
    public static func validate(_ endpoint: ClaudeNetworkEndpoint) throws {
        let fake = IPPrefix("198.18.0.0/15")!
        let prefix = IPPrefix(endpoint.address + (endpoint.address.contains(":") ? "/128" : "/32"))
        guard DisconnectProtectionPolicy.publicEndpoint(endpoint.address), let prefix,
              !fake.contains(prefix), endpoint.port > 0,
              endpoint.transport == .tcp || endpoint.transport == .udp else {
            throw ProxyError("云枢控制地址不是可核验的公网端点")
        }
    }
    public static func controlEndpoints(host: String, address: String) throws -> [ClaudeNetworkEndpoint] {
        guard matches(host) else { throw ProxyError("域名不属于云枢厂商控制范围") }
        var result = [ClaudeNetworkEndpoint(address: address, port: 443, transport: .tcp),
                      ClaudeNetworkEndpoint(address: address, port: 443, transport: .udp)]
        if host.hasPrefix("mqtt.") { result.append(ClaudeNetworkEndpoint(address: address, port: 8883, transport: .tcp)) }
        for item in result { try validate(item) }
        return result
    }
    public static func runtime(_ state: AppState, installed: Bool) throws -> AppState {
        guard state.usesClaudeBypasses, installed else { return state }
        var next = state
        let additions = domains.filter { domain in
            !state.enabledBypasses.contains { $0.kind == .suffix && $0.matches(host: domain) }
        }.map { NetworkBypass(kind: .suffix, value: $0, note: "云枢控制面运行时例外") }
        try next.setBypasses(next.effectiveBypasses + additions)
        return next
    }
    // lsof 的机器格式只采纳指定 PID 的已连接或正在重连端点，不采纳监听端口。
    public static func endpoints(_ text: String, trustedPIDs: Set<Int32>) throws -> [ClaudeNetworkEndpoint] {
        guard text.utf8.count <= 262144 else { throw ProxyError("云枢连接采样超过限制") }
        var trusted = false
        var proto: ClaudeFlowTransport = .unsupported
        var result: [ClaudeNetworkEndpoint] = []
        for row in text.components(separatedBy: .newlines) {
            if row.hasPrefix("p") { trusted = Int32(row.dropFirst()).map(trustedPIDs.contains) ?? false }
            if row.hasPrefix("f") { proto = .unsupported }
            if row == "PTCP" { proto = .tcp }
            if row == "PUDP" { proto = .udp }
            guard trusted, row.hasPrefix("n"), let remote = row.components(separatedBy: "->").last,
                  row.contains("->"), let colon = remote.lastIndex(of: ":"),
                  let port = UInt16(remote[remote.index(after: colon)...]) else { continue }
            let address = String(remote[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let endpoint = ClaudeNetworkEndpoint(address: address, port: port, transport: proto)
            guard (try? validate(endpoint)) != nil else { continue }
            if !result.contains(endpoint) { result.append(endpoint) }
        }
        guard result.count <= 64 else { throw ProxyError("云枢控制连接超过 64 个，未扩大公网例外") }
        return result
    }
    public static func exception(_ endpoint: ClaudeNetworkEndpoint, interface: String) throws -> ClaudeBypassException {
        try validate(endpoint)
        var item = ClaudeBypassException(destination: endpoint.address + (endpoint.address.contains(":") ? "/128" : "/32"), interface: interface)
        item.vpnControl = true
        item.controlPort = endpoint.port
        item.controlTransport = endpoint.transport
        try item.validate()
        return item
    }
}
