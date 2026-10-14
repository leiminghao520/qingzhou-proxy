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
    public var duration:String {let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];let date=f.date(from:start) ?? ISO8601DateFormatter().date(from:start);guard let date else{return "未知"};return "\(max(0,Int(Date().timeIntervalSince(date)))) 秒"}
}
public struct ConnectionSnapshot:Decodable,Sendable {public var downloadTotal:Int64;public var uploadTotal:Int64;public var connections:[CoreConnection]}
public actor CoreAPIClient {
    public let port:Int
    private let secret:String
    private let session:URLSession
    public init(context:CoreControlContext,protocolClasses:[AnyClass]?=nil) {
        port=context.port;secret=context.secret
        let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForRequest=10;configuration.timeoutIntervalForResource=10;configuration.urlCache=nil;configuration.httpCookieStorage=nil;configuration.protocolClasses=protocolClasses
        configuration.connectionProxyDictionary=[kCFNetworkProxiesHTTPEnable as String:0,kCFNetworkProxiesHTTPSEnable as String:0,kCFNetworkProxiesSOCKSEnable as String:0]
        session=URLSession(configuration:configuration)
    }
    private func request(_ path:String,method:String="GET",body:[String:String]?=nil,query:[URLQueryItem]=[]) throws -> URLRequest {
        var components=URLComponents();components.scheme="http";components.host="127.0.0.1";components.port=port;components.path=path;if !query.isEmpty{components.queryItems=query}
        guard let url=components.url else {throw ProxyError("控制请求无效")};var request=URLRequest(url:url);request.httpMethod=method;request.setValue("Bearer "+secret,forHTTPHeaderField:"Authorization")
        if let body {request.httpBody=try JSONEncoder().encode(body);request.setValue("application/json",forHTTPHeaderField:"Content-Type")};return request
    }
    private func send(_ request:URLRequest) async throws -> Data {
        do {
            let (bytes,response)=try await session.bytes(for:request)
            guard let http=response as? HTTPURLResponse else {throw CoreAPIError("控制接口")}
            guard (200...299).contains(http.statusCode) else {throw CoreAPIError(http.statusCode==401 || http.statusCode==403 ? "鉴权":http.statusCode==408 || http.statusCode==504 ? "超时":request.url?.path.hasSuffix("/delay")==true && http.statusCode>=500 ? "节点通道":"控制接口")}
            guard response.expectedContentLength<=2*1024*1024 else {throw ProxyError("核心响应过大")}
            var data=Data();for try await byte in bytes {guard data.count<2*1024*1024 else {throw ProxyError("核心响应超过限制")};data.append(byte)};return data
        } catch is CancellationError {throw CancellationError()} catch let error as CoreAPIError {throw error} catch let error as URLError {throw CoreAPIError(ConnectivityResult.category(error))} catch {throw CoreAPIError("控制接口")}
    }
    private func decode<T:Decodable>(_ type:T.Type,path:String) async throws -> T {let data=try await send(request(path));do {return try JSONDecoder().decode(type,from:data)} catch {throw CoreAPIError("控制接口响应格式")}}
    public func proxies() async throws -> [String:ProxyInfo] {struct Response:Decodable{var proxies:[String:ProxyInfo]};return try await decode(Response.self,path:"/proxies").proxies}
    public func connections() async throws -> ConnectionSnapshot {try await decode(ConnectionSnapshot.self,path:"/connections")}
    public func select(_ target:PolicyReference,group:String="proxy") async throws {
        guard group=="proxy" || group.hasPrefix("group-"),target != .selected,target != .reject else {throw ProxyError("策略选择无效")}
        _=try await send(request("/proxies/"+group,method:"PUT",body:["name":target.tag]))
    }
    public func setMode(_ mode:ProxyMode) async throws {_=try await send(request("/configs",method:"PATCH",body:["mode":mode.rawValue]))}
    public func delay(_ nodeID:UUID,url:String=ConfigBuilder.testURL) async throws -> Int {
        let tag=PolicyReference.node(nodeID).tag
        let data=try await send(request("/proxies/"+tag+"/delay",query:[URLQueryItem(name:"url",value:url),URLQueryItem(name:"timeout",value:"8000")]))
        struct Response:Decodable{var delay:Int};guard let response=try? JSONDecoder().decode(Response.self,from:data),response.delay>=0 else {throw CoreAPIError("节点测速响应格式")};return response.delay
    }
    private enum TargetHealth {case available,unavailable,unknown}
    private func targetHealth(_ nodeID:UUID,url:String) async -> TargetHealth {
        do {_ = try await delay(nodeID,url:url);return .available}
        catch let error as CoreAPIError where error.category == "节点通道" || error.category == "超时" {return .unavailable}
        catch {return .unknown}
    }
    public func probe(_ nodeID:UUID) async -> ProbeStatus {
        // 两个目标并行检测，共用核心的八秒请求预算，避免失效节点串行阻塞界面。
        async let first=targetHealth(nodeID,url:ConfigBuilder.testURL)
        async let second=targetHealth(nodeID,url:ConfigBuilder.secondaryTestURL)
        let outcomes=await [first,second]
        if outcomes.contains(where:{if case .available=$0{return true};return false}) {return .available}
        guard outcomes.allSatisfy({if case .unavailable=$0{return true};return false}) else{return .unknown}
        // 两个目标都失败后独立核对控制接口，避免核心退出被误判为节点故障。
        do {_ = try await proxies();return .unavailable}catch{return .unknown}
    }
    public func initializeFallback(_ group:PolicyGroup) async throws -> UUID? {
        guard group.kind == .fallback else{return nil}
        // 启动时按优先级寻找可用成员，避免默认成员失效让整个回退组无法启动。
        for member in group.members {
            try Task.checkCancellation()
            if case .node(let id)=member,case .available=await probe(id) {
                try await select(member,group:PolicyReference.group(group.id).tag);return id
            }
        }
        return nil
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
