import Foundation
import Darwin
import QingzhouKit

// 模拟传输故意拒绝所有交换；整批预检不得触发它。
final class NoExchangeTransport:RouteTransport {
    var exchanges=0
    func dump() throws -> Data {throw ProxyError("夹具禁止读取内核路由")}
    func exchange(_ request:Data,timeout:TimeInterval,cancelled:()->Bool) throws -> RouteExchangeResult {exchanges+=1;throw ProxyError("夹具禁止交换报文")}
}
@main struct CaptureCodecChecks {
    static var assertions=0
    static func check(_ value:Bool,_ message:String){assertions+=1;if !value{fatalError(message)}}
    static func main() throws {
        let default4=ProtectedRoute(destination:"0.0.0.0/0",gateway:"127.0.0.1",interface:"lo0")
        let default6=ProtectedRoute(destination:"::/0",gateway:"::1",interface:"lo0")
        let localA=ProtectedRoute(destination:"fe80::/64",gateway:"link#1",interface:"en0",scope:"en0")
        let localB=ProtectedRoute(destination:"fe80::/64",gateway:"link#2",interface:"en6",scope:"en6")
        let multicast=ProtectedRoute(destination:"ff02::/32",gateway:"link#1",interface:"en0",scope:"en0")
        let sample=NetworkRouteSample(routes:[default4,default6,localA,localB,multicast])
        let snapshot=NetworkSnapshot(primaryInterface:"lo0",routes:sample.planningRoutes,resolvers:[DNSResolverScope(service:"fixture",interface:"lo0",servers:["192.0.2.53"],defaultResolver:true)])
        let plan=try CapturePlan.make(snapshot:snapshot,extraCIDRs:[],extraDomains:[])
        let bypass=try BypassRoutePlan.capture(destinations:["fe80::/10","ff02::/32"],existingPrefixes:sample.planningRoutes.map(\.destination),hasIPv6:true,existingRoutes:sample.planningRoutes,lookup:{_,_ in throw ProxyError("夹具禁止默认出口猜测")})
        let capture=try CaptureRoutePlan.make(plan:plan,bypass:bypass,baseline:sample)
        check(bypass.preservedRoutes.count==3,"精确保留两个链路接口和组播作用域")
        check(capture.captures("fe81::1"),"不能把已知 /64 扩成整个链路本地绕过")
        for route in bypass.preservedRoutes {
            let prefix=IPPrefix(route.destination)!
            check(!capture.prefixes.compactMap(IPPrefix.init).contains{prefix.contains($0) && $0.bits>=prefix.bits},"已确认作用域路径比捕获更具体")
        }
        let transport=NoExchangeTransport(),backend=NativeRouteBackend(transport:NoExchangeTransport())
        let validator=NativeRouteBackend(transport:transport)
        let routes=capture.prefixes.map{ProtectedRoute(destination:$0,gateway:$0.contains(":") ? "fd71:717a::1":"100.64.1.1",interface:"lo0")}
        try validator.validateWrites(routes)
        check(transport.exchanges==0,"所有捕获编码通过，路由交换为零")
        let valid=ProtectedRoute(destination:"192.0.2.0/24",gateway:"127.0.0.1",interface:"lo0")
        let invalid=ProtectedRoute(destination:"fe80:0:0:1::/64",gateway:"fd71:717a:259::1",interface:"lo0")
        do {try validator.validateWrites([valid,invalid]);check(false,"坏项必须使整批预检失败")}
        catch {check(error.localizedDescription.contains("第 2 项") && error.localizedDescription.contains("未发送"),"明确报本地失败项序号")}
        check(transport.exchanges==0,"第二项失败时第一项也不能写入")
        var badScope=valid;badScope.scope="en0"
        do {try validator.validateWrites([badScope]);check(false,"错配作用域拒绝")}catch{check(true,"错配作用域拒绝")}
        backend.cancelled={true}
        do {try backend.validateWrites([valid]);check(false,"预检取消立即生效")}catch{check(error is CancellationError,"预检取消立即生效")}
        let impossible=try BypassRoutePlan.capture(destinations:["fe00::/9"],existingPrefixes:[],hasIPv6:true,existingRoutes:sample.planningRoutes,lookup:{_,_ in RouteRecord(route:default6,flags:3).queryText})
        do {_=try CaptureRoutePlan.make(plan:plan,bypass:impossible,baseline:sample);check(false,"无法表达的显式组合不能部分写入")}
        catch {check(error.localizedDescription.contains("无作用域链路本地"),"无法表达的组合在纯规划阶段拒绝")}
        let multicastImpossible=try BypassRoutePlan.capture(destinations:["ff00::/16"],existingPrefixes:[],hasIPv6:true,existingRoutes:sample.planningRoutes,lookup:{_,_ in RouteRecord(route:default6,flags:3).queryText})
        do {_=try CaptureRoutePlan.make(plan:plan,bypass:multicastImpossible,baseline:sample);check(false,"本地组播碎片不能冒充全局捕获")}
        catch {check(error.localizedDescription.contains("本地组播"),"本地组播同样在规划阶段拒绝")}
        let missing=NetworkRouteSample(routes:[default4,default6,localA,multicast])
        do {_=try CaptureRoutePlan.make(plan:plan,bypass:bypass,baseline:missing);check(false,"不能借用另一接口补足缺失作用域")}catch{check(true,"缺少原接口时拒绝")}
        print("CAPTURE_CODEC_CHECKS_OK assertions=\(assertions) prefixes=\(capture.prefixes.count) routeExchanges=\(transport.exchanges) kernelCalls=0")
    }
}
