import Foundation
import CFNetwork

public struct CoreAPIError:LocalizedError,Sendable {
    public let category:String
    public var errorDescription:String? {"核心检测失败："+category}
    public init(_ category:String){self.category=category}
}
public struct ProxyInfo:Decodable,Sendable {
    public struct History:Decodable,Sendable {public var delay:Int}
    public var type:String;public var name:String;public var now:String?;public var all:[String]?;public var history:[History]?
}
public struct TransferRate:Decodable,Sendable {public var up:Int64;public var down:Int64}
public struct ConnectionMetadata:Decodable,Sendable {
    public var network:String?;public var host:String?;public var destinationIP:String?;public var destinationPort:String?;public var processPath:String?;public var type:String?
}
public struct CoreConnection:Decodable,Identifiable,Sendable {
    public var id:String;public var metadata:ConnectionMetadata;public var upload:Int64;public var download:Int64;public var start:String;public var chains:[String];public var rule:String?;public var rulePayload:String?
    public var target:String {(metadata.host?.isEmpty==false ? metadata.host! : metadata.destinationIP ?? "未知")+":"+(metadata.destinationPort ?? "")}
    // 格式化器创建成本高且线程安全，列表每秒刷新时复用同一实例。
    nonisolated(unsafe) private static let fractionalFormatter:ISO8601DateFormatter={let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f}()
    nonisolated(unsafe) private static let plainFormatter=ISO8601DateFormatter()
    public var duration:String {let date=Self.fractionalFormatter.date(from:start) ?? Self.plainFormatter.date(from:start);guard let date else{return "未知"};return "\(max(0,Int(Date().timeIntervalSince(date)))) 秒"}
}
public struct ConnectionSnapshot:Decodable,Sendable {public var downloadTotal:Int64;public var uploadTotal:Int64;public var connections:[CoreConnection]}
// 会话级委托按块接收响应，超过上限立即取消；异步 data(for:) 不回调分块数据，逐字节迭代 AsyncBytes 又过慢。
final class BoundedResponseCollector:NSObject,URLSessionDataDelegate,@unchecked Sendable {
    private struct Pending {var data=Data();var response:URLResponse?;var exceeded=false;let continuation:CheckedContinuation<(Data,URLResponse),Error>}
    private let lock=NSLock()
    private var pending:[Int:Pending]=[:]
    let limit:Int
    init(limit:Int){self.limit=limit}
    func start(_ task:URLSessionDataTask,_ continuation:CheckedContinuation<(Data,URLResponse),Error>) {lock.lock();pending[task.taskIdentifier]=Pending(continuation:continuation);lock.unlock();task.resume()}
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
        let tooLarge=response.expectedContentLength>Int64(limit)
        lock.lock();pending[dataTask.taskIdentifier]?.response=response;if tooLarge{pending[dataTask.taskIdentifier]?.exceeded=true};lock.unlock()
        completionHandler(tooLarge ? .cancel:.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        lock.lock();let exceeded=(pending[dataTask.taskIdentifier]?.data.count ?? 0)+data.count>limit
        // 通过字典下标原地追加，避免每个分块复制整段缓冲。
        if exceeded {pending[dataTask.taskIdentifier]?.exceeded=true} else {pending[dataTask.taskIdentifier]?.data.append(data)}
        lock.unlock();if exceeded{dataTask.cancel()}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        lock.lock();let item=pending.removeValue(forKey:task.taskIdentifier);lock.unlock()
        guard let item else{return}
        if item.exceeded {item.continuation.resume(throwing:ProxyError("核心响应超过限制"))}
        else if let error {item.continuation.resume(throwing:error)}
        else if let response=item.response ?? task.response {item.continuation.resume(returning:(item.data,response))}
        else {item.continuation.resume(throwing:URLError(.badServerResponse))}
    }
}
public actor CoreAPIClient {
    public let port:Int
    private let secret:String
    private let session:URLSession
    private let collector=BoundedResponseCollector(limit:2*1024*1024)
    public init(context:CoreControlContext,protocolClasses:[AnyClass]?=nil) {
        port=context.port;secret=context.secret
        let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForRequest=10;configuration.timeoutIntervalForResource=10;configuration.urlCache=nil;configuration.httpCookieStorage=nil;configuration.protocolClasses=protocolClasses
        configuration.connectionProxyDictionary=[kCFNetworkProxiesHTTPEnable as String:0,kCFNetworkProxiesHTTPSEnable as String:0,kCFNetworkProxiesSOCKSEnable as String:0]
        session=URLSession(configuration:configuration,delegate:collector,delegateQueue:nil)
    }
    private func request(_ path:String,method:String="GET",body:[String:String]?=nil,query:[URLQueryItem]=[]) throws -> URLRequest {
        var components=URLComponents();components.scheme="http";components.host="127.0.0.1";components.port=port;components.path=path;if !query.isEmpty{components.queryItems=query}
        guard let url=components.url else {throw ProxyError("控制请求无效")};var request=URLRequest(url:url);request.httpMethod=method;request.setValue("Bearer "+secret,forHTTPHeaderField:"Authorization")
        if let body {request.httpBody=try JSONEncoder().encode(body);request.setValue("application/json",forHTTPHeaderField:"Content-Type")};return request
    }
    private func send(_ request:URLRequest) async throws -> Data {
        do {
            let task=session.dataTask(with:request),collector=self.collector
            let (data,response)=try await withTaskCancellationHandler(operation:{try await withCheckedThrowingContinuation{collector.start(task,$0)}},onCancel:{task.cancel()})
            guard let http=response as? HTTPURLResponse else {throw CoreAPIError("控制接口")}
            guard (200...299).contains(http.statusCode) else {throw CoreAPIError(http.statusCode==401 || http.statusCode==403 ? "鉴权":http.statusCode==408 || http.statusCode==504 ? "超时":request.url?.path.hasSuffix("/delay")==true && http.statusCode>=500 ? "节点通道":"控制接口")}
            return data
        } catch is CancellationError {throw CancellationError()} catch _ as URLError where Task.isCancelled {throw CancellationError()} catch let error as CoreAPIError {throw error} catch let error as URLError {throw CoreAPIError(ConnectivityResult.category(error))} catch {throw CoreAPIError("控制接口")}
    }
    private func decode<T:Decodable>(_ type:T.Type,path:String) async throws -> T {let data=try await send(request(path));do {return try JSONDecoder().decode(type,from:data)} catch {throw CoreAPIError("控制接口响应格式")}}
    public func proxies() async throws -> [String:ProxyInfo] {struct Response:Decodable{var proxies:[String:ProxyInfo]};return try await decode(Response.self,path:"/proxies").proxies}
    public func connections() async throws -> ConnectionSnapshot {try await decode(ConnectionSnapshot.self,path:"/connections")}
    public func select(_ target:PolicyReference,group:String="proxy") async throws {
        guard group=="proxy" || group.hasPrefix("group-"),target != .selected,target != .reject else {throw ProxyError("策略选择无效")}
        _=try await send(request("/proxies/"+group,method:"PUT",body:["name":target.tag]))
    }
    public func setMode(_ mode:ProxyMode) async throws {_=try await send(request("/configs",method:"PATCH",body:["mode":mode.rawValue]))}
    public func delay(_ nodeID:UUID) async throws -> Int {
        let tag=PolicyReference.node(nodeID).tag
        let data=try await send(request("/proxies/"+tag+"/delay",query:[URLQueryItem(name:"url",value:ConfigBuilder.testURL),URLQueryItem(name:"timeout",value:"8000")]))
        struct Response:Decodable{var delay:Int};guard let response=try? JSONDecoder().decode(Response.self,from:data),response.delay>=0 else {throw CoreAPIError("节点测速响应格式")};return response.delay
    }
    public func probe(_ nodeID:UUID) async -> ProbeStatus {
        do {_ = try await delay(nodeID);return .available}catch{return .unknown}
    }
    public func closeConnection(_ id:String) async throws {guard UUID(uuidString:id) != nil else {throw ProxyError("连接 ID 无效")};_=try await send(request("/connections/"+id,method:"DELETE"))}
    public func closeAllConnections() async throws {_=try await send(request("/connections",method:"DELETE"))}
    public func traffic() throws -> AsyncThrowingStream<TransferRate,Error> {
        var request=try request("/traffic");var components=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!;components.scheme="ws";request.url=components.url
        let socket=session.webSocketTask(with:request);socket.resume()
        return AsyncThrowingStream {continuation in
            let task=Task {
                do {while !Task.isCancelled {let message=try await socket.receive();let data:Data;switch message {case .data(let value):data=value;case .string(let value):data=Data(value.utf8);@unknown default:continue};guard data.count<4096,let rate=try? JSONDecoder().decode(TransferRate.self,from:data) else {throw ProxyError("流量数据格式无效")};continuation.yield(rate)}} catch {if !Task.isCancelled {continuation.finish(throwing:ProxyError("流量通道已断开"))}}
                socket.cancel(with:.goingAway,reason:nil);continuation.finish()
            }
            continuation.onTermination={_ in task.cancel();socket.cancel(with:.goingAway,reason:nil)}
        }
    }
    public func shutdown() {session.invalidateAndCancel()}
    public static func actualTag(_ proxies:[String:ProxyInfo]) -> String? {
        var next=proxies["proxy"]?.now;var seen=Set<String>()
        while let tag=next {guard seen.insert(tag).inserted else{return nil};if let nested=proxies[tag]?.now {next=nested} else{return tag}}
        return nil
    }
}
