import Foundation

// 独立于路由恢复日志持久化；核心、GUI 或控制通道意外退出不能撤销拒绝规则。
public final class DisconnectProtectionFirewall {
    private struct Lease:Codable {
        var anchor:String
        var allowed:[String]
        var tunnel:String?
        var expected:String?
        var token:String?
        var rootBefore:String?
        var rootExpected:String?
        var yunshuAddresses:[String]?
        var strictEndpoint: ClaudeNetworkEndpoint?
        var policyVersion: Int?
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
        if let endpoint = value.strictEndpoint {
            guard value.policyVersion == nil || value.policyVersion == ClaudePFPolicy.version else { throw ProxyError("整机保护规则版本无效") }
            _ = try ClaudePFPolicy.rules(endpoint: endpoint, tunnel: value.tunnel)
        } else { _=try DisconnectProtectionPolicy.rules(allowed:value.allowed,tunnel:value.tunnel) }
        lease=value
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
        guard try command(["-si"]).contains("Status: Enabled"),let expected=lease.expected,try command(["-a",lease.anchor,"-sr"])==expected else{throw ProxyError("断线保护规则已被外部修改或状态不明，保留记录并拒绝解除")}
    }
    public func verifyClaudeSafety(endpoint: String) throws -> Bool {
        try load()
        guard let lease else { return false }
        try verify()
        return lease.policyVersion == ClaudePFPolicy.version && lease.strictEndpoint?.address == endpoint
            && (lease.yunshuAddresses ?? []).isEmpty
    }
    public func verifyStrict(endpoint: ClaudeNetworkEndpoint) throws -> Bool {
        guard try verifyClaudeSafety(endpoint: endpoint.address) else { return false }
        return lease?.strictEndpoint == endpoint
    }
    public func armStrict(endpoint: ClaudeNetworkEndpoint) throws {
        _ = try ClaudePFPolicy.rules(endpoint: endpoint, tunnel: nil)
        try preflight()
        if let current = lease {
            try verify()
            if current.strictEndpoint == endpoint, current.policyVersion == ClaudePFPolicy.version {
                try apply(tunnel: nil, first: false)
                return
            }
            if let pinned = current.strictEndpoint, pinned != endpoint {
                throw ProxyError("请先明确解除保护，再更换固定出口")
            }
            // 迁移只收紧规则；失败也不恢复旧的云枢或私网例外。
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
                yunshuAddresses: [], strictEndpoint: endpoint, policyVersion: nil)
            try save()
            try apply(tunnel: nil, first: true)
        }
    }

    private func apply(tunnel:String?,first:Bool) throws {
        guard var next=lease else{return}
        let needsStateReset = first || (next.strictEndpoint != nil && next.policyVersion != ClaudePFPolicy.version)
        let rules = try next.strictEndpoint.map { try ClaudePFPolicy.rules(endpoint: $0, tunnel: tunnel) }
            ?? DisconnectProtectionPolicy.rules(allowed: next.allowed, tunnel: tunnel)
        try SecureFile.write(Data(rules.utf8),to:configuration,durable:true)
        _=try command(["-n","-a",next.anchor,"-f",configuration.path])
        next.tunnel=tunnel;lease=next;try save()
        _=try command(["-a",next.anchor,"-f",configuration.path])
        let actual=try command(["-a",next.anchor,"-sr"])
        guard !actual.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ProxyError("断线保护规则加载后为空，拒绝继续接管")}
        lease?.expected=actual;try save()
        let enabled=try command(["-si"]).contains("Status: Enabled")
        if !enabled || (first && next.token == nil) {
            let output=try command(["-E"])
            guard let line=output.components(separatedBy:.newlines).first(where:{$0.contains("Token")}),let token=line.split(whereSeparator:{$0.isWhitespace || $0==":"}).last,UInt64(token).map({$0>0})==true else{throw ProxyError("断线保护未取得防火墙启用凭据，保留记录")}
            lease?.token=String(token);try save()
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
    public func attach(tunnel:String) throws {try load();guard lease != nil else{return};try verify();try apply(tunnel:tunnel,first:false)}
    public func suspend() throws {try load();guard lease != nil else{return};try verify();if lease?.tunnel != nil {try apply(tunnel:nil,first:false)}}
    public func restoreAfterRestart() throws {
        try load();guard let lease else{return}
        try preflight()
        let current=try command(["-a",lease.anchor,"-sr"])
        // 重启后规则可为空；存在不同规则时不能认领或覆盖。
        guard current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || current==lease.expected else{throw ProxyError("断线保护锚点已有外部修改，未覆盖")}
        try apply(tunnel:nil,first:current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
    }
    public func release() throws {
        try load();guard let lease else{return}
        try preflight()
        let current=try command(["-a",lease.anchor,"-sr"])
        let detached=try lease.rootBefore.map{Self.normalizedRoot(try command(["-sr"])) == Self.normalizedRoot($0)} ?? false
        if !current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            if detached {guard current == lease.expected else{throw ProxyError("未挂接的保护锚点已有外部修改，未清理")}}
            else {try verify()}
        }
        if let before=lease.rootBefore,!detached {try loadRoot(Self.normalizedRoot(before))}
        _=try command(["-a",lease.anchor,"-F","all"])
        guard try command(["-a",lease.anchor,"-sr"]).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ProxyError("断线保护清理核验失败，记录已保留")}
        if let token=lease.token {guard UInt64(token).map({$0>0})==true else{throw ProxyError("防火墙启用凭据无效")};_=try command(["-X",token])}
        try FileManager.default.removeItem(at:record)
        self.lease=nil
        try? FileManager.default.removeItem(at:configuration)
        try? FileManager.default.removeItem(at:rootConfiguration)
    }
}
