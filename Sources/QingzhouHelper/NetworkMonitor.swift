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
        let routes=NetworkSnapshot.parseRoutes(table)
        return plan.protectedRoutes.allSatisfy {expected in
            routes.contains{actual in NetworkInspection.samePrefix(actual.destination,expected.destination) && actual.interface==expected.interface && actual.scope==nil}
        }
    }
    func verifyOwnedNetwork()->Bool {(try? inspectOwnedNetwork()) == true}
    func inspectOwnedNetwork() throws -> Bool {
        guard let record=journal,let expected=try PropertyListSerialization.propertyList(from:record.expectedDNS,format:nil) as? NSDictionary else{return false}
        let table=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
        let routes=NetworkSnapshot.parseRoutes(table)
        guard (SCDynamicStoreCopyValue(dynamic,record.dnsKey as CFString) as? NSDictionary)==expected else{return false}
        return record.routes.allSatisfy{owned in routes.contains{current in NetworkInspection.samePrefix(current.destination,owned.destination) && current.interface==owned.interface && current.scope==owned.scope && current.gateway==owned.gateway}}
    }
    func currentSnapshot() throws -> NetworkSnapshot {
        guard let record=journal,let global=SCDynamicStoreCopyValue(dynamic,"State:/Network/Global/IPv4" as CFString) as? [String:Any],let primary=global["PrimaryInterface"] as? String else{throw ProxyError("网络快照无法更新")}
        let routes=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
        var snapshot=try NetworkSnapshot.read(store:dynamic,primary:primary,routes:routes,ownedDNSKey:record.dnsKey,ownedTunnel:record.interface)
        snapshot.routes.removeAll {route in record.routes.contains{owned in NetworkInspection.samePrefix(route.destination,owned.destination) && route.interface==owned.interface && route.scope==owned.scope}}
        return snapshot
    }
    func startNetworkMonitor() {
        networkTimer?.cancel()
        var context=SCDynamicStoreContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        networkStore=SCDynamicStoreCreate(nil,"轻舟企业保护监控" as CFString,{_,_,info in
            guard let info else{return};Unmanaged<Service>.fromOpaque(info).takeUnretainedValue().checkNetworkChange()
        },&context)
        if let networkStore {SCDynamicStoreSetNotificationKeys(networkStore,nil,["State:/Network/Global/.*","State:/Network/Service/.*/(DNS|IPv4|IPv6)","State:/Network/Interface/.*/.*"] as CFArray);SCDynamicStoreSetDispatchQueue(networkStore,queue)}
        let descriptor=socket(PF_ROUTE,SOCK_RAW,0)
        if descriptor>=0 {
            _=fcntl(descriptor,F_SETFL,O_NONBLOCK)
            let source=DispatchSource.makeReadSource(fileDescriptor:descriptor,queue:queue);routeEvents=source
            source.setEventHandler{[weak self] in var buffer=[UInt8](repeating:0,count:8192);while recv(descriptor,&buffer,buffer.count,0)>0 {};self?.checkNetworkChange()}
            source.setCancelHandler{close(descriptor)};source.resume()
        }
        let timer=DispatchSource.makeTimerSource(queue:queue);networkTimer=timer
        timer.schedule(deadline:.now()+1,repeating:1)
        timer.setEventHandler{[weak self] in self?.checkNetworkChange()};timer.resume()
    }
    func checkNetworkChange() {
        guard ["active","networkRetry"].contains(phase),let previous=capturePlan,let request=activeRequest,let fd=owner else{return}
        // 每次通知和重试等待期间都先核对所有权，不能用退避掩盖外部改写。
        do {
            guard try inspectOwnedNetwork(),request.systemProxyPort == nil || verifyProxy() else {
                failNetworkChange("网络所有权冲突：接管设置被外部修改");return
            }
        } catch {retrySnapshot(error);return}
        guard snapshotRetry.ready(now:ProcessInfo.processInfo.systemUptime) else{return}
        let fresh:CapturePlan
        do {
            var snapshot=try currentSnapshot();snapshot.proxies=previous.snapshot.proxies
            fresh=try CapturePlan.make(snapshot:snapshot,extraCIDRs:request.state?.tunExcludedCIDRs ?? [],extraDomains:request.state?.protectedDomains ?? [])
        } catch {retrySnapshot(error);return}
        snapshotRetry.reset();phase="active"
        let defaultsChanged=fresh.snapshot.routes.filter{$0.destination.hasSuffix("/0")} != previous.snapshot.routes.filter{$0.destination.hasSuffix("/0")}
        let changed=fresh.snapshot.primaryInterface != previous.snapshot.primaryInterface || fresh.snapshot.resolvers != previous.snapshot.resolvers || fresh.protectedRoutes != previous.protectedRoutes || defaultsChanged
        if !changed {pendingNetworkChange=nil;return}
        guard let pending=pendingNetworkChange else{pendingNetworkChange=Date();return}
        guard Date().timeIntervalSince(pending)>=1 else{return}
        do {
            phase="networkReplan";try stop();try start(request,fd:fd)
            guard let activate=activatePrepared else{throw ProxyError("网络重规划未完成")}
            try activate();activatePrepared=nil;phase="active";lastFailure=nil
        } catch {failNetworkChange("网络重新激活失败："+error.localizedDescription)}
    }
    private func retrySnapshot(_ error:Error) {
        let now=ProcessInfo.processInfo.systemUptime
        // 事件风暴不能提前耗尽下一次重试预算。
        guard snapshotRetry.ready(now:now) else{return}
        if snapshotRetry.failed(now:now) {phase="networkRetry"}
        else {failNetworkChange("网络快照重试耗尽："+error.localizedDescription)}
    }
    private func failNetworkChange(_ reason:String) {
        do{try stop();lastFailure=reason+"；原网络已恢复"}catch{lastFailure=reason+"；恢复冲突："+error.localizedDescription}
        phase="networkProtectionFailed"
    }
}
