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
    public var log:((String)->Void)?
    private var monitor: SCDynamicStore?
    private var monitoredSignature: String?
    private var ownedPort:Int?
    private var ownershipMismatchCount=0
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
    public func apply(port: Int,ownedTunDNS:String?=nil) throws {
        guard !hasRecovery else { throw ProxyError("存在未恢复的代理设置，请先恢复原代理") }
        if preferencesFactory==nil {try NetworkSafety.check(ownedDNS:ownedTunDNS)}
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
        ownedPort=port;ownershipMismatchCount=0
        monitoredSignature=signature()
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
            let safeOriginal=NetworkSafety.restoration(original,listening:NetworkSafety.loopbackListening)
            if !NSDictionary(dictionary:safeOriginal).isEqual(to:original){log?("恢复快照中的回环代理已停止监听，恢复本次拥有的设置时不再启用该失效入口")}
            if NSDictionary(dictionary:current).isEqual(to:original), SCNetworkProtocolGetEnabled(proto) == record.originallyEnabled { continue }
            guard SCNetworkProtocolGetEnabled(proto), let restored = ProxyRecovery.restored(original:safeOriginal,applied:try dict(record.applied),current:current) else { conflicts.append(record); continue }
            guard SCNetworkProtocolSetConfiguration(proto,restored as CFDictionary), SCNetworkProtocolSetEnabled(proto,record.originallyEnabled) else { conflicts.append(record); continue }
            if !record.hadProtocol && restored.isEmpty && !SCNetworkServiceRemoveProtocolType(service,kSCNetworkProtocolTypeProxies) {conflicts.append(record)}
        }
        try commit(p)
        ownedPort=nil;ownershipMismatchCount=0
        monitoredSignature=signature()
        if conflicts.isEmpty { try FileManager.default.removeItem(at:journal) }
        else { log?("代理恢复存在外部修改冲突，保留恢复记录，未覆盖外部设置");try save(conflicts); throw ProxyError("部分网络服务已被外部修改，未覆盖其设置；请检查系统代理后重试恢复") }
    }
    public func startMonitoring() {
        var context = SCDynamicStoreContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        monitor = SCDynamicStoreCreate(nil,"轻舟网络监控" as CFString,{ _, _, info in
            guard let info else { return }
            let controller = Unmanaged<SystemProxyController>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                // 等待本应用提交的动态设置收敛，随后再判断外部变更。
                try? await Task.sleep(nanoseconds:300_000_000)
                controller.checkNetwork()
            }
        },&context)
        guard let monitor else { return }
        SCDynamicStoreSetNotificationKeys(monitor,nil,["State:/Network/Global/IPv4","State:/Network/Global/IPv6","Setup:/Network/Global/IPv4","Setup:/Network/Global/IPv6","State:/Network/Global/DNS","State:/Network/Global/Proxies","State:/Network/Service/.*/DNS","State:/Network/Service/.*/Proxies","Setup:/Network/Service/.*/DNS","Setup:/Network/Service/.*/Proxies"] as CFArray)
        SCDynamicStoreSetDispatchQueue(monitor,DispatchQueue.main)
        monitoredSignature = signature()
    }
    private func signature() -> String {
        guard let monitor else { return "" }
        let primary=["State:/Network/Global/IPv4","State:/Network/Global/IPv6"].map {key in
            let values=SCDynamicStoreCopyValue(monitor,key as CFString) as? [String:Any] ?? [:]
            return "\(values["PrimaryService"] ?? "")|\(values["PrimaryInterface"] ?? "")"
        }
        let pattern=ownedPort==nil ? "State:/Network/.*(DNS|Proxies)$":"State:/Network/.*DNS$"
        let keys=(SCDynamicStoreCopyKeyList(monitor,pattern as CFString) as? [String] ?? []).sorted()
        let settings=keys.map{key -> String in
            let values=SCDynamicStoreCopyValue(monitor,key as CFString) as? [String:Any] ?? [:]
            let data=(try? JSONSerialization.data(withJSONObject:values,options:.sortedKeys)) ?? Data()
            return key+":"+data.base64EncodedString()
        }
        return (primary+settings).joined(separator:";")
    }
    private func ownershipChanges()->[String]? {
        guard let data=try? Data(contentsOf:journal),let records=try? JSONDecoder().decode(ProxyJournal.self,from:data),let preferences=SCPreferencesCreate(nil,"轻舟所有权核对" as CFString,nil) else{return nil}
        var changes=Set<String>()
        for record in records.records {
            guard let service=SCNetworkServiceCopy(preferences,record.serviceID as CFString),let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies),let current=SCNetworkProtocolGetConfiguration(proto) as? [String:Any],let expected=try? dict(record.applied) else{return nil}
            if !SCNetworkProtocolGetEnabled(proto){changes.insert("ProtocolEnabled")}
            changes.formUnion(ProxyRecovery.changedOwnedKeys(expected:expected,current:current))
        }
        return changes.sorted()
    }
    private func checkNetwork() {
        let value=signature();let environmentChanged=monitoredSignature.map{$0 != value} ?? false
        monitoredSignature=value
        guard ownedPort != nil else {ownershipMismatchCount=0;return}
        // DNS、网络状态及系统合成代理字段变化不代表持久代理所有权丢失。
        guard let changes=ownershipChanges() else {
            if environmentChanged{log?("网络监控：所有权暂无法核对，保留连接")}
            return
        }
        if changes.isEmpty {
            ownershipMismatchCount=0
            if environmentChanged{log?("网络监控：环境更新，代理所有权正常，保留连接")}
            return
        }
        ownershipMismatchCount+=1
        log?("网络监控：持久代理字段变更 keys="+changes.joined(separator:","))
        if ownershipMismatchCount>=2 {ownershipMismatchCount=0;onNetworkChange?();return}
        // 再次核对稳定状态，避免系统提交期间的短暂变化被当成外部接管。
        Task{ @MainActor [weak self] in
            try? await Task.sleep(nanoseconds:1_000_000_000)
            self?.checkNetwork()
        }
    }
}
