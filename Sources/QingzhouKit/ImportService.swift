import Foundation

public struct ImportPreview:Sendable {
    public var fullConfiguration:ShadowrocketConfiguration?;public var revision:String?;public var profileName:String?
    public var candidates:[Candidate];public var source:String?;public var groups:[PolicyGroup];public var rules:[RoutingRule];public var final:PolicyReference?;public var unsupported:[String];public var ignored:[String];public var usage:UsageInfo?
    public init(candidates:[Candidate],source:String?=nil,groups:[PolicyGroup]=[],rules:[RoutingRule]=[],final:PolicyReference?=nil,unsupported:[String]=[],ignored:[String]=[],usage:UsageInfo?=nil,fullConfiguration:ShadowrocketConfiguration?=nil,revision:String?=nil,profileName:String?=nil){self.fullConfiguration=fullConfiguration;self.revision=revision;self.profileName=profileName;self.candidates=candidates;self.source=source;self.groups=groups;self.rules=rules;self.final=final;self.unsupported=unsupported;self.ignored=ignored;self.usage=usage}
}
public struct DownloadResult:Sendable {public var data:Data;public var usageHeader:String?}
public enum ImportService {
    public static func preview(_ input:String) async throws -> ImportPreview {
        let text=input.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.lowercased().hasPrefix("https://") {
            guard let url=URL(string:text),url.host != nil else {throw SubscriptionFailure.invalidURL}
            let response=try await BoundedDownload.fetchResponse(url)
            guard let content=String(data:response.data,encoding:.utf8) else {throw SubscriptionFailure.format}
            var result:ImportPreview;do{result=try ProfileImporter.parse(content)}catch{throw SubscriptionFailure.format};result.source=text;result.usage=UsageInfo.parse(response.usageHeader);return result
        }
        if text.lowercased().hasPrefix("http://"){throw SubscriptionFailure.invalidURL}
        return try ProfileImporter.parse(text)
    }
}
// 使用流式接收限制响应大小，避免先把整个订阅载入内存。
public final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var data = Data()
    private var continuation: CheckedContinuation<DownloadResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private var usageHeader:String?
    private let protocolClasses: [AnyClass]?
    private let limit: Int
    private let lock = NSLock()
    public init(limit: Int = 2 * 1024 * 1024, protocolClasses: [AnyClass]? = nil) { self.limit = limit; self.protocolClasses = protocolClasses }
    public static func fetch(_ url:URL,limit:Int=2*1024*1024,protocolClasses:[AnyClass]?=nil) async throws -> Data {
        try await fetchResponse(url,limit:limit,protocolClasses:protocolClasses).data
    }
    public static func fetchResponse(_ url:URL,limit:Int=2*1024*1024,protocolClasses:[AnyClass]?=nil) async throws -> DownloadResult {
        guard url.scheme?.lowercased()=="https" else {throw SubscriptionFailure.invalidURL}
        let download=BoundedDownload(limit:limit,protocolClasses:protocolClasses)
        return try await withTaskCancellationHandler(operation:{try await withCheckedThrowingContinuation{download.start(url,$0)}},onCancel:{download.cancel()})
    }
    private func start(_ url: URL, _ continuation: CheckedContinuation<DownloadResult, Error>) {
        lock.lock(); defer {lock.unlock()}
        self.continuation = continuation
        if failure != nil { self.continuation = nil; continuation.resume(throwing: SubscriptionFailure.cancelled); return }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15; config.urlCache = nil; config.httpCookieStorage = nil
        config.protocolClasses = protocolClasses
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session!.dataTask(with: url); task!.resume()
    }
    private func setFailure(_ error: Error) {lock.lock(); failure = error; lock.unlock()}
    private func cancel() { lock.lock(); failure = SubscriptionFailure.cancelled; let task = self.task; lock.unlock(); task?.cancel() }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { setFailure(SubscriptionFailure.invalidURL); completionHandler(nil); return }
        completionHandler(request)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {setFailure(SubscriptionFailure.http);completionHandler(.cancel);return}
        guard (200...299).contains(http.statusCode) else {setFailure(SubscriptionFailure.status(http.statusCode));completionHandler(.cancel);return}
        guard response.expectedContentLength <= Int64(limit) else { setFailure(SubscriptionFailure.tooLarge); completionHandler(.cancel); return }
        usageHeader=http.value(forHTTPHeaderField:"subscription-userinfo")
        completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.data.count + data.count > limit { setFailure(SubscriptionFailure.tooLarge); dataTask.cancel() } else { self.data.append(data) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = self.continuation; let failure = self.failure; self.continuation = nil; lock.unlock()
        if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: SubscriptionFailure.classify(error)) }
        else { continuation?.resume(returning: DownloadResult(data:data,usageHeader:usageHeader)) }
        session.finishTasksAndInvalidate(); self.session = nil
    }
}
