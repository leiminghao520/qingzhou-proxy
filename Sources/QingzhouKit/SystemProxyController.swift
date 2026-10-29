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
    public var onEnvironmentChange:(() -> Void)?
    public var log:((String)->Void)?
    private var monitor: SCDynamicStore?
    private var monitoredSignature: String?
    private var requiredExceptions:[String]=[]
    private var observedRecords:[ProxyRecord]?
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
    public func observeManagedProxy(port:Int) throws {
        guard let p=SCPreferencesCreate(nil,"轻舟代理只读观察" as CFString,nil),let set=SCNetworkSetCopyCurrent(p),let services=SCNetworkSetCopyServices(set) as? [SCNetworkService] else{throw ProxyError("无法读取系统代理")}
        var records:[ProxyRecord]=[]
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let id=SCNetworkServiceGetServiceID(service),let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies),let values=SCNetworkProtocolGetConfiguration(proto) as? [String:Any] else{continue}
            let data=try encode(values)
            records.append(ProxyRecord(serviceID:id as String,original:data,applied:data,originallyEnabled:true,hadProtocol:true))
        }
        guard !records.isEmpty else{throw ProxyError("系统代理观察快照为空")}
        observedRecords=records;ownedPort=port;requiredExceptions=[];ownershipMismatchCount=0;monitoredSignature=signature()
    }
    public func clearManagedObservation(){observedRecords=nil;ownedPort=nil;requiredExceptions=[];ownershipMismatchCount=0;monitoredSignature=signature()}
    public func apply(port: Int,ownedTunDNS:String?=nil,protectedDomains:[String]=[],exceptions:[String]=[]) throws {
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
            let applied = try ProxyRecovery.applied(to:original,port:port,protectedDomains:protectedDomains,exceptions:exceptions)
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
        requiredExceptions=try ProtectedDomainPolicy.exceptions(protectedDomains)+exceptions
        ownedPort=port;ownershipMismatchCount=0
        monitoredSignature=signature()
        try commit(p)
    }
    public func restore(preserveExternal:Bool=false) throws {
        guard hasRecovery else {clearManagedObservation();return}
        let records: [ProxyRecord]
        do { records = try JSONDecoder().decode(ProxyJournal.self,from:Data(contentsOf:journal)).records } catch { throw ProxyError("代理恢复记录损坏，请按使用说明手动恢复") }
        let p = try preferences(); defer {SCPreferencesUnlock(p)}
        var conflicts: [ProxyRecord] = []
        var externalPreserved=false
        for record in records {
            guard let service = SCNetworkServiceCopy(p,record.serviceID as CFString) else { continue }
            guard let proto = SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies) else { continue }
            let current = SCNetworkProtocolGetConfiguration(proto) as? [String:Any] ?? [:]
            let original = try dict(record.original)
            let safeOriginal=NetworkSafety.restoration(original,listening:NetworkSafety.loopbackListening)
            if !NSDictionary(dictionary:safeOriginal).isEqual(to:original){log?("恢复快照中的回环代理已停止监听，恢复本次拥有的设置时不再启用该失效入口")}
            if NSDictionary(dictionary:current).isEqual(to:original), SCNetworkProtocolGetEnabled(proto) == record.originallyEnabled { continue }
            let applied=try dict(record.applied)
            let strict=SCNetworkProtocolGetEnabled(proto) ? ProxyRecovery.restored(original:safeOriginal,applied:applied,current:current):nil
            guard strict != nil || preserveExternal else {conflicts.append(record);continue}
            if strict==nil {externalPreserved=true}
            let restored=strict ?? ProxyRecovery.restoredPreservingExternal(original:safeOriginal,applied:applied,current:current)
            let enabled=strict == nil ? SCNetworkProtocolGetEnabled(proto):record.originallyEnabled
            guard !preserveExternal || !enabled || !ProxyRecovery.pointsToOwnedEndpoint(current:restored,applied:applied) else {conflicts.append(record);continue}
            guard SCNetworkProtocolSetConfiguration(proto,restored as CFDictionary),SCNetworkProtocolSetEnabled(proto,enabled) else {conflicts.append(record);continue}
            if !record.hadProtocol && restored.isEmpty && !SCNetworkServiceRemoveProtocolType(service,kSCNetworkProtocolTypeProxies) {conflicts.append(record)}
        }
        try commit(p)
        requiredExceptions=[];ownedPort=nil;ownershipMismatchCount=0
        monitoredSignature=signature()
        if conflicts.isEmpty {
            if preserveExternal {
                try verifyReleased(records:records,preferences:p)
                if externalPreserved {
                    let archive=journal.deletingLastPathComponent().appendingPathComponent("proxy-recovery-preserved-"+UUID().uuidString+".json")
                    try SecureFile.write(Data(contentsOf:journal),to:archive)
                    log?("外部系统代理已保留，轻舟恢复记录已归档")
                }
            }
            try FileManager.default.removeItem(at:journal)
        }
        else { log?("代理恢复存在外部修改冲突，保留恢复记录，未覆盖外部设置");try save(conflicts); throw ProxyError("部分网络服务已被外部修改，未覆盖其设置；请检查系统代理后重试恢复") }
    }
    public func verifyReleased() throws {
        guard hasRecovery else{return}
        let records=try JSONDecoder().decode(ProxyJournal.self,from:Data(contentsOf:journal)).records
        let p=try preferences();defer{SCPreferencesUnlock(p)}
        try verifyReleased(records:records,preferences:p)
    }
    private func verifyReleased(records:[ProxyRecord],preferences:SCPreferences) throws {
        guard let live=SCDynamicStoreCopyProxies(nil) as? [String:Any] else{throw ProxyError("无法确认当前代理已离开轻舟入口")}
        for record in records {
            let applied=try dict(record.applied)
            guard !ProxyRecovery.pointsToOwnedEndpoint(current:live,applied:applied) else{throw ProxyError("当前生效代理仍指向轻舟，尚不能退出")}
            if let service=SCNetworkServiceCopy(preferences,record.serviceID as CFString),let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies),SCNetworkProtocolGetEnabled(proto),let current=SCNetworkProtocolGetConfiguration(proto) as? [String:Any],ProxyRecovery.pointsToOwnedEndpoint(current:current,applied:applied) {throw ProxyError("网络服务仍指向轻舟入口，尚不能退出")}
        }
    }
    // 唤醒复查只读核对代理和原 DNS 保护，不能因状态文字而认领当前入口。
    public func verifyWakeOwnership() async throws {
        try await verifyApplied()
        guard let changes=ownershipChanges(),changes.isEmpty else {throw WakeRecoveryError(.ownershipConflict)}
    }
    public func verifyApplied() async throws {
        for _ in 0..<30 {
            guard hasRecovery || observedRecords != nil,let changes=ownershipChanges(),changes.isEmpty else {throw ProxyError("系统代理提交后的持久配置核对失败")}
            if let settings=SCDynamicStoreCopyProxies(nil) as? [String:Any],let port=ownedPort,
               requiredExceptions.allSatisfy({(settings["ExceptionsList"] as? [String] ?? []).contains($0)}),
               ["HTTP","HTTPS"].allSatisfy({prefix in (settings[prefix+"Enable"] as? NSNumber)?.intValue==1 && settings[prefix+"Proxy"] as? String=="127.0.0.1" && (settings[prefix+"Port"] as? NSNumber)?.intValue==port}) {return}
            // 系统动态配置可能晚于持久提交收敛，限定预算等待，不把瞬态当成失败。
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw ProxyError("系统代理入口在三秒内未生效")
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
        let records=observedRecords ?? (try? Data(contentsOf:journal)).flatMap{try? JSONDecoder().decode(ProxyJournal.self,from:$0).records}
        guard let records,let preferences=SCPreferencesCreate(nil,"轻舟所有权核对" as CFString,nil) else{return nil}
        var changes=Set<String>()
        for record in records {
            guard let service=SCNetworkServiceCopy(preferences,record.serviceID as CFString),let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies),let current=SCNetworkProtocolGetConfiguration(proto) as? [String:Any],let expected=try? dict(record.applied) else{return nil}
            if !SCNetworkProtocolGetEnabled(proto){changes.insert("ProtocolEnabled")}
            let original=try? dict(record.original)
            let protectsExceptions = observedRecords != nil || !NSArray(array:(original?["ExceptionsList"] as? [String]) ?? []).isEqual(to:(expected["ExceptionsList"] as? [String]) ?? [])
            // 本轮不修改简单主机名开关，因此不把它认领为本应用所有。
            changes.formUnion(ProxyRecovery.changedOwnedKeys(expected:expected,current:current,protectsExceptions:protectsExceptions).filter{$0 != "ExcludeSimpleHostnames"})
        }
        return changes.sorted()
    }
    private func checkNetwork() {
        let value=signature();let environmentChanged=monitoredSignature.map{$0 != value} ?? false
        monitoredSignature=value
        guard ownedPort != nil else {
            ownershipMismatchCount=0
            if environmentChanged {onEnvironmentChange?()}
            return
        }
        // DNS、网络状态及系统合成代理字段变化不代表持久代理所有权丢失。
        guard let changes=ownershipChanges() else {
            if environmentChanged{log?("网络监控：所有权暂无法核对，保留连接")}
            return
        }
        if changes.isEmpty {
            ownershipMismatchCount=0
            if environmentChanged{log?("网络监控：环境更新，代理所有权正常，重新检测链路");onEnvironmentChange?()}
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
