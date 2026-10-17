import AppKit
import QingzhouKit

@main struct NetworkResumeModelChecks {
    @MainActor static func main() async throws {
        let model = AppModel()
        guard !model.loadingFailed else { fatalError("隔离模型初始化失败") }
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            assertions += 1
            if !condition { fatalError(message) }
        }
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
        print("RESULT network_resume_model_assertions=\(assertions) failures=0")
    }
}
