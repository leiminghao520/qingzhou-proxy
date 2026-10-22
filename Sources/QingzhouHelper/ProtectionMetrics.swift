import Foundation
import Darwin
import QingzhouKit

extension Service {
    func measured<T>(_ name:String,_ body:() throws -> T) rethrows -> T {
        guard let routeMetrics else {return try body()}
        return try routeMetrics.measure(name,body)
    }
    func sampledRoutes() throws -> NetworkRouteSample {try routeSample()}
    // 客户端通道断开后不再开始下一条路由写入；上层按原事务恢复已写入部分。
    func checkRouteOwner() throws {
        guard let owner else {throw ProxyError("接管客户端已离开")}
        var item=pollfd(fd:owner,events:Int16(POLLIN),revents:0)
        let result=poll(&item,1,0)
        guard result>=0,item.revents & Int16(POLLHUP|POLLERR|POLLNVAL)==0 else {throw ProxyError("接管客户端通道已中断")}
    }
}
