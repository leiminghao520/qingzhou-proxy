import Foundation
import CFNetwork

public struct ThroughputContext: Codable, Sendable, Equatable {
    public let profileID: UUID?
    public let connectionID: UUID
    public let nodeID: UUID
    public let captureMode: String
    public let coreVersion: String
    public init(profileID: UUID?, connectionID: UUID, nodeID: UUID, captureMode: String, coreVersion: String) {
        self.profileID=profileID; self.connectionID=connectionID; self.nodeID=nodeID
        self.captureMode=captureMode; self.coreVersion=coreVersion
    }
}

public enum ThroughputOutcome: String, Codable, Sendable {
    case completed, timedOut, cancelled, httpError, truncated, transportError, sizeLimit, invalidRequest
    public var label: String {
        switch self {
        case .completed: return "完整结束"
        case .timedOut: return "超时，未完整结束"
        case .cancelled: return "已取消，未完整结束"
        case .httpError: return "HTTP 状态异常"
        case .truncated: return "响应截断"
        case .transportError: return "传输失败"
        case .sizeLimit: return "超过测试流量上限"
        case .invalidRequest: return "测试请求无效"
        }
    }
}

// 结果只保存计量与会话身份，不持有 URL、请求头、正文或原始错误。
public struct ThroughputResult: Codable, Sendable, Equatable {
    public let id: UUID
    public let context: ThroughputContext
    public let startedAt: Date
    public let outcome: ThroughputOutcome
    public let statusCode: Int?
    public let firstByteSeconds: Double?
    public let receivedBytes: Int64
    public let totalSeconds: Double
    public let targetSeconds: Double
    public var bytesPerSecond: Double { Double(receivedBytes) / max(totalSeconds, 0.001) }
    public var withinBudget: Bool { outcome == .completed && receivedBytes > 0 && totalSeconds <= targetSeconds }
    public func export(json: Bool) throws -> Data {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if json { return try encoder.encode(self) }
        return Data("测试编号：\(id)\n连接代次：\(context.connectionID)\n节点编号：\(context.nodeID)\n接管模式：\(context.captureMode)\n核心版本：\(context.coreVersion)\n结果：\(outcome.label)\nHTTP：\(statusCode.map(String.init) ?? "未取得")\n首包：\(firstByteSeconds.map { String(format: "%.3f 秒", $0) } ?? "未取得")\n已收：\(receivedBytes) 字节\n总耗时：\(String(format: "%.3f", totalSeconds)) 秒\n平均速度：\(Int(bytesPerSecond)) 字节/秒\n目标预算：\(targetSeconds) 秒\n预算内完整下载：\(withinBudget ? "是" : "否")".utf8)
    }
}

// 每轮独占 URLSession；取消和超时只关闭本轮请求，不操作代理核心或其他连接。
public final class ThroughputProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock=NSLock()
    private let context: ThroughputContext
    private let timeout: TimeInterval
    private let target: TimeInterval
    private let byteLimit: Int64
    private let protocolClasses: [AnyClass]?
    private var session: URLSession?
    private var continuation: CheckedContinuation<ThroughputResult,Never>?
    private var result: ThroughputResult?
    private var deadline: DispatchWorkItem?
    private var began=ProcessInfo.processInfo.systemUptime
    private var date=Date()
    private var id=UUID()
    private var received: Int64=0
    private var expected: Int64 = -1
    private var firstByte: Double?
    private var status: Int?
    private var started=false
    private var progress: (@Sendable (Int64) -> Void)?
    public init(context: ThroughputContext, timeout: TimeInterval=25, target: TimeInterval=10, byteLimit: Int64=32*1024*1024, protocolClasses: [AnyClass]?=nil) {
        self.context=context; self.timeout=max(0.01,timeout); self.target=max(0,target)
        self.byteLimit=max(1,byteLimit); self.protocolClasses=protocolClasses
    }
    public func run(_ input: URLRequest, proxyPort: Int?, progress: (@Sendable (Int64) -> Void)?=nil) async -> ThroughputResult {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { reply in
                lock.lock()
                if let result { lock.unlock(); reply.resume(returning:result); return }
                // 同一探针不能并发复用，以免覆盖正在等待的 continuation。
                if started {
                    let value=makeResult(.invalidRequest); lock.unlock(); reply.resume(returning:value); return
                }
                started=true; continuation=reply; self.progress=progress; began=ProcessInfo.processInfo.systemUptime; date=Date()
                guard let url=input.url, url.scheme?.lowercased()=="https", url.host != nil, url.user==nil, url.password==nil,
                      proxyPort.map({(1024...65535).contains($0)}) ?? true else {
                    lock.unlock(); finish(.invalidRequest); return
                }
                let config=ConnectivityProbe.configuration(port:proxyPort)
                config.timeoutIntervalForRequest=timeout; config.timeoutIntervalForResource=timeout
                config.urlCache=nil; config.httpCookieStorage=nil; config.httpShouldSetCookies=false
                config.urlCredentialStorage=nil; config.protocolClasses=protocolClasses
                let queue=OperationQueue(); queue.maxConcurrentOperationCount=1; queue.qualityOfService = .utility
                let session=URLSession(configuration:config,delegate:self,delegateQueue:queue); self.session=session
                var request=input; request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
                let task=session.dataTask(with:request)
                let timer=DispatchWorkItem { [weak self] in self?.finish(.timedOut) }; deadline=timer
                lock.unlock()
                DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+timeout,execute:timer)
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    public func cancel() { finish(.cancelled) }
    private func makeResult(_ outcome: ThroughputOutcome) -> ThroughputResult {
        ThroughputResult(id:id,context:context,startedAt:date,outcome:outcome,statusCode:status,firstByteSeconds:firstByte,receivedBytes:received,totalSeconds:max(0,ProcessInfo.processInfo.systemUptime-began),targetSeconds:target)
    }
    private func finish(_ outcome: ThroughputOutcome) {
        lock.lock()
        guard result==nil else { lock.unlock(); return }
        let value=makeResult(outcome); result=value
        let reply=continuation; continuation=nil; progress=nil
        let session=self.session; self.session=nil; deadline?.cancel(); deadline=nil
        lock.unlock()
        session?.invalidateAndCancel(); reply?.resume(returning:value)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // 不把临时请求中的认证头和正文转发给重定向目标。
        completionHandler(nil); finish(.httpError)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // 保持系统证书校验，禁止隐式读取网站凭据或弹出登录窗口。
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard result==nil else {lock.unlock(); completionHandler(.cancel); return}
        guard let http=response as? HTTPURLResponse else {lock.unlock(); completionHandler(.cancel); finish(.transportError); return}
        status=http.statusCode
        let encoding=http.value(forHTTPHeaderField:"Content-Encoding")?.lowercased()
        expected=(encoding==nil || encoding=="identity") ? response.expectedContentLength : -1
        let failure: ThroughputOutcome? = !(200...299).contains(http.statusCode) ? .httpError : expected>byteLimit ? .sizeLimit : nil
        lock.unlock()
        completionHandler(failure==nil ? .allow : .cancel)
        if let failure {finish(failure)}
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard result==nil else {lock.unlock(); return}
        if !data.isEmpty, firstByte==nil {firstByte=ProcessInfo.processInfo.systemUptime-began}
        received+=Int64(data.count)
        let count=received, exceeded=count>byteLimit, callback=progress
        lock.unlock()
        callback?(count)
        if exceeded {finish(.sizeLimit)}
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let outcome: ThroughputOutcome
        if let error=error as? URLError {
            outcome=error.code == .timedOut ? .timedOut : error.code == .cancelled ? .cancelled : expected>=0 && received<expected ? .truncated : .transportError
        } else if error != nil {outcome = .transportError}
        else {outcome = expected>=0 && received != expected ? .truncated : .completed}
        lock.unlock(); finish(outcome)
    }
}
