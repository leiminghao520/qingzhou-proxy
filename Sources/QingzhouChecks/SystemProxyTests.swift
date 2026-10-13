import Foundation
import SystemConfiguration
import QingzhouKit

@MainActor func runSystemProxyChecks() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qingzhou-preferences-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:dir)}
    let prefsFile = dir.appendingPathComponent("preferences.plist")
    func preferences() throws -> SCPreferences {
        guard let p = SCPreferencesCreate(nil,"轻舟测试" as CFString,prefsFile.path as CFString) else {throw ProxyError("无法创建隔离偏好文件")};return p
    }
    let p = try preferences()
    guard let iface = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface])?.first(where:{SCNetworkInterfaceGetInterfaceType($0) as String? == "Ethernet"}), let service = SCNetworkServiceCreate(p,iface), let set = SCNetworkSetCreate(p) else {throw ProxyError("无法创建隔离网络服务")}
    guard SCNetworkSetAddService(set,service), SCNetworkSetSetCurrent(set), SCNetworkServiceSetEnabled(service,true) else {throw ProxyError("无法设置隔离网络服务")}
    if SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies) == nil {_ = SCNetworkServiceAddProtocolType(service,kSCNetworkProtocolTypeProxies)}
    let proto = SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies)!
    let original: [String:Any] = ["HTTPEnable":1,"HTTPProxy":"original.invalid","HTTPPort":8080,"ProxyAutoConfigEnable":1,"ProxyAutoConfigURLString":"https://example.invalid/proxy.pac","ExceptionsList":["local"]]
    expectTrue(SCNetworkProtocolSetConfiguration(proto,original as CFDictionary));expectTrue(SCNetworkProtocolSetEnabled(proto,true));expectTrue(SCPreferencesCommitChanges(p))
    let controller = SystemProxyController(journal:dir.appendingPathComponent("journal.json"),preferencesFactory:preferences,commitHandler:{p in if !SCPreferencesCommitChanges(p) {throw ProxyError("隔离文件提交失败")}})
    try controller.apply(port:7890);expectTrue(controller.hasRecovery)
    let appliedPrefs = try preferences();let appliedService = SCNetworkServiceCopy(appliedPrefs,SCNetworkServiceGetServiceID(service)!)!;let appliedProto = SCNetworkServiceCopyProtocol(appliedService,kSCNetworkProtocolTypeProxies)!
    let value = SCNetworkProtocolGetConfiguration(appliedProto) as! [String:Any]
    expectEqual(value["HTTPProxy"] as? String,"127.0.0.1");expectEqual(value["ProxyAutoConfigEnable"] as? Int,0)
    expectThrows(try controller.apply(port:7890))
    try controller.restore();expectFalse(controller.hasRecovery)
    let restoredPrefs = try preferences();let restoredService = SCNetworkServiceCopy(restoredPrefs,SCNetworkServiceGetServiceID(service)!)!;let restoredProto = SCNetworkServiceCopyProtocol(restoredService,kSCNetworkProtocolTypeProxies)!
    expectTrue(NSDictionary(dictionary:SCNetworkProtocolGetConfiguration(restoredProto) as! [String:Any]).isEqual(to:original));print("PASS SystemProxyTests.isolatedApplyRestorePAC")
    let cancelled = SystemProxyController(journal:dir.appendingPathComponent("cancelled.json"),preferencesFactory:{throw ProxyError("模拟授权取消")})
    expectThrows(try cancelled.apply(port:7890));expectFalse(cancelled.hasRecovery);print("PASS SystemProxyTests.authorizationCancelled")
    let failing = SystemProxyController(journal:dir.appendingPathComponent("failed.json"),preferencesFactory:preferences,commitHandler:{_ in throw ProxyError("模拟提交失败")})
    expectThrows(try failing.apply(port:7890));expectTrue(failing.hasRecovery)
    let recovery = SystemProxyController(journal:failing.journal,preferencesFactory:preferences,commitHandler:{p in if !SCPreferencesCommitChanges(p) {throw ProxyError("隔离文件提交失败")}})
    try recovery.restore();expectFalse(recovery.hasRecovery);print("PASS SystemProxyTests.failedCommitRecovery")
}
