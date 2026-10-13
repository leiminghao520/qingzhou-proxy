import Foundation

public struct ImportPreview: Sendable {
    public var candidates: [Candidate]
    public var source: String?
    public init(candidates: [Candidate], source: String? = nil) { self.candidates = candidates; self.source = source }
}
public enum ImportService {
    public static func preview(_ input: String) async throws -> ImportPreview {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("https://") {
            guard let url = URL(string: value), url.host != nil else { throw ProxyError("订阅地址无效") }
            let data = try await BoundedDownload.fetch(url)
            guard let text = String(data: data, encoding: .utf8) else { throw ProxyError("订阅必须为 UTF-8 节点链接列表") }
            return ImportPreview(candidates: try NodeParser.parseList(text), source: value)
        }
        if value.lowercased().hasPrefix("http://") { throw ProxyError("订阅地址必须使用 HTTPS") }
        return ImportPreview(candidates: try NodeParser.parseList(value))
    }
}
// 使用流式接收限制响应大小，避免先把整个订阅载入内存。
public final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private let protocolClasses: [AnyClass]?
    private let limit: Int
    private let lock = NSLock()
    public init(limit: Int = 2 * 1024 * 1024, protocolClasses: [AnyClass]? = nil) { self.limit = limit; self.protocolClasses = protocolClasses }
    public static func fetch(_ url: URL, limit: Int = 2 * 1024 * 1024, protocolClasses: [AnyClass]? = nil) async throws -> Data {
        let download = BoundedDownload(limit:limit,protocolClasses:protocolClasses)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in download.start(url, continuation) }
        }, onCancel: { download.cancel() })
    }
    private func start(_ url: URL, _ continuation: CheckedContinuation<Data, Error>) {
        lock.lock(); defer {lock.unlock()}
        self.continuation = continuation
        if failure != nil { self.continuation = nil; continuation.resume(throwing: ProxyError("订阅下载已取消")); return }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15; config.urlCache = nil; config.httpCookieStorage = nil
        config.protocolClasses = protocolClasses
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session!.dataTask(with: url); task!.resume()
    }
    private func setFailure(_ error: Error) {lock.lock(); failure = error; lock.unlock()}
    private func cancel() { lock.lock(); failure = ProxyError("订阅下载已取消"); let task = self.task; lock.unlock(); task?.cancel() }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { setFailure(ProxyError("订阅重定向必须使用 HTTPS")); completionHandler(nil); return }
        completionHandler(request)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { setFailure(ProxyError("订阅请求失败，请检查链接是否过期或被撤销")); completionHandler(.cancel); return }
        guard response.expectedContentLength <= Int64(limit) else { setFailure(ProxyError("订阅超过 2 MiB 限制")); completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.data.count + data.count > limit { setFailure(ProxyError("订阅超过 2 MiB 限制")); dataTask.cancel() } else { self.data.append(data) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = self.continuation; let failure = self.failure; self.continuation = nil; lock.unlock()
        if let failure { continuation?.resume(throwing: failure) }
        else if error != nil { continuation?.resume(throwing: ProxyError("订阅下载失败，请检查网络、证书和链接有效性")) }
        else { continuation?.resume(returning: data) }
        session.finishTasksAndInvalidate(); self.session = nil
    }
}
