import Foundation
import QingzhouKit

final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {true}
    override class func canonicalRequest(for request:URLRequest) -> URLRequest {request}
    override func startLoading() {
        let path = request.url!.path
        let status = path == "/expired" ? 403 : 200
        let headers = path == "/usage" ? ["subscription-userinfo":"upload=12; download=34; total=56; expire=200000"] : path == "/declared-large" ? ["Content-Length":"3000000"] : ["Content-Type":"text/plain"]
        let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if path == "/stream-large" {client?.urlProtocol(self,didLoad:Data(repeating:120,count:64));client?.urlProtocol(self,didLoad:Data(repeating:120,count:64))}
        else if path == "/error" {client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return}
        else {client?.urlProtocol(self,didLoad:Data("hy2://test@example.com\n".utf8))}
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func runAsyncChecks() async {
    let good = URL(string:"https://fixture.invalid/nodes")!
    do {let data = try await BoundedDownload.fetch(good,protocolClasses:[FixtureProtocol.self]);expectEqual(try NodeParser.parseList(String(decoding:data,as:UTF8.self)).count,1);print("PASS DownloadTests.success")} catch {CheckHarness.failure("订阅正常响应失败",file:#filePath,line:#line)}
    do {let response=try await BoundedDownload.fetchResponse(URL(string:"https://fixture.invalid/usage")!,protocolClasses:[FixtureProtocol.self]);expectEqual(UsageInfo.parse(response.usageHeader)?.download,34);print("PASS DownloadTests.usageHeader")}catch{CheckHarness.failure("订阅用量响应头失败",file:#filePath,line:#line)}
    for path in ["expired","declared-large","stream-large","error"] {
        do {_ = try await BoundedDownload.fetch(URL(string:"https://fixture.invalid/"+path)!,limit:100,protocolClasses:[FixtureProtocol.self]);CheckHarness.failure("订阅错误未被拒绝",file:#filePath,line:#line)} catch {expectFalse(error.localizedDescription.contains("fixture.invalid"));print("PASS DownloadTests.\(path)")}
    }
    do {_ = try await ImportService.preview("http://example.com/private-token");CheckHarness.failure("HTTP 订阅应被拒绝",file:#filePath,line:#line)} catch {expectFalse(error.localizedDescription.contains("private-token"));print("PASS DownloadTests.httpsRequired")}
    let framer = LogFramer(secrets:["split-secret"])
    expectEqual(framer.receive(Data("value=split-".utf8)).count,0)
    let lines = framer.receive(Data("secret\nnext\n".utf8));expectEqual(lines.count,2);expectFalse(lines[0].contains("split-"));expectFalse(lines[0].contains("secret"))
    expectEqual(framer.receive(Data(repeating:120,count:9000)).count,0);expectEqual(framer.receive(Data("\n".utf8)).count,0)
    expectEqual(framer.receive(Data("tail".utf8),end:true),["tail"])
    print("PASS LogFramerTests.chunkedSecretsAndBound")
}
