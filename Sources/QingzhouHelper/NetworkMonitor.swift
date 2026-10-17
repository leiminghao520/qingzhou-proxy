import Foundation
import QingzhouKit
import SystemConfiguration
import Darwin

extension Service {
    func protect(_ route:ProtectedRoute) throws {
        // 接口限定路由不能保护未绑定的应用；补充同出口的全局路由并记录所有权。
        if route.scope != nil {try addRoute(route.destination,route.gateway,route.interface,ipv6:route.ipv6)}
    }
    func verifyProtection()->Bool {
        guard let plan=capturePlan else{return false}
        guard let table=try? NetworkInspection.command("/usr/sbin/netstat",["-rn"]) else{return false}
        let routes=NetworkSnapshot.parseRoutes(table,includeTransient:true)
        return plan.protectedRoutes.allSatisfy {expected in
            routes.contains{actual in NetworkInspection.samePrefix(actual.destination,expected.destination) && actual.interface==expected.interface && actual.scope==nil}
        }
    }
    func verifyOwnedNetwork()->Bool {(try? inspectOwnedNetwork()) == true}
    func inspectOwnedNetwork() throws -> Bool {try ownedNetworkIssues().isEmpty}
    func ownedNetworkIssues(sample: NetworkRouteSample? = nil) throws -> [String] {
        guard let record=journal,let expected=try PropertyListSerialization.propertyList(from:record.expectedDNS,format:nil) as? NSDictionary else{return ["恢复快照缺失或 DNS 快照不可读取"]}
        let routes=try (sample ?? routeSample()).ownershipRoutes
        var issues:[String]=[]
        let currentDNS: NSDictionary?
        if let networkDNSRead { currentDNS=networkDNSRead(record.dnsKey) }
        else { currentDNS=SCDynamicStoreCopyValue(dynamic,record.dnsKey as CFString) as? NSDictionary }
        if currentDNS != expected {issues.append("本次补充 DNS 服务与应用值不一致")}
        let expectedRoutes=record.routes.map{ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface,scope:$0.scope)}
        issues += CaptureOwnership.protectionIssues(owned:expectedRoutes,preserved:record.preservedRoutes ?? [],actual:routes)
        return issues
    }
    func currentSnapshot(sample: NetworkRouteSample? = nil) throws -> NetworkSnapshot {
        guard let record=journal else{throw NetworkEnvironmentNotReady("网络快照无法更新")}
        let sample=try sample ?? routeSample()
        var snapshot: NetworkSnapshot
        if let networkSnapshotRead { snapshot=try networkSnapshotRead(sample) }
        else {
            guard let global=SCDynamicStoreCopyValue(dynamic,"State:/Network/Global/IPv4" as CFString) as? [String:Any],let primary=global["PrimaryInterface"] as? String else{throw NetworkEnvironmentNotReady("网络快照无法更新")}
            snapshot=try NetworkSnapshot.read(store:dynamic,primary:primary,routes:sample.table,ownedDNSKey:record.dnsKey,ownedTunnel:record.interface)
        }
        snapshot.routes.removeAll {route in record.routes.contains{owned in NetworkInspection.samePrefix(route.destination,owned.destination) && route.interface==owned.interface && route.scope==owned.scope}}
        return snapshot
    }
    func startNetworkMonitor() {
        networkTimer?.cancel()
        networkChecks?.cancel()
        let checks=NetworkCheckScheduler(enqueue: { [weak self] operation in self?.queue.async(execute: operation) }, operation: { [weak self] in self?.checkNetworkChange() })
        networkChecks=checks
        var context=SCDynamicStoreContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        networkStore=SCDynamicStoreCreate(nil,"轻舟企业保护监控" as CFString,{_,_,info in
            guard let info else{return};Unmanaged<Service>.fromOpaque(info).takeUnretainedValue().networkChecks?.request()
        },&context)
        if let networkStore {SCDynamicStoreSetNotificationKeys(networkStore,nil,["State:/Network/Global/.*","State:/Network/Service/.*/(DNS|IPv4|IPv6)","State:/Network/Interface/.*/.*"] as CFArray);SCDynamicStoreSetDispatchQueue(networkStore,queue)}
        let descriptor=socket(PF_ROUTE,SOCK_RAW,0)
        if descriptor>=0 {
            _=fcntl(descriptor,F_SETFL,O_NONBLOCK)
            let source=DispatchSource.makeReadSource(fileDescriptor:descriptor,queue:queue);routeEvents=source
            source.setEventHandler{[weak checks] in var buffer=[UInt8](repeating:0,count:8192);while recv(descriptor,&buffer,buffer.count,0)>0 {};checks?.request()}
            source.setCancelHandler{close(descriptor)};source.resume()
        }
        let timer=DispatchSource.makeTimerSource(queue:queue);networkTimer=timer
        timer.schedule(deadline:.now()+1,repeating:1)
        timer.setEventHandler{[weak checks] in checks?.request()};timer.resume()
    }
    func checkNetworkChange() {
        guard ["active","networkRetry"].contains(phase),let previous=capturePlan,let request=activeRequest,let fd=owner else{return}
        // 每轮重新采样；所有权和重规划共享本轮路由，退避期间也核对外部改写。
        let sample: NetworkRouteSample
        do {
            sample=try routeSample()
            var issues=try ownedNetworkIssues(sample: sample)
            if request.systemProxyPort != nil {issues += proxyOwnershipIssues()}
            if !issues.isEmpty {
                failNetworkChange("网络保护核验未通过："+issues.prefix(8).joined(separator:"；"));return
            }
        } catch {retrySnapshot(error);return}
        guard snapshotRetry.ready(now:networkUptime()) else{return}
        let fresh:CapturePlan
        do {
            var snapshot=try currentSnapshot(sample: sample);snapshot.proxies=previous.snapshot.proxies
            fresh=try CapturePlan.make(snapshot:snapshot,extraCIDRs:request.state?.tunExcludedCIDRs ?? [],extraDomains:request.state?.protectedDomains ?? [])
        } catch {retrySnapshot(error);return}
        snapshotRetry.reset();phase="active"
        let defaultsChanged=fresh.snapshot.routes.filter{$0.destination.hasSuffix("/0")} != previous.snapshot.routes.filter{$0.destination.hasSuffix("/0")}
        let changed=fresh.snapshot.primaryInterface != previous.snapshot.primaryInterface || fresh.snapshot.resolvers != previous.snapshot.resolvers || fresh.protectedRoutes != previous.protectedRoutes || defaultsChanged
        if !changed {pendingNetworkChange=nil;return}
        guard let pending=pendingNetworkChange else{pendingNetworkChange=networkClock();return}
        guard networkClock().timeIntervalSince(pending)>=1 else{return}
        beginNetworkResume(request,fd:fd)
    }
    private func retrySnapshot(_ error:Error) {
        let now=networkUptime()
        // 事件风暴不能提前耗尽下一次重试预算。
        guard snapshotRetry.ready(now:now) else{return}
        if snapshotRetry.failed(now:now) {phase="networkRetry"}
        else if let request=activeRequest,let fd=owner {
            // 快照仍未就绪时先安全恢复旧接管，再使用同一连接的有限重建流程。
            beginNetworkResume(request,fd:fd)
        } else {failNetworkChange("网络快照重试耗尽："+error.localizedDescription)}
    }
    private func failNetworkChange(_ reason:String) {
        do{try stop();lastFailure=reason+"；原网络已恢复"}catch{lastFailure=reason+"；恢复冲突："+error.localizedDescription}
        phase="networkProtectionFailed"
    }
}
