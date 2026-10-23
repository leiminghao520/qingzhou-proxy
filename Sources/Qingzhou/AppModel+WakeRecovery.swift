import Foundation
import QingzhouKit

extension AppModel {
    func cancelWakeRecovery() {
        wakeRecovery.cancel();wakeIntent=nil;wakeNeedsRebuild=false
        wakeRecoveryStatus=WakeRecoveryStatus(.idle)
    }
    func cancelWakeRecoveryAndWait() async {
        wakeIntent=nil;wakeNeedsRebuild=false
        await wakeRecovery.cancelAndWait()
        wakeRecoveryStatus=WakeRecoveryStatus(.idle)
    }
    func wakeStartupError(_ results:[ConnectivityResult])->Error {
        switch WakeRecoveryCheck.connectivity(results) {
        case .failed(let reason),.stop(let reason),.inconclusive(let reason):return WakeRecoveryError(reason)
        default:return WakeRecoveryError(.unverified)
        }
    }
    func beginWakeRecovery() {
        guard let intent=wakeIntent,!wakeRecovery.active,!healthPower.suspended,healthDisplayAwake() else{return}
        recordEvent(.network,.changed,.systemWake,recoveryID:intent.id,originalSessionID:intent.session)
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
                self.wakeIntent=nil;self.errorMessage=status.label
                Task { @MainActor [weak self] in await Task.yield();self?.drainPendingDisconnect() }
            }
            if status.phase == .recovered {self.wakeIntent=nil;self.coreFailed=false;self.helperFailureReason=nil;self.failedHealthCycles=0;self.healthFailures=HealthFailureCounter()}
        }
        var recoveryToken:UUID?
        wakeRecovery.start(id:intent.id,stableDelay:healthPower.remaining(uptime:healthPowerUptime()),isCurrent:{ [weak self] in
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
        if wakeNeedsRebuild {
            do {try NetworkSafety.check();try NetworkInspection.checkConflicts(routes:NetworkInspection.command("/usr/sbin/netstat",["-rn"]))}
            catch {return .stop(.ownershipConflict)}
            return .failed(.networkNotReady)
        }
        if state.captureMode.usesTunnel || capture.helperRunning {
            do {
                let status=try await capture.wakeStatus()
                if status.networkReconnecting || (status.phase=="networkRetry" && state.pinnedBypasses.isEmpty) {return .helperRecovering}
                if let reason=status.wakeRecoveryReason {return reason.terminal ? .stop(reason):.failed(reason)}
                if status.phase=="networkProtectionFailed" {return .stop(.ownershipConflict)}
                if status.networkNotReady==true {return .failed(.networkNotReady)}
                // 旧辅助服务缺少核验结果时不能据此认领或重建网络。
                if status.running && state.captureMode.usesTunnel {
                    let checks=[status.routesVerified,status.dnsVerified,status.protectionVerified]+(state.captureMode == .compatible ? [status.proxyVerified]:[])
                    if checks.contains(where:{$0==false}) {return .stop(.ownershipConflict)}
                    if checks.contains(where:{$0==nil}) {return .inconclusive(.unverified)}
                    if !wakeNetworkReady() {return .failed(.networkNotReady)}
                } else if !status.running {return .stop(.configuration)}
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
        async let path=wakeHTTPSProbe(state.captureMode.usesTunnel ? nil:state.listenPort)
        async let node=ConnectivityProbe.wakeNode(client:client,mode:state.mode)
        let results=await [path,node]
        guard !Task.isCancelled,wakeRecovery.id==recoveryToken,epoch==connectionToken,!healthPower.suspended,healthDisplayAwake(),wakeIntent != nil else{return .inconclusive(.cancelled)}
        connectivityResults=results;reachability=ConnectivityResult.combinedSummary(results)
        return .connectivity(results)
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
