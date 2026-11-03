import Foundation
import QingzhouKit

// 只读对照只测路由采样与查询，不能替代完整连接或企业业务验收。
@main struct NativeBenchmark {
    static func main() throws {
        let native=NativeRouteBackend(),legacy=LegacyRouteBackend()
        var nativeSamples:[Double]=[],legacySamples:[Double]=[]
        for run in 1...10 {
            let oldStart=ProcessInfo.processInfo.systemUptime
            let old=try legacy.snapshot()
            let oldDefault=try legacy.lookup("default",ipv6:false,scope:nil,deadline:nil)
            let oldMs=(ProcessInfo.processInfo.systemUptime-oldStart)*1000
            let start=ProcessInfo.processInfo.systemUptime
            let current=try native.snapshot()
            let currentDefault=try native.lookup("default",ipv6:false)
            let elapsed=(ProcessInfo.processInfo.systemUptime-start)*1000
            let stable=old.planningRoutes.filter{!$0.destination.hasSuffix("/32") && !$0.destination.hasSuffix("/128")}
            let index=RouteIdentityIndex(current.planningRoutes)
            guard stable.allSatisfy({index.contains($0)}),oldDefault.route.destination==currentDefault.route.destination,oldDefault.route.interface==currentDefault.route.interface,oldDefault.route.gateway==currentDefault.route.gateway else {throw ProxyError("路由表或默认出口变化，取消本轮性能比较")}
            nativeSamples.append(elapsed);legacySamples.append(oldMs)
            print("READONLY run=\(run) legacyMs=\(Int(oldMs)) nativeMs=\(Int(elapsed)) legacyCommands=2 nativeCommands=0 samples=1 queries=1 stableCompared=\(stable.count) equivalent=true")
        }
        for (name,values) in [("legacy",legacySamples),("native",nativeSamples)] {
            let sorted=values.sorted()
            print("READONLY_SUMMARY backend=\(name) n=10 medianMs=\((sorted[4]+sorted[5])/2) p95Ms=\(sorted[9])")
        }
    }
}
