import Foundation
import QingzhouKit

final class ConnectivityFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let url=request.url!;let port=url.port ?? 0
        if port==18404 {client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return}
        var code=200;var body="Success"
        if url.host=="www.gstatic.com"{code=204;body=""}
        if url.path=="/proxies" {
            let tag="node-00000000-0000-0000-0000-000000000001"
            body=port==18405 ? "{}":"{\"proxies\":{\"proxy\":{\"type\":\"Selector\",\"name\":\"proxy\",\"now\":\"group-a\"},\"group-a\":{\"type\":\"Selector\",\"name\":\"group-a\",\"now\":\"\(tag)\"},\"\(tag)\":{\"type\":\"Hysteria2\",\"name\":\"\(tag)\"}}}"
        }else if url.path.hasSuffix("/delay") {
            expectTrue(url.path.contains("00000000-0000-0000-0000-000000000001"),"必须使用核心实际选中的节点")
            expectTrue(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.contains{$0.name=="url" && $0.value==ConfigBuilder.testURL}==true)
            code=port==18401 ? 503:port==18403 ? 401:200;body="{\"delay\":42}"
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:code,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func runConnectivityChecks() async {
    let transparent=ConnectivityProbe.configuration(port:nil)
    expectTrue(transparent.connectionProxyDictionary != nil)
    expectEqual(transparent.connectionProxyDictionary?.count,0)
    expectTrue(ConnectivityProbe.configuration(port:27890).connectionProxyDictionary?.count ?? 0 > 0)
    for code in [306,310,311] {expectEqual(ConnectivityResult.category(NSError(domain:"kCFErrorDomainCFNetwork",code:code)),"代理入口")}
    expectEqual(ConnectivityResult.category(NSError(domain:NSPOSIXErrorDomain,code:51)),"连接")

    let failed=CoreAPIClient(context:CoreControlContext(port:18401,secret:"synthetic"),protocolClasses:[ConnectivityFixtureProtocol.self])
    let results=await ConnectivityProbe.all(port:27890,client:failed,mode:.rule,protocolClasses:[ConnectivityFixtureProtocol.self])
    expectEqual(results.count,3);expectEqual(results[0].status,.passed);expectEqual(results[1].status,.failed);expectEqual(results[1].category,"节点通道");expectEqual(results[2].status,.passed)
    expectEqual(ConnectivityResult.combinedSummary(results),results[1].summary)
    expectEqual(ConnectivityResult.combinedSummary([]),"连通性尚未完成检测")
    expectEqual(ConnectivityResult.combinedSummary(ConnectivityResult.pending),"连通性尚未完成检测")
    expectEqual(ConnectivityResult.combinedSummary([ConnectivityResult("入口",.passed,""),ConnectivityResult("节点",.notApplicable,"")]),"适用路径的 HTTPS 连通性正常")
    expectEqual(ConnectivityResult.combinedSummary([ConnectivityResult("入口",.notApplicable,"")]),"连通性尚未完成检测")
    expectFalse(results[1].summary.contains("正常"));expectFalse(results[1].summary.contains("通过"));await failed.shutdown()
    for port in [18402,18403,18404,18405] {
        let client=CoreAPIClient(context:CoreControlContext(port:port,secret:"synthetic"),protocolClasses:[ConnectivityFixtureProtocol.self])
        let result=await ConnectivityProbe.node(client:client,mode:.rule)
        expectEqual(result.status,port==18402 ? .passed:.failed)
        if port==18402{expectEqual(result.milliseconds,42)}
        if port==18403{expectEqual(result.category,"鉴权")}
        if port==18404{expectEqual(result.category,"超时")}
        if port==18405{expectEqual(result.category,"控制接口响应格式")}
        let direct=await ConnectivityProbe.node(client:client,mode:.direct);expectEqual(direct.status,.notApplicable)
        await client.shutdown()
    }
    let tunEntry=await ConnectivityProbe.https(port:nil,entry:true);expectEqual(tunEntry.status,.notApplicable)
    for (code,category) in [(URLError.Code.dnsLookupFailed,"DNS"),(.secureConnectionFailed,"TLS"),(.cancelled,"取消"),(.cannotConnectToHost,"连接")] {expectEqual(ConnectivityResult.category(URLError(code)),category)}
    let safe="{\"stage\":\"identify\",\"category\":\"timeout\",\"elapsedMs\":10000,\"count\":1,\"url\":\"https://private/token\"}"
    let message=CompatibilityDiagnostic.message(safe)
    expectTrue(message?.contains("elapsedMs=10000")==true);expectFalse(message?.contains("private")==true)
    expectNil(CompatibilityDiagnostic.message("private password"))
    expectNil(CompatibilityDiagnostic.message(safe.replacingOccurrences(of:"identify",with:"https://private")))
    expectNil(CompatibilityDiagnostic.message(safe.replacingOccurrences(of:"timeout",with:"password")))
    expectNil(CompatibilityDiagnostic.message(safe.replacingOccurrences(of:"10000",with:"-1")))
    print("PASS Connectivity.independentResultsAndPrivateEvents")
}
