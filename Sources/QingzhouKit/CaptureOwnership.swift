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
        // 原路由和恢复删除仍严格按前缀核验，不能把可达性误当成路由所有权。
        return routeIssues(expected:required+preserved,actual:actual)
    }
    // 所有权检查使用完整路由视图；规划时忽略缓存，不能表示缓存路由不存在。
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
