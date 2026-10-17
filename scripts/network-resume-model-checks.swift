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
        print("RESULT network_resume_model_assertions=\(assertions) failures=0")
    }
}
