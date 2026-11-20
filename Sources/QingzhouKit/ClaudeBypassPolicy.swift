import Foundation

// 例外是目标与出口的联合约束，不代表按应用隔离。
public struct ClaudeBypassException: Codable, Equatable, Sendable {
    public var destination: String
    public var interface: String
    public var dnsOnly: Bool
    public var vpnControl: Bool?
    public var controlGateway: String?
    public var controlPort: UInt16?
    public var controlTransport: ClaudeFlowTransport?
    public init(destination: String, interface: String, dnsOnly: Bool = false) {
        self.destination = destination
        self.interface = interface
        self.dnsOnly = dnsOnly
    }
    public func validate() throws {
        guard let prefix = IPPrefix(destination), prefix.bits > 3,
              interface.range(of: "^[a-z][a-z0-9]{0,15}$", options: .regularExpression) != nil else {
            throw ProxyError("网络绕过例外的目标或出口无效：" + destination)
        }
        if vpnControl == true && !dnsOnly {
            guard let port = controlPort, let transport = controlTransport,
                  prefix.bits == (prefix.ipv6 ? 128 : 32) else { throw ProxyError("云枢例外缺少精确端口或协议") }
            try YunshuConnectionPolicy.validate(ClaudeNetworkEndpoint(address: prefix.address, port: port, transport: transport))
        } else if controlPort != nil || controlTransport != nil { throw ProxyError("非云枢例外不能指定控制端口") }
        if dnsOnly && prefix.bits != (prefix.ipv6 ? 128 : 32) {
            throw ProxyError("DNS 例外必须限定单个服务器")
        }
    }
}

public enum ClaudeBypassPolicy {
    public static let version = 2

    public static func validate(_ state: AppState) throws {
        let items = try NetworkBypassPolicy.normalize(state.enabledBypasses)
        for ipv6 in [false, true] {
            let prefixes = items.filter { $0.kind == .cidr }.compactMap { IPPrefix($0.value) }.filter { $0.ipv6 == ipv6 }
            guard prefixes.allSatisfy({ $0.bits > 3 }),
                  prefixes.reduce(0.0, { $0 + pow(2.0, -Double($1.bits)) }) < 0.5 else {
                throw ProxyError("Claude 保护不能放行覆盖公网大范围的绕过网段，请缩小范围")
            }
        }
    }

    public static func initialExceptions(state: AppState, plan: CapturePlan) throws -> [ClaudeBypassException] {
        try validate(state)
        let items = try NetworkBypassPolicy.normalize(state.enabledBypasses)
        var result: [ClaudeBypassException] = []
        var candidates: [ProtectedRoute] = []
        for item in items where item.kind == .cidr {
            let requested = IPPrefix(item.value)!
            let scoped = plan.snapshot.routes.filter { route in
                route.interface == plan.snapshot.primaryInterface && IPPrefix(route.destination)?.contains(requested) == true
            }.max { IPPrefix($0.destination)!.bits < IPPrefix($1.destination)!.bits }
            guard let path = plan.protectedRoutes.first(where: { NetworkInspection.samePrefix($0.destination, item.value) }) ?? plan.originalRoute(for: requested.address) ?? scoped else {
                throw NetworkEnvironmentNotReady("绕过目标缺少可核验原出口：" + item.value)
            }
            candidates.append(ProtectedRoute(destination: item.value, gateway: path.gateway, interface: path.interface))
            for route in plan.protectedRoutes {
                if let prefix = IPPrefix(route.destination), requested.contains(prefix) {
                    candidates.append(route)
                }
            }
        }
        // 一个用户网段可能跨越多个原出口，按最长前缀切分后再生成接口限制。
        for (interface, cidrs) in try DynamicCaptureRules.partitionRoutes(candidates) {
            result += cidrs.map { ClaudeBypassException(destination: $0, interface: interface) }
        }
        // 允许作用域解析器处理后续子域名，但只开放这些服务器的 DNS 端口。
        if state.enabledBypasses.contains(where: { $0.kind != .cidr }) {
            let resolvers = plan.snapshot.resolvers
            for resolver in resolvers {
                for raw in resolver.servers {
                    let address = raw.components(separatedBy: "%")[0]
                    let host = IPPrefix(address + (address.contains(":") ? "/128" : "/32"))
                    // 回环已是基础例外，不能追加端口限制而误封同地址上的代理入口。
                    if let host, IPPrefix("127.0.0.0/8")!.contains(host) || IPPrefix("::1/128")!.contains(host) { continue }
                    result.append(ClaudeBypassException(destination: address + (address.contains(":") ? "/128" : "/32"), interface: resolver.interface, dnsOnly: true))
                }
            }
        }
        return try normalized(result)
    }

    public static func normalized(_ exceptions: [ClaudeBypassException]) throws -> [ClaudeBypassException] {
        guard exceptions.count <= 4096 else { throw ProxyError("网络绕过例外超过 4096 条") }
        var result: [ClaudeBypassException] = []
        for item in exceptions {
            try item.validate()
            if !result.contains(item) { result.append(item) }
        }
        // 重叠目标跨出口无法使用单条拒绝规则安全表示，拒绝扩权而不是猜测。
        for (index, item) in result.enumerated() {
            for other in result.dropFirst(index + 1) where item.interface != other.interface {
                if IPPrefix(item.destination)!.overlaps(IPPrefix(other.destination)!) {
                    throw ProxyError("网络绕过目标存在竞争出口：" + item.destination)
                }
            }
        }
        return result.sorted { ($0.destination, $0.interface, $0.controlPort ?? 0, $0.dnsOnly ? 1 : 0) < ($1.destination, $1.interface, $1.controlPort ?? 0, $1.dnsOnly ? 1 : 0) }
    }

    public static func covers(_ old: ClaudeBypassException, with items: [ClaudeBypassException]) -> Bool {
        let matches = items.filter { $0.interface == old.interface && IPPrefix($0.destination)!.contains(IPPrefix(old.destination)!) }
        if matches.contains(where: { !$0.dnsOnly && $0.vpnControl != true }) { return true }
        if old.dnsOnly {
            return matches.contains(where: \.dnsOnly) || [ClaudeFlowTransport.tcp, .udp].allSatisfy { proto in
                matches.contains { $0.controlTransport == proto && $0.controlPort == 53 }
            }
        }
        if old.vpnControl == true {
            return matches.contains { $0.controlTransport == old.controlTransport && $0.controlPort == old.controlPort }
                || old.controlPort == 53 && matches.contains(where: \.dnsOnly)
        }
        return false
    }

    public static func configure(_ object: inout [String: Any], state: AppState, plan: CapturePlan, dnsForwardPort: Int, nodeInterfaces: [String: String]) {
        var outbounds = object["outbounds"] as! [[String: Any]]
        for index in outbounds.indices where outbounds[index]["server"] != nil {
            outbounds[index]["bind_interface"] = (outbounds[index]["server"] as? String).flatMap { nodeInterfaces[$0] } ?? plan.snapshot.primaryInterface
        }
        outbounds.removeAll { $0["type"] as? String == "direct" }
        // 域名答案先由辅助服务核验并写入原路由；此出口不强行绑定物理网卡。
        outbounds.append(["type": "direct", "tag": "claude-bypass", "domain_resolver": ["server": "local", "strategy": ""]])
        object["outbounds"] = outbounds
        var dns = object["dns"] as! [String: Any]
        var servers = (dns["servers"] as! [[String: Any]]).filter { $0["tag"] as? String == "remote" }
        servers.append(["type": "udp", "tag": "local", "server": "127.0.0.1", "server_port": dnsForwardPort, "bind_interface": "lo0"])
        var dnsRules: [[String: Any]] = []
        var bypassRules: [[String: Any]] = []
        for item in state.enabledBypasses where item.kind != .cidr {
            let key = item.kind == .domain ? "domain" : "domain_suffix"
            dnsRules.append([key: [item.value], "action": "route", "server": "local", "disable_cache": true])
            bypassRules.append([key: [item.value], "action": "resolve", "server": "local", "strategy": ""])
            bypassRules.append([key: [item.value], "action": "route", "outbound": "claude-bypass"])
        }
        dns["servers"] = servers
        dns["rules"] = dnsRules
        dns["final"] = "remote"
        object["dns"] = dns
        var route = object["route"] as! [String: Any]
        let leading = (route["rules"] as! [[String: Any]]).filter { ["sniff", "hijack-dns"].contains($0["action"] as? String ?? "") }
        bypassRules.append(["action": "resolve", "server": "remote", "strategy": state.effectiveAddressFamilyPolicy.strategy])
        for item in state.enabledBypasses where item.kind == .cidr {
            bypassRules.append(["ip_cidr": [item.value], "action": "route", "outbound": "claude-bypass"])
        }
        if state.effectiveAddressFamilyPolicy == .ipv4Only { bypassRules.append(["ip_version": 6, "action": "reject"]) }
        route["rules"] = leading + bypassRules
        route["final"] = "proxy"
        route["default_domain_resolver"] = ["server": "remote", "strategy": state.effectiveAddressFamilyPolicy.strategy]
        object["route"] = route
    }
}
