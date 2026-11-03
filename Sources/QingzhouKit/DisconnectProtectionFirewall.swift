import Foundation

// 独立于路由恢复日志持久化；核心、GUI 或控制通道意外退出不能撤销拒绝规则。
public final class DisconnectProtectionFirewall {
    private struct Lease:Codable {
        var anchor:String
        var allowed:[String]
        var tunnel:String?
        var expected:String?
        var token:String?
    }
    private let directory:URL
    private let command:([String]) throws -> String
    private var lease:Lease?
    private var record:URL {directory.appendingPathComponent("disconnect-protection.json")}
    private var configuration:URL {directory.appendingPathComponent("disconnect-protection.conf")}
    public var armed:Bool {lease != nil || FileManager.default.fileExists(atPath:record.path)}
    public init(directory:URL,command:@escaping ([String]) throws -> String) {self.directory=directory;self.command=command}
    private func load() throws {
        guard lease==nil,FileManager.default.fileExists(atPath:record.path) else{return}
        let attributes=try FileManager.default.attributesOfItem(atPath:record.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,let permissions=(attributes[.posixPermissions] as? NSNumber)?.intValue,permissions&0o077==0 else{throw ProxyError("断线保护记录权限无效")}
        let value=try JSONDecoder().decode(Lease.self,from:Data(contentsOf:record))
        guard value.anchor.range(of:"^com\\.apple/qingzhou-lock-[0-9a-f-]{36}$",options:.regularExpression) != nil else{throw ProxyError("断线保护锚点记录无效")}
        _=try DisconnectProtectionPolicy.rules(allowed:value.allowed,tunnel:value.tunnel)
        lease=value
    }
    private func save() throws {if let lease {try SecureFile.write(JSONEncoder().encode(lease),to:record,durable:true)}}
    public func preflight() throws {
        try load()
        do {try PinnedBypassPolicy.validateFirewallRoot(command(["-sr"]))}
        catch {throw ProxyError("断线保护不可用：系统防火墙包含企业 VPN 或其他不兼容规则，未改写现有防火墙")}
        let children=try command(["-a","com.apple","-s","Anchors"]).components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        guard children.allSatisfy({$0==lease?.anchor || $0==lease?.anchor.components(separatedBy:"/").last}) else{throw ProxyError("断线保护不可用：保护锚点有其他组件，无法确认规则顺序")}
    }
    public func verify() throws {
        try load()
        guard let lease else{return}
        try preflight()
        guard try command(["-si"]).contains("Status: Enabled"),let expected=lease.expected,try command(["-a",lease.anchor,"-sr"])==expected else{throw ProxyError("断线保护规则已被外部修改或状态不明，保留记录并拒绝解除")}
    }
    private func apply(tunnel:String?,first:Bool) throws {
        guard var next=lease else{return}
        let rules=try DisconnectProtectionPolicy.rules(allowed:next.allowed,tunnel:tunnel)
        try SecureFile.write(Data(rules.utf8),to:configuration,durable:true)
        _=try command(["-n","-a",next.anchor,"-f",configuration.path])
        next.tunnel=tunnel;lease=next;try save()
        _=try command(["-a",next.anchor,"-f",configuration.path])
        let actual=try command(["-a",next.anchor,"-sr"])
        guard !actual.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ProxyError("断线保护规则加载后为空，拒绝继续接管")}
        lease?.expected=actual;try save()
        let enabled=try command(["-si"]).contains("Status: Enabled")
        if first || !enabled {
            let output=try command(["-E"])
            guard let line=output.components(separatedBy:.newlines).first(where:{$0.contains("Token")}),let token=line.split(whereSeparator:{$0.isWhitespace || $0==":"}).last,UInt64(token).map({$0>0})==true else{throw ProxyError("断线保护未取得防火墙启用凭据，保留记录")}
            lease?.token=String(token);try save()
        }
        if first {
            // 已有浮动状态可能绕过新规则；首次开启明确中断旧连接，两种地址族分别清理。
            _=try command(["-k","0.0.0.0/0"])
            _=try command(["-k","::/0"])
        }
        try verify()
    }
    public func arm(allowed:[String]) throws {
        try preflight()
        let normalized=Array(Set(allowed)).sorted()
        if let lease {
            guard lease.allowed==normalized else{throw ProxyError("保护生效期间不能更换固定出口或网络例外，请先手动断开")}
            try verify();try apply(tunnel:nil,first:false);return
        }
        lease=Lease(anchor:"com.apple/qingzhou-lock-"+UUID().uuidString.lowercased(),allowed:normalized)
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
        if !current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {try verify()}
        _=try command(["-a",lease.anchor,"-F","all"])
        guard try command(["-a",lease.anchor,"-sr"]).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ProxyError("断线保护清理核验失败，记录已保留")}
        if let token=lease.token {guard UInt64(token).map({$0>0})==true else{throw ProxyError("防火墙启用凭据无效")};_=try command(["-X",token])}
        try FileManager.default.removeItem(at:record)
        self.lease=nil
        try? FileManager.default.removeItem(at:configuration)
    }
}
