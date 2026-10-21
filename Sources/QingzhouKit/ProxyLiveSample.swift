import Foundation

// 提交后的服务配置与异步发布的汇总状态分开核验，不能把尚未发布当作外部接管。
public struct ProxyLiveSample {
    public let expected:[String:Any]
    public let current:[String:Any]?
    public init(expected:[String:Any],current:[String:Any]?) {self.expected=expected;self.current=current}
    public var issues:[String] {
        guard let current else{return ["系统汇总代理状态尚未发布"]}
        var issues:[String]=[]
        for prefix in ["HTTP","HTTPS","SOCKS"] {
            let expectedEnabled=(expected[prefix+"Enable"] as? NSNumber)?.boolValue==true
            let currentEnabled=(current[prefix+"Enable"] as? NSNumber)?.boolValue==true
            if currentEnabled != expectedEnabled {issues.append(prefix+"Enable：期望="+String(expectedEnabled)+"，实际="+String(currentEnabled));continue}
            guard expectedEnabled else {continue}
            let expectedHost=expected[prefix+"Proxy"] as? String ?? "缺失"
            let currentHost=current[prefix+"Proxy"] as? String ?? "缺失"
            let loopback=["127.0.0.1","localhost","::1"]
            if expectedHost != currentHost && !(loopback.contains(expectedHost) && loopback.contains(currentHost)) {issues.append(prefix+"Proxy：期望="+expectedHost+"，实际="+currentHost)}
            let expectedPort=expected[prefix+"Port"] as? NSNumber
            let actualPort=current[prefix+"Port"] as? NSNumber
            if expectedPort != actualPort {issues.append(prefix+"Port：期望="+(expectedPort?.stringValue ?? "缺失")+"，实际="+(actualPort?.stringValue ?? "缺失"))}
        }
        for key in ["ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable"] {
            if (current[key] as? NSNumber)?.boolValue==true {issues.append(key+" 已被启用")}
        }
        return issues
    }
}
