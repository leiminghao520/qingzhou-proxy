import Foundation

public enum SubscriptionFailure: String, Error, LocalizedError, CaseIterable {
    case network, dns, tls, timeout, unauthorized, gone, rateLimited, server, format, tooLarge, invalidURL, http, cancelled
    public var retryable:Bool {[.network,.dns,.timeout,.rateLimited,.server].contains(self)}
    public static func isTransientMessage(_ message:String?)->Bool {
        guard let message else{return false}
        return allCases.contains{$0.retryable && $0.localizedDescription==message}
    }
    public var errorDescription:String? {
        switch self {
        case .network:return "网络不可用，请检查网络连接后重试"
        case .dns:return "订阅域名解析失败，请检查 DNS 或网络后重试"
        case .tls:return "订阅 TLS 证书验证失败，请检查系统时间与订阅证书，不要关闭证书验证"
        case .timeout:return "订阅请求超时，请检查网络后重试"
        case .unauthorized:return "订阅鉴权失败（401/403），请更新订阅地址或授权"
        case .gone:return "订阅地址失效（404/410），请向提供方获取新地址"
        case .rateLimited:return "订阅请求被限流（429），稍后自动重试"
        case .server:return "订阅服务器暂时异常，稍后自动重试"
        case .format:return "订阅格式无法解析，请核对文件格式或联系提供方；旧配置已保留"
        case .tooLarge:return "订阅超过允许大小，请减少节点或规则数量"
        case .invalidURL:return "订阅地址必须是有效 HTTPS 地址，请检查后重试"
        case .http:return "订阅 HTTP 请求被拒绝，请检查地址或联系提供方"
        case .cancelled:return "订阅下载已取消"
        }
    }
    public static func status(_ code:Int)->Self {
        switch code {case 401,403:return .unauthorized;case 404,410:return .gone;case 429:return .rateLimited;case 500...599:return .server;default:return .http}
    }
    public static func classify(_ error:Error)->Self {
        if let failure=error as? Self {return failure}
        if error is CancellationError {return .cancelled}
        guard let url=error as? URLError else{return .format}
        switch url.code {
        case .cannotFindHost,.dnsLookupFailed:return .dns
        case .timedOut:return .timeout
        case .secureConnectionFailed,.serverCertificateHasBadDate,.serverCertificateUntrusted,.serverCertificateHasUnknownRoot,.serverCertificateNotYetValid,.clientCertificateRejected,.clientCertificateRequired:return .tls
        case .cancelled:return .cancelled
        default:return .network
        }
    }
    public static func retryState(_ error:Error,previousCount:Int,now:Date=Date())->(count:Int,after:Date?) {
        let failure=classify(error)
        guard failure.retryable else{return (4,nil)}
        let count=min(4,max(0,previousCount)+1)
        return (count,UpdateSchedule.nextRetry(count,now:now))
    }
}
