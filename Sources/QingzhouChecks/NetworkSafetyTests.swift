import Foundation
import QingzhouKit

final class NetworkSafetyTests:CheckCase {
    func testPersistentProxyOwnership() {
        let expected=ProxyRecovery.applied(to:[:],port:27890)
        var current=expected;current["ExceptionsList"]=["local"];current["__SCOPED__"]=["en0":["HTTPEnable":0]]
        expectEqual(ProxyRecovery.changedOwnedKeys(expected:expected,current:current),[])
        for key in ProxyRecovery.keys {
            var replaced=current;replaced.removeValue(forKey:key)
            expectEqual(ProxyRecovery.changedOwnedKeys(expected:expected,current:replaced),[key])
        }
        current["HTTPPort"]=1082;current["HTTPSPort"]=1082
        expectEqual(Set(ProxyRecovery.changedOwnedKeys(expected:expected,current:current)),Set(["HTTPPort","HTTPSPort"]))
    }
    func testConflictDetection() {
        expectNil(NetworkSafety.conflict(proxies:[:],dns:"nameserver[0] : 192.168.1.1"))
        for key in ["HTTPEnable","HTTPSEnable","SOCKSEnable","ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable"] {expectTrue(NetworkSafety.conflict(proxies:[key:1],dns:"") != nil)}
        expectTrue(NetworkSafety.conflict(proxies:[:],dns:"  nameserver[0] : 198.18.0.2") != nil)
        expectTrue(NetworkSafety.conflict(proxies:[:],dns:"nameserver[1] : 198.19.255.254") != nil)
        expectNil(NetworkSafety.conflict(proxies:[:],dns:"search domain : 198.18.0.2"))
        expectNil(NetworkSafety.conflict(proxies:["HTTPEnable":0],dns:"nameserver[0] : 198.20.0.2"))
    }
    func testDeadProxyRestorationAndOwnership() {
        let original:[String:Any]=["HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":1082,"HTTPSEnable":1,"HTTPSProxy":"localhost","HTTPSPort":1082,"SOCKSEnable":1,"SOCKSProxy":"::1","SOCKSPort":1082,"ExceptionsList":["local"]]
        let safe=NetworkSafety.restoration(original,listening:{_,_ in false})
        for key in ["HTTPEnable","HTTPSEnable","SOCKSEnable"] {expectEqual(safe[key] as? Int,0)}
        expectEqual(safe["ExceptionsList"] as? [String],["local"])
        expectTrue(NSDictionary(dictionary:NetworkSafety.restoration(original,listening:{_,_ in true})).isEqual(to:original))
        let applied=ProxyRecovery.applied(to:original,port:27890)
        let restored=ProxyRecovery.restored(original:safe,applied:applied,current:applied)!
        expectEqual(restored["HTTPEnable"] as? Int,0)
        var external=applied;external["HTTPPort"]=8888
        expectNil(ProxyRecovery.restored(original:safe,applied:applied,current:external))
        let remote:[String:Any]=["HTTPEnable":1,"HTTPProxy":"company.example","HTTPPort":8080]
        expectTrue(NSDictionary(dictionary:NetworkSafety.restoration(remote,listening:{_,_ in false})).isEqual(to:remote))
    }
    func testUnknownHealthDoesNotMeanNodeFailure() {
        var counter=HealthFailureCounter()
        expectFalse(counter.update([]))
        expectFalse(counter.update([.unavailable]))
        expectFalse(counter.update([.unknown]))
        expectEqual(counter.failures,0)
        expectFalse(counter.update([.unavailable,.available]))
        expectFalse(counter.update([.unavailable,.unknown]))
        expectFalse(counter.update([.unavailable]))
        expectTrue(counter.update([.unavailable]))
    }
    func testBoundedPrivateLogAndRedaction() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("diagnostic.log")
        let log=DiagnosticLog(url:url)
        try log.append("订阅 https://private.example/s/secret/qingzhou.json password=private-password")
        let text=try String(contentsOf:url,encoding:.utf8)
        expectFalse(text.contains("secret"));expectFalse(text.contains("private-password"))
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try log.append(String(repeating:"x",count:600000))
        expectTrue(try Data(contentsOf:url).count<=512*1024)
        try log.append("下一次启动可读取")
        expectTrue(try String(contentsOf:url,encoding:.utf8).contains("下一次启动可读取"))
    }
}

final class ProbeFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let port=request.url!.port!
        let response=HTTPURLResponse(url:request.url!,statusCode:port==18001 ? 401:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        let body=port==18003 ? "{\"delay\":42}":"{\"error\":\"synthetic\"}"
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func runNetworkProbeChecks() async {
    for port in [18001,18002,18003] {
        let client=CoreAPIClient(context:CoreControlContext(port:port,secret:"synthetic"),protocolClasses:[ProbeFixtureProtocol.self])
        let status=await client.probe(UUID())
        switch status {case .available:expectEqual(port,18003);case .unknown:expectTrue(port != 18003);case .unavailable:expectTrue(false,"鉴权和响应错误不能判定节点失效")}
        await client.shutdown()
    }
    print("PASS NetworkSafety.controlErrorsClassifiedUnknown")
}
