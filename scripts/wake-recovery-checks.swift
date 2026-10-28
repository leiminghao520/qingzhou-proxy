import Foundation
import Darwin
import CQingzhouRoute
import QingzhouKit

final class DeleteCaptureTransport:RouteTransport {
    var sent:[Data]=[]
    func dump() throws -> Data {Data()}
    func exchange(_ request:Data,timeout:TimeInterval,cancelled:()->Bool) throws -> RouteExchangeResult {
        sent.append(request);return RouteExchangeResult(reply:request)
    }
}
final class WakeProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let port=request.url!.port!,path=request.url!.path
        var code=200,body="{\"delay\":18}"
        if path=="/proxies" {
            if port==18504 {code=401}
            else if port==18505 {body="{\"proxies\":{}}"}
            else {
                let actual=port==18506 ? "direct":port==18507 ? "broken":"node-00000000-0000-0000-0000-000000000002"
                body="{\"proxies\":{\"proxy\":{\"name\":\"proxy\",\"type\":\"Selector\",\"now\":\"\(actual)\"}}}"
            }
        } else {
            guard path.contains("000000000002") else {fatalError("必须检测实际节点，不能取列表首项")}
            if port==18502 {code=500}
            if port==18503 {client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return}
            if port==18508 {code=401}
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct WakeChecks {
    @MainActor static func main() async throws {
        var count=0
        func check(_ value:Bool,_ message:String){count+=1;if !value {fatalError(message)}}
        func run(_ results:[WakeRecoveryCheck],rebuildResult:WakeRecoveryCheck = .healthy) async -> (WakeRecoveryStatus,Int,[Double]) {
            var calls=0,rebuilds=0,delays:[Double]=[]
            let c=WakeRecoveryCoordinator(sleep:{delays.append($0);try Task.checkCancellation()})
            c.start(isCurrent:{true},check:{let item=results[min(calls,results.count-1)];calls+=1;return item},rebuild:{rebuilds+=1;return rebuildResult})
            await c.waitUntilFinished()
            return (c.status,rebuilds,delays)
        }
        let normal=await run([.healthy]);check(normal.0.phase == .recovered && normal.1==0 && normal.2==[15],"正常唤醒保留原会话并等待十五秒")
        let delayed=await run([.failed(.networkNotReady),.healthy]);check(delayed.1==0 && delayed.2==[15,3],"单轮失败不重建")
        let transient=await run([.inconclusive(.timeout),.healthy]);check(transient.0.phase == .recovered && transient.1==0,"超时不作为节点失效证据")
        let unknown=await run(Array(repeating:.inconclusive(.unverified),count:130)+[.healthy]);check(unknown.0.phase == .recovered && unknown.1==0,"未知检测超过原总预算仍只读复查，最终自行恢复")
        check(unknown.2.max()==30 && unknown.2.count==131,"长期未知复查退避到三十秒，避免高频空转")
        let helper=await run([.helperRecovering,.helperRecovering,.healthy]);check(helper.1==0,"辅助服务重建时客户端只等待")
        let helperBudget=await run(Array(repeating:.helperRecovering,count:65)+[.healthy]);check(helperBudget.0.phase == .recovered && helperBudget.1==0 && helperBudget.2.max()==30,"辅助服务超过旧等待预算后仍可自行恢复，不并发重建")
        let failures=await run(Array(repeating:.failed(.nodeUnavailable),count:18)+[.healthy],rebuildResult:.failed(.nodeUnavailable));check(failures.0.phase == .recovered && failures.1==6,"持续故障超过三次仍自动恢复")
        check(failures.2.filter{$0 != 15 && $0 != 3} == [1,10,30,60,60] && failures.2.contains(3),"重建退避逐步增加并封顶六十秒")
        let beforeWrite=await run([.failed(.pathUnavailable),.failed(.pathUnavailable),.healthy]);check(beforeWrite.1==0 && beforeWrite.0.phase == .recovered,"退避结束重查避免重复重建")
        let helperRace=await run([.failed(.pathUnavailable),.failed(.pathUnavailable),.helperRecovering,.healthy]);check(helperRace.1==0,"写入前辅助服务已开始重建则让行")
        for reason in [WakeRecoveryReason.ownershipConflict,.authentication,.configuration] {
            let terminal=await run([.stop(reason)]);check(terminal.1==0 && terminal.0.reason==reason,"永久错误不抢占网络")
            let classified=await run([.failed(reason)]);check(classified.1==0 && classified.0.phase == .manual,"结构化永久失败立即停止")
        }
        let failedWrite=await run([.failed(.controlUnavailable)],rebuildResult:.stop(.ownershipConflict));check(failedWrite.1==1 && failedWrite.0.reason == .ownershipConflict,"恢复冲突不重试")
        var c=WakeRecoveryCoordinator(sleep:{_ in try await Task.sleep(nanoseconds:30_000_000_000)})
        c.start(isCurrent:{true},check:{fatalError("取消后不得探测")},rebuild:{fatalError("取消后不得写入")})
        await Task.yield();let start=Date();c.cancel();check(!c.active && Date().timeIntervalSince(start)<1 && c.status.phase == .cancelled,"取消立即打断长退避")
        var resumed:CheckedContinuation<WakeRecoveryCheck,Never>?
        c=WakeRecoveryCoordinator(sleep:{_ in})
        c.start(isCurrent:{true},check:{await withCheckedContinuation{resumed=$0}},rebuild:{fatalError("取消后不得重建")})
        while resumed==nil {await Task.yield()}
        c.cancel();resumed?.resume(returning:.healthy);await Task.yield();check(c.status.phase == .cancelled,"取消后的迟到成功不能发布")
        var allowed=false,probes=0
        c=WakeRecoveryCoordinator(sleep:{_ in})
        c.start(isCurrent:{allowed},check:{probes+=1;return .healthy},rebuild:{.healthy});await c.waitUntilFinished();check(probes==0,"连接代次或配置已失效不探测")
        allowed=true
        c.start(isCurrent:{allowed},check:{probes+=1;return .healthy},rebuild:{.healthy});let first=c.id;c.start(isCurrent:{true},check:{fatalError("重复唤醒启动第二任务")},rebuild:{.healthy});check(c.id==first,"重复唤醒复用单一任务");await c.waitUntilFinished()
        for category in ["超时","取消","控制接口缺少实际节点","控制接口节点格式","无法确定"] {
            check(WakeRecoveryCheck.connectivity([ConnectivityResult("当前节点通道检测",.failed,category)]) == .inconclusive(.unverified),"未确认错误不计连续失败")
        }
        check(WakeRecoveryCheck.connectivity([ConnectivityResult("当前节点通道检测",.failed,"鉴权")]) == .stop(.authentication),"鉴权立即停止")
        check(WakeRecoveryCheck.connectivity([ConnectivityResult("当前节点通道检测",.failed,"节点通道")]) == .failed(.nodeUnavailable),"明确节点失败与规则路径分开")
        check(WakeRecoveryCheck.connectivity([ConnectivityResult("规则路径",.failed,"连接")]) == .failed(.pathUnavailable),"明确规则路径失败")
        check(WakeRecoveryCheck.connectivity([]) == .inconclusive(.unverified),"空结果不能成功")
        for phase in [WakeRecoveryStatus.Phase.idle,.waiting,.checking,.retryWaiting,.rebuilding,.recovered,.manual,.cancelled] {let text=WakeRecoveryStatus(phase,attempt:2,reason:.nodeUnavailable).label;check(phase == .idle || !text.isEmpty,"每个状态有明确显示")}
        for reason in [WakeRecoveryReason.networkNotReady,.controlUnavailable,.nodeUnavailable,.pathUnavailable,.unverified,.timeout,.ownershipConflict,.authentication,.configuration,.exitUnavailable,.helperRecovery,.retryExhausted,.cancelled] {check(!reason.label.isEmpty && WakeRecoveryError(reason).errorDescription==reason.label,"结构化原因可显示")}

        for (port,expected) in [(18501,WakeRecoveryCheck.healthy),(18502,.failed(.nodeUnavailable)),(18503,.inconclusive(.unverified)),(18504,.stop(.authentication)),(18505,.inconclusive(.unverified)),(18506,.inconclusive(.unverified)),(18507,.inconclusive(.unverified)),(18508,.stop(.authentication))] {
            let client=CoreAPIClient(context:CoreControlContext(port:port,secret:"fixture"),protocolClasses:[WakeProtocol.self])
            let result=await ConnectivityProbe.wakeNode(client:client,mode:.global)
            if port==18506 {check(result.status == .notApplicable,"真实直连出站不伪造节点")}
            else {check(WakeRecoveryCheck.connectivity([result])==expected,"真实控制接口适配器保留明确失败、未知与鉴权分类")}
            if port != 18504 {do{_ = try await client.proxies();check(true,"本次节点等待结束不关闭共享控制会话")}catch{check(false,"共享控制会话必须仍可用")}}
            await client.shutdown()
        }
        let clockFailure=WakeRecoveryCoordinator(sleep:{_ in throw NSError(domain:"注入时钟失败",code:1)})
        clockFailure.start(isCurrent:{true},check:{.healthy},rebuild:{.healthy});await clockFailure.waitUntilFinished()
        check(clockFailure.status.phase == .manual,"执行器异常如实结束，不能误报已恢复")
        let cancellation=WakeRecoveryCoordinator(sleep:{_ in try await Task.sleep(nanoseconds:30_000_000_000)})
        cancellation.start(isCurrent:{true},check:{.healthy},rebuild:{.healthy});await Task.yield()
        await cancellation.cancelAndWait();check(cancellation.status.phase == .cancelled && !cancellation.active,"取消等待已收尾再允许退出或切配置")
        let external=UUID(),reused=WakeRecoveryCoordinator(sleep:{_ in})
        var oldProbe:CheckedContinuation<WakeRecoveryCheck,Never>?,newProbe:CheckedContinuation<WakeRecoveryCheck,Never>?
        reused.start(id:external,isCurrent:{true},check:{await withCheckedContinuation{oldProbe=$0}},rebuild:{.healthy})
        while oldProbe==nil {await Task.yield()}
        reused.cancel()
        reused.start(id:external,isCurrent:{true},check:{await withCheckedContinuation{newProbe=$0}},rebuild:{.healthy})
        while newProbe==nil {await Task.yield()}
        oldProbe?.resume(returning:.healthy);for _ in 0..<10 {await Task.yield()}
        check(reused.active && reused.id==external,"同一睡眠任务再次亮屏时，旧执行器收尾不能清除新任务")
        newProbe?.resume(returning:.healthy);await reused.waitUntilFinished();check(reused.status.phase == .recovered,"新执行代次独立完成")
        let lateConflict=await run([.failed(.nodeUnavailable),.failed(.nodeUnavailable),.failed(.ownershipConflict)])
        check(lateConflict.1==0 && lateConflict.0.reason == .ownershipConflict,"写入前新发现的永久失败立即停止")
        var ordered=0,actualWrites=0
        let sharedBudget=WakeRecoveryCoordinator(sleep:{_ in})
        sharedBudget.start(isCurrent:{true},check:{ordered+=1;return ordered>15 ? .healthy:ordered==3 ? .helperRecovering:.failed(.nodeUnavailable)},rebuild:{actualWrites+=1;return .failed(.nodeUnavailable)})
        await sharedBudget.waitUntilFinished()
        check(actualWrites==4 && sharedBudget.status.attempt==4,"辅助服务让行不算实际重建，超过三次后仍可恢复")
        ordered=0
        let unsettled=WakeRecoveryCoordinator(sleep:{_ in})
        unsettled.start(isCurrent:{true},check:{ordered+=1;return ordered>130 ? .healthy:ordered%3==0 ? .inconclusive(.unverified):.failed(.pathUnavailable)},rebuild:{fatalError("未确认失败不能写网络")})
        await unsettled.waitUntilFinished();check(unsettled.status.phase == .recovered,"持续交替的未知结果保留意图，恢复前不写网络")
        let defaultClock=WakeRecoveryCoordinator()
        defaultClock.start(stableDelay:0,isCurrent:{true},check:{.healthy},rebuild:{.healthy})
        await defaultClock.waitUntilFinished();check(defaultClock.status.phase == .recovered,"正式时钟适配器可运行并保留健康会话")
        let parent=ProtectedRoute(destination:"239.255.255.250/32",gateway:"link#11",interface:"en0")
        let cache=ProtectedRoute(destination:parent.destination,gateway:"1:0:5e:7f:ff:fa",interface:"en0")
        let pf=UInt32(RTF_UP|RTF_MULTICAST|RTF_CLONING),cf=UInt32(RTF_UP|RTF_HOST|RTF_MULTICAST|RTF_LLINFO|RTF_STATIC)
        func state(_ values:[RouteRecord],expected:ProtectedRoute=parent)->CaptureOwnership.RecoveryRouteState {RouteIdentityIndex(records:values).state(expected)}
        let full=[RouteRecord(route:parent,flags:pf),RouteRecord(route:cache,flags:cf)]
        check(state(full) == .owned,"完整现场父项与缓存共存不再歧义")
        check(RouteIdentityIndex([parent,cache]).state(parent) == .ambiguous,"旧格式无原始标志不得猜测缓存来源")
        var competitor=cache;competitor.interface="en1"
        check(state([full[0],RouteRecord(route:competitor,flags:cf)]) == .ambiguous,"不同接口缓存不能忽略")
        competitor=parent;competitor.interface="utun7";competitor.gateway="link#22"
        check(state(full+[RouteRecord(route:competitor,flags:pf)]) == .ambiguous,"第三个出口阻止认领")
        for removed in [RTF_MULTICAST,RTF_CLONING] {check(state([RouteRecord(route:parent,flags:pf & ~UInt32(removed)),full[1]]) == .ambiguous,"父项证据缺失不能忽略缓存")}
        check(state([full[0],RouteRecord(route:cache,flags:UInt32(RTF_HOST|RTF_STATIC))]) == .ambiguous,"独立静态主机路由不得当缓存")
        var unicast=parent;unicast.destination="192.0.2.1/32";var neighbor=cache;neighbor.destination=unicast.destination
        check(state([RouteRecord(route:unicast,flags:pf),RouteRecord(route:neighbor,flags:cf)],expected:unicast) == .ambiguous,"普通单播从不套用组播例外")
        check(state([full[1]]) == .replaced,"父项删除后缓存不能被认领为父项")
        check(state([RouteRecord(route:competitor,flags:pf)]) == .replaced,"VPN 已替换路由保持外部出口")
        check(state([]) == .absent,"已删除路由允许重入恢复")
        var scoped=cache;scoped.scope="en0"
        check(state([full[0],RouteRecord(route:scoped,flags:cf)]) == .owned,"其他作用域不干扰全局所有权")
        func rawMulticast(cache:Bool,badAddress:Bool=false)->Data {
            var header=rt_msghdr();header.rtm_version=UInt8(RTM_VERSION);header.rtm_type=UInt8(RTM_ADD)
            header.rtm_index=UInt16(if_nametoindex("lo0"));header.rtm_flags=Int32(cache ? cf:pf);header.rtm_addrs=RTA_DST|RTA_GATEWAY|RTA_NETMASK
            var bytes=Data(count:MemoryLayout<rt_msghdr>.size)
            func append<T>(_ value:inout T) {withUnsafeBytes(of:&value){bytes.append(contentsOf:$0)};while bytes.count % 4 != 0 {bytes.append(0)}}
            var destination=sockaddr_in();destination.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);destination.sin_family=sa_family_t(AF_INET);destination.sin_addr.s_addr=inet_addr("239.255.255.250");append(&destination)
            var link=sockaddr_dl();link.sdl_len=UInt8(MemoryLayout<sockaddr_dl>.size);link.sdl_family=UInt8(AF_LINK);link.sdl_index=header.rtm_index;link.sdl_alen=cache ? 6:0
            withUnsafeMutableBytes(of:&link.sdl_data) {raw in for (i,byte) in [UInt8(1),0,0x5e,0x7f,0xff,0xfa].enumerated() {raw[i]=byte}}
            if badAddress {link.sdl_nlen=250}
            append(&link)
            var mask=sockaddr_in();mask.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);mask.sin_family=sa_family_t(AF_INET);mask.sin_addr.s_addr=UInt32.max;append(&mask)
            header.rtm_msglen=UInt16(bytes.count);withUnsafeBytes(of:&header){bytes.replaceSubrange(0..<MemoryLayout<rt_msghdr>.size,with:$0)}
            return bytes
        }
        let decoded=try NativeRouteBackend.decode(rawMulticast(cache:false)+rawMulticast(cache:true))
        check(decoded.count==2 && decoded[0].route.gateway==decoded[1].route.gateway,"原生采样父项与缓存可能具有相同 link# 网关")
        check(NetworkRouteSample(records:[decoded[1]]).identityIndex.state(decoded[0].route) == .ambiguous,"父项消失后不能把同 link# 缓存认领成父项")
        var broad=decoded[0];broad.route.destination="224.0.0.0/4"
        let orphan=[broad,decoded[1]]
        check(state(orphan,expected:decoded[0].route) == .replaced,"满长父项删除后由当前同接口组播父网段证明缓存来源")
        check(NetworkRouteSample(records:orphan).identityIndex.ownedRecord(decoded[0].route)==nil,"已证明的系统缓存绝不进入删除入口")
        var foreignBroad=broad;foreignBroad.route.interface="utun250"
        check(state(orphan+[foreignBroad],expected:decoded[0].route) == .ambiguous,"组播父网段有同作用域竞争时不得排除缓存")
        for flag in [RTF_UP,RTF_MULTICAST,RTF_CLONING] {
            var incomplete=broad;incomplete.flags &= ~UInt32(flag)
            check(state([incomplete,decoded[1]],expected:decoded[0].route) == .ambiguous,"父网段证据不全时保持保守")
        }
        var changedCache=decoded[1];changedCache.linkLayerAddress="1:0:5e:7f:ff:fb"
        check(state([broad,changedCache],expected:decoded[0].route) == .ambiguous,"链路地址变化不能借用旧缓存来源")
        check(decoded[1].linkLayerAddress=="1:0:5e:7f:ff:fa" && decoded[0].linkLayerAddress==nil,"原生解码独立保留真实链路地址")
        check(NetworkRouteSample(records:decoded).identityIndex.state(decoded[0].route) == .owned,"原生字节经过正式快照索引可正确分类")
        let deleteWire=DeleteCaptureTransport()
        let preciseBackend=NativeRouteBackend(transport:deleteWire)
        check(NetworkRouteSample(records:decoded).identityIndex.ownedRecord(decoded[0].route)?.flags==decoded[0].flags,"分类后保留实际父项原始删除身份")
        check(try preciseBackend.delete(decoded[0]) == .applied,"父项使用结构化删除入口")
        let parentDelete=deleteWire.sent.last!.withUnsafeBytes{$0.loadUnaligned(as:rt_msghdr.self)}
        check(parentDelete.rtm_flags & RTF_HOST==0 && parentDelete.rtm_addrs & RTA_NETMASK != 0,"满长组播网络父项按原非 HOST 身份删除")
        check(try preciseBackend.delete(decoded[1]) == .applied,"独立主机删除入口保留兼容")
        let cacheDelete=deleteWire.sent.last!.withUnsafeBytes{$0.loadUnaligned(as:rt_msghdr.self)}
        check(cacheDelete.rtm_flags & RTF_HOST != 0 && cacheDelete.rtm_addrs & RTA_NETMASK==0,"主机路由仍使用 HOST 删除身份")
        check(NetworkRouteSample(records:[decoded[1]]).identityIndex.ownedRecord(decoded[0].route)==nil,"孤立缓存不会进入自有父项删除入口")
        let badLink=try NativeRouteBackend.decode(rawMulticast(cache:true,badAddress:true))
        check(badLink[0].linkLayerAddress==nil,"畸形链路地址不能伪造缓存来源")
        let legacy=Data(#"{"id":"C0E381F3-7486-4D6C-83A8-D586B8229B4E","time":0,"lastTime":0,"uptime":0,"sessionID":"C0E381F3-7486-4D6C-83A8-D586B8229B4E","category":"network","outcome":"changed","reason":"environmentChanged","count":1}"#.utf8)
        let old=try JSONDecoder().decode(NetworkEvent.self,from:legacy);check(old.recoveryID==nil && old.recoveryReason==nil,"旧事件格式向后兼容")
        print("RESULT wake_recovery_assertions=\(count) failures=0")
    }
}
