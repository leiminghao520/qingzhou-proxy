import Foundation
import QingzhouKit

extension Service {
    func addRoute(_ destination:String,_ gateway:String,_ interface:String,ipv6:Bool,scope:String?=nil,deadline:Date?=nil,preparationBypass:Bool=false) throws {
        if let info=try? routeInfo(destination,ipv6:ipv6,scope:scope,deadline:deadline),let current=prefix(info),NetworkInspection.samePrefix(current,destination),NetworkInspection.routeScopeMatches(scope,flags:field("flags",info),interface:field("interface",info)){
            guard interface==field("interface",info) else {
                let message="路由前缀 \(destination) 已被 \(field("interface",info) ?? "未知接口") 占用，未替换现有路由"
                // 仅绕过计划允许回滚后重新采样；默认接管和动态保护冲突仍立即停止。
                if preparationBypass {throw NetworkEnvironmentNotReady(message+"；准备期间原路径变化，需要重新采样")}
                throw ProxyError(message)
            };return
        }
        let args=NetworkInspection.routeArguments(.add,destination:destination,gateway:gateway,ipv6:ipv6,scope:scope,interface:interface)
        let route=OwnedRoute(destination:destination,gateway:gateway,interface:interface,ipv6:ipv6,scope:scope)
        // 先记录意图再写路由；崩溃恢复仍通过当前网关和接口确认所有权。
        journal!.routes.append(route);try save()
        // 命令超时也可能已经写入路由，保留意图以便按所有权恢复。
        _=try writeRoute(args,deadline:deadline)
        if let current=try? routeInfo(destination,ipv6:ipv6,scope:scope,deadline:deadline),let actual=field("gateway",current) {journal!.routes[journal!.routes.count-1].gateway=actual};try save()
    }
}
