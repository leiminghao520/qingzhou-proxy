import Foundation
import Darwin
import QingzhouKit

// 显式采样入口只读取内核整表；回放只读文件，所有变更都发生在内存夹具。
@main struct WakeRouteSnapshot {
    static func main() throws {
        guard CommandLine.arguments.count==3 else {throw ProxyError("用法：--capture-current 或 --replay 加文件路径")}
        let file=URL(fileURLWithPath:CommandLine.arguments[2]),raw:Data
        if CommandLine.arguments[1]=="--capture-current" {
            raw=try DarwinRouteTransport().dump();try SecureFile.write(raw,to:file)
        } else if CommandLine.arguments[1]=="--replay" {raw=try Data(contentsOf:file)}
        else {throw ProxyError("仅支持显式只读采样或离线回放")}
        let records=try NativeRouteBackend.decode(raw),target="239.255.255.250/32"
        let realParent=records.first{$0.route.destination==target && $0.flags & UInt32(RTF_MULTICAST|RTF_CLONING)==UInt32(RTF_MULTICAST|RTF_CLONING) && !$0.isTransient}
        let parent=realParent ?? RouteRecord(route:ProtectedRoute(destination:target,gateway:"link#11",interface:"en0"),flags:UInt32(RTF_UP|RTF_MULTICAST|RTF_CLONING))
        let realCache=records.first{$0.route.destination==target && $0.route.interface==parent.route.interface && $0.linkLayerAddress=="1:0:5e:7f:ff:fa" && $0.isTransient}
        let cache=realCache ?? RouteRecord(route:parent.route,flags:UInt32(RTF_UP|RTF_HOST|RTF_LLINFO|RTF_MULTICAST|RTF_STATIC),linkLayerAddress:"1:0:5e:7f:ff:fa")
        let baseline=records.filter{$0.route.destination != target}
        let coexist=NetworkRouteSample(records:baseline+[parent,cache])
        guard coexist.identityIndex.state(parent.route) == .owned else {throw ProxyError("完整整表中的父项与缓存不能正确分类")}
        var competitor=parent;competitor.route.interface="utun250";competitor.route.gateway="link#250"
        guard NetworkRouteSample(records:baseline+[parent,cache,competitor]).identityIndex.state(parent.route) == .ambiguous else {throw ProxyError("完整整表中的其他接口竞争被错误忽略")}
        var staticHost=cache;staticHost.flags=UInt32(RTF_UP|RTF_HOST|RTF_STATIC)
        guard NetworkRouteSample(records:baseline+[parent,staticHost]).identityIndex.state(parent.route) == .ambiguous else {throw ProxyError("独立静态主机项被错误当作缓存")}
        let broadParent=baseline.contains{$0.route.destination=="224.0.0.0/4" && $0.route.interface==parent.route.interface && $0.route.scope==parent.route.scope && $0.route.gateway==parent.route.gateway && $0.flags & UInt32(RTF_MULTICAST|RTF_CLONING)==UInt32(RTF_MULTICAST|RTF_CLONING)}
        if broadParent {
            guard NetworkRouteSample(records:baseline+[cache]).identityIndex.state(parent.route) == .replaced else {throw ProxyError("当前组播父网段不能证明残留缓存来源")}
        }
        print("WAKE_ROUTE_FULL_SNAPSHOT_OK records=\(records.count) observedParent=\(realParent != nil) observedCache=\(realCache != nil) replayChecks=\(broadParent ? 4:3) routeWrites=0")
    }
}
