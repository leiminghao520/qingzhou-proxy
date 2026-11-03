import Foundation
import CFNetwork

public struct CoreAPIError:LocalizedError,Sendable {
    public let category:String
    public let transportCode:Int?
    public var retryableDuringStartup:Bool {transportCode.map{[URLError.cannotConnectToHost.rawValue,URLError.networkConnectionLost.rawValue,URLError.timedOut.rawValue].contains($0)} ?? false}
    public var errorDescription:String? {"核心检测失败："+category}
    public init(_ category:String,transportCode:Int?=nil){self.category=category;self.transportCode=transportCode}
}
public struct ProxyInfo:Decodable,Sendable,Equatable {
    public struct History:Decodable,Sendable,Equatable {public var delay:Int}
    public var type:String;public var name:String;public var now:String?;public var all:[String]?;public var history:[History]?
}
public struct TransferRate:Decodable,Sendable {public var up:Int64;public var down:Int64}
public struct ConnectionMetadata:Decodable,Sendable,Equatable {
    public var network:String?;public var host:String?;public var destinationIP:String?;public var destinationPort:String?;public var processPath:String?;public var type:String?
}
public struct CoreConnection:Decodable,Identifiable,Sendable,Equatable {
    public var id:String;public var metadata:ConnectionMetadata;public var upload:Int64;public var download:Int64;public var start:String;public var chains:[String];public var rule:String?;public var rulePayload:String?
    public var target:String {(metadata.host?.isEmpty==false ? metadata.host! : metadata.destinationIP ?? "未知")+":"+(metadata.destinationPort ?? "")}
    // 格式化器创建成本高且线程安全，连接列表刷新时复用同一实例。
    nonisolated(unsafe) private static let fractionalFormatter:ISO8601DateFormatter={let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f}()
    nonisolated(unsafe) private static let plainFormatter=ISO8601DateFormatter()
    public var duration:String {let date=Self.fractionalFormatter.date(from:start) ?? Self.plainFormatter.date(from:start);guard let date else{return "未知"};return "\(max(0,Int(Date().timeIntervalSince(date)))) 秒"}
}
public struct ConnectionSnapshot:Decodable,Sendable {public var downloadTotal:Int64;public var uploadTotal:Int64;public var connections:[CoreConnection]}
// 会话级委托按块接收响应，超过上限立即取消；逐字节迭代 AsyncBytes 在连接列表较大时 CPU 开销明显。
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
    private var closed=false
    private var activeRequests=0
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
        guard !closed else {throw CoreAPIError("控制通道已关闭")}
        try Task.checkCancellation()
        activeRequests+=1
        defer {activeRequests-=1;if closed && activeRequests==0 {session.invalidateAndCancel()}}
        do {
            let task=session.dataTask(with:request),collector=self.collector
            let (data,response)=try await withTaskCancellationHandler(operation:{try await withCheckedThrowingContinuation{collector.start(task,$0)}},onCancel:{task.cancel()})
            guard let http=response as? HTTPURLResponse else {throw CoreAPIError("控制接口")}
            guard (200...299).contains(http.statusCode) else {throw CoreAPIError(http.statusCode==401 || http.statusCode==403 ? "鉴权":http.statusCode==408 || http.statusCode==504 ? "超时":request.url?.path.hasSuffix("/delay")==true && http.statusCode>=500 ? "节点通道":"控制接口")}
            return data
        // 调用方取消或控制通道关闭导致的 URLError.cancelled 属于正常收尾，按取消处理而不是报告“核心检测失败”。
        } catch is CancellationError {throw CancellationError()} catch let error as URLError where error.code == .cancelled && (Task.isCancelled || closed) {throw CancellationError()} catch let error as CoreAPIError {throw error} catch let error as URLError {throw CoreAPIError(ConnectivityResult.category(error),transportCode:error.code.rawValue)} catch {throw CoreAPIError("控制接口")}
    }
    private func decode<T:Decodable>(_ type:T.Type,path:String,timeout:TimeInterval?=nil) async throws -> T {var query=try request(path);if let timeout {query.timeoutInterval=timeout};let data=try await send(query);do {return try JSONDecoder().decode(type,from:data)} catch {throw CoreAPIError("控制接口响应格式")}}
    private struct ProxyResponse:Decodable {var proxies:[String:ProxyInfo]}
    public func proxies() async throws -> [String:ProxyInfo] {try await decode(ProxyResponse.self,path:"/proxies").proxies}
    public func preparedProxies() async throws -> [String:ProxyInfo] {
        let initial=try await proxies()
        guard Self.actualTag(initial)==nil else{return initial}
        let candidates=Self.pendingAutomaticNodes(initial)
        guard !candidates.isEmpty else{return initial}
        // URLTest 在首轮测速完成前会返回空 now；直接测成员以建立核心自己的选择历史。
        // 不猜测首个节点，也不借用 GLOBAL 组绕过当前选择，最终仍读取并验证实际节点。
        return try await withThrowingTaskGroup(of:Bool.self) { group in
            for id in candidates.prefix(4) {group.addTask{if case .success = await self.measureNode(id){return true};return false}}
            while let succeeded=try await group.next() {
                try Task.checkCancellation()
                if succeeded {
                    let refreshed=try await proxies()
                    if Self.actualTag(refreshed) != nil {group.cancelAll();return refreshed}
                }
            }
            try Task.checkCancellation()
            return try await proxies()
        }
    }
    public func waitUntilReady(timeout:TimeInterval=5) async throws {
        try await CoreAPIReadiness.wait(timeout:timeout) {budget in
            _ = try await self.decode(ProxyResponse.self,path:"/proxies",timeout:budget)
        }
    }
    public func connections() async throws -> ConnectionSnapshot {try await decode(ConnectionSnapshot.self,path:"/connections")}
    public func select(_ target:PolicyReference,group:String="proxy") async throws {
        guard group=="proxy" || group.hasPrefix("group-"),target != .selected,target != .reject else {throw ProxyError("策略选择无效")}
        _=try await send(request("/proxies/"+group,method:"PUT",body:["name":target.tag]))
    }
    public func setMode(_ mode:ProxyMode) async throws {_=try await send(request("/configs",method:"PATCH",body:["mode":mode.rawValue]))}
    public func verifySelection(_ target:PolicyReference,group:String="proxy") async throws {
        let info=try await proxies()
        guard info[group]?.now==target.tag else {throw CoreAPIError("选择未生效")}
    }
    // 让 URLTest 更新自身成员健康及实际出口，绝不把自动策略改成固定节点。
    public func refreshAutomatic() async throws {
        _ = try await send(request("/group/auto/delay",query:[URLQueryItem(name:"url",value:ConfigBuilder.testURL),URLQueryItem(name:"timeout",value:"8000")]))
    }
    public func delay(_ nodeID:UUID,url:String=ConfigBuilder.testURL) async throws -> Int {
        let tag=PolicyReference.node(nodeID).tag
        let data=try await send(request("/proxies/"+tag+"/delay",query:[URLQueryItem(name:"url",value:url),URLQueryItem(name:"timeout",value:"8000")]))
        struct Response:Decodable{var delay:Int};guard let response=try? JSONDecoder().decode(Response.self,from:data),response.delay>=0 else {throw CoreAPIError("节点测速响应格式")};return response.delay
    }
    public enum NodeMeasurement: Sendable {case success(Int), failure([String])}
    public func measureNode(_ nodeID: UUID) async -> NodeMeasurement {
        await withTaskGroup(of: (Int, Result<Int, CoreAPIError>).self) { tasks in
            for (index, url) in [ConfigBuilder.testURL, ConfigBuilder.secondaryTestURL].enumerated() {
                tasks.addTask {
                    do { return (index, .success(try await self.delay(nodeID, url: url))) }
                    catch { return (index, .failure(CoreAPIError(ConnectivityResult.category(error)))) }
                }
            }
            var failures = [String?](repeating: nil, count: 2)
            for await (index, result) in tasks {
                guard !Task.isCancelled else { tasks.cancelAll(); return .failure(["取消"]) }
                switch result {
                case .success(let delay):
                    // 取消只作用于本轮的剩余请求，不关闭共享控制会话。
                    tasks.cancelAll(); return .success(delay)
                case .failure(let error): failures[index] = error.category
                }
            }
            return .failure(failures.compactMap { $0 })
        }
    }
    public func probe(_ nodeID:UUID) async -> ProbeStatus {
        switch await measureNode(nodeID) {
        case .success: return Task.isCancelled ? .unknown : .available
        case .failure(let failures):
            guard !Task.isCancelled, failures.count == 2,
                  failures.allSatisfy({ $0 == "节点通道" }) else { return .unknown }
            // 两个目标都失败后独立核对控制接口，避免核心退出被误判为节点故障。
            do { _ = try await proxies(); return Task.isCancelled ? .unknown : .unavailable }
            catch { return .unknown }
        }
    }
    public func initializeFallback(_ group:PolicyGroup) async throws -> UUID? {
        guard group.kind == .fallback else{return nil}
        let selected = try await FallbackBootstrap.initialize(groups: [group], probe: { await self.probe($0) }, select: { groupID, nodeID in
            try await self.select(.node(nodeID), group: PolicyReference.group(groupID).tag)
        })
        return selected[group.id]
    }
    public func initializeFallbacks(state: AppState) async throws {
        let groups = FallbackBootstrap.groups(in: state)
        let selected = try await FallbackBootstrap.initialize(groups: groups, probe: { await self.probe($0) }, select: { groupID, nodeID in
            try await self.select(.node(nodeID), group: PolicyReference.group(groupID).tag)
        })
        guard groups.allSatisfy({ selected[$0.id] != nil }) else {
            throw ProxyError("使用中的回退组没有可按优先级确认的可用节点")
        }
    }
    public func closeConnection(_ id:String) async throws {guard UUID(uuidString:id) != nil else {throw ProxyError("连接 ID 无效")};_=try await send(request("/connections/"+id,method:"DELETE"))}
    public func closeAllConnections() async throws {_=try await send(request("/connections",method:"DELETE"))}
    public func traffic() throws -> AsyncThrowingStream<TransferRate,Error> {
        guard !closed else {throw CoreAPIError("控制通道已关闭")}
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
    public func shutdown() {
        guard !closed else{return};closed=true
        // 先拒绝新请求并取消已创建任务；在途请求收尾后再失效，避免 Foundation 创建任务时抛异常。
        if activeRequests==0 {session.invalidateAndCancel()}
        else {session.getAllTasks{tasks in tasks.forEach{$0.cancel()}}}
    }
    public static func actualTag(_ proxies:[String:ProxyInfo]) -> String? {actualTag(proxies,root:"proxy")}
    public static func actualTag(_ proxies:[String:ProxyInfo],root:String) -> String? {
        var next=proxies[root]?.now;var seen=Set<String>()
        while let tag=next {guard !tag.isEmpty,seen.insert(tag).inserted else{return nil};if let nested=proxies[tag]?.now {next=nested} else if proxies[tag]?.all != nil || proxies[tag]?.type.lowercased()=="urltest" {return nil} else{return tag}}
        return nil
    }
    public static func pendingAutomaticNodes(_ proxies:[String:ProxyInfo]) -> [UUID] {
        var next="proxy",seen=Set<String>()
        while seen.insert(next).inserted,let info=proxies[next] {
            if info.type.lowercased()=="urltest",info.now?.isEmpty != false {
                return (info.all ?? []).compactMap { tag in
                    guard tag.hasPrefix("node-"),let id=UUID(uuidString:String(tag.dropFirst(5))),
                          let member=proxies[tag],member.now==nil,member.all==nil else{return nil}
                    return id
                }
            }
            guard let selected=info.now,!selected.isEmpty else{return []}
            next=selected
        }
        return []
    }
}
