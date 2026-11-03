import Foundation
import QingzhouKit

final class ThroughputFixtureProtocol:URLProtocol {
    private let gate=NSLock()
    private var stopped=false
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let path=request.url!.path
        if path=="/hang" {return}
        let status=path=="/status" ? 401:200
        var headers=["Content-Length":path=="/declared" ? "99999999":path=="/empty" ? "0":"8"]
        if path=="/compressed" {headers["Content-Encoding"]="gzip"}
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if path=="/status" || path=="/declared" {client?.urlProtocolDidFinishLoading(self);return}
        if path=="/fail" {client?.urlProtocol(self,didFailWithError:URLError(.cannotConnectToHost));return}
        if path=="/transport" {client?.urlProtocol(self,didFailWithError:URLError(.secureConnectionFailed));return}
        if path=="/timeout" {client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return}
        if path=="/cancel" {client?.urlProtocol(self,didFailWithError:URLError(.cancelled));return}
        if path=="/other-error" {client?.urlProtocol(self,didFailWithError:NSError(domain:"fixture",code:1));return}
        let count=path=="/empty" ? 0:path=="/truncated" ? 4:path=="/overflow" ? 16:8
        let block={ [self] in
            gate.lock();defer{gate.unlock()};guard !stopped else{return}
            client?.urlProtocol(self,didLoad:Data(repeating:120,count:count))
            client?.urlProtocolDidFinishLoading(self)
        }
        if path=="/slow" {DispatchQueue.global().asyncAfter(deadline:.now()+0.06,execute:block)}else{block()}
    }
    override func stopLoading() {gate.lock();stopped=true;gate.unlock()}
}

func throughputFixtureContext()->ThroughputContext {
    ThroughputContext(profileID:UUID(),connectionID:UUID(),nodeID:UUID(),captureMode:"systemProxy",coreVersion:"fixture-1")
}
func runThroughputChecks() async {
    let context=throughputFixtureContext()
    func run(_ path:String,limit:Int64=1024,target:Double=10) async -> ThroughputResult {
        let probe=ThroughputProbe(context:context,timeout:0.15,target:target,byteLimit:limit,protocolClasses:[ThroughputFixtureProtocol.self])
        return await probe.run(URLRequest(url:URL(string:"https://fixture.invalid/"+path+"?token=private-value")!),proxyPort:27890)
    }
    let empty=await run("empty");expectEqual(empty.receivedBytes,0);expectNil(empty.firstByteSeconds);expectFalse(empty.withinBudget)
    for outcome in [ThroughputOutcome.completed,.timedOut,.cancelled,.httpError,.truncated,.transportError,.sizeLimit,.invalidRequest] {expectFalse(outcome.label.isEmpty)}
    let good=await run("success")
    expectEqual(good.outcome,.completed);expectEqual(good.receivedBytes,8);expectTrue(good.withinBudget)
    expectTrue(good.firstByteSeconds != nil);expectEqual(good.statusCode,200);expectTrue(good.bytesPerSecond>0)
    expectEqual(good.context,context)
    for json in [true,false] {
        let text=String(decoding:try! good.export(json:json),as:UTF8.self)
        expectFalse(text.contains("private-value"));expectFalse(text.contains("fixture.invalid"));expectFalse(text.contains("token"))
        expectTrue(text.contains("fixture-1"))
    }
    let cases:[(String,ThroughputOutcome)]=[("status",.httpError),("declared",.sizeLimit),("truncated",.truncated),("fail",.transportError),("timeout",.timedOut),("cancel",.cancelled),("other-error",.transportError),("hang",.timedOut),("overflow",.sizeLimit)]
    for (path,outcome) in cases {let r=await run(path,limit:path=="overflow" ? 10:1024);print("CASE \(path) actual=\(r.outcome.rawValue) expected=\(outcome.rawValue)");expectEqual(r.outcome,outcome);expectFalse(r.withinBudget)}
    let slow=await run("slow",target:0.01);expectEqual(slow.outcome,.completed);expectFalse(slow.withinBudget);expectTrue(slow.totalSeconds>=0.04)
    let compressed=await run("compressed");expectEqual(compressed.outcome,.completed)
    for input in ["http://fixture.invalid/","https://user:secret@fixture.invalid/"] {
        let p=ThroughputProbe(context:context);let r=await p.run(URLRequest(url:URL(string:input)!),proxyPort:nil)
        expectEqual(r.outcome,.invalidRequest)
    }
    let invalidPort=ThroughputProbe(context:context);let ip=await invalidPort.run(URLRequest(url:URL(string:"https://fixture.invalid")!),proxyPort:1);expectEqual(ip.outcome,.invalidRequest)
    let cancelled=ThroughputProbe(context:context);cancelled.cancel()
    let c=await cancelled.run(URLRequest(url:URL(string:"https://fixture.invalid")!),proxyPort:nil);expectEqual(c.outcome,.cancelled);expectTrue(String(decoding:try! c.export(json:false),as:UTF8.self).contains("未取得"))
    let reused=ThroughputProbe(context:context,protocolClasses:[ThroughputFixtureProtocol.self])
    let request=URLRequest(url:URL(string:"https://fixture.invalid/success")!)
    let first=await reused.run(request,proxyPort:nil),second=await reused.run(request,proxyPort:nil);expectEqual(first,second)
    let hanging=ThroughputProbe(context:context,timeout:3,protocolClasses:[ThroughputFixtureProtocol.self])
    let waiting=Task {await hanging.run(URLRequest(url:URL(string:"https://fixture.invalid/hang")!),proxyPort:nil)}
    try? await Task.sleep(nanoseconds:20_000_000)
    let duplicate=await hanging.run(request,proxyPort:nil);expectEqual(duplicate.outcome,.invalidRequest)
    waiting.cancel();let exit=await waiting.value;expectEqual(exit.outcome,.cancelled);expectTrue(exit.totalSeconds<1)
    let survivor=await run("success");expectEqual(survivor.outcome,.completed)
    await checkThroughputDelegatePolicies(context)
    print("RESULT throughput_assertions=\(CheckHarness.assertions) failures=\(CheckHarness.failures)")
}

private final class ThroughputChallengeSender:NSObject,URLAuthenticationChallengeSender {
    func use(_ credential:URLCredential,for challenge:URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge:URLAuthenticationChallenge) {}
    func cancel(_ challenge:URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge:URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge:URLAuthenticationChallenge) {}
}
private func checkThroughputDelegatePolicies(_ context:ThroughputContext) async {
    let url=URL(string:"https://fixture.invalid/success")!,session=URLSession(configuration:.ephemeral)
    defer{session.invalidateAndCancel()}
    let task=session.dataTask(with:url),request=URLRequest(url:url)
    let redirect=ThroughputProbe(context:context)
    redirect.urlSession(session,task:task,willPerformHTTPRedirection:HTTPURLResponse(url:url,statusCode:302,httpVersion:nil,headerFields:nil)!,newRequest:URLRequest(url:URL(string:"https://other.invalid/?token=secret")!)) {next in expectNil(next)}
    let denied=await redirect.run(request,proxyPort:nil);expectEqual(denied.outcome,.httpError)
    for method in [NSURLAuthenticationMethodServerTrust,NSURLAuthenticationMethodHTTPBasic] {
        let space=URLProtectionSpace(host:"fixture.invalid",port:443,protocol:"https",realm:nil,authenticationMethod:method)
        let challenge=URLAuthenticationChallenge(protectionSpace:space,proposedCredential:nil,previousFailureCount:0,failureResponse:nil,error:nil,sender:ThroughputChallengeSender())
        redirect.urlSession(session,task:task,didReceive:challenge) {disposition,credential in
            expectEqual(disposition,method==NSURLAuthenticationMethodServerTrust ? .performDefaultHandling:.cancelAuthenticationChallenge);expectNil(credential)
        }
    }
    let invalid=ThroughputProbe(context:context)
    invalid.urlSession(session,dataTask:task,didReceive:URLResponse(url:url,mimeType:nil,expectedContentLength:0,textEncodingName:nil)) {value in expectEqual(value,.cancel)}
    let nonHTTP=await invalid.run(request,proxyPort:nil);expectEqual(nonHTTP.outcome,.transportError)
    let truncated=ThroughputProbe(context:context)
    truncated.urlSession(session,dataTask:task,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Length":"99"])!) {value in expectEqual(value,.allow)}
    truncated.urlSession(session,dataTask:task,didReceive:Data([1,2]))
    truncated.urlSession(session,task:task,didCompleteWithError:URLError(.networkConnectionLost))
    let short=await truncated.run(request,proxyPort:nil);expectEqual(short.outcome,.truncated)
    truncated.urlSession(session,dataTask:task,didReceive:Data([3]))
    truncated.urlSession(session,dataTask:task,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!) {value in expectEqual(value,.cancel)}
    let same=await truncated.run(request,proxyPort:nil);expectEqual(short,same)
    var noURL=URLRequest(url:url);noURL.url=nil
    let missing=await ThroughputProbe(context:context).run(noURL,proxyPort:nil);expectEqual(missing.outcome,.invalidRequest)
}
