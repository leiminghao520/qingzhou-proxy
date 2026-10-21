import Foundation
import QingzhouKit
import SystemConfiguration

extension Service {
    // 企业网络变化只能影响企业保护项；公网接管、补充 DNS 和代理入口仍单独核对。
    func essentialNetworkIssues(sample:NetworkRouteSample) throws -> [String] {
        guard let record=journal else{return ["恢复记录缺失"]}
        let expected=try PropertyListSerialization.propertyList(from:record.expectedDNS,format:nil) as? NSDictionary
        let current=networkDNSRead?(record.dnsKey) ?? (SCDynamicStoreCopyValue(dynamic,record.dnsKey as CFString) as? NSDictionary)
        var issues:[String]=[]
        if current != expected {issues.append("本次补充 DNS 服务与应用值不一致")}
        let takeover=record.routes.filter{$0.interface==record.interface || $0.destination.hasSuffix("/1")}.map{ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface,scope:$0.scope)}
        issues += CaptureOwnership.routeIssues(expected:takeover,actual:sample.ownershipRoutes)
        return issues
    }
    func reconciledNetworkIssues(_ fresh:CapturePlan,sample:NetworkRouteSample) throws -> [String] {
        guard let record=journal else{return ["恢复记录缺失"]}
        let corporate=fresh.protectedRoutes.filter{CapturePlan.isVPN($0.interface)}
        let optional=record.routes.filter {route in
            guard route.interface != record.interface,!route.destination.hasSuffix("/1") else{return false}
            if CapturePlan.isVPN(route.interface) {return true}
            let address=String(route.destination.split(separator:"/")[0])
            return corporate.contains{RuleEvaluator.matches(RoutingRule(kind:.cidr,value:$0.destination,action:.direct),host:address,ip:address)==true}
        }
        return try ownedNetworkIssues(sample:sample,excluding:Set(optional.map(\.destination)))
    }
    func suspendCorporateQueries() {
        if !protectedQueriesSuspended {dnsForwarder?.suspendProtectedQueries()}
        protectedQueriesSuspended=true
    }
    func stageCorporateQueries(_ fresh:CapturePlan) throws {
        // 新企业域名一经发现立即加入拒绝解析范围，不能在等待路由时走普通公网解析。
        suspendCorporateQueries()
        var guarded=fresh
        guarded.domains=Array(knownProtectedDomains.union(fresh.domains)).sorted()
        dnsForwarder?.updatePlan(guarded,suspended:true)
        try dynamicRules?.stageDomains(guarded.domains)
    }
    func applyCorporatePlan(_ fresh:CapturePlan,sample:NetworkRouteSample) throws -> Bool {
        guard let old=capturePlan,let rules=dynamicRules,let request=activeRequest,let state=request.state,let record=journal else{return false}
        guard old.snapshot.primaryInterface==fresh.snapshot.primaryInterface,rules.supports(fresh) else{return false}
        let oldDefaults=old.snapshot.routes.filter{$0.interface==old.snapshot.primaryInterface && $0.destination.hasSuffix("/0")}
        let newDefaults=fresh.snapshot.routes.filter{$0.interface==fresh.snapshot.primaryInterface && $0.destination.hasSuffix("/0")}
        guard oldDefaults==newDefaults else{return false}
        let nodeInterfaces=try fresh.nodeInterfaces(captureNodeAddresses,family:state.effectiveAddressFamilyPolicy)
        guard nodeInterfaces==captureNodeInterfaces else{return false}
        // 先撤回仍由轻舟拥有的旧出口，随后应用新路径；不删除企业 VPN 自有路由。
        let expected=record.routes.filter {owned in
            guard owned.interface != record.interface,!owned.destination.hasSuffix("/1") else{return false}
            let address=String(owned.destination.split(separator:"/")[0])
            let migrated=fresh.protectedRoutes.contains {route in
                CapturePlan.isVPN(route.interface) && route.interface != owned.interface && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:route.destination,action:.direct),host:address,ip:address)==true
            }
            guard CapturePlan.isVPN(owned.interface) || migrated else{return false}
            return !fresh.protectedRoutes.contains {route in
                NetworkInspection.samePrefix(route.destination,owned.destination) && route.interface==owned.interface && route.gateway==owned.gateway
            }
        }
        for route in expected {
            let target=ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope)
            let current=try routeSample().ownershipRoutes
            switch CaptureOwnership.recoveryState(expected:target,actual:current) {
            case .owned:
                let output=try writeRoute(NetworkInspection.routeArguments(.delete,destination:route.destination,gateway:route.gateway,ipv6:route.ipv6,scope:route.scope,interface:route.interface),deadline:Date().addingTimeInterval(1))
                guard !CaptureOwnership.routeWriteFailed(output) else {throw NetworkEnvironmentNotReady("企业保护项撤回尚未完成")}
            case .ambiguous:throw ProxyError("企业保护路由存在竞争出口，未删除")
            case .absent,.replaced:break
            }
            journal?.routes.removeAll{$0.destination==route.destination && $0.gateway==route.gateway && $0.interface==route.interface && $0.scope==route.scope}
        }
        for route in fresh.protectedRoutes {try protect(route)}
        let installed=try routeSample().ownershipRoutes
        let required=fresh.protectedRoutes.map{ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface)}
        let problems=CaptureOwnership.protectionIssues(owned:required,preserved:[],actual:installed)
        guard problems.isEmpty else {throw NetworkEnvironmentNotReady("企业路径仍在变化："+problems.joined(separator:"；"))}
        journal?.preservedRoutes=(record.preservedRoutes ?? []).filter {sample.ownershipRoutes.contains($0)}
        try save()
        try rules.update(fresh)
        capturePlan=fresh
        protectedQueriesSuspended=false
        dnsForwarder?.updatePlan(fresh)
        domainRouteSummary=[]
        lastFailure=nil
        return true
    }
}
