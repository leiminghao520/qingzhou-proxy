import Foundation
import QingzhouKit

// 只读取当前路由，不启动或停止核心，不写路由、DNS、代理或日常配置。
@main struct ProtectionReadOnlyBenchmark {
    static func main() throws {
        for run in 1...3 {
            let baseline=try NetworkRouteSample()
            let expected=NetworkSnapshot.parseRoutes(baseline.table).filter{$0.scope==nil}.prefix(48)
            var legacyResults:[Bool]=[],queryCount=0,fallbackCount=0
            let oldStart=DispatchTime.now().uptimeNanoseconds
            for route in expected {
                let info=try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.get,destination:route.destination,ipv6:route.ipv6,scope:route.scope));queryCount+=1
                if CaptureOwnership.matchesQuery(route,info:info) {legacyResults.append(true)}
                else {fallbackCount+=1;legacyResults.append(CaptureOwnership.recoveryState(expected:route,actual:try NetworkRouteSample().ownershipRoutes) == .owned)}
            }
            let oldMs=Int((DispatchTime.now().uptimeNanoseconds-oldStart)/1_000_000)
            let newStart=DispatchTime.now().uptimeNanoseconds
            let current=RouteIdentityIndex(try NetworkRouteSample().ownershipRoutes)
            let indexedResults=expected.map{current.state($0) == .owned}
            let newMs=Int((DispatchTime.now().uptimeNanoseconds-newStart)/1_000_000)
            guard legacyResults==indexedResults else {throw ProxyError("采样间路径变化或核验结果不同，不能比较性能")}
            print("READ_ONLY_VERIFICATION run=\(run) routes=\(expected.count) baselineMs=\(oldMs) indexedMs=\(newMs) baselineQueries=\(queryCount) baselineTables=\(fallbackCount) indexedQueries=0 indexedTables=1 equivalent=true")
        }
    }
}
