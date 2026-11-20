import Foundation
import Darwin
import Security
import SystemConfiguration
import QingzhouKit

// 只信任固定安装位置且通过厂商签名核验的正在运行进程，不以进程名称授权公网例外。
enum YunshuConnections {
    static let paths = [
        "/Applications/Yunshu.app/Contents/MacOS/Yunshu",
        "/opt/.yunshu/YunshuAgent.app/Contents/MacOS/YunshuAgent",
        "/opt/.yunshu/YunshuManager.app/Contents/MacOS/YunshuManager",
        "/opt/.yunshu/YunshuAgent.app/Contents/XPCServices/YunshuPluginService.xpc/Contents/MacOS/YunshuPluginService",
        "/opt/.yunshu/dpengine",
        "/Library/PrivilegedHelperTools/com.eagleyun.sase.helper"
    ]
    static func endpoints() throws -> [ClaudeNetworkEndpoint] {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"585Z2747F9\"" as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw ProxyError("云枢厂商签名要求无法建立")
        }
        let allowed = Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        let processes = try NetworkInspection.command("/bin/ps", ["-axo", "pid=,comm="])
        var pids = Set<Int32>()
        for row in processes.components(separatedBy: .newlines) {
            let fields = row.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
            let path = URL(fileURLWithPath: String(fields[1]).trimmingCharacters(in: .whitespaces)).resolvingSymlinksInPath().path
            guard allowed.contains(path) else { continue }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  allowed.contains(URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path) else { continue }
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
                  let code, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
                throw ProxyError("云枢进程签名未通过，不能采纳其联网端点")
            }
            pids.insert(pid)
        }
        guard !pids.isEmpty, pids.count <= 16 else { throw ProxyError("未找到可核验的云枢进程，请先启动云枢") }
        // lsof 在部分指定进程没有网络文件时也返回 1；仅接受无诊断文本的机器记录。
        let text = try NetworkInspection.command("/usr/sbin/lsof", ["-nP", "-a", "-p", pids.sorted().map(String.init).joined(separator: ","), "-i", "-F", "pPnT"], acceptedExitCodes: [0, 1])
        guard text.components(separatedBy: .newlines).allSatisfy({ $0.isEmpty || ["p", "f", "P", "n", "T"].contains(String($0.prefix(1))) }) else {
            throw ProxyError("云枢连接采样含错误诊断，不能据此放行")
        }
        for pid in pids {
            var buffer = [CChar](repeating: 0, count: 4096)
            var code: SecCode?
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  allowed.contains(URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path),
                  SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
                  let code, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
                throw NetworkEnvironmentNotReady("云枢进程在采样期间变化，需要重新核验")
            }
        }
        return try YunshuConnectionPolicy.endpoints(text, trustedPIDs: pids)
    }
}

extension Service {
    func prepareYunshuConnections(state: AppState, plan: CapturePlan) throws -> [ClaudeBypassException] {
        guard state.usesClaudeBypasses, !(plan.yunshuControlDomains ?? []).isEmpty else { return [] }
        let physicalDNS = try vpnResolverExceptions(state: state, plan: plan)
        if disconnectFirewall.armed && disconnectFirewall.vpnControlExceptions.isEmpty { try disconnectFirewall.stageVPNResolvers(physicalDNS) }
        return try YunshuConnections.prepare(plan: plan, physicalDNS: physicalDNS,
            endpointsRead: yunshuEndpointsRead, transport: yunshuBootstrapTransport, resolve: yunshuBootstrapResolve)
    }

    func vpnResolverExceptions(state: AppState, plan: CapturePlan) throws -> [ClaudeBypassException] {
        try ClaudeBypassPolicy.initialExceptions(state: state, plan: plan).filter { $0.dnsOnly && $0.interface == plan.snapshot.primaryInterface }.map { item in
            var next = item
            next.vpnControl = true
            next.controlGateway = try plan.originalPhysicalRoute(for: IPPrefix(item.destination)!.address).gateway
            return next
        }
    }

    func installYunshuControlRoutes(_ exceptions: [ClaudeBypassException]) throws {
        for item in exceptions where !item.dnsOnly {
            guard let gateway = item.controlGateway else { throw ProxyError("云枢控制路由缺少原网关") }
            try addRoute(item.destination, gateway, item.interface, ipv6: item.destination.contains(":"))
        }
    }

    func configureYunshuControlRules(_ object: inout [String: Any], exceptions: [ClaudeBypassException], interface: String) throws {
        let file = root.appendingPathComponent("yunshu-control-rules.json")
        try writeYunshuControlRules(exceptions)
        var route = object["route"] as! [String: Any]
        var sets = route["rule_set"] as? [[String: Any]] ?? []
        sets.append(["type": "local", "tag": "yunshu-control", "format": "source", "path": file.path])
        route["rule_set"] = sets
        var rules = route["rules"] as! [[String: Any]]
        let position = rules.firstIndex { !["sniff", "hijack-dns"].contains($0["action"] as? String ?? "") } ?? rules.endIndex
        rules.insert(["rule_set": ["yunshu-control"], "action": "route", "outbound": "yunshu-control"], at: position)
        route["rules"] = rules
        object["route"] = route
        var outbounds = object["outbounds"] as! [[String: Any]]
        outbounds.append(["type": "direct", "tag": "yunshu-control", "bind_interface": interface, "domain_resolver": ["server": "local", "strategy": ""]])
        object["outbounds"] = outbounds
    }

    func writeYunshuControlRules(_ exceptions: [ClaudeBypassException]) throws {
        let rules: [[String: Any]] = exceptions.filter { $0.vpnControl == true && !$0.dnsOnly }.map {
            ["ip_cidr": [$0.destination], "network": [$0.controlTransport!.rawValue], "port": [Int($0.controlPort!)]]
        }
        try SecureFile.write(JSONSerialization.data(withJSONObject: ["version": 3, "rules": rules]), to: root.appendingPathComponent("yunshu-control-rules.json"))
    }
}

extension Service {
    // 控制面监控独立于代理连接；暂停代理不能同时停止云枢重连所需的维护。
    func startYunshuMonitor() {
        yunshuMonitor?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.refreshYunshuConnections(background: true) }
        yunshuMonitor = timer
        timer.resume()
    }

    func refreshYunshuConnections(background: Bool = false) {
        if background && yunshuRefreshInFlight { return }
        guard disconnectFirewall.armed, disconnectFirewall.bypassMode, let state = yunshuRuntimeState else {
            yunshuMonitor?.cancel()
            yunshuMonitor = nil
            return
        }
        do {
            let snapshot: NetworkSnapshot
            if let read = yunshuSnapshotRead { snapshot = try read() }
            else {
                guard let global = SCDynamicStoreCopyValue(dynamic, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
                      let primary = global["PrimaryInterface"] as? String, !CapturePlan.isVPN(primary) else {
                    throw NetworkEnvironmentNotReady("云枢控制面原网络尚未就绪")
                }
                let sample = try routeSample()
                if journal != nil { snapshot = try currentSnapshot(sample: sample) }
                else {
                    snapshot = try NetworkSnapshot.read(store: dynamic, primary: primary, routes: sample.table, structuredRoutes: sample.planningRoutes,
                        lookup: { try self.routeInfo($0, ipv6: $1) })
                }
            }
            let primary = snapshot.primaryInterface
            guard !CapturePlan.isVPN(primary), primary != "lo0" else { throw NetworkEnvironmentNotReady("云枢控制出口不是原物理网络") }
            var plan = try CapturePlan.make(snapshot: snapshot, state: state)
            plan.yunshuControlDomains = YunshuConnectionPolicy.domains
            let physicalDNS = try vpnResolverExceptions(state: state, plan: plan)
            let changedInterface = yunshuControlExceptions.contains { $0.interface != primary }
            if changedInterface {
                // 新物理网络只先开放已确认 DNS，旧地址不会转移到新接口。
                try disconnectFirewall.updateBypassExceptions(physicalDNS)
                yunshuControlExceptions = physicalDNS
                if activeRequest != nil { return }
            }
            if disconnectFirewall.vpnControlExceptions.isEmpty { try disconnectFirewall.stageVPNResolvers(physicalDNS) }
            if background {
                yunshuRefreshInFlight = true
                let generation = captureGeneration
                let read = yunshuEndpointsRead
                let transport = yunshuBootstrapTransport
                let resolve = yunshuBootstrapResolve
                DispatchQueue.global().async { [weak self] in
                    let result = Result { try YunshuConnections.prepare(plan: plan, physicalDNS: physicalDNS, endpointsRead: read, transport: transport, resolve: resolve) }
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        self.yunshuRefreshInFlight = false
                        guard self.captureGeneration == generation, self.disconnectFirewall.armed, self.disconnectFirewall.bypassMode else { return }
                        do {
                            let controls = try result.get()
                            guard controls.allSatisfy(self.validateYunshuControlPath) else { throw NetworkEnvironmentNotReady("云枢原出口在准备期间变化") }
                            try self.applyYunshuControls(controls, state: state, plan: plan)
                        } catch { self.failYunshuRefresh(error) }
                    }
                }
            } else {
                let controls = try YunshuConnections.prepare(plan: plan, physicalDNS: physicalDNS,
                    endpointsRead: yunshuEndpointsRead, transport: yunshuBootstrapTransport, resolve: yunshuBootstrapResolve)
                try applyYunshuControls(controls, state: state, plan: plan)
            }
        } catch { failYunshuRefresh(error) }
    }
    func applyYunshuControls(_ controls: [ClaudeBypassException], state: AppState, plan: CapturePlan) throws {
        if let active = capturePlan, active.snapshot.primaryInterface != plan.snapshot.primaryInterface { return }
        if activeRequest != nil { try installYunshuControlRoutes(controls) }
        let business = activeRequest == nil ? [] : try ClaudeBypassPolicy.initialExceptions(state: state, plan: plan) + claudeAnswerExceptions.values.flatMap { $0 }.filter { $0.vpnControl != true }
        try disconnectFirewall.updateBypassExceptions(business + controls)
        if activeRequest != nil { try writeYunshuControlRules(controls) }
        yunshuControlExceptions = controls
    }
    func failYunshuRefresh(_ error: Error) {
        // 解析暂时超时但旧端点原路径仍被核验时，保留重连机会；失去路径证据才收紧。
        let retained = disconnectFirewall.vpnControlExceptions
        if retained.isEmpty || !retained.allSatisfy(validateYunshuControlPath) {
            try? disconnectFirewall.revokeBypassExceptions(preservingVPN: false)
            yunshuControlExceptions = []
        }
        lastFailure = "云枢控制面准备未完成：" + error.localizedDescription
    }
}


private struct YunshuControlContext: Codable {
    let version: Int
    let bypasses: [NetworkBypass]
    let trustedDNS: [TrustedCorporateDNS]
    let family: AddressFamilyPolicy?
}

extension Service {
    func validateYunshuControlPath(_ item: ClaudeBypassException) -> Bool {
        if let validate = yunshuPathValidate { return validate(item) }
        guard let gateway = item.controlGateway, if_nametoindex(item.interface) != 0,
              let global = SCDynamicStoreCopyValue(dynamic, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              global["PrimaryInterface"] as? String == item.interface,
              !CapturePlan.isVPN(item.interface),
              let prefix = IPPrefix(item.destination),
              let info = try? routeInfo(prefix.address, ipv6: prefix.ipv6, scope: item.interface) else { return false }
        return field("interface", info) == item.interface && field("gateway", info) == gateway
    }
    func saveYunshuContext(_ state: AppState) throws {
        let context = YunshuControlContext(version: YunshuConnectionPolicy.version, bypasses: state.effectiveBypasses,
            trustedDNS: state.trustedCorporateDNS ?? [], family: state.addressFamilyPolicy)
        try SecureFile.write(JSONEncoder().encode(context), to: root.appendingPathComponent("yunshu-control-context.json"), durable: true)
    }
    func restoreYunshuMonitor() throws {
        guard disconnectFirewall.armed, disconnectFirewall.bypassMode else { return }
        let path = root.appendingPathComponent("yunshu-control-context.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 2 * 1024 * 1024 else {
            throw ProxyError("云枢控制面恢复上下文权限或大小无效")
        }
        let context = try JSONDecoder().decode(YunshuControlContext.self, from: Data(contentsOf: path))
        guard context.version == YunshuConnectionPolicy.version else { throw ProxyError("云枢控制面上下文版本无效") }
        var state = AppState()
        state.claudeSafetyMode = true
        state.claudeAllowsBypasses = true
        state.disconnectProtection = true
        state.trustedCorporateDNS = try TrustedCorporateDNS.normalize(context.trustedDNS)
        state.addressFamilyPolicy = context.family
        try state.setBypasses(context.bypasses)
        try ClaudeBypassPolicy.validate(state)
        yunshuRuntimeState = state
        startYunshuMonitor()
    }
}


extension YunshuConnections {
    static func prepare(plan: CapturePlan, physicalDNS: [ClaudeBypassException],
                        endpointsRead: () throws -> [ClaudeNetworkEndpoint],
                        transport: ((Data, String, String) -> Data?)?,
                        resolve: ((String, UInt16, CapturePlan) throws -> [String])?) throws -> [ClaudeBypassException] {
        let bootstrap = try ScopedDNSForwarder(plan: plan, transport: transport)
        var endpoints = try endpointsRead()
        // 引导发生在阻断之前，直接使用原物理网卡 DNS，避免云枢通过自身隧道寻找控制服务器。
        for name in YunshuConnectionPolicy.bootstrapHosts {
            var addresses: [String] = []
            for type: UInt16 in [1, 28] {
                if let resolve = resolve { addresses += try resolve(name, type, plan); continue }
                let query = DNSPacket.query(name, type: type)
                let response = bootstrap.resolve(query, name: name, budget: 2)
                if DNSPacket.acceptable(response, query: query) { addresses += try DNSPacket.addresses(response) }
            }
            if addresses.isEmpty && name.hasPrefix("mqtt.") { continue }
            guard !addresses.isEmpty else { throw NetworkEnvironmentNotReady("云枢控制服务器引导解析失败：" + name) }
            let physical = addresses.filter { (try? plan.originalPhysicalRoute(for: $0)) != nil }
            if physical.isEmpty && !name.hasPrefix("mqtt.") { throw NetworkEnvironmentNotReady("云枢控制服务器缺少可用物理出口：" + name) }
            endpoints += try physical.flatMap { try YunshuConnectionPolicy.controlEndpoints(host: name, address: $0) }
        }
        guard endpoints.count <= 128 else { throw ProxyError("云枢引导端点超过限制") }
        let result = try endpoints.compactMap { endpoint -> ClaudeBypassException? in
            try YunshuConnectionPolicy.validate(endpoint)
            if endpoint.address.contains(":"), !plan.snapshot.routes.contains(where: {
                $0.interface == plan.snapshot.primaryInterface && $0.ipv6 &&
                RuleEvaluator.matches(RoutingRule(kind: .cidr, value: $0.destination, action: .direct), host: endpoint.address, ip: endpoint.address) == true
            }) { return nil }
            let route = try plan.domainRoute(address: endpoint.address, resolver: plan.selectResolvers(for: YunshuConnectionPolicy.bootstrapHosts[0])[0], host: YunshuConnectionPolicy.bootstrapHosts[0])
            var item = try YunshuConnectionPolicy.exception(endpoint, interface: route.interface)
            item.controlGateway = route.gateway
            return item
        }
        return try ClaudeBypassPolicy.normalized(result + physicalDNS)
    }
}
