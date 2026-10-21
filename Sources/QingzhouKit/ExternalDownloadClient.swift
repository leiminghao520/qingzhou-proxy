import Foundation

public protocol DownloadClient: Sendable {
    func fetchResponse(_ url: URL, limit: Int) async throws -> DownloadResult
    func networkEnvironmentChanged()
}

// 下载任务分别持有响应和取消状态；会话只负责复用外部 HTTPS 连接。
public final class ExternalDownloadClient: NSObject, DownloadClient, URLSessionDataDelegate, @unchecked Sendable {
    public static let shared = ExternalDownloadClient()
    private struct Pending {
        var data = Data()
        var usage: String?
        var clientAPI: String?
        var failure: Error?
        let limit: Int
        let continuation: CheckedContinuation<DownloadResult, Error>
    }
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var session: URLSession!
    private let protocolClasses: [AnyClass]?
    private var closed = false
    public private(set) var generation = 0

    public init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
        super.init()
        session = makeSession()
    }
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.protocolClasses = protocolClasses
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }
    public func fetchResponse(_ url: URL, limit: Int = 2 * 1024 * 1024) async throws -> DownloadResult {
        guard url.scheme?.lowercased() == "https", url.host != nil, limit > 0 else { throw SubscriptionFailure.invalidURL }
        let cancellation = DownloadCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !closed else {lock.unlock(); continuation.resume(throwing: SubscriptionFailure.cancelled); return}
                let task = session.dataTask(with: url)
                pending[ObjectIdentifier(task)] = Pending(limit: limit, continuation: continuation)
                lock.unlock()
                cancellation.install(task)
                task.resume()
            }
        }, onCancel: { cancellation.cancel() })
    }
    public func networkEnvironmentChanged() {
        lock.lock()
        guard !closed else {lock.unlock(); return}
        let old = session
        generation += 1; session = makeSession()
        lock.unlock()
        old?.invalidateAndCancel()
    }
    public func shutdown() {
        lock.lock(); closed = true; let old = session; session = nil; lock.unlock()
        old?.invalidateAndCancel()
    }
    public var activeRequestCount: Int {lock.lock(); defer {lock.unlock()}; return pending.count}
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            lock.lock(); pending[ObjectIdentifier(task)]?.failure = SubscriptionFailure.invalidURL; lock.unlock()
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer {lock.unlock()}
        let key = ObjectIdentifier(dataTask)
        guard var item = pending[key] else {completionHandler(.cancel); return}
        if let http = response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) {item.failure = SubscriptionFailure.status(http.statusCode)}
            else if response.expectedContentLength > Int64(item.limit) {item.failure = SubscriptionFailure.tooLarge}
            else {item.usage = http.value(forHTTPHeaderField: "subscription-userinfo"); item.clientAPI = http.value(forHTTPHeaderField:"Qingzhou-Client-API")}
        } else {item.failure = SubscriptionFailure.http}
        pending[key] = item
        completionHandler(item.failure == nil ? .allow : .cancel)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let key = ObjectIdentifier(dataTask)
        guard var item = pending[key] else {lock.unlock(); return}
        if item.data.count + data.count > item.limit {item.failure = SubscriptionFailure.tooLarge}
        else if item.failure == nil {item.data.append(data)}
        pending[key] = item; let failed = item.failure != nil
        lock.unlock()
        if failed {dataTask.cancel()}
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let item = pending.removeValue(forKey: ObjectIdentifier(task)); lock.unlock()
        guard let item else {return}
        if let error = item.failure ?? error.map({SubscriptionFailure.classify($0)}) {item.continuation.resume(throwing: error)}
        else {item.continuation.resume(returning: DownloadResult(data: item.data, usageHeader: item.usage, clientAPI:item.clientAPI))}
    }
}

private final class DownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func install(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
        if cancel {task.cancel()}
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
}
