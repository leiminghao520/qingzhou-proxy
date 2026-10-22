import Foundation
import Darwin
import QingzhouKit

extension Service {
    func configureRouteCancellation(_ fd:Int32) {
        if let backend=routeBackend as? NativeRouteBackend {backend.cancelled={ [weak self] in
            guard self != nil else{return true}
            var item=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            return poll(&item,1,0)<0 || item.revents & Int16(POLLHUP|POLLERR|POLLNVAL) != 0
        }}
    }

    // 正常写入的接口来自已落盘意图，不能在公网接管后重新按网关猜测出口。
    func routeInterfaceHint(_ arguments:[String])->String? {
        journal?.routes.reversed().first {route in
            (arguments.contains(route.destination) || arguments.contains(String(route.destination.split(separator:"/")[0]))) &&
            (arguments.contains(route.gateway) || arguments.contains(route.interface))
        }?.interface
    }
    func deleteOwnedRoute(_ route:ProtectedRoute) throws {
        let before=try routeSample().ownershipRoutes
        let state=CaptureOwnership.recoveryState(expected:route,actual:before)
        if state == .absent || state == .replaced {return}
        guard state == .owned else {throw ProxyError("删除前路由身份存在竞争，保留恢复记录")}

        let result=try routeAudit.operation(transaction:routeTransaction,stage:phase,kind:"delete",identity:route.destination+"|"+route.gateway+"|"+route.interface+"|"+(route.scope ?? "global"),result:{if case .applied=$0 {return "confirmed"};return "rejected"}) {try measured("routeWrite") {try routeBackend.write(.delete,route:route,legacy:false,deadline:nil)}}
        if case .rejected(let error)=result {throw RouteBackendError(error)}
        let remaining=CaptureOwnership.recoveryState(expected:route,actual:try routeSample().ownershipRoutes)
        guard remaining != .owned,remaining != .ambiguous else {throw ProxyError("删除后路由仍存在或存在竞争，保留恢复记录")}

    }
}
