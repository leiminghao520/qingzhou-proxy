import Foundation
import CFNetwork

public enum ConnectivityProbe {
    public static func test(port: Int) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10;config.timeoutIntervalForResource = 10
        config.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String:1,kCFNetworkProxiesHTTPProxy as String:"127.0.0.1",kCFNetworkProxiesHTTPPort as String:port,kCFNetworkProxiesHTTPSEnable as String:1,kCFNetworkProxiesHTTPSProxy as String:"127.0.0.1",kCFNetworkProxiesHTTPSPort as String:port]
        let session = URLSession(configuration:config);defer {session.invalidateAndCancel()}
        do {
            let (data,response) = try await session.data(from:URL(string:"https://www.apple.com/library/test/success.html")!)
            return (response as? HTTPURLResponse)?.statusCode == 200 && String(decoding:data,as:UTF8.self).contains("Success")
        } catch {return false}
    }
}
