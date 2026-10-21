import Foundation

public struct ImportPreview:Sendable {
    public var fullConfiguration:ShadowrocketConfiguration?;public var revision:String?;public var profileName:String?
    public var candidates:[Candidate];public var source:String?;public var groups:[PolicyGroup];public var rules:[RoutingRule];public var final:PolicyReference?;public var unsupported:[String];public var ignored:[String];public var usage:UsageInfo?
    public init(candidates:[Candidate],source:String?=nil,groups:[PolicyGroup]=[],rules:[RoutingRule]=[],final:PolicyReference?=nil,unsupported:[String]=[],ignored:[String]=[],usage:UsageInfo?=nil,fullConfiguration:ShadowrocketConfiguration?=nil,revision:String?=nil,profileName:String?=nil){self.fullConfiguration=fullConfiguration;self.revision=revision;self.profileName=profileName;self.candidates=candidates;self.source=source;self.groups=groups;self.rules=rules;self.final=final;self.unsupported=unsupported;self.ignored=ignored;self.usage=usage}
}
public struct DownloadResult:Sendable {public var data:Data;public var usageHeader:String?;public init(data:Data,usageHeader:String?=nil){self.data=data;self.usageHeader=usageHeader}}
public enum ImportService {
    public static func preview(_ input:String, downloader: any DownloadClient = ExternalDownloadClient.shared) async throws -> ImportPreview {
        let text=input.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.lowercased().hasPrefix("https://") {
            guard let url=URL(string:text),url.host != nil else {throw SubscriptionFailure.invalidURL}
            let response=try await downloader.fetchResponse(url,limit:2*1024*1024)
            guard let content=String(data:response.data,encoding:.utf8) else {throw SubscriptionFailure.format}
            var result:ImportPreview;do{result=try ProfileImporter.parse(content)}catch{throw SubscriptionFailure.format};result.source=text;result.usage=UsageInfo.parse(response.usageHeader);return result
        }
        if text.lowercased().hasPrefix("http://"){throw SubscriptionFailure.invalidURL}
        return try ProfileImporter.parse(text)
    }
}
// 保留原静态入口，生产环境共享会话，注入协议的测试会话单独释放。
public enum BoundedDownload {
    public static func fetch(_ url:URL,limit:Int=2*1024*1024,protocolClasses:[AnyClass]?=nil) async throws -> Data {
        try await fetchResponse(url,limit:limit,protocolClasses:protocolClasses).data
    }
    public static func fetchResponse(_ url:URL,limit:Int=2*1024*1024,protocolClasses:[AnyClass]?=nil) async throws -> DownloadResult {
        if let protocolClasses {
            let client=ExternalDownloadClient(protocolClasses:protocolClasses)
            defer {client.shutdown()}
            return try await client.fetchResponse(url,limit:limit)
        }
        return try await ExternalDownloadClient.shared.fetchResponse(url,limit:limit)
    }
}
