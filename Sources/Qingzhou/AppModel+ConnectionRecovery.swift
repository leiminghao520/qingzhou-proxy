import Foundation
import SystemConfiguration
import QingzhouKit

extension AppModel {
    var effectiveState:AppState {guard let runtimeState else{return state};var current=state;current.captureMode=runtimeState.captureMode;current.dnsPreference=runtimeState.dnsPreference;return current}
    var connectionTitle:String {
        if recovering || connection == .disconnecting {return "正在恢复原网络设置"}
        if recoveryPending {return "网络恢复未完成，需要处理"}
        if networkWaiting {return networkReleased ? "等待网络恢复 · 汐航已停止接管":"等待网络恢复 · 将自动重连"}
        if wakeRecovery.active || networkReconnecting {return "正在自动恢复连接"}
        if selectionNetworkUncertain {return "网络状态待确认"}
        if connection == .connected,connectivityHealth != .healthy {return connectivityHealth == .unhealthy ? "当前线路检测异常":"已接管 · 网络待确认"}
        if connection == .connected,activeRecovery != nil {return "已连接 · 使用备用方案"}
        if networkReleased {return "汐航已停止接管，已恢复原网络设置"}
        if connection == .error {return issueTitle ?? "连接未完成，请检查网络"}
        return connection.rawValue
    }
    var effectivePathSummary:String {
        let current=effectiveState
        return current.captureMode.label+" · DNS："+(current.dnsPreference == .system ? "系统 DNS":"代理 HTTPS DNS")+" · "+(connection == .connected ? actualName:current.label(current.activePolicy))
    }
    func recoveryEnvironment()->String {
        if let read=dependencies.recoveryEnvironmentOverride {return read()}
        let dynamic=SCDynamicStoreCreate(nil,"汐航回退环境" as CFString,nil,nil)
        let services=BypassNetworkService.read().filter{$0.active && !CapturePlan.isVPN($0.interface) && $0.interface != "lo0"}.sorted{$0.id<$1.id}
        let parts=services.map{service -> String in
            let address=dynamic.flatMap{SCDynamicStoreCopyValue($0,("State:/Network/Service/"+service.id+"/IPv4") as CFString) as? [String:Any]}
            let address6=dynamic.flatMap{SCDynamicStoreCopyValue($0,("State:/Network/Service/"+service.id+"/IPv6") as CFString) as? [String:Any]}
            let dns=dynamic.flatMap{SCDynamicStoreCopyValue($0,("Setup:/Network/Service/"+service.id+"/DNS") as CFString) as? [String:Any]}
            let addresses=((address?["Addresses"] as? [String]) ?? [])+((address6?["Addresses"] as? [String]) ?? [])
            let routers=[address?["Router"] as? String,address6?["Router"] as? String].compactMap{$0}
            return ([service.id,service.interface]+addresses.sorted()+routers+((dns?["ServerAddresses"] as? [String]) ?? []).sorted()).joined(separator:":")
        }
        let helperDate=(try? FileManager.default.attributesOfItem(atPath:HelperPaths.directory+"/QingzhouHelper")[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return parts.joined(separator:"|")+"|"+BuildVersion.current+"|"+String(helperDate)
    }
    func fallbackPlan(for kind:ConnectionFailureKind,state:AppState)->RecoveryPlan? {
        var alternate=state
        switch kind {
        case .dns:
            guard state.dnsPreference == .httpsProxy,state.strictDNS != true,state.shadowrocket==nil else{return nil}
            alternate.dnsPreference = .system
        case .tunnel:
            guard state.captureMode.usesTunnel,(state.trustedCorporateDNS ?? []).isEmpty else{return nil}
            alternate.captureMode = .systemProxy
        default:return nil
        }
        return RecoveryPlan(alternate)
    }
    func verifyRecoverySafety(_ runtime:AppState,generation:UUID) async throws {
        if let verify=dependencies.recoveryReleasedOverride {try await verify()}else{try await capture.verifyReleasedForQuit()}
        try checkStartup(generation)
        if runtime.captureMode == .systemProxy {
            if let verify=dependencies.recoverySafetyOverride {try verify()}else{
                try NetworkSafety.check()
                try NetworkInspection.checkConflicts(routes:NetworkInspection.command("/usr/sbin/netstat",["-rn"]))
            }
        }
    }
    func startWithRecovery(_ next:AppState,generation:UUID,profileID:UUID?,attempt:(AppState) async throws -> Void) async throws {
        defer{networkReconnecting=false}
        stableRecoveryTask?.cancel();stableRecoveryTask=nil
        let key=ConnectionRecoveryStore.key(state:next,environment:recoveryEnvironment())
        let force=forceOriginalOnce;forceOriginalOnce=false
        let stored=recoveryStore.preferred(key:key,now:dependencies.now(),force:force)
        let preferred=stored.flatMap{fallbackPlan(for:$0.kind,state:next)==$0.plan ? $0:nil}
        runtimeState=nil;activeRecovery=nil
        if !force,let record=recoveryStore.records[key],!record.verified,dependencies.now()<record.retryAfter {
            throw ConnectionFailure(record.kind,"上次连接未能建立可用备用方案，已暂停重复尝试；可手动重试原方案，或等待至 "+record.retryAfter.formatted(date:.omitted,time:.standard))
        }
        if let preferred {
            startupStage="使用已验证的备用方案"
            log("回退复用 key=\(key) kind=\(preferred.kind.rawValue) failures=\(preferred.failures)")
            do {
                try await verifyRecoverySafety(preferred.plan.applying(to:next),generation:generation)
                try await attempt(preferred.plan.applying(to:next))
                try checkStartup(generation)
                guard connectivityHealth == .healthy else {throw ConnectionFailure(.unavailable,"备用方案连通性尚未验证")}
                runtimeState=preferred.plan.applying(to:next);activeRecovery=preferred
            }catch {
                if !(error is CancellationError) {try recoveryStore.unavailable(key:key,now:dependencies.now())}
                throw error
            }
            errorMessage=nil
            return
        }
        // 原方案重新验证期间仍保留备用及退避，防止观察期内崩溃后再次从零开始。
        let previousAttempt=recoveryStore.records[key]
        if let previousAttempt {try recoveryStore.failed(key:key,kind:previousAttempt.kind,plan:previousAttempt.plan,now:dependencies.now())}
        var firstKind:ConnectionFailureKind?
        do {
            do {try await attempt(next)} catch {
                try checkStartup(generation)
                let kind=ConnectionFailureKind.classify(error);firstKind=kind
                guard kind.retryable,!recoveryPending else{throw error}
                startupStage="正在恢复连接";networkReconnecting=true
                try await dependencies.recoveryWait(1)
                try checkStartup(generation)
                try await attempt(next)
            }
            try checkStartup(generation)
            runtimeState=next;errorMessage=nil
            if recoveryStore.records[key] != nil {observeStableOriginal(key:key,generation:generation)}
        } catch {
            try checkStartup(generation)
            let kind=ConnectionFailureKind.classify(error)
            guard kind.retryable,!recoveryPending,firstKind == nil || firstKind==kind else{throw error}
            guard let plan=fallbackPlan(for:kind,state:next) else {
                if previousAttempt?.kind != kind {try recoveryStore.failed(key:key,kind:kind,plan:RecoveryPlan(next),now:dependencies.now())}
                throw error
            }
            // 先持久化失败再尝试备用，进程意外退出也不会丢失退避计数。
            if previousAttempt?.kind != kind {try recoveryStore.failed(key:key,kind:kind,plan:plan,now:dependencies.now())}
            log("回退开始 key=\(key) kind=\(kind.rawValue)；"+Redactor.redact(error.localizedDescription))
            startupStage="正在连接备用方案"
            let alternate=plan.applying(to:next)
            do {
                try await verifyRecoverySafety(alternate,generation:generation)
                try await attempt(alternate)
                try checkStartup(generation)
                guard connectivityHealth == .healthy else {throw ConnectionFailure(.unavailable,"备用方案连通性尚未验证")}
                try recoveryStore.verified(key:key,now:dependencies.now())
                runtimeState=alternate;activeRecovery=recoveryStore.records[key];errorMessage=nil
                log("回退成功 key=\(key)；"+effectivePathSummary)
            }catch {
                if !(error is CancellationError) {try recoveryStore.unavailable(key:key,now:dependencies.now())}
                throw error
            }
        }
    }
    func observeStableOriginal(key:String,generation:UUID) {
        stableRecoveryTask=Task { @MainActor [weak self] in
            var stableSeconds=0
            while !Task.isCancelled {
                do {try await self?.dependencies.recoveryWait(1)}catch{return}
                guard let self,self.startupGeneration==generation,self.connection == .connected,!self.recoveryPending else{return}
                let healthy = (self.dependencies.recoveryRuntimeHealthyOverride?() ?? self.capture.running) && !self.coreFailed && !self.wakeRecovery.active && !self.networkReconnecting && !self.networkRechecking && !self.healthPower.suspended && self.connectivityHealth == .healthy
                stableSeconds=healthy ? stableSeconds+1:0
                guard stableSeconds>=60 else{continue}
                do {try self.recoveryStore.stableOriginal(key:key);self.log("原方案已稳定运行 60 秒，解除回退 key="+key)}catch{self.log("回退记录清理失败："+error.localizedDescription)}
                return
            }
        }
    }
    func retryOriginal() async {
        guard !locked else{return}
        busy=true
        await cancelWakeRecoveryAndWait()
        do {if connection == .connected {try await disconnectInternal(preserveExternal:true)}}catch{busy=false;report(error);return}
        forceOriginalOnce=true
        busy=false
        await connect()
    }
    func adoptRecovery() {
        guard !locked,connection == .connected,let current=runtimeState,let record=activeRecovery else{return}
        do {
            var next=state;next.captureMode=current.captureMode;next.dnsPreference=current.dnsPreference
            try persist(next)
            try recoveryStore.stableOriginal(key:record.key)
            activeRecovery=nil;log("用户已采用当前备用方案")
        }catch{report(error)}
    }
}
