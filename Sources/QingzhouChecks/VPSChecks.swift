import Foundation
import QingzhouKit
import CryptoKit

private final class VPSFixture:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let path=request.url!.lastPathComponent
        let access=request.value(forHTTPHeaderField:"Authorization") ?? ""
        if path=="never" || access.contains("backup-never") {return}
        if path=="transport" || access.contains("backup-fail") {client?.urlProtocol(self,didFailWithError:URLError(.cannotConnectToHost));return}
        let status=path=="pair" && access=="Bearer reject-pair" ? 401 : Int(path) ?? 200
        var body=path == "download" ? Data(repeating:67,count:131073):path == "invalid" ? Data("{".utf8):path == "large" ? Data(repeating:65,count:128):Data("{\"owner\":true,\"count\":12,\"name\":\"fixture\",\"missing\":null,\"list\":[1]}".utf8)
        if path=="pair",let stream=request.httpBodyStream {
            stream.open();defer{stream.close()}
            var buffer=[UInt8](repeating:0,count:1024),payload=Data()
            while stream.hasBytesAvailable {let count=stream.read(&buffer,maxLength:buffer.count);if count<=0{break};payload.append(contentsOf:buffer.prefix(count))}
            if let object=try? JSONSerialization.jsonObject(with:payload) {body=(try? JSONSerialization.data(withJSONObject:object)) ?? Data()}
        }
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:[:])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func runVPSChecks() async throws {
    let base=URL(string:"https://fixture.invalid/api/client/v1")!
    let c=try VPSClient(base:base,token:"synthetic",protocolClasses:[VPSFixture.self])
    let redirectSession=URLSession(configuration:.ephemeral)
    defer{redirectSession.invalidateAndCancel()}
    let redirect=URLRequest(url:URL(string:"https://other.invalid/")!)
    c.urlSession(redirectSession,task:redirectSession.dataTask(with:redirect),willPerformHTTPRedirection:HTTPURLResponse(url:base,statusCode:302,httpVersion:nil,headerFields:nil)!,newRequest:redirect) {request in expectTrue(request==nil)}
    let value=try await c.json("me")
    expectEqual(value["owner"].bool,true);expectEqual(value["count"].number,12)
    expectEqual(value["name"].string,"fixture");expectTrue(value["missing"].isNull)
    expectEqual(value["list"].array.count,1);expectTrue(value["unknown"].isNull)
    expectTrue(value.pretty.contains("fixture"));expectEqual(VPSValue.null.pretty,"未提供")
    _=try await c.json("me",method:"POST",value:["fixture":"value"])
    let pairingCode=String(repeating:"a",count:30)+"_-"
    let paired=try await c.pair(code:" \n"+pairingCode+"\r\n")
    expectEqual(paired["code"].string,pairingCode)
    for invalid in ["",String(repeating:"a",count:31),String(repeating:"a",count:33),String(repeating:"a",count:31)+" ",String(repeating:"a",count:15)+" "+String(repeating:"a",count:16)] {
        do{_=try await c.pair(code:invalid);CheckHarness.failure("不完整配对码未拒绝",file:#filePath,line:#line)}catch{expectTrue(error.localizedDescription.contains("32 位"))}
    }
    let rejectedPair=try VPSClient(base:base,token:"reject-pair",protocolClasses:[VPSFixture.self])
    do{_=try await rejectedPair.pair(code:pairingCode);CheckHarness.failure("失效配对码未拒绝",file:#filePath,line:#line)}catch{expectTrue(error.localizedDescription.contains("配对码不匹配"));expectFalse(error.localizedDescription.contains("授权已失效"))}
    do{_=try await c.json("401");CheckHarness.failure("失效访问授权未拒绝",file:#filePath,line:#line)}catch{expectTrue(error.localizedDescription.contains("联动授权已失效"))}
    do{_=try await c.json("transport");CheckHarness.failure("网络失败未拒绝",file:#filePath,line:#line)}catch{expectTrue(error.localizedDescription.contains("代理运行不受影响"))}
    let roundtrip=try JSONDecoder().decode(VPSValue.self,from:JSONEncoder().encode(value))
    expectEqual(roundtrip["count"].number,12)
    for path in ["401","403","429","500","302"] {
        do{_=try await c.json(path);CheckHarness.failure("错误状态未拒绝",file:#filePath,line:#line)}
        catch{expectFalse(error.localizedDescription.contains("fixture.invalid"));expectFalse(error.localizedDescription.contains("synthetic"))}
    }
    for path in ["../me","a?x=1","a#f","/me"] {
        do{_=try await c.json(path);CheckHarness.failure("危险路径未拒绝",file:#filePath,line:#line)}catch{}
    }
    do{_=try await c.request("large",limit:64);CheckHarness.failure("超限响应未拒绝",file:#filePath,line:#line)}catch{}
    for url in ["http://fixture.invalid/api/client/v1","https://user:pass@fixture.invalid/api/client/v1","https://fixture.invalid/api/client/v1?secret=x","https://fixture.invalid/other"] {
        do{_=try VPSClient(base:URL(string:url)!);CheckHarness.failure("非法服务地址未拒绝",file:#filePath,line:#line)}catch{}
    }
    for advertised in [nil,"https://other.invalid/api/client/v1","/other"] {
        do{_=try VPSClient.endpoint(subscription:URL(string:"https://fixture.invalid/s/private/qingzhou.json")!,advertised:advertised);CheckHarness.failure("外部服务地址未拒绝",file:#filePath,line:#line)}catch{}
    }
    let endpoint=try VPSClient.endpoint(subscription:URL(string:"https://fixture.invalid:8443/s/private/qingzhou.json")!,advertised:"/api/client/v1")
    expectEqual(endpoint.absoluteString,"https://fixture.invalid:8443/api/client/v1")
    do{_=try await c.json("invalid");CheckHarness.failure("畸形 JSON 未拒绝",file:#filePath,line:#line)}catch{}
    for port in [0,65536] {do{_=try await c.request("me",proxyPort:port);CheckHarness.failure("非法代理端口未拒绝",file:#filePath,line:#line)}catch{}}
    _=try await c.request("me",method:"POST",body:Data("{}".utf8),proxyPort:7890)
    let cancellation=Task{try await c.request("never")}
    try await Task.sleep(for:.milliseconds(30));cancellation.cancel()
    do{_=try await cancellation.value;CheckHarness.failure("取消请求仍成功",file:#filePath,line:#line)}catch{expectTrue(error is CancellationError)}
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:folder)}
    let target=folder.appendingPathComponent("backup.age"),fixture=Data(repeating:67,count:131073)
    let sha=SHA256.hash(data:fixture).map{String(format:"%02x",$0)}.joined()
    try await c.downloadBackup(to:target,size:fixture.count,sha256:sha)
    expectEqual(try Data(contentsOf:target),fixture)
    for (size,hash) in [(fixture.count,String(repeating:"0",count:64)),(fixture.count-1,sha),(fixture.count+1,sha),(0,sha),(fixture.count,"bad")] {
        do{try await c.downloadBackup(to:target,size:size,sha256:hash);CheckHarness.failure("异常备份未拒绝",file:#filePath,line:#line)}catch{}
        expectEqual(try Data(contentsOf:target),fixture)
        expectEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path),["backup.age"])
    }
    let offline=try VPSClient(base:base,token:"backup-fail",protocolClasses:[VPSFixture.self])
    do{try await offline.downloadBackup(to:target,size:fixture.count,sha256:sha);CheckHarness.failure("下载中断未拒绝",file:#filePath,line:#line)}catch{}
    let waiting=try VPSClient(base:base,token:"backup-never",protocolClasses:[VPSFixture.self])
    let interrupted=Task{try await waiting.downloadBackup(to:target,size:fixture.count,sha256:sha)}
    try await Task.sleep(for:.milliseconds(30));interrupted.cancel()
    do{try await interrupted.value;CheckHarness.failure("备份取消未生效",file:#filePath,line:#line)}catch{expectTrue(error is CancellationError)}
    expectEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path),["backup.age"])
    let unknown=VPSDiagnostics.summarize(local:[],server:.null)
    expectEqual(unknown.first?.status,"未验证")
    let status=try JSONDecoder().decode(VPSValue.self,from:Data("{\"state\":\"fresh\",\"data\":{\"hysteria\":\"active\",\"auth\":\"failed\"}}".utf8))
    let diagnosis=VPSDiagnostics.summarize(local:[DiagnosticResult("配置","失败","fixture")],server:status)
    expectEqual(diagnosis.map(\.status),["失败","通过","失败","未验证"])
    let connection=try JSONDecoder().decode(CoreConnection.self,from:Data("{\"id\":\"fixture\",\"metadata\":{\"host\":\"fixture.invalid\"},\"upload\":1,\"download\":0,\"start\":\"2026-10-21T00:00:00Z\",\"chains\":[\"node-fixture\"]}".utf8))
    let since=Date(timeIntervalSince1970:0)
    expectTrue(VPSDiagnostics.confirmsPath([connection],host:"FIXTURE.invalid",nodeTag:"node-fixture",since:since))
    expectFalse(VPSDiagnostics.confirmsPath([connection],host:"other.invalid",nodeTag:"node-fixture",since:since))
    expectFalse(VPSDiagnostics.confirmsPath([connection],host:"fixture.invalid",nodeTag:"direct",since:since))
    expectFalse(VPSDiagnostics.confirmsPath([connection],host:"fixture.invalid",nodeTag:"node-fixture",since:Date.distantFuture))
    let recovery="AGE-SECRET-KEY-SYNTHETIC"
    let encrypted=try BackupService.encryptRecoveryKey(recovery,password:"twelve-character-password")
    expectFalse(String(decoding:encrypted,as:UTF8.self).contains("SYNTHETIC"))
    expectEqual(try BackupService.decryptRecoveryKey(encrypted,password:"twelve-character-password"),recovery)
    do{_=try BackupService.decryptRecoveryKey(encrypted,password:"wrong");CheckHarness.failure("错误恢复口令未拒绝",file:#filePath,line:#line)}catch{}
    do{_=try BackupService.decryptRecoveryKey(Data(repeating:0,count:20000),password:"x");CheckHarness.failure("超限密钥未拒绝",file:#filePath,line:#line)}catch{}
}
