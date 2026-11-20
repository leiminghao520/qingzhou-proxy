import Foundation

// 独立于路由恢复日志持久化；核心、GUI 或控制通道意外退出不能撤销拒绝规则。
public final class DisconnectProtectionFirewall {
    private struct Lease:Codable {
        var anchor:String
        var allowed:[String]
        var tunnel:String?
        var expected:String?
        var token:String?
        var tokenBoot:String?
        var rootBefore:String?
        var rootExpected:String?
        var yunshuAddresses:[String]?
        var strictEndpoint: ClaudeNetworkEndpoint?
        var policyVersion: Int?
        var bypassVersion: Int?
        var bypassExceptions: [ClaudeBypassException]?
    }
    private let directory:URL
    private let command:([String]) throws -> String
    private var lease:Lease?
    private var record:URL {directory.appendingPathComponent("disconnect-protection.json")}
    private var configuration:URL {directory.appendingPathComponent("disconnect-protection.conf")}
    private var rootConfiguration:URL {directory.appendingPathComponent("disconnect-protection-root.conf")}
    public var armed:Bool {lease != nil || FileManager.default.fileExists(atPath:record.path)}
    public init(directory:URL,command:@escaping ([String]) throws -> String) {self.directory=directory;self.command=command}
    private func load() throws {
        guard lease==nil,FileManager.default.fileExists(atPath:record.path) else{return}
        let attributes=try FileManager.default.attributesOfItem(atPath:record.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,let permissions=(attributes[.posixPermissions] as? NSNumber)?.intValue,permissions&0o077==0 else{throw ProxyError("断线保护记录权限无效")}
        let value=try JSONDecoder().decode(Lease.self,from:Data(contentsOf:record))
        guard (value.yunshuAddresses ?? []).count <= 32,
              (value.yunshuAddresses ?? []).allSatisfy(DisconnectProtectionPolicy.publicEndpoint) else {
            throw ProxyError("云枢控制服务例外恢复记录无效")
        }
        guard value.anchor.range(of:"^(com\\.apple/)?qingzhou-lock-[0-9a-f-]{36}$",options:.regularExpression) != nil else{throw ProxyError("断线保护锚点记录无效")}
        if let before = value.rootBefore {
            guard Self.isCorporateRoot(before), !value.anchor.contains("/"),
                  value.rootExpected == Self.rootReference(value.anchor) + Self.normalizedRoot(before) else {
                throw ProxyError("断线保护根规则恢复记录无效")
            }
        } else if value.rootExpected != nil || !value.anchor.hasPrefix("com.apple/") {
            throw ProxyError("断线保护根规则恢复记录不完整")
        }
        guard value.bypassVersion == nil || value.bypassVersion == 1 || value.bypassVersion == ClaudeBypassPolicy.version,
              value.bypassExceptions == nil || value.bypassVersion != nil else { throw ProxyError("网络绕过恢复记录版本无效") }
        if let endpoint = value.strictEndpoint {
            guard value.policyVersion == nil || value.policyVersion == ClaudePFPolicy.version else { throw ProxyError("整机保护规则版本无效") }
            _ = try ClaudePFPolicy.rules(endpoint: endpoint, tunnel: value.tunnel, exceptions: value.bypassExceptions ?? [])
        } else { _=try DisconnectProtectionPolicy.rules(allowed:value.allowed,tunnel:value.tunnel) }
        lease=value
    }
    private func anchorPresent(_ anchor: String) throws -> Bool {
        var parent = ""
        for component in anchor.split(separator: "/").map(String.init) {
            let arguments = parent.isEmpty ? ["-s", "Anchors"] : ["-a", parent, "-s", "Anchors"]
            let output = try command(arguments)
            guard !output.contains("pfctl:") else { throw ProxyError("防火墙锚点清单读取失败") }
            let names = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard names.contains(component) || names.contains(parent + "/" + component) else { return false }
            parent = parent.isEmpty ? component : parent + "/" + component
        }
        return true
    }
    private func ownedRules(_ anchor: String) throws -> String {
        let output = try command(["-a", anchor, "-sr"])
        if output.contains("pfctl:") {
            let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard lines == ["pfctl: DIOCGETRULES: Invalid argument"], try !anchorPresent(anchor) else {
                throw ProxyError("防火墙规则读取失败，不能把诊断文字当成规则证明")
            }
            return ""
        }
        return output
    }
    private func ownedChildren(_ anchor: String) throws -> String {
        guard try anchorPresent(anchor) else { return "" }
        let output = try command(["-a", anchor, "-s", "Anchors"])
        guard !output.contains("pfctl:") else { throw ProxyError("防火墙子锚点读取失败") }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func save() throws {if let lease {try SecureFile.write(JSONEncoder().encode(lease),to:record,durable:true)}}
    private static func normalizedRoot(_ text:String) -> String {
        text.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}.joined(separator:"\n") + "\n"
    }
    private static func rootReference(_ anchor:String) -> String { "anchor \"" + anchor + "\" quick all\n" }
    private static func isCorporateRoot(_ text:String) -> Bool {
        let names = ["atrust", "atrust1", "vpn", "app01", "app02", "byod"].map { "anchor \"com.sangfor." + $0 + "\" all" }
        let lines = normalizedRoot(text).split(separator:"\n").map(String.init)
        let permitted = Set(names + ["anchor \"com.apple/*\" all"])
        return !lines.isEmpty && lines.count <= permitted.count && Set(lines).count == lines.count && lines.allSatisfy{permitted.contains($0)} && lines.contains{names.contains($0)}
    }
    private func loadRoot(_ rules:String) throws {
        try SecureFile.write(Data(rules.utf8),to:rootConfiguration,durable:true)
        // 只更新过滤根引用，不加载外部锚点内容，不接触 NAT、转发或磁盘上的企业配置。
        _=try command(["-n","-R","-f",rootConfiguration.path])
        _=try command(["-R","-f",rootConfiguration.path])
        guard Self.normalizedRoot(try command(["-sr"])) == rules else {throw ProxyError("断线保护根引用加载后核验失败，恢复记录已保留")}
    }
    private func attachRootIfNeeded() throws {
        guard let lease,let before=lease.rootBefore,let expected=lease.rootExpected else{return}
        let current=Self.normalizedRoot(try command(["-sr"]))
        if current == Self.normalizedRoot(before) {try loadRoot(expected)}
        else if current != expected {throw ProxyError("企业防火墙根规则已变化，未覆盖外部规则")}
    }
    public func preflight() throws {
        try load()
        let root=try command(["-sr"])
        if let before=lease?.rootBefore {
            let current=Self.normalizedRoot(root)
            guard current == Self.normalizedRoot(before) || current == lease?.rootExpected else {throw ProxyError("企业防火墙根规则已变化，未覆盖外部规则")}
            return
        }
        if lease == nil && Self.isCorporateRoot(root) {return}
        do {try PinnedBypassPolicy.validateFirewallRoot(root)}
        catch {throw ProxyError("断线保护不可用：系统防火墙包含未识别的规则，未改写现有防火墙")}
        let children=try command(["-a","com.apple","-s","Anchors"]).components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        guard children.allSatisfy({$0==lease?.anchor || $0==lease?.anchor.components(separatedBy:"/").last}) else{throw ProxyError("断线保护不可用：保护锚点有其他组件，无法确认规则顺序")}
    }
    public func verify() throws {
        try load()
        guard let lease else{return}
        try preflight()
        if let expected=lease.rootExpected {
            guard Self.normalizedRoot(try command(["-sr"])) == expected else {throw ProxyError("断线保护根引用未生效，无法确认公网阻断")}
        }
        guard try command(["-si"]).contains("Status: Enabled"),let expected=lease.expected,try ownedRules(lease.anchor)==expected else{throw ProxyError("断线保护规则已被外部修改或状态不明，保留记录并拒绝解除")}
    }
    // 仅写操作可恢复本应用空锚点；只读状态核验不会修改防火墙。
    private func prepareOwnedMutation() throws {
        try load()
        guard let lease else { return }
        try preflight()
        let actual = try ownedRules(lease.anchor)
        guard actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { try verify(); return }
        guard let expected = lease.expected, !expected.isEmpty else { throw ProxyError("空锚点缺少自有规则证据，拒绝重载") }
        if let rootExpected = lease.rootExpected {
            let root = Self.normalizedRoot(try command(["-sr"]))
            guard root == rootExpected || root == lease.rootBefore.map(Self.normalizedRoot) else { throw ProxyError("自有根引用已变化，不能重载空锚点") }
        }
        let children = try ownedChildren(lease.anchor)
        guard children.isEmpty else { throw ProxyError("自有空锚点包含其他子锚点，不能重载") }
        try apply(tunnel: lease.tunnel, first: false)
    }
    public func verifyClaudeSafety(endpoint: String) throws -> Bool {
        try load()
        guard let lease else { return false }
        try verify()
        return lease.policyVersion == ClaudePFPolicy.version && lease.strictEndpoint?.address == endpoint
            && (lease.yunshuAddresses ?? []).isEmpty
    }
    public func verifyStrict(endpoint: ClaudeNetworkEndpoint, allowsBypasses: Bool = false) throws -> Bool {
        guard try verifyClaudeSafety(endpoint: endpoint.address) else { return false }
        return lease?.strictEndpoint == endpoint && (allowsBypasses ? lease?.bypassVersion == ClaudeBypassPolicy.version : lease?.bypassVersion == nil)
    }
    public func armStrict(endpoint: ClaudeNetworkEndpoint, exceptions: [ClaudeBypassException]? = nil) throws {
        let normalized = try exceptions.map { try ClaudeBypassPolicy.normalized($0) }
        _ = try ClaudePFPolicy.rules(endpoint: endpoint, tunnel: nil, exceptions: normalized ?? [])
        try preflight()
        if let current = lease {
            try prepareOwnedMutation()
            if current.strictEndpoint == endpoint, current.policyVersion == ClaudePFPolicy.version {
                guard (current.bypassVersion != nil) == (normalized != nil) else { throw ProxyError("请先解除保护，再更换网络绕过模式") }
                lease?.bypassVersion = normalized == nil ? nil : ClaudeBypassPolicy.version
                lease?.bypassExceptions = normalized
                try save()
                try apply(tunnel: nil, first: false)
                return
            }
            if let pinned = current.strictEndpoint, pinned != endpoint {
                throw ProxyError("请先明确解除保护，再更换固定出口")
            }
            // 迁移只收紧规则；失败也不恢复旧的云枢或私网例外。
            lease?.bypassVersion = normalized == nil ? nil : ClaudeBypassPolicy.version
            lease?.bypassExceptions = normalized
            lease?.strictEndpoint = endpoint
            lease?.policyVersion = nil
            lease?.yunshuAddresses = []
            try save()
            try apply(tunnel: nil, first: true)
        } else {
            let root = Self.normalizedRoot(try command(["-sr"]))
            let corporate = Self.isCorporateRoot(root)
            let anchor = (corporate ? "" : "com.apple/") + "qingzhou-lock-" + UUID().uuidString.lowercased()
            lease = Lease(anchor: anchor, allowed: [endpoint.address + (endpoint.address.contains(":") ? "/128" : "/32")],
                rootBefore: corporate ? root : nil, rootExpected: corporate ? Self.rootReference(anchor) + root : nil,
                yunshuAddresses: [], strictEndpoint: endpoint, policyVersion: nil, bypassVersion: normalized == nil ? nil : ClaudeBypassPolicy.version, bypassExceptions: normalized)
            try save()
            try apply(tunnel: nil, first: true)
        }
    }

    private func apply(tunnel:String?,first:Bool) throws {
        guard var next=lease else{return}
        let needsStateReset = first || (next.strictEndpoint != nil && next.policyVersion != ClaudePFPolicy.version)
        let rules = try next.strictEndpoint.map { try ClaudePFPolicy.rules(endpoint: $0, tunnel: tunnel, exceptions: next.bypassExceptions ?? []) }
            ?? DisconnectProtectionPolicy.rules(allowed: next.allowed, tunnel: tunnel)
        try SecureFile.write(Data(rules.utf8),to:configuration,durable:true)
        _=try command(["-n","-a",next.anchor,"-f",configuration.path])
        next.tunnel=tunnel;lease=next;try save()
        // 先建立自有根引用，避免向不存在且无引用的锚点写入后无法核验其生命周期。
        try attachRootIfNeeded()
        _=try command(["-a",next.anchor,"-f",configuration.path])
        var actual = try ownedRules(next.anchor)
        // 接口重建可能令企业组件同时重载 PF，只在自有空锚点和完整根引用证据下有限重试。
        for _ in 0..<2 where actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try preflight()
            if let rootExpected = next.rootExpected {
                let root = Self.normalizedRoot(try command(["-sr"]))
                guard root == rootExpected || root == next.rootBefore.map(Self.normalizedRoot) else { throw ProxyError("根引用变化，停止重载自有规则") }
            }
            let children = try ownedChildren(next.anchor)
            guard children.isEmpty else { throw ProxyError("空锚点存在其他子项，拒绝重载") }
            _ = try command(["-a", next.anchor, "-f", configuration.path])
            actual = try ownedRules(next.anchor)
        }
        guard !actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProxyError("断线保护规则重载后仍为空，拒绝继续接管") }
        lease?.expected=actual;try save()
        let enabled=try command(["-si"]).contains("Status: Enabled")
        if !enabled || (first && next.token == nil) {
            let output=try command(["-E"])
            guard let line=output.components(separatedBy:.newlines).first(where:{$0.contains("Token")}),let token=line.split(whereSeparator:{$0.isWhitespace || $0==":"}).last,UInt64(token).map({$0>0})==true else{throw ProxyError("断线保护未取得防火墙启用凭据，保留记录")}
            lease?.token=String(token);lease?.tokenBoot=Self.bootIdentity();try save()
        }
        try attachRootIfNeeded()
        if needsStateReset {
            // 已有浮动状态可能绕过新规则；首次开启明确中断旧连接，两种地址族分别清理。
            _=try command(["-k","0.0.0.0/0"])
            _=try command(["-k","::/0"])
        }
        try verify()
        // 只有规则、启用状态、根引用及旧连接清理全部完成后，才发布严格版本证明。
        if next.strictEndpoint != nil {
            lease?.policyVersion = ClaudePFPolicy.version
            try save()
        }
    }
    public func arm(allowed:[String],yunshuAddresses:[String]=[]) throws {
        guard yunshuAddresses.count <= 32, yunshuAddresses.allSatisfy(DisconnectProtectionPolicy.publicEndpoint) else {
            throw ProxyError("云枢控制服务例外地址无效")
        }
        try preflight()
        // 活跃会话固定已核验地址；DNS 变化需显式关闭再开启，不能后台扩大例外。
        let cloud=(lease?.yunshuAddresses ?? yunshuAddresses).map{$0+($0.contains(":") ? "/128":"/32")}
        let normalized=Array(Set(allowed+cloud)).sorted()
        if let lease {
            guard lease.allowed==normalized else{throw ProxyError("保护生效期间不能更换固定出口或网络例外，请先手动断开")}
            try verify();try apply(tunnel:nil,first:false);return
        }
        let root=Self.normalizedRoot(try command(["-sr"]))
        let corporate=Self.isCorporateRoot(root)
        let anchor=(corporate ? "" : "com.apple/")+"qingzhou-lock-"+UUID().uuidString.lowercased()
        lease=Lease(anchor:anchor,allowed:normalized,rootBefore:corporate ? root:nil,rootExpected:corporate ? Self.rootReference(anchor)+root:nil,yunshuAddresses:yunshuAddresses)
        try save()
        try apply(tunnel:nil,first:true)
    }
    public var bypassExceptionCount: Int { lease?.bypassExceptions?.count ?? 0 }
    public var bypassMode: Bool { lease?.bypassVersion == ClaudeBypassPolicy.version }
    public func updateBypassExceptions(_ exceptions: [ClaudeBypassException]) throws {
        try load()
        guard lease?.bypassVersion == ClaudeBypassPolicy.version else { throw ProxyError("网络绕过保护未启用") }
        try prepareOwnedMutation()
        let normalized = try ClaudeBypassPolicy.normalized(exceptions)
        let removed = (lease?.bypassExceptions ?? []).filter { !ClaudeBypassPolicy.covers($0, with: normalized) }
        lease?.bypassExceptions = normalized
        try save()
        do {
            try apply(tunnel: lease?.tunnel, first: false)
            // PF 已有状态可绕过新拒绝规则，撤销目标必须同步清理其两端连接状态。
            for item in removed {
                let any = item.destination.contains(":") ? "::/0" : "0.0.0.0/0"
                _ = try command(["-k", any, "-k", item.destination])
                _ = try command(["-k", item.destination])
            }
        } catch {
            lease?.policyVersion = nil
            try save()
            throw error
        }
    }
    public func stageVPNResolvers(_ exceptions: [ClaudeBypassException]) throws {
        try load()
        guard let current = lease, current.strictEndpoint != nil, current.bypassVersion != nil,
              exceptions.allSatisfy({ $0.dnsOnly && $0.vpnControl == true }) else { throw ProxyError("云枢引导 DNS 未获得绕过模式授权") }
        try prepareOwnedMutation()
        lease?.bypassVersion = ClaudeBypassPolicy.version
        try updateBypassExceptions(vpnControlExceptions + exceptions)
    }
    public var vpnControlExceptions: [ClaudeBypassException] { (lease?.bypassExceptions ?? []).filter { $0.vpnControl == true } }
    public func revokeBypassExceptions(preservingVPN: Bool = true) throws {
        try load()
        if lease?.bypassVersion != nil {
            // 旧记录仅用于安全清理，不能直接作为新协议的有效证明。
            lease?.bypassVersion = ClaudeBypassPolicy.version
            try updateBypassExceptions(preservingVPN ? vpnControlExceptions : [])
        }
    }
    public func attach(tunnel:String) throws {try load();guard lease != nil else{return};try prepareOwnedMutation();try apply(tunnel:tunnel,first:false)}
    public func suspend() throws {try load();guard lease != nil else{return};try prepareOwnedMutation();if lease?.tunnel != nil {try apply(tunnel:nil,first:false)}}
    public func restoreAfterRestart(validateVPN: (ClaudeBypassException) -> Bool = { _ in false }) throws {
        try load();guard let lease else{return}
        try preflight()
        self.lease?.bypassExceptions = lease.bypassVersion == nil ? nil : (lease.bypassExceptions ?? []).filter { $0.vpnControl == true && validateVPN($0) }
        try save()
        let current=try ownedRules(lease.anchor)
        // 重启后规则可为空；存在不同规则时不能认领或覆盖。
        guard current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || current==lease.expected else{throw ProxyError("断线保护锚点已有外部修改，未覆盖")}
        try apply(tunnel:nil,first:current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || lease.bypassVersion != nil)
    }
    private static func bootIdentity() -> String? {
        try? NetworkInspection.command("/usr/sbin/sysctl", ["-n", "kern.boottime"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public private(set) var releaseWarning: String?
    public func release() throws {
        try load();guard let lease else{return}
        try preflight()
        let current=try ownedRules(lease.anchor)
        let detached=try lease.rootBefore.map{Self.normalizedRoot(try command(["-sr"])) == Self.normalizedRoot($0)} ?? false
        if !current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            if detached {guard current == lease.expected else{throw ProxyError("未挂接的保护锚点已有外部修改，未清理")}}
            else {guard current == lease.expected else {throw ProxyError("保护锚点已有外部修改，未清理")}}
        }
        guard try ownedChildren(lease.anchor).isEmpty else { throw ProxyError("自有保护锚点存在未知子项，未清理") }
        if let before=lease.rootBefore,!detached {try loadRoot(Self.normalizedRoot(before))}
        _=try command(["-a",lease.anchor,"-F","rules"])
        guard try ownedRules(lease.anchor).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ProxyError("断线保护清理核验失败，记录已保留")}
        releaseWarning = nil
        if let token = lease.token {
            // 旧版本或跨启动周期的凭据不能认领；规则释放不依赖凭据仍有效。
            do {
                guard UInt64(token).map({ $0 > 0 }) == true else { throw ProxyError("防火墙启用凭据无效") }
                let references = try command(["-s", "References"])
                let pattern = try NSRegularExpression(pattern: "(?i)\\btoken\\s*:\\s*([0-9]+)\\b")
                let range = NSRange(references.startIndex..., in: references)
                let tokens = pattern.matches(in: references, range: range).compactMap { match -> String? in
                    guard let range = Range(match.range(at: 1), in: references) else { return nil }
                    return String(references[range])
                }
                guard references.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tokens.isEmpty else {
                    throw ProxyError("PF 引用格式无法确认，未释放启用引用")
                }
                if tokens.contains(token) {
                    guard let boot = lease.tokenBoot, boot == Self.bootIdentity() else {
                        throw ProxyError("防火墙启用引用缺少当前启动周期证据，未释放引用")
                    }
                    _ = try command(["-X", token])
                }
            } catch { releaseWarning = "自有阻断已清理；PF 启用引用未确认释放：" + error.localizedDescription }
        }
        // 私有审计记录不能作为下次启动重新施加保护的依据。
        try SecureFile.write(JSONEncoder().encode(lease), to: directory.appendingPathComponent("disconnect-protection-released.json"), durable: true)
        if let releaseWarning {
            try SecureFile.write(Data(releaseWarning.utf8), to: directory.appendingPathComponent("disconnect-protection-release-warning.txt"), durable: true)
        }
        try FileManager.default.removeItem(at:record)
        self.lease=nil
        try? FileManager.default.removeItem(at:configuration)
        try? FileManager.default.removeItem(at:rootConfiguration)
    }
}
