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
            if activeRequest?.state?.pinnedBypasses.contains(where:{NetworkInspection.samePrefix($0.value,route.destination)}) == true {return true}
            if plannedPathWithdrawn(route,fresh:fresh),CaptureOwnership.recoveryState(expected:ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope),actual:sample.ownershipRoutes) == .absent {return true}
            if CapturePlan.isVPN(route.interface) {return true}
            let address=String(route.destination.split(separator:"/")[0])
            return corporate.contains{RuleEvaluator.matches(RoutingRule(kind:.cidr,value:$0.destination,action:.direct),host:address,ip:address)==true}
        }
        return try ownedNetworkIssues(sample:sample,excluding:Set(optional.map(\.destination)))
    }
    // 只撤回旧计划明确管理的路径，不能把节点绕过项或异步域名主机项混入普通网卡更新。
    func plannedPathWithdrawn(_ owned:OwnedRoute,fresh:CapturePlan)->Bool {
        let previous=capturePlan?.protectedRoutes.contains{NetworkInspection.samePrefix($0.destination,owned.destination) && $0.interface==owned.interface && $0.gateway==owned.gateway} == true
        return previous && !fresh.protectedRoutes.contains{NetworkInspection.samePrefix($0.destination,owned.destination) && $0.interface==owned.interface && $0.gateway==owned.gateway}
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
        try dynamicRules?.stageDomains(guarded.domains,exact:guarded.exactDomains ?? [])
    }
    func applyCorporatePlan(_ fresh:CapturePlan,sample:NetworkRouteSample) throws -> Bool {
        guard let old=capturePlan,let rules=dynamicRules,let request=activeRequest,let state=request.state,let record=journal else{return false}
        guard old.snapshot.primaryInterface==fresh.snapshot.primaryInterface,rules.supports(fresh) else{return false}
        let oldDefaults=old.snapshot.routes.filter{$0.interface==old.snapshot.primaryInterface && $0.destination.hasSuffix("/0")}
        let newDefaults=fresh.snapshot.routes.filter{$0.interface==fresh.snapshot.primaryInterface && $0.destination.hasSuffix("/0")}
        guard oldDefaults==newDefaults else{return false}
        let nodeInterfaces=try fresh.nodeInterfaces(captureNodeAddresses,family:state.effectiveAddressFamilyPolicy)
        guard nodeInterfaces==captureNodeInterfaces else{return false}
        // 新保护和新捕获必须先建立；同前缀竞争出口无法无缝新增时保留旧保护并等待重规划。
        let expected=record.routes.filter {owned in
            guard owned.interface != record.interface,!owned.destination.hasSuffix("/1") else{return false}
            let address=String(owned.destination.split(separator:"/")[0])
            let migrated=fresh.protectedRoutes.contains {route in
                CapturePlan.isVPN(route.interface) && route.interface != owned.interface && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:route.destination,action:.direct),host:address,ip:address)==true
            }
            guard CapturePlan.isVPN(owned.interface) || migrated || plannedPathWithdrawn(owned,fresh:fresh) else{return false}
            return !fresh.protectedRoutes.contains {route in
                NetworkInspection.samePrefix(route.destination,owned.destination) && route.interface==owned.interface && route.gateway==owned.gateway
            }
        }
        let original=fresh.snapshot.routes
        let dns=fresh.snapshot.resolvers.flatMap(\.servers).map{$0.components(separatedBy:"%")[0]}
        let bootstrap=Set(dns+["1.1.1.1"]+captureNodeAddresses.values.flatMap{$0})
        let destinations=fresh.exclusions.filter{cidr in !state.pinnedBypasses.contains{NetworkInspection.samePrefix($0.value,cidr)}}+bootstrap.map{$0+($0.contains(":") ? "/128":"/32")}
        let bypass=try BypassRoutePlan.capture(destinations:destinations,existingPrefixes:original.map(\.destination),hasIPv6:original.contains{$0.destination=="::/0"},existingRoutes:original,lookup:{address,_ in
            let path=try CaptureRoutePlan.systemPath(address,routes:original)
            return RouteRecord(route:path,flags:3).queryText
        })
        let baseline=NetworkRouteSample(routes:original)
        let capture=try CaptureRoutePlan.make(plan:fresh,bypass:bypass,baseline:baseline)
        let retained=capture.fallbackReason==nil ? bypass.routes.filter{!capture.excludes($0.destination)}:bypass.routes
        let additions=fresh.protectedRoutes.filter{$0.scope != nil || $0.source=="用户网络绕过"}.map{ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface)}+retained
        let identity=RouteIdentityIndex(sample.ownershipRoutes)
        for route in additions where identity.state(route) == .replaced || identity.state(route) == .ambiguous {
            throw NetworkEnvironmentNotReady("保护前缀竞争出口，保留当前保护等待网络稳定："+route.destination)
        }
        if let backend=routeBackend as? NativeRouteBackend {
            let captures: [ProtectedRoute]
            if record.captureRoutes != nil,let tunnel=record.interface {
                captures=capture.prefixes.map{ProtectedRoute(destination:$0,gateway:$0.contains(":") ? String(record.address6.split(separator:"/")[0]):String(record.address4.split(separator:"/")[0]),interface:tunnel)}
            } else {captures=[]}
            try backend.validateWrites(additions+captures)
        }
        for route in additions {try addRoute(route.destination,route.gateway,route.interface,ipv6:route.ipv6)}
        // 旧记录缺少捕获列表时继续原捕获范围，升级不会猜测历史事务的排除项。
        if record.captureRoutes != nil,let tunnel=record.interface {
            for destination in capture.prefixes {
                try addRoute(destination,destination.contains(":") ? String(record.address6.split(separator:"/")[0]):String(record.address4.split(separator:"/")[0]),tunnel,ipv6:destination.contains(":"))
            }
        }
        let installed=try routeSample().ownershipRoutes
        var required=fresh.protectedRoutes.map{ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface)}+retained
        if record.captureRoutes != nil,let tunnel=record.interface {
            required += capture.prefixes.map{ProtectedRoute(destination:$0,gateway:$0.contains(":") ? String(record.address6.split(separator:"/")[0]):String(record.address4.split(separator:"/")[0]),interface:tunnel)}
        }
        let problems=CaptureOwnership.protectionIssues(owned:required,preserved:bypass.preservedRoutes,actual:installed)
        guard problems.isEmpty else {throw NetworkEnvironmentNotReady("企业路径仍在变化："+problems.joined(separator:"；"))}
        let obsoleteCapture=record.captureRoutes==nil ? []:record.routes.filter{$0.interface==record.interface && !capture.prefixes.contains($0.destination)}
        for route in expected+obsoleteCapture {
            if required.contains(where:{NetworkInspection.samePrefix($0.destination,route.destination) && $0.gateway==route.gateway && $0.interface==route.interface}) {continue}
            let target=ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope)
            let current=try routeSample().ownershipRoutes
            switch CaptureOwnership.recoveryState(expected:target,actual:current) {
            case .owned:
                let output=try writeRoute(NetworkInspection.routeArguments(.delete,destination:route.destination,gateway:route.gateway,ipv6:route.ipv6,scope:route.scope,interface:route.interface),deadline:Date().addingTimeInterval(1))
                guard !CaptureOwnership.routeWriteFailed(output) else {throw NetworkEnvironmentNotReady("旧保护项撤回尚未完成")}
                let after=try routeSample().ownershipRoutes
                guard CaptureOwnership.recoveryState(expected:target,actual:after) != .owned else {throw NetworkEnvironmentNotReady("旧保护项撤回尚未核验")}
            case .ambiguous:throw NetworkEnvironmentNotReady("企业保护路由存在竞争出口，保留当前保护")
            case .absent,.replaced:break
            }
            journal?.routes.removeAll{$0.destination==route.destination && $0.gateway==route.gateway && $0.interface==route.interface && $0.scope==route.scope}
            try save()
        }
        if record.captureRoutes != nil {journal?.captureRoutes=capture.prefixes}
        journal?.preservedRoutes=bypass.preservedRoutes
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
