import Foundation
import SystemConfiguration
import Security

struct ProxyRecord: Codable {
    var serviceID: String
    var original: Data
    var applied: Data
    var originallyEnabled: Bool
    var hadProtocol: Bool
}
struct ProxyJournal: Codable { var records: [ProxyRecord] }
@MainActor public final class SystemProxyController {
    public let journal: URL
    private var authorization: AuthorizationRef?
    public var onNetworkChange: (() -> Void)?
    private var monitor: SCDynamicStore?
    private var monitoredSignature: String?
    private let preferencesFactory: (() throws -> SCPreferences)?
    private let commitHandler: ((SCPreferences) throws -> Void)?
    public init(journal: URL, preferencesFactory: (() throws -> SCPreferences)? = nil, commitHandler: ((SCPreferences) throws -> Void)? = nil) {
        self.journal = journal;self.preferencesFactory = preferencesFactory;self.commitHandler = commitHandler
    }
    public var hasRecovery: Bool { FileManager.default.fileExists(atPath: journal.path) }
    private func preferences() throws -> SCPreferences {
        if let preferencesFactory {
            let preferences = try preferencesFactory()
            guard SCPreferencesLock(preferences,true) else {throw ProxyError("无法锁定网络配置")}
            return preferences
        }
        if authorization == nil {
            let flags: AuthorizationFlags = [.interactionAllowed,.extendRights,.preAuthorize]
            var auth: AuthorizationRef?
            guard AuthorizationCreate(nil,nil,flags,&auth) == errAuthorizationSuccess else { throw ProxyError("系统授权被取消或失败") }
            authorization = auth
        }
        guard let p = SCPreferencesCreateWithAuthorization(nil,"轻舟代理" as CFString,nil,authorization) else { throw ProxyError("无法打开系统网络配置") }
        guard SCPreferencesLock(p,true) else { throw ProxyError("无法锁定网络配置") }
        return p
    }
    private func dict(_ data: Data) throws -> [String:Any] { guard let value = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else { throw ProxyError("代理恢复记录损坏") }; return value }
    private func encode(_ dict: [String:Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList:dict,format:.binary,options:0) }
    private func save(_ records: [ProxyRecord]) throws { try SecureFile.write(JSONEncoder().encode(ProxyJournal(records:records)), to:journal) }
    private func commit(_ preferences: SCPreferences) throws {
        if let commitHandler {try commitHandler(preferences);return}
        guard SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else { throw ProxyError("系统代理修改失败，请执行恢复原代理") }
    }
    public func apply(port: Int) throws {
        guard !hasRecovery else { throw ProxyError("存在未恢复的代理设置，请先恢复原代理") }
        let p = try preferences(); defer {SCPreferencesUnlock(p)}
        guard let set = SCNetworkSetCopyCurrent(p), let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { throw ProxyError("无法读取当前网络服务") }
        var records: [ProxyRecord] = []
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let serviceID = SCNetworkServiceGetServiceID(service) else { continue }
            let id = serviceID as String
            let existing = SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies)
            let original = existing.flatMap {SCNetworkProtocolGetConfiguration($0) as? [String:Any]} ?? [:]
            let applied = ProxyRecovery.applied(to:original,port:port)
            let record = ProxyRecord(serviceID:id,original:try encode(original),applied:try encode(applied),originallyEnabled:existing.map {SCNetworkProtocolGetEnabled($0)} ?? false,hadProtocol:existing != nil)
            records.append(record)
        }
        guard !records.isEmpty else { throw ProxyError("没有启用的网络服务") }
        // 在系统配置提交前持久化恢复记录，支持进程被强制结束后的恢复。
        try save(records)
        for record in records {
            guard let service = SCNetworkServiceCopy(p,record.serviceID as CFString) else { throw ProxyError("网络服务已变化") }
            if !record.hadProtocol, !SCNetworkServiceAddProtocolType(service,kSCNetworkProtocolTypeProxies) { throw ProxyError("无法添加代理协议") }
            guard let proto = SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies), SCNetworkProtocolSetConfiguration(proto,try dict(record.applied) as CFDictionary), SCNetworkProtocolSetEnabled(proto,true) else { throw ProxyError("无法设置系统代理") }
        }
        try commit(p)
    }
    public func restore() throws {
        guard hasRecovery else { return }
        let records: [ProxyRecord]
        do { records = try JSONDecoder().decode(ProxyJournal.self,from:Data(contentsOf:journal)).records } catch { throw ProxyError("代理恢复记录损坏，请按使用说明手动恢复") }
        let p = try preferences(); defer {SCPreferencesUnlock(p)}
        var conflicts: [ProxyRecord] = []
        for record in records {
            guard let service = SCNetworkServiceCopy(p,record.serviceID as CFString) else { continue }
            guard let proto = SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies) else { continue }
            let current = SCNetworkProtocolGetConfiguration(proto) as? [String:Any] ?? [:]
            let original = try dict(record.original)
            if NSDictionary(dictionary:current).isEqual(to:original), SCNetworkProtocolGetEnabled(proto) == record.originallyEnabled { continue }
            guard SCNetworkProtocolGetEnabled(proto), let restored = ProxyRecovery.restored(original:original,applied:try dict(record.applied),current:current) else { conflicts.append(record); continue }
            guard SCNetworkProtocolSetConfiguration(proto,restored as CFDictionary), SCNetworkProtocolSetEnabled(proto,record.originallyEnabled) else { conflicts.append(record); continue }
            if !record.hadProtocol && restored.isEmpty && !SCNetworkServiceRemoveProtocolType(service,kSCNetworkProtocolTypeProxies) {conflicts.append(record)}
        }
        try commit(p)
        if conflicts.isEmpty { try FileManager.default.removeItem(at:journal) }
        else { try save(conflicts); throw ProxyError("部分网络服务已被外部修改，未覆盖其设置；请检查系统代理后重试恢复") }
    }
    public func startMonitoring() {
        var context = SCDynamicStoreContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        monitor = SCDynamicStoreCreate(nil,"轻舟网络监控" as CFString,{ _, _, info in
            guard let info else { return }
            let controller = Unmanaged<SystemProxyController>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in controller.checkNetwork() }
        },&context)
        guard let monitor else { return }
        SCDynamicStoreSetNotificationKeys(monitor,nil,["State:/Network/Global/IPv4","State:/Network/Global/IPv6","Setup:/Network/Global/IPv4","Setup:/Network/Global/IPv6"] as CFArray)
        SCDynamicStoreSetDispatchQueue(monitor,DispatchQueue.main)
        monitoredSignature = signature()
    }
    private func signature() -> String {
        guard let monitor else { return "" }
        return ["State:/Network/Global/IPv4","State:/Network/Global/IPv6"].map {key in
            let values = SCDynamicStoreCopyValue(monitor,key as CFString) as? [String:Any] ?? [:]
            return "\(values["PrimaryService"] ?? "")|\(values["PrimaryInterface"] ?? "")"
        }.joined(separator:";")
    }
    private func checkNetwork() { let value = signature(); if let old = monitoredSignature, old != value { onNetworkChange?() }; monitoredSignature = value }
}
