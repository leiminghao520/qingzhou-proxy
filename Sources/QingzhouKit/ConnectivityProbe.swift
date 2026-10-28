import Foundation
import CFNetwork

public struct ConnectivityResult:Sendable,Equatable {
    public enum Status:String,Sendable {case pending="尚未检测",passed="通过",failed="失败",notApplicable="不适用"}
    public let title:String
    public let status:Status
    public let category:String
    public let milliseconds:Int?
    public init(_ title:String,_ status:Status,_ category:String,milliseconds:Int?=nil){self.title=title;self.status=status;self.category=category;self.milliseconds=milliseconds}
    public var summary:String {title+"："+status.rawValue+(category.isEmpty ? "":"（"+category+"）")}
    public static let pending:[ConnectivityResult]=[ConnectivityResult("按当前规则的 HTTPS 检测",.pending,""),ConnectivityResult("当前节点通道检测",.pending,""),ConnectivityResult("本地代理入口检测",.pending,"")]
    // 任一路径失败都应显示具体失败，避免直连检测通过掩盖节点故障。
    public static func combinedSummary(_ results:[ConnectivityResult])->String {
        if let failure=results.first(where:{$0.status == .failed}) {return failure.summary}
        guard !results.isEmpty,results.allSatisfy({$0.status == .passed || $0.status == .notApplicable}),results.contains(where:{$0.status == .passed}) else{return "连通性尚未完成检测"}
        return "适用路径的 HTTPS 连通性正常"
    }
    public static func category(_ error:Error)->String {
        if let error=error as? CoreAPIError{return error.category}
        if error is CancellationError{return "取消"}
        let native=error as NSError
        if native.domain=="kCFErrorDomainCFNetwork",[306,310,311].contains(native.code){return "代理入口"}
        guard let error=error as? URLError else{return "连接"}
        switch error.code {
        case .cannotFindHost,.dnsLookupFailed:return "DNS"
        case .timedOut:return "超时"
        case .cancelled:return "取消"
        case .secureConnectionFailed,.serverCertificateHasBadDate,.serverCertificateUntrusted,.serverCertificateHasUnknownRoot,.serverCertificateNotYetValid,.clientCertificateRejected,.clientCertificateRequired:return "TLS"
        default:return "连接"
        }
    }
}
public enum ConnectivityProbe {
    public static func configuration(port:Int?,protocolClasses:[AnyClass]?=nil)->URLSessionConfiguration {
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=10;config.timeoutIntervalForResource=10;config.protocolClasses=protocolClasses
        if let port {config.connectionProxyDictionary=[kCFNetworkProxiesHTTPEnable as String:1,kCFNetworkProxiesHTTPProxy as String:"127.0.0.1",kCFNetworkProxiesHTTPPort as String:port,kCFNetworkProxiesHTTPSEnable as String:1,kCFNetworkProxiesHTTPSProxy as String:"127.0.0.1",kCFNetworkProxiesHTTPSPort as String:port]}else{
            // 空字典明确覆盖系统代理；TUN 检测必须检验内核路径，不能继承组合接管的 HTTP 代理。
            config.connectionProxyDictionary=[:]
        }
        return config
    }
    public static func test(port:Int) async -> Bool {(await detailed(port:port)).contains("正常")}
    public static func detailed(port:Int?,protocolClasses:[AnyClass]?=nil) async -> String {
        let result=await https(port:port,entry:false,protocolClasses:protocolClasses)
        return result.status == .passed ? "按当前规则的 HTTPS 连通性正常":result.summary
    }
    public static func https(port:Int?,entry:Bool,protocolClasses:[AnyClass]?=nil) async -> ConnectivityResult {
        let title=entry ? "本地代理入口检测":"按当前规则的 HTTPS 检测"
        if entry && port==nil{return ConnectivityResult(title,.notApplicable,"TUN 模式")}
        let config=configuration(port:port,protocolClasses:protocolClasses)
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel()};let start=Date()
        do {
            let (data,response)=try await session.data(from:URL(string:entry ? "https://www.gstatic.com/generate_204":ConfigBuilder.testURL)!)
            guard let http=response as? HTTPURLResponse else{return ConnectivityResult(title,.failed,"响应格式")}
            let expected=entry ? http.statusCode==204:http.statusCode==200 && String(decoding:data,as:UTF8.self).contains("Success")
            guard expected else{return ConnectivityResult(title,.failed,http.statusCode==401 || http.statusCode==407 ? "鉴权":"HTTP 响应")}
            return ConnectivityResult(title,.passed,"TLS 与 HTTP 已校验",milliseconds:Int(Date().timeIntervalSince(start)*1000))
        }catch{return ConnectivityResult(title,.failed,ConnectivityResult.category(error))}
    }
    public static func node(client:CoreAPIClient,mode:ProxyMode) async -> ConnectivityResult {
        // 日常、启动与唤醒共用分类，超时不能升级为已确认的节点失效。
        await wakeNode(client:client,mode:mode)
    }
    public static func wakeNode(client:CoreAPIClient,mode:ProxyMode) async -> ConnectivityResult {
        let title="当前节点通道检测"
        if mode == .direct {return ConnectivityResult(title,.notApplicable,"全部直连模式")}
        do {
            let info=try await client.preparedProxies()
            guard let tag=CoreAPIClient.actualTag(info) else{return ConnectivityResult(title,.failed,"控制接口缺少实际节点")}
            if tag=="direct" || tag=="reject" {return ConnectivityResult(title,.notApplicable,"当前策略未选择节点")}
            guard tag.hasPrefix("node-"),let id=UUID(uuidString:String(tag.dropFirst(5))) else{return ConnectivityResult(title,.failed,"控制接口节点格式")}
            switch await client.measureNode(id) {
            case .success(let ms):return ConnectivityResult(title,.passed,"实际节点 HTTPS",milliseconds:ms)
            case .failure(let errors):
                if errors.contains("鉴权") {return ConnectivityResult(title,.failed,"鉴权")}
                // 任一目标超时都不升级为节点失效；两个明确的节点错误才计入连续失败。
                if errors.count==2 && errors.allSatisfy({$0=="节点通道"}) {return ConnectivityResult(title,.failed,"节点通道")}
                return ConnectivityResult(title,.failed,errors.contains("超时") ? "超时":"无法确定")
            }
        }catch{
            let category=ConnectivityResult.category(error)
            return ConnectivityResult(title,.failed,category)
        }
    }
    public static func all(port:Int?,client:CoreAPIClient,mode:ProxyMode,protocolClasses:[AnyClass]?=nil) async -> [ConnectivityResult] {
        async let rules=https(port:port,entry:false,protocolClasses:protocolClasses)
        async let node=node(client:client,mode:mode)
        async let entry=https(port:port,entry:true,protocolClasses:protocolClasses)
        return await [rules,node,entry]
    }
}

public enum ConnectivityHealth:String,Sendable {
    case checking="检测中",healthy="正常",unhealthy="异常",unknown="无法确定"
    public static func evaluate(_ results:[ConnectivityResult])->Self {
        if results.contains(where:{$0.status == .failed}) {return .unhealthy}
        if results.contains(where:{$0.status == .pending}) {return .checking}
        if results.contains(where:{$0.status == .passed}) && results.allSatisfy({$0.status == .passed || $0.status == .notApplicable}) {return .healthy}
        return .unknown
    }
}

// 网站探测只提示连通性；本地监听、核心、路由、DNS 和网络所有权由启动流程单独强制核验。
public enum StartupConnectivityPolicy {
    public static func allows(_ results:[ConnectivityResult],mode:ProxyMode)->Bool {
        guard results.count==3,results.allSatisfy({$0.status != .pending}) else{return false}
        // 明确鉴权错误和取消仍终止启动；外部网站、代理请求及测速超时不能撤销已核验的接管。
        return !results.contains(where:{$0.status == .failed && ["鉴权","取消"].contains($0.category)})
    }
    public static func recovery(_ results:[ConnectivityResult])->WakeRecoveryCheck {
        // 实际节点已可用时，测试网站局部异常不触发重建，也不改写检测结果。
        if results.count==2,results[0].status != .pending,results[1].status == .passed,
           !results.contains(where:{$0.status == .failed && ["鉴权","代理入口","取消"].contains($0.category)}) {return .healthy}
        return .connectivity(results)
    }
}
