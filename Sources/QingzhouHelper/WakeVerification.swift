import Foundation
import QingzhouKit

extension Service {
    func wakeNetworkReply(record:Journal,sample:NetworkRouteSample,proxySample:(issues:[String],verified:Bool)?=nil) throws -> TunReply {
        let prefixes=record.captureRoutes ?? CaptureRoutePlan.legacyPrefixes
        let owned=record.routes.map{ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface,scope:$0.scope)}
        let tunnels=owned.filter{$0.interface==record.interface && prefixes.contains($0.destination)}
        let tunnelVerified=tunnels.count==prefixes.count && tunnels.allSatisfy{sample.identityIndex.state($0) == .owned}
        // 保护的是未绑定接口的业务，按实际建立的全局保护项核验。
        let protected=capturePlan?.protectedRoutes.map{ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface)}
        // 原系统路径只核验仍有对应出口；不能把未由汐航写入的路径当成自有路由认领。
        let protectionVerified=protected.map {routes in routes.allSatisfy {expected in
            sample.ownershipRoutes.contains {actual in
                NetworkInspection.samePrefix(actual.destination,expected.destination) && actual.interface==expected.interface && actual.gateway==expected.gateway && actual.scope==nil
            } || CaptureOwnership.hasEquivalentHostPath(expected,actual:sample.ownershipRoutes)
        }} ?? false
        let routeStates=owned.map{CaptureOwnership.liveState($0,sample:sample)}
        var missingDNS=false,changedDNS=false,unreadableDNS=false
        for service in record.allDNSServices {
            do {
                let expected=try DNSServiceTransaction.decode(service.expected)
                if let current=try readDNSService(service.key) {if current != expected {changedDNS=true}}
                else {missingDNS=true}
            } catch {unreadableDNS=true}
        }
        let proxyRequired=activeRequest?.systemProxyPort != nil
        let proxyIssues=proxyRequired ? (proxySample?.issues ?? proxyConfigurationIssues()):[]
        let proxyVerified=proxyRequired ? proxyIssues.isEmpty && (proxySample?.verified ?? (proxyLiveSample()?.issues.isEmpty==true)):true
        let dnsVerified = !missingDNS && !changedDNS && !unreadableDNS
        var reply=TunReply(ok:true,message:networkStatus,coreDiagnostics:coreDiagnostics.recent,running:true,routesVerified:tunnelVerified,dnsVerified:dnsVerified,proxyVerified:proxyVerified,protectionVerified:protectionVerified,protectionSummary:networkSummary,phase:phase)
        var details:[String]=[]
        if routeStates.contains(.replaced) || routeStates.contains(.ambiguous) {details.append("路由被替换或存在同前缀竞争")}
        if changedDNS {details.append("DNS 服务值被修改")}
        details += proxyIssues
        // 只有已观测到外部改写才停止竞争；缺失、发布延迟和不可读不能证明外部接管。
        if !details.isEmpty {reply.wakeRecoveryReason = .ownershipConflict}
        else if unreadableDNS {reply.wakeRecoveryReason = .unverified;details.append("DNS 状态未验证")}
        else if missingDNS || routeStates.contains(.absent) || !tunnelVerified || !proxyVerified || (protected != nil && !protectionVerified) {
            reply.wakeRecoveryReason = .networkNotReady
            if missingDNS {details.append("DNS 服务暂缺")}
            if !tunnelVerified {details.append("接管路由未就绪：记录 \(tunnels.count)/\(prefixes.count) 项")}
            let missingOwned=zip(owned,routeStates).filter{$0.1 == .absent}.map{$0.0.destination+" → "+$0.0.interface}
            if !missingOwned.isEmpty {details.append("自有路由暂缺："+missingOwned.prefix(3).joined(separator:"，"))}
            if !protectionVerified {
                let missing=(protected ?? []).filter {expected in
                    !sample.ownershipRoutes.contains{NetworkInspection.samePrefix($0.destination,expected.destination) && $0.interface==expected.interface && $0.gateway==expected.gateway && $0.scope==nil} && !CaptureOwnership.hasEquivalentHostPath(expected,actual:sample.ownershipRoutes)
                }
                details.append("原系统保护路径暂缺："+missing.prefix(3).map{$0.destination+" → "+$0.interface}.joined(separator:"，"))
            }
            if !proxyVerified {details.append("服务配置仍属汐航，系统汇总代理尚未就绪")}
        }
        else if protected==nil {reply.wakeRecoveryReason = .unverified;details.append("保护快照未验证")}
        if !details.isEmpty {reply.message="唤醒网络核验："+details.prefix(8).joined(separator:"；")}
        return reply
    }
}
