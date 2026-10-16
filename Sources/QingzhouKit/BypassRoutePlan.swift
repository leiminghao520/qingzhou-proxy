import Foundation

public struct BypassRoutePlan:Sendable {
    public let routes:[ProtectedRoute]
    public let preservedRoutes:[ProtectedRoute]
    // 所有原出口在启动核心和写保护路由前一次读取，不能被本次修改反过来影响。
    public static func capture(destinations:[String],existingPrefixes:[String],hasIPv6:Bool,existingRoutes:[ProtectedRoute]=[],lookup:(String,Bool) throws -> String) throws -> BypassRoutePlan {
        var routes:[ProtectedRoute]=[],preserved:[ProtectedRoute]=[]
        for destination in Set(destinations).sorted() {
            try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:destination,action:.direct))
            // 本机和链路组播由系统按接口选择出口；不能补写全局主机路由争夺作用域。
            let localMulticast=["ff01::/16","ff02::/16"].contains {range in
                let bits=Int(destination.split(separator:"/").last ?? "0") ?? 0
                return bits>=16 && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:range,action:.direct),host:String(destination.split(separator:"/")[0]),ip:String(destination.split(separator:"/")[0]))==true
            }
            if localMulticast {
                let address=String(destination.split(separator:"/")[0]),bits=Int(destination.split(separator:"/")[1])!
                let candidates=existingRoutes.filter {route in
                    route.scope==route.interface && (Int(route.destination.split(separator:"/").last ?? "129") ?? 129)<=bits && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:route.destination,action:.direct),host:address,ip:address)==true
                }
                guard !candidates.isEmpty else {throw ProxyError("本地组播绕过项 "+destination+" 缺少原接口作用域路由，未接管网络")}
                for interface in Set(candidates.map(\.interface)).sorted() {
                    let route=candidates.filter{$0.interface==interface}.max{(Int($0.destination.split(separator:"/").last!) ?? 0)<(Int($1.destination.split(separator:"/").last!) ?? 0)}!
                    if !preserved.contains(route) {preserved.append(route)}
                }
                continue
            }
            if TunAddressPlan.containsRoute(destination,prefixes:existingPrefixes) {continue}
            let ipv6=destination.contains(":")
            if ipv6 && !hasIPv6 {continue}
            let target=String(destination.split(separator:"/")[0])
            do {
                let info=try lookup(target,ipv6)
                guard let gateway=NetworkInspection.routeGateway(info),let interface=NetworkInspection.routeField("interface",info) else {throw ProxyError("原路径不完整："+summary(info))}
                routes.append(ProtectedRoute(destination:destination,gateway:gateway,interface:interface,source:"接管前绕过路径"))
            }catch{throw ProxyError("绕过项 "+destination+" 快照失败："+error.localizedDescription)}
        }
        return BypassRoutePlan(routes:routes,preservedRoutes:preserved)
    }
    public func validate(lookup:(String,Bool) throws -> String) throws {
        for route in routes {
            let target=String(route.destination.split(separator:"/")[0])
            let info=try lookup(target,route.ipv6)
            guard NetworkInspection.routeGateway(info)==route.gateway,NetworkInspection.routeField("interface",info)==route.interface else {throw ProxyError("绕过项 "+route.destination+" 准备期间原路径变化：期望 "+route.interface+"/"+route.gateway+"；实际 "+Self.summary(info))}
        }
    }
    public func validatePreservedRoutes(_ actual:[ProtectedRoute]) throws {
        let issues=CaptureOwnership.routeIssues(expected:preservedRoutes,actual:actual)
        guard issues.isEmpty else {throw ProxyError("本地组播原路径变化："+issues.joined(separator:"；"))}
    }
    private static func summary(_ info:String)->String {
        let fields=["interface","gateway","flags"].map{$0+"="+(NetworkInspection.routeField($0,info) ?? "缺失")}.joined(separator:"，")
        return fields+"；查询输出："+Redactor.redact(String(info.prefix(512))).replacingOccurrences(of:"\n",with:" ")
    }
}
