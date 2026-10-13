import Foundation
import CFNetwork

public enum ConnectivityProbe {
    public static func test(port:Int) async -> Bool {(await detailed(port:port)).contains("正常")}
    public static func detailed(port:Int?,protocolClasses:[AnyClass]?=nil) async -> String {
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=10;config.timeoutIntervalForResource=10;config.protocolClasses=protocolClasses
        if let port {config.connectionProxyDictionary=[kCFNetworkProxiesHTTPEnable as String:1,kCFNetworkProxiesHTTPProxy as String:"127.0.0.1",kCFNetworkProxiesHTTPPort as String:port,kCFNetworkProxiesHTTPSEnable as String:1,kCFNetworkProxiesHTTPSProxy as String:"127.0.0.1",kCFNetworkProxiesHTTPSPort as String:port]}else{config.connectionProxyDictionary=[kCFNetworkProxiesHTTPEnable as String:0,kCFNetworkProxiesHTTPSEnable as String:0,kCFNetworkProxiesSOCKSEnable as String:0]}
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel()}
        do {
            let (data,response)=try await session.data(from:URL(string:ConfigBuilder.testURL)!);guard let http=response as? HTTPURLResponse else{return "HTTPS 检测失败：响应格式无效"}
            guard http.statusCode==200,String(decoding:data,as:UTF8.self).contains("Success") else{return "HTTPS 检测失败：检测页响应不符合预期"};return "HTTPS 连通性正常"
        }catch let error as URLError {switch error.code {case .cannotFindHost,.dnsLookupFailed:return "DNS 检测失败：目标解析失败";case .secureConnectionFailed,.serverCertificateHasBadDate,.serverCertificateUntrusted,.serverCertificateHasUnknownRoot,.serverCertificateNotYetValid,.clientCertificateRejected,.clientCertificateRequired:return "TLS 检测失败：目标证书或握手错误";case .cannotConnectToHost,.networkConnectionLost:return "节点或接管路径失败：代理连接不可达或已中断";case .timedOut:return "HTTPS 检测失败：请求超时，尚不能独立判断节点或 TLS 原因";case .cancelled:return "HTTPS 检测已取消";default:return "HTTPS 检测失败：网络请求未完成"}}
        catch{return "HTTPS 检测失败：网络请求未完成"}
    }
}
