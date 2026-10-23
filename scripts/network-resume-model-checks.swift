import AppKit
import QingzhouKit

final class WakeModelProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let port=request.url!.port!
        if port==18602 || port==18603 {client?.urlProtocol(self,didFailWithError:URLError(port==18602 ? .timedOut:.cannotConnectToHost));return}
        let body=request.url!.path=="/proxies" ? (port==18605 ? "{\"proxies\":{}}":"{\"proxies\":{\"proxy\":{\"name\":\"proxy\",\"type\":\"Selector\",\"now\":\"node-00000000-0000-0000-0000-000000000002\"}}}"):"{\"delay\":12}"
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:port==18601 ? 401:200,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct NetworkResumeModelChecks {
    @MainActor static func main() async throws {
        let model = AppModel()
        guard !model.loadingFailed else { fatalError("隔离模型初始化失败") }
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            assertions += 1
            if !condition { fatalError(message) }
        }
        model.connection = .connecting
        model.startupStage = "验证实际网络"
        check(model.connectionSummary == "连接中 · 验证实际网络", "连接中必须显示实际阶段")
        model.networkReconnecting = true
        model.startupStage = "第 2 次准备，1 秒后重试"
        check(model.connectionSummary.contains("第 2 次准备"), "重试阶段不能被通用状态遮盖")
        model.networkReconnecting = false
        model.startupStage = nil
        let startupToken=model.startupGeneration
        try model.checkStartup(startupToken)
        model.busy=true
        await model.disconnect()
        check(model.startupStage == nil, "手动取消必须清除启动阶段")
        do {try model.checkStartup(startupToken);check(false,"旧代次不能提交结果")}
        catch {check(error is CancellationError,"旧代次必须按取消处理")}
        model.connection = .disconnected;model.stopRequested=false;model.busy=false
        model.connection = .connected
        model.state.captureMode = .tun
        model.monitorPaused = true
        model.uploadRate = 1024; model.downloadRate = 2048
        model.updateHelperNetworkStatus(TunReply(ok: true, message: "IPv6 暂未就绪", running: false, phase: "networkReconnecting"))
        check(model.networkReconnecting && model.networkRechecking, "暂停监控仍识别待重连状态")
        check(model.connection == .connected && model.errorMessage == nil, "待重连不能变为核心崩溃提示")
        check(model.locked && model.canStop && !model.stopDisabled, "重连时阻止配置变更，但允许用户安全断开")
        check(model.connectionSummary.contains("自动重连"), "摘要明确显示自动重连")
        check(model.connectivityResults == ConnectivityResult.pending, "等待时不继续展示历史连通性通过结果")
        check(model.uploadRate == 0 && model.downloadRate == 0, "等待时清除历史速率")
        model.updateHelperNetworkStatus(TunReply(ok: true, message: "已恢复", running: true, phase: "active"))
        check(!model.networkReconnecting && !model.locked, "重新激活后恢复正常交互")
        model.updateHelperNetworkStatus(TunReply(ok: true, message: "等待", running: false, phase: "networkReconnecting"))
        model.updateHelperNetworkStatus(TunReply(ok: true, message: "恢复冲突", running: false, phase: "networkProtectionFailed"))
        check(!model.networkReconnecting && model.helperStatus == "恢复冲突", "最终失败显示真实原因，不能一直显示等待")
        let temporary=TunReply(ok:false,message:"原路径变化",networkNotReady:true)
        let roundTrip=try JSONDecoder().decode(TunReply.self,from:JSONEncoder().encode(temporary))
        do {try roundTrip.validateSuccess();check(false,"暂态响应必须失败")}
        catch {check(error is NetworkEnvironmentNotReady,"跨控制通道保留暂态错误类型")}
        let legacy=try JSONDecoder().decode(TunReply.self,from:Data(#"{"ok":false,"message":"外部接管","running":false}"#.utf8))
        do {try legacy.validateSuccess();check(false,"旧响应仍拒绝")}
        catch {check(!(error is NetworkEnvironmentNotReady),"旧响应和外部冲突不得按字符串误判为暂态")}
        var attempts=0,waits:[Double]=[]
        try await NetworkPreparationRetry.run(operation:{
            attempts += 1
            if attempts == 1 {throw NetworkEnvironmentNotReady("企业路由后到，已回滚")}
        },shouldContinue:{true},wait:{waits.append($0)})
        check(attempts == 2 && waits == [1],"首次连接失败后重新执行完整操作")
        var limitAttempts=0,limitWaits:[Double]=[]
        do {
            try await NetworkPreparationRetry.run(operation:{limitAttempts += 1;throw NetworkEnvironmentNotReady("持续变化")},shouldContinue:{true},wait:{limitWaits.append($0)})
            check(false,"持续变化必须耗尽预算")
        } catch {check(error is NetworkEnvironmentNotReady && limitAttempts == 8 && limitWaits == [1,2,4,8,15,30,30],"首次连接重试也有预算上限")}
        var allowed=true,cancelAttempts=0
        do {
            try await NetworkPreparationRetry.run(operation:{cancelAttempts += 1;throw NetworkEnvironmentNotReady("变化")},shouldContinue:{allowed},wait:{_ in allowed=false})
            check(false,"取消后不能继续")
        } catch {check(error is CancellationError && cancelAttempts == 1,"等待期间用户取消不会重新接管")}
        var conflictAttempts=0,conflictWaits=0
        do {
            try await NetworkPreparationRetry.run(operation:{conflictAttempts += 1;throw ProxyError("恢复冲突")},shouldContinue:{true},wait:{_ in conflictWaits += 1})
            check(false,"恢复冲突必须停止")
        } catch {check(!(error is NetworkEnvironmentNotReady) && conflictAttempts == 1 && conflictWaits == 0,"永久错误和回滚失败均不重试")}
        do {
            try await NetworkPreparationRetry.run(operation:{throw NetworkEnvironmentNotReady("变化")},shouldContinue:{true},wait:{_ in throw CancellationError()})
            check(false,"等待任务取消必须退出")
        } catch {check(error is CancellationError,"任务取消直接退出重试")}
        model.healthDisplayAwake={true}
        var powerTime=100.0
        model.healthPowerUptime={powerTime}
        let beforeSleep=model.healthPower.generation
        check(!model.recordNodeHealth([.unavailable],powerGeneration:beforeSleep),"清醒状态第一轮失败不立即断开")
        model.handleHealthPowerEvent(.willSleep)
        check(model.healthPower.suspended && !model.healthResultIsCurrent(beforeSleep),"进入睡眠取消旧结果并挂起健康检查")
        check(model.connection == .connected && model.canStop,"睡眠保护保留连接和手动停止入口")
        // 回放从傍晚合盖到夜间开盖；多次维护唤醒都不恢复屏幕健康检查。
        for wake in [101.0,103,148,150,172,218,220,265] {
            powerTime=wake
            model.handleHealthPowerEvent(.didWake)
            check(!model.recordNodeHealth([.unavailable],powerGeneration:model.healthPower.generation),"后台唤醒失败不能累计为节点失效")
            model.handleHealthPowerEvent(.willSleep)
        }
        powerTime=300
        model.handleHealthPowerEvent(.didWake)
        check(model.healthPower.suspended,"系统后台唤醒而屏幕仍睡眠时继续挂起")
        model.handleHealthPowerEvent(.screensWake)
        let afterWake=model.healthPower.generation
        check(!model.healthPower.suspended && !model.healthResultIsCurrent(afterWake),"真正开盖后先等待网络稳定")
        check(!model.recordNodeHealth([.unavailable],powerGeneration:afterWake),"唤醒宽限期的失败不计数")
        powerTime=314.999
        check(!model.healthResultIsCurrent(afterWake),"十五秒运行预算未结束时不能探测")
        powerTime=315
        check(model.wakeRecovery.active,"正式唤醒后恢复协调器独占复查，避免健康检查并发断开")
        model.cancelWakeRecovery()
        check(model.healthResultIsCurrent(afterWake),"运行预算结束后恢复健康检查")
        check(!model.healthResultIsCurrent(beforeSleep),"跨越睡眠的旧请求即使晚返回也必须丢弃")
        check(!model.recordNodeHealth([.unavailable],powerGeneration:afterWake),"睡前和维护唤醒失败不能带到新周期")
        check(model.recordNodeHealth([.unavailable],powerGeneration:afterWake),"清醒状态真实连续失败仍触发原有停止策略")
        model.healthDisplayAwake={false}
        check(!model.healthResultIsCurrent(afterWake),"电源通知尚未送达时也按实际屏幕睡眠状态拒绝旧结果")
        model.healthDisplayAwake={true}
        let deadline=model.healthPower.readyAt
        model.handleHealthPowerEvent(.didWake);model.handleHealthPowerEvent(.screensWake)
        check(model.healthPower.readyAt==deadline && model.healthPower.generation==afterWake,"重复唤醒通知不能无限延长宽限期")
        model.handleHealthPowerEvent(.screensSleep)
        check(!model.recordNodeHealth([.unavailable],powerGeneration:model.healthPower.generation),"仅显示器睡眠同样不能误判节点失效")
        model.handleHealthPowerEvent(.willSleep)
        model.handleHealthPowerEvent(.screensWake)
        check(model.healthPower.suspended,"屏幕先醒但系统尚未唤醒时保持挂起")
        model.handleHealthPowerEvent(.didWake)
        check(!model.healthPower.suspended && model.healthPower.readyAt==330,"屏幕先于系统通知时也能完成唤醒和宽限期")
        // 使用正式 AppModel 和接管控制器，注入辅助服务响应，禁止真实网络写入。
        var recoveryFails=false,releaseSafe=true,helperRunning=false,pending=false
        var requests:[TunRequest]=[]
        let capture=CaptureController(core:model.core,proxy:model.proxy,helperRequest:{request in
            requests.append(request)
            if request.operation=="prepare" {helperRunning=true;pending=true}
            if request.operation=="recover" {
                helperRunning=false
                if recoveryFails {throw ProxyError("合成归档错误")}
                pending=false
            }
            var reply=TunReply(ok:true,message:"合成状态",running:helperRunning)
            reply.supportsExternalRecovery=true;reply.recoveryPending=pending;reply.safeToQuit=releaseSafe
            return reply
        })
        model.capture=capture
        var state=AppState();state.captureMode = .tun
        let control=CoreControlContext(port:19992,secret:String(repeating:"a",count:64))
        try await capture.start(state,credentials:MemoryCredentials(),control:control)
        model.connection = .error;model.recoveryPending=true
        await model.recover()
        for _ in 0..<200 where model.recovering {try await Task.sleep(nanoseconds:5_000_000)}
        check(!model.recovering && !model.recoveryPending,"手动恢复完成后解除恢复锁")
        check(model.connection == .disconnected && model.errorMessage==nil,"恢复成功清除旧错误")
        check(requests.contains{$0.operation=="recover" && $0.preserveExternal==true},"恢复按钮必须走保留外部网络入口")
        recoveryFails=true
        try await capture.start(state,credentials:MemoryCredentials(),control:control)
        model.recoveryPending=true
        let quitAllowed=await model.quit()
        check(quitAllowed && pending,"已确认释放时保留记录也能退出")
        check(model.errorMessage==nil,"允许退出时不能再次弹出旧的恢复失败提示")
        releaseSafe=false
        try await capture.start(state,credentials:MemoryCredentials(),control:control)
        let blocked=await model.quit()
        check(!blocked && model.errorMessage != nil,"真实残留接管仍阻止不安全退出")
        model.cancelWakeRecovery()
        model.wakeRecovery=WakeRecoveryCoordinator(sleep:{_ in try Task.checkCancellation()})
        var wakeProbes=0,wakeBuilds=0
        model.wakeCheckOverride={wakeProbes+=1;return .healthy}
        model.wakeRebuildOverride={wakeBuilds+=1;return .healthy}
        model.connection = .connected
        model.handleHealthPowerEvent(.screensSleep);model.handleHealthPowerEvent(.screensWake)
        await Task.yield()
        check(model.wakeIntent==nil && wakeProbes==0,"单独熄屏和锁屏不建立重连意图")
        model.handleHealthPowerEvent(.willSleep);model.handleHealthPowerEvent(.didWake)
        await Task.yield();check(wakeProbes==0,"后台维护唤醒不执行业务探测")
        model.handleHealthPowerEvent(.screensWake)
        await model.wakeRecovery.waitUntilFinished()
        check(wakeProbes==1 && wakeBuilds==0 && model.wakeRecoveryStatus.phase == .recovered,"系统和屏幕唤醒后保留健康会话")
        model.wakeCheckOverride={.stop(.authentication)};model.coreFailed=false
        model.handleHealthPowerEvent(.willSleep);model.handleHealthPowerEvent(.didWake);model.handleHealthPowerEvent(.screensWake)
        await model.wakeRecovery.waitUntilFinished()
        check(model.wakeIntent==nil && model.wakeRecoveryStatus.phase == .manual,"转入手动处理后撤销恢复意图，不永久阻止原有核心退出清理")
        model.wakeCheckOverride={wakeProbes+=1;return .healthy}

        model.connection = .disconnected
        model.handleHealthPowerEvent(.willSleep);model.handleHealthPowerEvent(.didWake);model.handleHealthPowerEvent(.screensWake)
        check(!model.wakeRecovery.active && model.wakeIntent==nil,"睡前未连接不能自动创建连接")
        model.connection = .connected
        model.wakeRecovery=WakeRecoveryCoordinator(sleep:{_ in try await Task.sleep(nanoseconds:30_000_000_000)})
        model.handleHealthPowerEvent(.willSleep);model.handleHealthPowerEvent(.didWake);model.handleHealthPowerEvent(.screensWake)
        let oldID=model.wakeRecovery.id
        model.handleHealthPowerEvent(.didWake);model.handleHealthPowerEvent(.screensWake)
        check(model.wakeRecovery.id==oldID,"重复唤醒不延后稳定等待或创建第二任务")
        model.epoch=UUID()
        check(!model.wakeRecovery.active && model.wakeIntent==nil,"连接代次改变立即撤销旧任务")
        model.handleHealthPowerEvent(.willSleep);model.handleHealthPowerEvent(.didWake);model.handleHealthPowerEvent(.screensWake)
        check(model.wakeRecovery.active,"新一轮真实睡眠重新建立恢复任务")
        model.busy=true;await model.disconnect()
        check(!model.wakeRecovery.active && model.wakeIntent==nil,"手动断开在忙碌时也立即撤销恢复意图")
        model.connection = .disconnected;model.stopRequested=false;model.busy=false
        do {
            var supports=true,helperBusy=false,ipcBusy=false,race=false,invalidRecovery=false,recoverCalls=0
            let atomic=CaptureController(core:model.core,proxy:model.proxy,helperRequest:{request in
                if ipcBusy {throw HelperRequestBusy()}
                if request.operation=="recover" {recoverCalls+=1}
                var reply=TunReply(ok:true,message:"隔离唤醒恢复",running:request.operation != "recover" || helperBusy || race || invalidRecovery,phase:(helperBusy || (race && request.operation=="recover")) ? "networkReconnecting":"active")
                reply.supportsWakeRecovery=supports;reply.supportsExternalRecovery=true
                return reply
            })
            var tunnel=AppState();tunnel.captureMode = .tun
            try await atomic.start(tunnel,credentials:MemoryCredentials(),control:control)
            supports=false
            do {_=try await atomic.recoverForWake();check(false,"旧服务不得尝试不受保护的恢复")}
            catch let error as WakeRecoveryError {check(error.reason == .configuration && recoverCalls==0,"旧辅助服务保守停止，不发送恢复")}
            supports=true;ipcBusy=true
            let busyIPC=try await atomic.recoverForWake()
            check(!busyIPC && recoverCalls==0 && atomic.activeMode == .tun,"辅助服务控制请求占用时只等待，不误报归属冲突")
            ipcBusy=false;helperBusy=true
            let deferred=try await atomic.recoverForWake()
            check(!deferred && recoverCalls==0 && atomic.activeMode == .tun,"辅助服务已重建时客户端保留会话")
            helperBusy=false;race=true
            let raced=try await atomic.recoverForWake()
            check(!raced && recoverCalls==1 && atomic.activeMode == .tun,"状态查询后出现的辅助重建也不会被客户端停止")
            race=false;invalidRecovery=true
            do {_=try await atomic.recoverForWake();check(false,"辅助服务仍运行不能发布恢复完成")}
            catch let error as WakeRecoveryError {check(error.reason == .configuration && atomic.activeMode == .tun,"恢复响应必须确认已停止，不能仅凭成功文字清理控制状态")}
            invalidRecovery=false
            let released=try await atomic.recoverForWake()
            check(released && recoverCalls==3 && atomic.activeMode==nil && !atomic.helperRunning,"原子恢复成功才释放控制器进入下一次启动")
        }
        do {
            model.busy=false;model.stopRequested=false;model.state.captureMode = .tun;model.state.mode = .global
            model.state.networkBypasses=[];model.connection = .connected
            var reply=TunReply(ok:true,message:"只读夹具",running:true,routesVerified:true,dnsVerified:true,proxyVerified:true,protectionVerified:true,phase:"active")
            var occupied=false
            model.capture=CaptureController(core:model.core,proxy:model.proxy,helperRequest:{_ in if occupied {throw HelperRequestBusy()};return reply})
            model.wakeNetworkReady={true}
            model.wakeHTTPSProbe={_ in ConnectivityResult("按当前规则的 HTTPS 检测",.passed,"TLS 与 HTTP 已校验")}
            model.wakeIntent=(UUID(),model.eventSessionID,model.currentProfileID,model.epoch)
            func inspect(_ expected:WakeRecoveryCheck,_ message:String) async {let actual=await model.checkWakeSession();check(actual==expected,message)}
            for (port,expected) in [(18600,WakeRecoveryCheck.healthy),(18601,.stop(.authentication)),(18602,.inconclusive(.timeout)),(18603,.failed(.controlUnavailable)),(18605,.inconclusive(.unverified))] {
                let client=CoreAPIClient(context:CoreControlContext(port:port,secret:"fixture"),protocolClasses:[WakeModelProtocol.self]);model.api=client
                await inspect(expected,"正式复查适配器区分控制故障、节点未知和鉴权")
                await client.shutdown()
            }
            model.api=CoreAPIClient(context:CoreControlContext(port:18600,secret:"fixture"),protocolClasses:[WakeModelProtocol.self])
            occupied=true;await inspect(.helperRecovering,"辅助服务串行控制通道占用时继续等待而非累积未知失败")
            occupied=false
            reply.phase="networkReconnecting";await inspect(.helperRecovering,"辅助服务正在重建时不再探测业务")
            reply.phase="networkRetry";await inspect(.helperRecovering,"辅助服务等待网络快照时不发起第二次重连")
            reply.phase="networkProtectionFailed";await inspect(.stop(.ownershipConflict),"辅助保护失败立即退出竞争")
            reply.phase="active";reply.wakeRecoveryReason = .networkNotReady;reply.routesVerified=false
            await inspect(.failed(.networkNotReady),"唤醒路径暂缺不当作外部归属冲突")
            reply.wakeRecoveryReason = .ownershipConflict;await inspect(.stop(.ownershipConflict),"真实替换立即停止")
            reply.wakeRecoveryReason=nil;reply.networkNotReady=true;await inspect(.failed(.networkNotReady),"兼容旧暂态错误字段")
            reply.networkNotReady=nil;await inspect(.stop(.ownershipConflict),"缺少结构化暂态证据时保持保守")
            reply.routesVerified=nil;await inspect(.inconclusive(.unverified),"旧服务未返回核验值不能认领网络")
            reply.routesVerified=true;reply.running=false;await inspect(.stop(.configuration),"辅助会话已停止时不能发布恢复成功")
            reply.running=true;model.state.captureMode = .compatible;reply.proxyVerified=false
            await inspect(.stop(.ownershipConflict),"完整接管还核对系统代理所有权")
            reply.proxyVerified=true;model.wakeNetworkReady={false};await inspect(.failed(.networkNotReady),"物理网络延迟就绪进入确认而非冲突")
            model.wakeNetworkReady={true};model.busy=true;await inspect(.helperRecovering,"旧重建尚未收尾时不并发探测")
            model.busy=false;await model.api?.shutdown();model.api=nil;await inspect(.failed(.controlUnavailable),"控制客户端缺失不伪报节点失败")
            let cancelled=Task{@MainActor in await model.checkWakeSession()};cancelled.cancel()
            check(await cancelled.value == .inconclusive(.cancelled),"取消复查不关闭当前代理会话")
            for result in [WakeRecoveryCheck.failed(.nodeUnavailable),.stop(.authentication),.inconclusive(.unverified),.healthy] {
                let row:ConnectivityResult
                switch result {case .failed:row=ConnectivityResult("当前节点通道检测",.failed,"节点通道");case .stop:row=ConnectivityResult("路径",.failed,"鉴权");case .inconclusive:row=ConnectivityResult("路径",.failed,"超时");default:row=ConnectivityResult("路径",.passed,"")}
                check(model.wakeStartupError([row]) is WakeRecoveryError,"重建沿用结构化启动故障")
            }
            model.cancelWakeRecovery();model.connection = .disconnected
        }
        print("RESULT network_resume_model_assertions=\(assertions) failures=0")
    }
}
