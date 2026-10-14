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
            var applied=ProxyRecovery.applied(to:original,port:port)
            let exceptions=(original["ExceptionsList"] as? [String] ?? [])+plan.exclusions+plan.protectedRoutes.map(\.destination)+plan.domains.flatMap{[$0,"*."+$0]}
            applied["ExceptionsList"]=Array(Set(exceptions)).sorted();applied["ExcludeSimpleHostnames"]=1
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
    func restoreProxy(_ records:[HelperProxyRecord]) throws -> Bool {
        guard !records.isEmpty else{return true}
        let preferences=try proxyPreferences();defer{SCPreferencesUnlock(preferences)};var clean=true
        for record in records {
            guard let service=SCNetworkServiceCopy(preferences,record.service as CFString),let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies) else{continue}
            let current=SCNetworkProtocolGetConfiguration(proto) as? [String:Any] ?? [:],original=try plist(record.original)
            if NSDictionary(dictionary:current).isEqual(to:original),SCNetworkProtocolGetEnabled(proto)==record.enabled {continue}
            guard SCNetworkProtocolGetEnabled(proto),let restored=ProxyRecovery.restored(original:original,applied:try plist(record.applied),current:current) else{clean=false;continue}
            guard SCNetworkProtocolSetConfiguration(proto,restored as CFDictionary),SCNetworkProtocolSetEnabled(proto,record.enabled) else{clean=false;continue}
            if !record.hadProtocol,restored.isEmpty,!SCNetworkServiceRemoveProtocolType(service,kSCNetworkProtocolTypeProxies) {clean=false}
        }
        try commitProxy(preferences);return clean
    }
    func verifyProxy()->Bool {
        guard let records=journal?.proxies,!records.isEmpty,let preferences=SCPreferencesCreate(nil,"轻舟代理核对" as CFString,nil) else{return false}
        return records.allSatisfy {record in
            guard let service=SCNetworkServiceCopy(preferences,record.service as CFString),let proto=SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies),SCNetworkProtocolGetEnabled(proto),let expected=try? plist(record.applied) else{return false}
            return ProxyRecovery.changedOwnedKeys(expected:expected,current:SCNetworkProtocolGetConfiguration(proto) as? [String:Any] ?? [:],protectsExceptions:true).isEmpty
        }
    }
}
