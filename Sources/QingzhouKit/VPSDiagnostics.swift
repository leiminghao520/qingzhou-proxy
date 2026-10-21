import Foundation

public enum VPSDiagnostics {
    // 管理通道和转发通道分别给出证据；服务在线不能证明节点认证或转发成功。
    public static func summarize(local:[DiagnosticResult],server:VPSValue)->[DiagnosticResult] {
        var result:[DiagnosticResult]=[]
        let failures=local.filter{$0.status=="失败"}
        if !failures.isEmpty {result.append(DiagnosticResult("本机检查","失败",failures.map(\.stage).joined(separator:"、")+" 检查未通过，请先处理对应项目"))}
        guard server["state"].string=="fresh" else {
            result.append(DiagnosticResult("服务端证据","未验证","管理通道不可达、未配置或数据过期；不能据此判定代理故障"));return result
        }
        for (key,label) in [("hysteria","代理服务"),("auth","认证服务"),("nginx","管理入口")] {
            let state=server["data"][key].string
            let failed=["inactive","failed","activating","deactivating"].contains(state ?? "")
            result.append(DiagnosticResult(label,state=="active" ? "通过":failed ? "失败":"未验证",state=="active" ? "进程在线；实际认证与转发仍以客户端检测为准":failed ? "服务端采集到进程状态："+(state ?? "未知"):"尚无有效进程状态"))
        }
        return result
    }
    public static func confirmsPath(_ connections:[CoreConnection],host:String,nodeTag:String,since:Date)->Bool {
        let plain=ISO8601DateFormatter(),fractional=ISO8601DateFormatter();fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return connections.contains { row in
            guard row.metadata.host?.lowercased()==host.lowercased(),row.chains.contains(nodeTag),
                  let start=fractional.date(from:row.start) ?? plain.date(from:row.start),start>=since else{return false}
            return row.download>0 || row.upload>0
        }
    }
}
