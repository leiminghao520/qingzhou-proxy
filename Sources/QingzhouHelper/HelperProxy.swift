import Foundation
import SystemConfiguration
import QingzhouKit

struct HelperProxyRecord:Codable {
    var service:String
    var original:Data
    var applied:Data
    var enabled:Bool
    var hadProtocol:Bool
}
extension Service {
    func verifyNoOwnedProxyEndpoint(_ records:[HelperProxyRecord]) throws {
        guard !records.isEmpty else{return}
        let preferences=try proxyPreferences();defer{SCPreferencesUnlock(preferences)}
        guard let live=SCDynamicStoreCopyProxies(nil) as? [String:Any] else{throw ProxyError("当前生效代理无法读取，不能保留外部网络并释放恢复记录")}
        for record in records {
            let applied=try plist(record.applied)
            if ProxyRecovery.pointsToOwnedEndpoint(current:live,applied:applied) {throw ProxyError("当前系统代理仍指向轻舟，不能按外部接管方式释放恢复记录")}
            if let service=SCNetworkServiceCopy(preferences,record.service as CFString),let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies),SCNetworkProtocolGetEnabled(proto),let current=SCNetworkProtocolGetConfiguration(proto) as? [String:Any],ProxyRecovery.pointsToOwnedEndpoint(current:current,applied:applied) {throw ProxyError("代理服务仍有轻舟入口，不能保留该残留")}
        }
    }
    func proxyPreferences() throws -> SCPreferences {
        guard let preferences=SCPreferencesCreate(nil,"轻舟兼容接管" as CFString,nil),SCPreferencesLock(preferences,true) else{throw ProxyError("无法锁定代理配置")};return preferences
    }
    func plist(_ data:Data) throws -> [String:Any] {guard let value=try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else{throw ProxyError("代理快照无效")};return value}
    func commitProxy(_ preferences:SCPreferences) throws {
        guard SCPreferencesCommitChanges(preferences),SCPreferencesApplyChanges(preferences) else{throw ProxyError("兼容代理提交失败")}
    }
    func applyProxy(port:Int,plan:CapturePlan) throws {
        guard CoreController.listening(port) else{throw ProxyError("兼容代理入口尚未监听")}
        let preferences=try proxyPreferences();defer{SCPreferencesUnlock(preferences)}
        guard let set=SCNetworkSetCopyCurrent(preferences),let services=SCNetworkSetCopyServices(set) as? [SCNetworkService] else{throw ProxyError("当前网络服务无法读取")}
        var records:[HelperProxyRecord]=[]
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let id=SCNetworkServiceGetServiceID(service) else{continue}
            let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies)
            let original=proto.flatMap{SCNetworkProtocolGetConfiguration($0) as? [String:Any]} ?? [:]
            var applied=try ProxyRecovery.applied(to:original,port:port,protectedDomains:plan.domains)
            let exceptions=(original["ExceptionsList"] as? [String] ?? [])+plan.exclusions+plan.protectedRoutes.map(\.destination)+plan.domains.flatMap{[$0,"*."+$0]}
            var ordered=original["ExceptionsList"] as? [String] ?? []
            for entry in exceptions where !ordered.contains(entry) {ordered.append(entry)}
            applied["ExceptionsList"]=ordered
            applied["ExcludeSimpleHostnames"]=1
            records.append(HelperProxyRecord(service:id as String,original:try PropertyListSerialization.data(fromPropertyList:original,format:.binary,options:0),applied:try PropertyListSerialization.data(fromPropertyList:applied,format:.binary,options:0),enabled:proto.map{SCNetworkProtocolGetEnabled($0)} ?? false,hadProtocol:proto != nil))
        }
        guard !records.isEmpty else{throw ProxyError("没有可用代理服务")}
        journal!.proxies=records;try save()
        for record in records {
            guard let service=SCNetworkServiceCopy(preferences,record.service as CFString) else{throw ProxyError("代理服务已变化")}
            if !record.hadProtocol {guard SCNetworkServiceAddProtocolType(service,kSCNetworkProtocolTypeProxies) else{throw ProxyError("代理协议创建失败")}}
            guard let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies),SCNetworkProtocolSetConfiguration(proto,try plist(record.applied) as CFDictionary),SCNetworkProtocolSetEnabled(proto,true) else{throw ProxyError("兼容代理配置失败")}
        }
        try commitProxy(preferences)
    }
    func restoreProxy(_ records:[HelperProxyRecord],preserveExternal:Bool=false) throws -> [String] {
        guard !records.isEmpty else{return []}
        let preferences=try proxyPreferences();defer{SCPreferencesUnlock(preferences)};var issues:[String]=[]
        for (index,record) in records.enumerated() {
            let label="系统代理服务 "+String(index+1)
            guard let service=SCNetworkServiceCopy(preferences,record.service as CFString),let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies) else{continue}
            let current=SCNetworkProtocolGetConfiguration(proto) as? [String:Any] ?? [:],original=try plist(record.original)
            if NSDictionary(dictionary:current).isEqual(to:original),SCNetworkProtocolGetEnabled(proto)==record.enabled {continue}
            let applied=try plist(record.applied)
            let strict=SCNetworkProtocolGetEnabled(proto) ? ProxyRecovery.restored(original:original,applied:applied,current:current):nil
            guard strict != nil || preserveExternal else{
                let changed=ProxyRecovery.changedOwnedKeys(expected:applied,current:current,protectsExceptions:true)
                issues.append(label+" 已有外部修改，保留当前值："+(changed.isEmpty ? "协议启用状态":changed.joined(separator:",")));continue
            }
            let restored=strict ?? ProxyRecovery.restoredPreservingExternal(original:original,applied:applied,current:current)
            let enabled=strict == nil ? SCNetworkProtocolGetEnabled(proto):record.enabled
            guard !preserveExternal || !enabled || !ProxyRecovery.pointsToOwnedEndpoint(current:restored,applied:applied) else{issues.append(label+" 仍指向轻舟入口");continue}
            guard SCNetworkProtocolSetConfiguration(proto,restored as CFDictionary),SCNetworkProtocolSetEnabled(proto,enabled) else{issues.append(label+" 恢复写入失败");continue}
            if !record.hadProtocol,restored.isEmpty,!SCNetworkServiceRemoveProtocolType(service,kSCNetworkProtocolTypeProxies) {issues.append(label+" 临时代理协议移除失败")}
        }
        try commitProxy(preferences);return issues
    }
    func verifyProxy()->Bool {proxyOwnershipIssues().isEmpty}
    func proxyOwnershipIssues()->[String] {
        guard let records=journal?.proxies,!records.isEmpty else{return ["系统代理应用快照缺失"]}
        guard let preferences=SCPreferencesCreate(nil,"轻舟代理核对" as CFString,nil) else{return ["系统代理配置无法读取"]}
        var issues:[String]=[]
        for (index,record) in records.enumerated() {
            guard let service=SCNetworkServiceCopy(preferences,record.service as CFString),let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies),let expected=try? plist(record.applied) else{issues.append("系统代理服务 "+String(index+1)+" 或快照缺失");continue}
            if !SCNetworkProtocolGetEnabled(proto) {issues.append("系统代理服务 "+String(index+1)+" 已被禁用")}
            let changed=ProxyRecovery.changedOwnedKeys(expected:expected,current:SCNetworkProtocolGetConfiguration(proto) as? [String:Any] ?? [:],protectsExceptions:true)
            if !changed.isEmpty {issues.append("系统代理服务 "+String(index+1)+" 字段变化："+changed.joined(separator:","))}
        }
        return issues
    }
}
