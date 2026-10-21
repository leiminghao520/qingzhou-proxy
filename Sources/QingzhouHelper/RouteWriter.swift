import Foundation
import QingzhouKit

extension Service {
    // 路由查询可能命中同目标的接口缓存项；完整表中按作用域核对真实静态路由。
    func verifiedRoute(_ expected:ProtectedRoute,info:String) throws -> Bool {
        if CaptureOwnership.matchesQuery(expected,info:info) {return true}
        let actual=try routeSample().ownershipRoutes
        return CaptureOwnership.recoveryState(expected:expected,actual:actual) == .owned
    }
    func addRoute(_ destination:String,_ gateway:String,_ interface:String,ipv6:Bool,scope:String?=nil,deadline:Date?=nil,preparationBypass:Bool=false) throws {
        if let info=try? routeInfo(destination,ipv6:ipv6,scope:scope,deadline:deadline),let current=prefix(info),NetworkInspection.samePrefix(current,destination),NetworkInspection.routeScopeMatches(scope,flags:field("flags",info),interface:field("interface",info)){
            guard CaptureOwnership.matchesQuery(ProtectedRoute(destination:destination,gateway:gateway,interface:interface,scope:scope),info:info) else {
                let message="路由前缀 \(destination) 已被 \(field("interface",info) ?? "未知接口")/\(field("gateway",info) ?? "未知网关") 占用，未替换现有路由"
                // 仅绕过计划允许回滚后重新采样；默认接管和动态保护冲突仍立即停止。
                if preparationBypass {throw NetworkEnvironmentNotReady(message+"；准备期间原路径变化，需要重新采样")}
                throw ProxyError(message)
            };return
        }
        let expected=ProtectedRoute(destination:destination,gateway:gateway,interface:interface,scope:scope)
        let beforeSample=try routeSample()
        let before=beforeSample.ownershipRoutes
        let previous=CaptureOwnership.recoveryState(expected:expected,actual:before)
        // 查询可能命中缓存，写入前仍须防止认领完整表中已存在的外部路由。
        if previous == .owned {return}
        if previous == .replaced || previous == .ambiguous {throw ProxyError("路由前缀已有其他出口，未写入或认领："+destination)}
        if CaptureOwnership.legacyHostRouteInTable(expected,table:beforeSample.table) {
            throw ProxyError("检测到旧版遗留的异常 IPv6 主机路由："+destination+"；未修改该项，需要先核对旧恢复记录并处理残留")
        }
        let args=NetworkInspection.routeArguments(.add,destination:destination,gateway:gateway,ipv6:ipv6,scope:scope,interface:interface)
        let route=OwnedRoute(destination:destination,gateway:gateway,interface:interface,ipv6:ipv6,scope:scope)
        // 先记录意图再写路由；崩溃恢复仍通过当前网关和接口确认所有权。
        journal!.routes.append(route);try save()
        // 命令超时也可能已经写入路由，保留意图以便按所有权恢复。
        let output=try writeRoute(args,deadline:deadline)
        guard !CaptureOwnership.routeWriteFailed(output) else {
            // 命令明确拒绝写入时不认领原有路由；超时等未知结果仍保留意图。
            journal!.routes.removeLast();try save()
            throw ProxyError("路由命令拒绝写入："+destination+"；"+String(output.prefix(512)))
        }
        let current=try routeInfo(destination,ipv6:ipv6,scope:scope,deadline:deadline)
        guard try verifiedRoute(expected,info:current) else {
            throw ProxyError("路由写入核验失败："+destination+"；期望="+interface+"/"+gateway+"/scope="+(scope ?? "global")+"；实际作用域="+(NetworkInspection.routeField("flags",current) ?? "未知")+"；实际前缀="+(prefix(current) ?? "未知")+"，接口="+(field("interface",current) ?? "未知")+"，网关="+(field("gateway",current) ?? "未知"))
        }
        // 仅保存经过完整身份核验的网关，失败时保留原始意图供所有权恢复。
        journal!.routes[journal!.routes.count-1].gateway=gateway
        try save()
    }
}
