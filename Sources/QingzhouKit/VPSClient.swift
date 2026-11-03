import Foundation
import CFNetwork
import CryptoKit
import Darwin

// 联动接口使用独立会话和凭据，不控制连接生命周期，也不跟随任何重定向。
public final class VPSClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let base: URL
    private let token: String
    private let protocols: [AnyClass]?
    public init(base: URL, token: String = "", protocolClasses: [AnyClass]? = nil) throws {
        guard base.scheme == "https", base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, base.path == "/api/client/v1" else { throw ProxyError("联动服务地址无效") }
        self.base=base; self.token=token; self.protocols=protocolClasses
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    public func request(_ path: String, method: String = "GET", body: Data? = nil, limit: Int = 2*1024*1024, proxyPort: Int? = nil, timeout: Double = 10) async throws -> (Data, HTTPURLResponse) {
        guard !path.contains(".."), !path.contains("?"), !path.contains("#"), !path.hasPrefix("/") else { throw ProxyError("联动请求无效") }
        let config=URLSessionConfiguration.ephemeral
        config.urlCache=nil; config.httpCookieStorage=nil; config.httpShouldSetCookies=false
        config.timeoutIntervalForRequest=timeout; config.timeoutIntervalForResource=timeout; config.protocolClasses=protocols
        if let port=proxyPort {
            guard (1...65535).contains(port) else { throw ProxyError("代理端口无效") }
            config.connectionProxyDictionary=[kCFNetworkProxiesHTTPEnable as String:1,kCFNetworkProxiesHTTPProxy as String:"127.0.0.1",kCFNetworkProxiesHTTPPort as String:port,kCFNetworkProxiesHTTPSEnable as String:1,kCFNetworkProxiesHTTPSProxy as String:"127.0.0.1",kCFNetworkProxiesHTTPSPort as String:port]
        }
        let session=URLSession(configuration:config,delegate:self,delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        var req=URLRequest(url:base.appendingPathComponent(path)); req.httpMethod=method; req.httpBody=body
        if !token.isEmpty {req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
        if body != nil { req.setValue(path == "speed/upload" ? "application/octet-stream":"application/json",forHTTPHeaderField:"Content-Type") }
        do {
            let (bytes,response)=try await session.bytes(for:req)
            guard let http=response as? HTTPURLResponse else {throw ProxyError("联动服务响应无效")}
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode==401 && path=="pair" {
                    throw ProxyError("配对码不匹配、已过期或已使用，请复制后台最新生成的完整配对码")
                }
                throw ProxyError(http.statusCode == 401 ? "联动授权已失效，请重新配对":http.statusCode == 403 ? "当前设备没有此功能权限":http.statusCode == 429 ? "请求过于频繁，请稍后重试":"联动请求失败（HTTP \(http.statusCode)）")
            }
            guard response.expectedContentLength <= limit else {throw ProxyError("联动响应超过上限")}
            var data=Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else {throw ProxyError("联动响应超过上限")}
                data.append(byte)
            }
            return (data,http)
        } catch is CancellationError {throw CancellationError()}
        catch let error as ProxyError {throw error}
        catch {if Task.isCancelled {throw CancellationError()};throw ProxyError("联动服务暂不可达，代理运行不受影响")}
    }
    public func json(_ path: String, method: String = "GET", value: [String:String]? = nil) async throws -> VPSValue {
        let body=try value.map {try JSONEncoder().encode($0)}
        let (data,_)=try await request(path,method:method,body:body)
        do {return try JSONDecoder().decode(VPSValue.self,from:data)} catch {throw ProxyError("联动数据格式不支持")}
    }
    public func pair(code:String) async throws -> VPSValue {
        // 只去除复制附带的首尾空白，内部字符必须与服务端生成值完全一致。
        let clean=code.trimmingCharacters(in:.whitespacesAndNewlines)
        guard clean.range(of:"^[A-Za-z0-9_-]{32}$",options:.regularExpression) != nil else {
            throw ProxyError("请粘贴完整的 32 位一次性配对码，不要包含说明文字或内部空格")
        }
        return try await json("pair",method:"POST",value:["code":clean])
    }
    public func downloadBackup(to target:URL,size:Int,sha256:String) async throws {
        guard size>0,size<=512*1024*1024,sha256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{throw ProxyError("备份清单无效")}
        let directory=target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temp=directory.appendingPathComponent(".backup-"+UUID().uuidString)
        guard FileManager.default.createFile(atPath:temp.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw ProxyError("无法创建备份文件")}
        defer{try? FileManager.default.removeItem(at:temp)}
        let handle=try FileHandle(forWritingTo:temp);defer{try? handle.close()}
        let config=URLSessionConfiguration.ephemeral;config.urlCache=nil;config.httpCookieStorage=nil;config.httpShouldSetCookies=false
        config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=120;config.protocolClasses=protocols
        let session=URLSession(configuration:config,delegate:self,delegateQueue:nil);defer{session.invalidateAndCancel()}
        var req=URLRequest(url:base.appendingPathComponent("backup/download"));req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        do {
            let (bytes,response)=try await session.bytes(for:req)
            guard let http=response as? HTTPURLResponse,http.statusCode==200,response.expectedContentLength<=size else{throw ProxyError("备份下载响应无效")}
            var chunk=Data(),hasher=SHA256(),count=0
            for try await byte in bytes {
                try Task.checkCancellation();count+=1
                guard count<=size else{throw ProxyError("备份超过清单大小")}
                chunk.append(byte)
                if chunk.count==65536 {hasher.update(data:chunk);try handle.write(contentsOf:chunk);chunk.removeAll(keepingCapacity:true)}
            }
            hasher.update(data:chunk);try handle.write(contentsOf:chunk);try handle.synchronize()
            guard count==size,hasher.finalize().map({String(format:"%02x",$0)}).joined()==sha256 else{throw ProxyError("备份校验失败")}
            guard rename(temp.path,target.path)==0 else{throw ProxyError("备份原子保存失败")}
        }catch is CancellationError{throw CancellationError()}
        catch let e as ProxyError{throw e}
        catch{if Task.isCancelled {throw CancellationError()};throw ProxyError("备份下载中断，将在下次同步时重试")}
    }
    public static func endpoint(subscription: URL, advertised: String?) throws -> URL {
        guard subscription.scheme == "https", let host=subscription.host, subscription.user == nil, subscription.password == nil,
              advertised == "/api/client/v1" else {throw ProxyError("该订阅没有提供汐航联动能力")}
        var url=URLComponents(); url.scheme="https"; url.host=host; url.port=subscription.port; url.path="/api/client/v1"
        guard let result=url.url else {throw ProxyError("联动地址无效")}; return result
    }
}

// 兼容服务端增量扩展；未知字段不会变成错误的零值。
public enum VPSValue: Codable, Sendable {
    case object([String:VPSValue]), array([VPSValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil() {self = .null}
        else if let v=try? c.decode(Bool.self) {self = .bool(v)}
        else if let v=try? c.decode(Double.self) {self = .number(v)}
        else if let v=try? c.decode(String.self) {self = .string(v)}
        else if let v=try? c.decode([String:VPSValue].self) {self = .object(v)}
        else {self = .array(try c.decode([VPSValue].self))}
    }
    public func encode(to encoder: Encoder) throws {
        var c=encoder.singleValueContainer()
        switch self {case .object(let v):try c.encode(v);case .array(let v):try c.encode(v);case .string(let v):try c.encode(v);case .number(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .null:try c.encodeNil()}
    }
    public subscript(_ key:String) -> VPSValue {if case .object(let o)=self {return o[key] ?? .null};return .null}
    public var string:String? {if case .string(let v)=self{return v};return nil}
    public var number:Double? {if case .number(let v)=self{return v};return nil}
    public var bool:Bool? {if case .bool(let v)=self{return v};return nil}
    public var array:[VPSValue] {if case .array(let v)=self{return v};return []}
    public var isNull:Bool {if case .null=self{return true};return false}
    public var pretty:String {guard let d=try? JSONEncoder().encode(self),let object=try? JSONSerialization.jsonObject(with:d),let text=try? JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]) else{return "未提供"};return String(decoding:text,as:UTF8.self)}
}
