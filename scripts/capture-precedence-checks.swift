import Foundation
import QingzhouKit
@main struct CapturePrecedenceChecks {
 static var assertions=0
 static func check(_ value:Bool,_ message:String) {assertions+=1;if !value {fatalError(message)}}
 static func make(_ routes:[ProtectedRoute],bypasses:[String]=[]) throws -> CaptureRoutePlan {
  let defaultRoute=ProtectedRoute(destination:"0.0.0.0/0",gateway:"192.0.2.1",interface:"en0")
  let default6=ProtectedRoute(destination:"::/0",gateway:"fe80::1%en0",interface:"en0")
  let sample=NetworkRouteSample(routes:[defaultRoute,default6]+routes)
  var plan=try CapturePlan.make(snapshot:NetworkSnapshot(primaryInterface:"en0",routes:sample.planningRoutes,resolvers:[DNSResolverScope(service:"fixture",interface:"en0",servers:["192.0.2.53"],defaultResolver:true)]),extraCIDRs:[],extraDomains:[])
  plan.protectedRoutes=routes
  let bypass=try BypassRoutePlan.capture(destinations:bypasses,existingPrefixes:[],hasIPv6:true,lookup:{address,_ in RouteRecord(route:try CaptureRoutePlan.systemPath(address,routes:sample.planningRoutes),flags:3).queryText})
  let capture=try CaptureRoutePlan.make(plan:plan,bypass:bypass,baseline:sample)
  // 捕获与更具体企业路由可相交，但不能存在同长或更长捕获项夺走企业出口。
  for route in routes {
   let prefix=IPPrefix(route.destination)!
   check(!capture.prefixes.compactMap(IPPrefix.init).contains{prefix.contains($0) && $0.bits>=prefix.bits},"捕获碎片不得覆盖企业出口")
  }
  for address in bypasses {check(capture.excludes(address),"明确系统绕过仍必须做差集")}
  return capture
 }
 static func main() throws {
  let scattered=(1...103).map{ProtectedRoute(destination:"\(20+$0).\(($0*17)%256).\(($0*43)%256).7/32",gateway:"10.251.1.1",interface:"utun6")}
  let prior=try CaptureRoutePlan(exclusions:scattered.map(\.destination))
  let compact=try make(scattered)
  check(prior.prefixes.count>1000 && compact.prefixes.count==4,"大量稀疏企业主机不得放大捕获表")
  let adjacent=ProtectedRoute(destination:"203.0.113.1/32",gateway:"10.251.1.1",interface:"utun6")
  check(try make([adjacent],bypasses:["203.0.113.0/32"]).excludes(adjacent.destination),"同长相邻碎片必须继续差集")
  let nested=ProtectedRoute(destination:"203.0.113.0/24",gateway:"10.251.1.1",interface:"utun6")
  check(try make([nested],bypasses:["203.0.113.1/32"]).excludes(nested.destination),"内嵌绕过不能制造更长捕获覆盖企业网段")
  let v6=ProtectedRoute(destination:"2001:db8::/64",gateway:"fe80::1%utun6",interface:"utun6")
  check(try make([v6],bypasses:["2001:db8::1/128"]).excludes(v6.destination),"IPv6 同样核对最长前缀优先级")
  var scoped=nested;scoped.scope=scoped.interface
  check(try make([scoped],bypasses:["203.0.113.1/32"]).excludes(scoped.destination),"作用域企业路径的全局保护也不能被捕获覆盖")
  // 检查相邻前缀新增排除后产生的后续碎片，避免只做一轮优先级判断。
  let chain=[1,2,4,8].map{ProtectedRoute(destination:"203.0.113.\($0)/32",gateway:"10.251.1.1",interface:"utun6")}
  _=try make(chain,bypasses:["203.0.113.0/32"])
  print("CAPTURE_PRECEDENCE_OK assertions=\(assertions) priorPrefixes=\(prior.prefixes.count) optimizedPrefixes=\(compact.prefixes.count) kernelCalls=0")
 }
}
