import Foundation
import Darwin
import QingzhouKit

// 仅在独立验收窗口显式运行；写入限定为回环作用域和文档保留地址。
@main struct NativeKernelChecks {
    static func main() throws {
        guard CommandLine.arguments.contains("--run-loopback") else {print("未执行内核写入；独立窗口使用 sudo 后附加 --run-loopback");return}
        guard geteuid()==0 else {throw ProxyError("回环内核夹具需要管理员权限")}
        let backend=NativeRouteBackend(),gateway="link#\(if_nametoindex("lo0"))"
        let routes=["192.0.2.254/32","2001:db8:717a::254/128"].map{ProtectedRoute(destination:$0,gateway:gateway,interface:"lo0",scope:"lo0")}
        let original=try backend.snapshot().ownershipRoutes
        for route in routes {guard RouteIdentityIndex(original).state(route) == .absent else {throw ProxyError("测试地址已有路由，拒绝覆盖")}}
        var intents:[ProtectedRoute]=[]
        defer {
            for route in intents.reversed() {
                do {
                    if try RouteIdentityIndex(backend.snapshot().ownershipRoutes).state(route) == .owned {
                        guard try backend.write(.delete,route:route) == .applied else {throw ProxyError("回环清理被内核拒绝")}
                    }
                } catch {FileHandle.standardError.write(Data("回环夹具恢复失败：\(route.destination)：\(error)\n".utf8))}
            }
        }
        for route in routes {
            intents.append(route)
            guard try backend.write(.add,route:route,deadline:Date().addingTimeInterval(2)) == .applied else {throw ProxyError("原生回环路由写入被拒绝")}
            let found=try backend.lookup(String(route.destination.split(separator:"/")[0]),ipv6:route.ipv6,scope:"lo0",deadline:Date().addingTimeInterval(2))
            guard CaptureOwnership.matchesQuery(route,info:found.queryText),try RouteIdentityIndex(backend.snapshot().ownershipRoutes).state(route) == .owned else {throw ProxyError("原生回环路由身份核验失败")}
            guard try backend.write(.delete,route:route,deadline:Date().addingTimeInterval(2)) == .applied,try RouteIdentityIndex(backend.snapshot().ownershipRoutes).state(route) == .absent else {throw ProxyError("原生回环路由删除核验失败")}
            intents.removeAll{$0==route}
        }
        print("NATIVE_KERNEL_LOOPBACK_OK routes=2")
    }
}
