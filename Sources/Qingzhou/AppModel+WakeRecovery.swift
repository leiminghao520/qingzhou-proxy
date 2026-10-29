import Foundation
import QingzhouKit

extension AppModel {
    func cancelWakeRecovery() {
        networkWaiting=false
        wakeRecovery.cancel();wakeIntent=nil;wakeNeedsRebuild=false;routineRecovery=false
        wakeRecoveryStatus=WakeRecoveryStatus(.idle)
    }
    func cancelWakeRecoveryAndWait() async {
        networkWaiting=false
        wakeIntent=nil;wakeNeedsRebuild=false;routineRecovery=false
        await wakeRecovery.cancelAndWait()
        wakeRecoveryStatus=WakeRecoveryStatus(.idle)
    }
    func beginRoutineRecovery(reason:WakeRecoveryReason) {
        guard connection == .connected,!locked,!wakeRecovery.active,wakeIntent==nil else{return}
        cancelHealthRefresh()
        errorMessage=nil
        routineRecovery=true
        wakeIntent=(UUID(),eventSessionID,currentProfileID,epoch)
        log("日常连接进入自动恢复："+reason.label)
        beginWakeRecovery()
    }
    func finishRoutineRecovery(_ status:WakeRecoveryStatus,epoch token:UUID) async {
        await wakeRecovery.waitUntilFinished()
        guard epoch==token,wakeRecoveryStatus==status,!stopRequested,!busy else{return}
        // 未知检测只降级；指定出口不可用时保留拒绝保护，不能恢复成其他出口。
        if connection == .connected,[.unverified,.timeout,.helperRecovery].contains(status.reason) {
            wakeRecoveryStatus=WakeRecoveryStatus(.idle)
            monitor.health="连接暂无法确认，保留会话继续复查"
            return
        }
        if status.reason == .exitUnavailable {userWantsConnection=false;networkWaiting=false;return}
        userWantsConnection=false;networkWaiting=false
        busy=true;wakeRebuilding=true;defer{wakeRebuilding=false;busy=false}
        do {
            try await disconnectInternal(preserveExternal:true)
            try await verifyConnectionReleased();networkReleased=true
            wakeRecoveryStatus=status
            connection = .error
            errorMessage=status.label+"；已释放轻舟接管，外部网络已保留"
        }catch{recoveryPending=true;wakeRecoveryStatus=status;report(error)}
    }
    func wakeStartupError(_ results:[ConnectivityResult])->Error {
        if results.contains(where:{$0.status == .failed && $0.category == "DNS"}) {return ConnectionFailure(.dns,"实际连接的 DNS 解析失败")}
        switch WakeRecoveryCheck.connectivity(results) {
        case .failed(let reason),.stop(let reason),.inconclusive(let reason):return WakeRecoveryError(reason)
        default:return WakeRecoveryError(.unverified)
        }
    }
    func beginWakeRecovery() {
        guard let intent=wakeIntent,!wakeRecovery.active,!healthPower.suspended,healthDisplayAwake() else{return}
        if !routineRecovery {recordEvent(.network,.changed,.systemWake,recoveryID:intent.id,originalSessionID:intent.session)}
        wakeRecovery.changed={ [weak self] status,id in
            guard let self else{return}
            self.wakeRecoveryStatus=status
            let reason:NetworkEventReason
            switch status.phase {
            case .waiting:return
            case .checking:reason = .wakeCheckFailed
            case .retryWaiting:reason = .wakeRetryWaiting
            case .rebuilding:reason = .reconnecting
            case .recovered:reason = .wakeRecovered
            case .manual,.cancelled:reason = .wakeStopped
            case .idle:return
            }
            // 检查开始不是失败事件；只在有结论的阶段记录转折。
            if status.phase != .checking {
                self.timeline.record(NetworkEvent(sessionID:self.eventSessionID,profileID:self.currentProfileID,category:.recovery,outcome:status.phase == .recovered ? .succeeded:status.phase == .manual ? .failed:status.phase == .cancelled ? .cancelled:.started,reason:reason,recoveryID:id,originalSessionID:intent.session,recoveryReason:status.reason,recoveryAttempt:status.attempt,time:self.dependencies.now()))
            }
            if status.phase == .manual {
                let routine=self.routineRecovery,token=self.epoch
                self.wakeIntent=nil;self.routineRecovery=false
                let uncertain=routine && self.connection == .connected && [.unverified,.timeout,.helperRecovery].contains(status.reason)
                self.errorMessage=uncertain ? nil:status.label
                self.recoveryFinishTask=Task { @MainActor [weak self] in await self?.finishRoutineRecovery(status,epoch:token) }
            }
            if status.phase == .recovered {self.routineRecovery=false;self.wakeIntent=nil;self.networkWaiting=false;self.networkReleased=false;self.coreFailed=false;self.helperFailureReason=nil;self.failedHealthCycles=0;self.healthFailures=HealthFailureCounter();self.exitHealth=ExitHealthTracker()}
        }
        var recoveryToken:UUID?
        wakeRecovery.start(id:intent.id,stableDelay:healthPower.remaining(uptime:healthPowerUptime()),maxRebuildAttempts:3,isCurrent:{ [weak self] in
            guard let self else{return false}
            return self.wakeIntent != nil && self.currentProfileID==intent.profile && !self.stopRequested && !self.healthPower.suspended && self.healthDisplayAwake()
        },check:{ [weak self] in
            guard let self else{return .inconclusive(.cancelled)}
            let result:WakeRecoveryCheck
            if let check=self.wakeCheckOverride {result=await check()} else {result=await self.checkWakeSession()}
            if case .failed(let reason)=result,!Task.isCancelled,let id=self.wakeRecovery.id,id==recoveryToken {
                self.timeline.record(NetworkEvent(sessionID:self.eventSessionID,profileID:self.currentProfileID,category:.recovery,outcome:.failed,reason:.wakeCheckFailed,recoveryID:id,originalSessionID:intent.session,recoveryReason:reason,recoveryAttempt:self.wakeRecovery.status.attempt,time:self.dependencies.now()))
            }
            return result
        },rebuild:{ [weak self] in
            guard let self else{return .stop(.cancelled)}
            if let run=self.wakeRebuildOverride {return await run()}
            return await self.rebuildWakeSession()
        })
        recoveryToken=wakeRecovery.id
    }
    func checkWakeSession() async -> WakeRecoveryCheck {
        guard !Task.isCancelled else{return .inconclusive(.cancelled)}
        let recoveryToken=wakeRecovery.id,connectionToken=epoch
        if busy || wakeRebuilding {return .helperRecovering}
        if !state.pinnedBypasses.isEmpty {
            let services=BypassNetworkService.read()
            guard state.pinnedBypasses.allSatisfy({item in services.contains{$0.id==item.serviceID && $0.active}}) else{return .stop(.exitUnavailable)}
        }
        if !wakeNetworkReady() {return await releaseWhileWaitingForNetwork()}
        networkWaiting=false
        if wakeNeedsRebuild {
            do {try NetworkSafety.check();try NetworkInspection.checkConflicts(routes:NetworkInspection.command("/usr/sbin/netstat",["-rn"]))}
            catch {return .stop(.ownershipConflict)}
            return .failed(.controlUnavailable)
        }
        if effectiveState.captureMode.usesTunnel || capture.helperRunning {
            do {
                let status=try await capture.wakeStatus()
                if status.wakeRecoveryReason != nil {log("唤醒网络核验："+Redactor.redact(status.message))}
                if status.networkReconnecting || (status.phase=="networkRetry" && state.pinnedBypasses.isEmpty) {return .helperRecovering}
                if let reason=status.wakeRecoveryReason {
                    if [.unverified,.timeout].contains(reason) {return .inconclusive(reason)}
                    if reason == .helperRecovery {return .helperRecovering}
                    return reason.terminal ? .stop(reason):.failed(reason)
                }
                if status.phase=="networkProtectionFailed" {return .stop(.ownershipConflict)}
                if status.networkNotReady==true {return .failed(.networkNotReady)}
                // 旧辅助服务缺少核验结果时不能据此认领或重建网络。
                if status.running && effectiveState.captureMode.usesTunnel {
                    let checks=[status.routesVerified,status.dnsVerified,status.protectionVerified]+(effectiveState.captureMode == .compatible ? [status.proxyVerified]:[])
                    // 旧服务的失败布尔值不能证明外部所有权；保持会话且不据此重建。
                    if checks.contains(where:{$0==false}) {return .inconclusive(.unverified)}
                    if checks.contains(where:{$0==nil}) {return .inconclusive(.unverified)}
                    if !wakeNetworkReady() {return .failed(.networkNotReady)}
                } else if !status.running {return .stop(.configuration)}
                if effectiveState.captureMode == .systemProxy,status.supportsManagedSystemProxy==true,status.proxyVerified != true {return .stop(.ownershipConflict)}
            }catch is HelperRequestBusy {return .helperRecovering}
            catch{return .inconclusive(.unverified)}
        } else {
            do {
                let table=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
                if NetworkInspection.conflicts(vpn:"",routes:table,proxies:[:]) != nil {return .stop(.ownershipConflict)}
                try await proxy.verifyWakeOwnership()
                if !wakeNetworkReady() {return .failed(.networkNotReady)}
            }catch{return .stop(.ownershipConflict)}
        }
        guard !Task.isCancelled,wakeRecovery.id==recoveryToken else{return .inconclusive(.cancelled)}
        guard let client=api else{return .failed(.controlUnavailable)}
        do {_ = try await client.proxies()}
        catch let error as CoreAPIError {
            if error.category=="鉴权" {return .stop(.authentication)}
            if error.category=="超时" || error.category=="取消" {return .inconclusive(.timeout)}
            return .failed(.controlUnavailable)
        }catch{return .inconclusive(.unverified)}
        async let path=wakeHTTPSProbe(effectiveState.captureMode.usesTunnel ? nil:state.listenPort)
        async let node=ConnectivityProbe.wakeNode(client:client,mode:state.mode)
        let results=await [path,node]
        guard !Task.isCancelled,wakeRecovery.id==recoveryToken,epoch==connectionToken,!healthPower.suspended,healthDisplayAwake(),wakeIntent != nil else{return .inconclusive(.cancelled)}
        connectivityResults=results;reachability=ConnectivityResult.combinedSummary(results)
        return StartupConnectivityPolicy.recovery(results)
    }
    func rebuildWakeSession() async -> WakeRecoveryCheck {
        guard !busy,!stopRequested,!Task.isCancelled else{return .inconclusive(.cancelled)}
        busy=true;wakeRebuilding=true
        defer {wakeRebuilding=false;busy=false}
        do {
            // 恢复必须成功才能重新接管；恢复冲突不进入下一次自动尝试。
            do {guard try await capture.recoverForWake() else{return .helperRecovering}}
            catch let error as WakeRecoveryError {return .stop(error.reason)}
            catch {recoveryPending=true;connection = .error;return .stop(.ownershipConflict)}
            stopTelemetry()
            try Task.checkCancellation()
            connection = .connecting
            try await startService(state)
            try Task.checkCancellation()
            guard SelectionConnectivityPolicy.evaluate(connectivityResults,requiresNode:state.mode != .direct && state.activePolicy != .direct) == .verified else {
                let result=WakeRecoveryCheck.connectivity(connectivityResults)
                try await disconnectInternal(preserveExternal:true)
                try await verifyConnectionReleased();networkReleased=true;wakeNeedsRebuild=true
                return result == .healthy ? .inconclusive(.unverified):result
            }
            wakeNeedsRebuild=false
            return .healthy
        } catch {
            if error is CancellationError {if capture.running {connection = .connected} else if wakeIntent != nil {wakeNeedsRebuild=true};return .inconclusive(.cancelled)}
            wakeNeedsRebuild=true
            connection = .error
            if error is NetworkEnvironmentNotReady {return .failed(.networkNotReady)}
            if let error=error as? WakeRecoveryError {return error.reason.terminal ? .stop(error.reason):.failed(error.reason)}
            return .stop(.configuration)
        }
    }
}
