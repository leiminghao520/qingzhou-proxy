import Foundation
import CryptoKit
import CommonCrypto
import QingzhouKit

// 按旧版格式构造备份，用于确认短口令的历史备份在新长度限制下仍可恢复。
func legacyBackup(_ snapshot:BackupSnapshot,password:String) throws -> Data {
    struct Envelope:Encodable {var version:Int;var rounds:Int;var salt:Data;var sealed:Data}
    let salt=Data((0..<16).map{_ in UInt8.random(in:0...255)});let bytes=Array(password.utf8);var key=[UInt8](repeating:0,count:32)
    let status=bytes.withUnsafeBytes{p in salt.withUnsafeBytes{s in CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),p.baseAddress!.assumingMemoryBound(to:Int8.self),p.count,s.baseAddress!.assumingMemoryBound(to:UInt8.self),s.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),600000,&key,key.count)}}
    guard status==kCCSuccess else{throw ProxyError("测试密钥生成失败")}
    let sealed=try AES.GCM.seal(JSONEncoder().encode(snapshot),using:SymmetricKey(data:key),authenticating:Data("QingzhouBackup-v1".utf8)).combined!
    return try JSONEncoder().encode(Envelope(version:1,rounds:600000,salt:salt,sealed:sealed))
}

// 按端口区分核心控制接口的响应场景：正常、分块超限、声明超限、鉴权失败。
final class CoreLimitFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest) -> Bool {true}
    override class func canonicalRequest(for request:URLRequest) -> URLRequest {request}
    override func startLoading() {
        let port=request.url?.port ?? 0
        let headers=port==18503 ? ["Content-Length":"3000000"]:["Content-Type":"application/json"]
        let response=HTTPURLResponse(url:request.url!,statusCode:port==18504 ? 401:200,httpVersion:"HTTP/1.1",headerFields:headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if port==18502 {for _ in 0..<3 {client?.urlProtocol(self,didLoad:Data(repeating:32,count:1024*1024))}}
        else {client?.urlProtocol(self,didLoad:Data(#"{"downloadTotal":7,"uploadTotal":3,"connections":[{"id":"a","metadata":{"host":"example.com","destinationPort":"443"},"upload":1,"download":2,"start":"2026-01-01T00:00:00.123Z","chains":["proxy"]},{"id":"b","metadata":{"destinationIP":"1.1.1.1","destinationPort":"53"},"upload":0,"download":0,"start":"2026-01-01T00:00:00Z","chains":[]}]}"#.utf8))}
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func runHardeningChecks() async {
    // 原子写入：权限 0600、内容一致、覆盖成功且不残留临时文件。
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("qz-secure-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:folder)}
    let file=folder.appendingPathComponent("state.json")
    do {
        try SecureFile.write(Data("first".utf8),to:file);try SecureFile.write(Data("second".utf8),to:file)
        let mode=(try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue
        expectEqual(mode,0o600);expectEqual(try Data(contentsOf:file),Data("second".utf8))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path),["state.json"])
        print("PASS HardeningTests.secureFileAtomicWrite")
    } catch {CheckHarness.failure("安全写入失败："+error.localizedDescription,file:#filePath,line:#line)}
    func client(_ port:Int)->CoreAPIClient {CoreAPIClient(context:CoreControlContext(port:port,secret:"synthetic"),protocolClasses:[CoreLimitFixtureProtocol.self])}
    do {
        let snapshot=try await client(18501).connections()
        expectEqual(snapshot.connections.count,2);expectEqual(snapshot.downloadTotal,7);expectEqual(snapshot.connections[0].target,"example.com:443")
        expectTrue(snapshot.connections.allSatisfy{$0.duration.hasSuffix(" 秒")})
        print("PASS HardeningTests.coreAPIChunkedRead")
    } catch {CheckHarness.failure("核心接口正常响应失败："+error.localizedDescription,file:#filePath,line:#line)}
    for port in [18502,18503] {
        do {_=try await client(port).connections();CheckHarness.failure("超限响应未被拒绝",file:#filePath,line:#line)} catch {expectTrue(error is CoreAPIError)}
    }
    do {_=try await client(18504).connections();CheckHarness.failure("鉴权失败未被拒绝",file:#filePath,line:#line)} catch {expectEqual((error as? CoreAPIError)?.category,"鉴权")}
    print("PASS HardeningTests.coreAPIResponseLimit")
}
