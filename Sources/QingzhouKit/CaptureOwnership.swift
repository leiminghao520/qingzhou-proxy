import Foundation

public enum CaptureOwnership {
    public enum RecoveryRouteState:Equatable {case owned,absent,replaced,ambiguous}
    public static func recoveryState(expected:ProtectedRoute,actual:[ProtectedRoute])->RecoveryRouteState {
        let matches=actual.filter{NetworkInspection.samePrefix($0.destination,expected.destination) && $0.scope==expected.scope}
        guard !matches.isEmpty else{return .absent}
        let owned=matches.filter{$0.interface==expected.interface && $0.gateway==expected.gateway}
        guard !owned.isEmpty else{return .replaced}
        return matches.count==1 ? .owned:.ambiguous
    }
    // 动态企业主机路由可能被 VPN 回收；只接受最长匹配仍指向同一网关、接口和作用域。
    // 精确前缀已被外部改写、存在等长竞争或仅剩默认出口时仍视为失去保护。
    public static func hasEquivalentHostPath(_ expected:ProtectedRoute,actual:[ProtectedRoute])->Bool {
        let bits=expected.ipv6 ? 128:32
        guard CapturePlan.isVPN(expected.interface),Int(expected.destination.split(separator:"/").last ?? "0")==bits else{return false}
        let address=String(expected.destination.split(separator:"/")[0])
        let matches=actual.filter {route in
            route.scope==expected.scope && route.ipv6==expected.ipv6 && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:route.destination,action:.direct),host:address,ip:address)==true
        }
        guard let longest=matches.compactMap({Int($0.destination.split(separator:"/").last ?? "0")}).max(),longest>1 else{return false}
        return matches.filter{Int($0.destination.split(separator:"/").last ?? "0")==longest}.allSatisfy{$0.gateway==expected.gateway && $0.interface==expected.interface}
    }
    public static func protectionIssues(owned:[ProtectedRoute],preserved:[ProtectedRoute],actual:[ProtectedRoute])->[String] {
        let required=owned.filter{!hasEquivalentHostPath($0,actual:actual)}
        // 轻舟写入的路由和其他保留路径仍严格核验；系统组播接口的生命周期不代表公网保护失效。
        return routeIssues(expected:required+monitoredPreservedRoutes(preserved),actual:actual)
    }
    public static func monitoredPreservedRoutes(_ routes:[ProtectedRoute])->[ProtectedRoute] {
        routes.filter {route in
            // 仅排除系统维护的本机、链路组播及链路本地作用域基路由；不豁免全局或轻舟自有路由。
            let systemMulticast=route.scope==route.interface && ["ff01::/32","ff02::/32"].contains {NetworkInspection.samePrefix(route.destination,$0)}
            let systemLinkLocal=route.scope==route.interface && IPPrefix(route.destination).map{IPPrefix("fe80::/10")!.contains($0)}==true
            return !systemMulticast && !systemLinkLocal
        }
    }
    // 所有权检查使用完整路由视图；规划时忽略缓存，不能表示缓存路由不存在。
    // 仅供恢复记录中的旧版主机路由使用；非零目的地址却没有主机标志和有效掩码是旧写法的特征。
    public static func legacyHostRouteMatches(_ expected:ProtectedRoute,info:String)->Bool {
        guard expected.ipv6,expected.destination.hasSuffix("/128"),
              let destination=NetworkInspection.routeField("destination",info),destination != "default",destination != "::",
              NetworkInspection.samePrefix(destination.components(separatedBy:"%")[0]+"/128",expected.destination),
              let flags=NetworkInspection.routeField("flags",info),flags.contains("STATIC"),!flags.contains("HOST"),
              [nil,"::","default"].contains(NetworkInspection.routeField("mask",info)) else{return false}
        return NetworkInspection.routeGateway(info)==expected.gateway && NetworkInspection.routeField("interface",info)==expected.interface && NetworkInspection.routeScopeMatches(expected.scope,flags:flags,interface:expected.interface)
    }
    // 保留原始零前缀异常项进行单独识别，不能把它解析成有效的主机保护路由。
    public static func legacyHostRouteInTable(_ expected:ProtectedRoute,table:String)->Bool {
        guard expected.ipv6,expected.destination.hasSuffix("/128"),!expected.destination.hasPrefix("::/") else{return false}
        let rows=table.components(separatedBy:.newlines).map{$0.split(whereSeparator:{$0.isWhitespace}).map(String.init)}.filter {fields in
            guard fields.count>=4,fields[0].hasSuffix("/0"),NetworkInspection.samePrefix(String(fields[0].dropLast(2))+"/128",expected.destination) else{return false}
            return (fields[2].contains("I") ? fields[3]:nil)==expected.scope
        }
        guard rows.count==1,let row=rows.first else{return false}
        return row[1]==expected.gateway && row[3]==expected.interface && row[2].contains("U") && row[2].contains("S") && !row[2].contains("H") && !row[2].contains("W") && !row[2].contains("L")
    }
    public static func legacyHostDeletionArguments(_ expected:ProtectedRoute)->[String] {
        var args=["-n","delete","-inet6"]
        if let scope=expected.scope {args += ["-ifscope",scope]}
        args += ["-net",expected.destination]
        return args+(expected.gateway.hasPrefix("link#") ? ["-interface",expected.interface]:[expected.gateway])
    }
    // macOS 路由命令可能在套接字写入失败时仍返回零，不能只依赖进程退出码。
    public static func routeWriteFailed(_ output:String)->Bool {
        output.contains("writing to routing socket:") || output.contains(": File exists") || output.contains(": not in table")
    }
    // 查询结果只有前缀、网关、接口和作用域全部一致时，才能确认同一条路由。
    public static func matchesQuery(_ expected:ProtectedRoute,info:String)->Bool {
        guard let current=NetworkInspection.routePrefix(destination:NetworkInspection.routeField("destination",info),mask:NetworkInspection.routeField("mask",info),host:NetworkInspection.routeField("flags",info)?.contains("HOST")==true),
              NetworkInspection.samePrefix(current,expected.destination) else{return false}
        return NetworkInspection.routeGateway(info)==expected.gateway && NetworkInspection.routeField("interface",info)==expected.interface && NetworkInspection.routeScopeMatches(expected.scope,flags:NetworkInspection.routeField("flags",info),interface:NetworkInspection.routeField("interface",info))
    }
    public static func routeIssues(expected:[ProtectedRoute],actual:[ProtectedRoute])->[String] {
        var issues:[String]=[]
        for route in expected {
            let candidates=actual.filter{NetworkInspection.samePrefix($0.destination,route.destination)}
            if candidates.contains(where:{$0.interface==route.interface && $0.gateway==route.gateway && $0.scope==route.scope}) {continue}
            let state=candidates.prefix(3).map{$0.interface+"/"+$0.gateway+"/scope="+($0.scope ?? "global")}.joined(separator:"；")
            issues.append("路由 "+route.destination+"：期望 "+route.interface+"/"+route.gateway+"/scope="+(route.scope ?? "global")+"，实际 "+(state.isEmpty ? "未发现同前缀项":state))
            if issues.count>=8 {break}
        }
        return issues
    }
}
