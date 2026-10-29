import Foundation
import Darwin
import SwiftUI
import AppKit
import CoreImage
import ServiceManagement
import SystemConfiguration
import QingzhouKit

@MainActor final class AppModel:ObservableObject {
    enum Connection:String {case disconnected="未连接",connecting="连接中",connected="已连接",disconnecting="断开中",error="错误"}
    @Published var activeBypasses:[NetworkBypass]?
    @Published var bypassApplyFailure:String?
    @Published var pendingMode:ProxyMode?
    let office=OfficeDashboardModel()
    var officeNetworkID=UUID()
    var officeHelperDNSSignature:Data?
    let connectionRefreshSignal=OfficeRefreshSignal()
    let policyRefreshSignal=OfficeRefreshSignal()
    var connectionsPageVisible=false
    var telemetryRefreshRequested=false
    var policyRefreshRequested=false
    var policyTask:Task<Void,Never>?
    var connectionListTask:Task<Void,Never>?
    @Published var selectionStatus:SelectionStatus?
    @Published var measurementCancelling=false
    @Published var state=AppState()
    @Published private(set) var connectedSince: Date?
    @Published var connection=Connection.disconnected {didSet{if connection != oldValue {connectedSince = connection == .connected ? dependencies.now() : nil};if connection != oldValue {invalidateDiagnostic();invalidateOfficeResults();if connection == .connected {publishOfficeConnectivity()}}}}
    @Published var startupStage:String?
    @Published var startupStartedAt:TimeInterval?
    var startupGeneration=UUID()
    @Published var runtimeState:AppState?
    @Published var activeRecovery:ConnectionRecoveryRecord?
    var noticeTask:Task<Void,Never>?
    var stableRecoveryTask:Task<Void,Never>?
    var forceOriginalOnce=false
    var helperAuthorizationAttempted=false
    lazy var recoveryStore=ConnectionRecoveryStore(url:directory.appendingPathComponent("connection-recovery.json"))
    private var startupClient:CoreAPIClient?
    private var startupProbeTask:Task<[ConnectivityResult],Never>?
    @Published var wakeRecoveryStatus=WakeRecoveryStatus(.idle)
    @Published var userWantsConnection=false
    @Published var networkWaiting=false
    @Published var networkReleased=false
    var lastAutomaticRefresh=Date.distantPast
    var automaticRefreshRequested=true
    var wakeRecovery=WakeRecoveryCoordinator()
    var wakeIntent:(id:UUID,session:UUID,profile:UUID?,epoch:UUID)?
    var routineRecovery=false
    var wakeRebuilding=false
    var wakeNeedsRebuild=false
    var wakeCheckOverride:(() async -> WakeRecoveryCheck)?
    var connectivityProbe:(Int?,CoreAPIClient,ProxyMode) async -> [ConnectivityResult] = {await ConnectivityProbe.all(port:$0,client:$1,mode:$2)}
    var wakeHTTPSProbe:(Int?) async -> ConnectivityResult = {await ConnectivityProbe.https(port:$0,entry:false)}
    var wakeNetworkReady:()->Bool = {BypassNetworkService.read().contains{$0.active && !CapturePlan.isVPN($0.interface) && $0.interface != "lo0"}}
    var wakeRebuildOverride:(() async -> WakeRecoveryCheck)?
    var recoveryFinishTask:Task<Void,Never>?
    @Published var reachability="尚未检测"
    @Published var connectivityResults:[ConnectivityResult]=[] {didSet{publishOfficeConnectivity()}}
    var connectivityHealth:ConnectivityHealth {ConnectivityHealth.evaluate(connectivityResults)}
    var linkStatusLabel:String {
        if wakeRecovery.active {return "自动恢复中"}
        if wakeRecoveryStatus.phase == .manual {return "需手动处理"}
        switch connectivityHealth {
        case .healthy:return "链路正常"
        case .unhealthy:return "检测降级"
        case .checking:return "检测中"
        case .unknown:return "尚未验证"
        }
    }
    @Published var networkReconnecting = false {didSet{if networkReconnecting != oldValue {invalidateDiagnostic();invalidateOfficeResults(network:true)}}}
    var networkRechecking:Bool {networkReconnecting || (connection == .connected && state.captureMode.usesTunnel && helperStatus == "网络变化，正在重新检查")}
    var connectionSummary:String {
        if networkWaiting {return connectionTitle}
        if wakeRecovery.active || wakeRecoveryStatus.phase == .manual {return wakeRecoveryStatus.label}
        if connection == .connected,activeRecovery != nil {return "已连接 · 使用备用方案"}
        if connection == .connecting {return "连接中 · "+(startupStage ?? "准备网络与核心")}
        if networkReconnecting {return "网络恢复中 · 正在自动重连"}
        if networkRechecking {return "已连接 · 网络变化，正在重新检查"}
        return connectionTitle
    }
    @Published var busy=false {didSet{if busy{cancelHealthRefresh();healthRefreshPending=true}else{drainPendingDisconnect()}}}
    @Published var healthChecking=false
    @Published var recovering=false
    @Published var stopRequested=false
    @Published var latencyInvalidatedAt=Date()
    @Published var latencyClock=Date()
    private let healthScheduler=HealthRefreshScheduler()
    var healthRefreshKey:String?
    private var pendingRecovery=false
    var canStop:Bool {!loadingFailed && !recovering && !stopRequested && connection != .disconnecting}
    var stopDisabled:Bool {hasConnectionActivity ? !canStop:locked}
    @Published var measuring=false {didSet{if !measuring{drainPendingDisconnect()}}}
    @Published var measurementProgress=""
    @Published var issueTitle:String?
    @Published var errorMessage:String? {didSet{if errorMessage != oldValue {issueTitle=errorMessage.map{ConnectionFailureKind.classify(ProxyError($0)).label}}}}
    let drafts=SessionDraftStore()
    let logBuffer = RuntimeLogBuffer()
    @Published var preview:ImportPreview?
    @Published var previewDiff:UpdateDiff?
    let trafficDisplay=OfficeTrafficDisplay()
    var rateHistory:[RateSample] {get{trafficDisplay.sample.history}set{trafficDisplay.sample.history=newValue}}
    @Published var trafficByNode:[String:Int64]=[:]
    @Published var trafficByTarget:[String:Int64]=[:]
    var observedConnections:[String:Int64]=[:]
    private let shortcuts=ShortcutController()
    @Published var throughputResult:ThroughputResult?
    @Published var throughputBytes:Int64=0
    @Published var throughputRunning=false
    @Published var throughputError:String?
    var throughputTask:Task<Void,Never>?
    var throughputProbe:ThroughputProbe?
    var throughputGeneration=UUID()
    @Published var diagnosticRows:[DiagnosticResult]=[]
    @Published var diagnosing=false
    @Published var diagnosticSession:DiagnosticSession?
    var diagnosticTask:Task<DiagnosticSession,Never>?
    @Published var diagnosticGeneration=UUID()
    @Published var historyStatus:String?
    lazy var profileHistory=ProfileHistoryStore(directory:directory.appendingPathComponent("ProfileHistory"),credentials:store?.credentials ?? credentials,now:dependencies.now)
    let timeline:NetworkTimelineModel
    var eventSessionID=UUID()
    var activeHistoryTransactionID:UUID?
    var fallbackStates:[UUID:FallbackController]=[:]
    var healthTask:Task<Void,Never>?
    var failedHealthCycles=0
    var healthFailures=HealthFailureCounter()
    var exitHealth=ExitHealthTracker()
    @Published var recoveryPending=false
    @Published var loadingFailed=false
    var uploadRate:Int64 {get{trafficDisplay.sample.upload}set{trafficDisplay.sample.upload=newValue}}
    var downloadRate:Int64 {get{trafficDisplay.sample.download}set{trafficDisplay.sample.download=newValue}}
    @Published var uploadTotal:Int64=0
    @Published var downloadTotal:Int64=0
    @Published var connections:[CoreConnection]=[]
    @Published var proxyInfo:[String:ProxyInfo]=[:]
    @Published var monitorPaused=false
    @Published var monitor = RuntimeMonitorState()
    var monitorStatus: String { monitor.summary }
    var uploadRateText: String { monitor.rateLabel(uploadRate, paused: monitorPaused, format: formatRate) }
    var downloadRateText: String { monitor.rateLabel(downloadRate, paused: monitorPaused, format: formatRate) }
    private(set) var store:NodeStore?
    let credentials:any CredentialStore
    let core:CoreController
    let proxy:SystemProxyController
    let directory:URL
    lazy var capture=CaptureController(core:core,proxy:proxy)
    @Published var helperStatus="未检测"
    @Published var protectionSummary:[String]=[]
    var api:CoreAPIClient?
    var verifiedSelectionTag:String?
    var connectivityEpoch=UUID()
    var telemetryTask:Task<Void,Never>?
    var trafficTask:Task<Void,Never>?
    private var maintenanceTask:Task<Void,Never>?
    var transientRefreshPending=false
    var nextHistoryMaintenance=Date.distantPast
    private var measurementTask:Task<Void,Never>?
    private var temporaryCore:CoreController?
    private var temporaryAPI:CoreAPIClient?
    var epoch=UUID() {didSet {if epoch != oldValue {invalidateDiagnostic();invalidateOfficeResults();if !wakeRebuilding {cancelWakeRecovery()}}}}
    private var networkChanged=false
    var coreFailed=false
    var helperFailureReason:String?
    private var sessionLockFD:Int32 = -1
    var pendingSubscription:Subscription?
    private var started=false
    private var powerObservers:[NSObjectProtocol]=[]
    private(set) var healthPower=HealthPowerState()
    var healthDisplayAwake:() -> Bool = {CGDisplayIsAsleep(CGMainDisplayID())==0}
    var healthPowerUptime:() -> TimeInterval = {TimeInterval(DispatchTime.now().uptimeNanoseconds)/1_000_000_000}
    var healthRefreshPending=false
    // 只读复查和重连退避不锁住界面；实际重建仍由 busy 串行保护，用户可随时换线或停止。
    var locked:Bool {busy || measuring || loadingFailed || recovering || stopRequested || networkReconnecting}
    var selected:Node? {if case .node(let id)=state.activePolicy {return state.nodes.first{$0.id==id}};return nil}
    var selectedName:String {state.label(state.activePolicy)}
    var actualName:String {if state.mode == .direct{return "直连"};guard let tag=CoreAPIClient.actualTag(proxyInfo) else {return "尚未检测"};return label(tag)}
    var allNodesUnavailable:Bool { !state.nodes.isEmpty && state.nodes.allSatisfy{proxyInfo[PolicyReference.node($0.id).tag]?.history?.last == nil} }
    let dependencies:AppDependencies
    let history:TrafficHistoryModel
    init(dependencies:AppDependencies = AppDependencies()) {
        self.dependencies=dependencies
        var isolated=false
        // 独立测试目录由启动参数显式指定，不改变日常配置位置。
        if let index=CommandLine.arguments.firstIndex(of:"--test-directory"),index+1<CommandLine.arguments.count,CommandLine.arguments[index+1].hasPrefix("/") {
            directory=URL(fileURLWithPath:CommandLine.arguments[index+1]);isolated=true
        }else{directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Qingzhou")}
        credentials=dependencies.makeCredentials(isolated)
        timeline=NetworkTimelineModel(url:directory.appendingPathComponent("network-events.jsonl"),now:dependencies.now,autoload:false)
        history=TrafficHistoryModel(url:directory.appendingPathComponent("traffic-history.sqlite"),now:dependencies.now,makeStore:dependencies.makeHistory)
        core=CoreController(directory:directory);proxy=SystemProxyController(journal:directory.appendingPathComponent("proxy-recovery.json"))
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            sessionLockFD=open(directory.appendingPathComponent("session.lock").path,O_CREAT|O_RDWR,0o600)
            if sessionLockFD>=0 {_ = fcntl(sessionLockFD,F_SETFD,FD_CLOEXEC)}
            guard sessionLockFD>=0,flock(sessionLockFD,LOCK_EX|LOCK_NB)==0 else {throw ProxyError("应用已经运行")}
            store=try dependencies.makeStore(directory.appendingPathComponent("state.json"),credentials);state=store!.state
        } catch {loadingFailed=true;errorMessage="配置无法读取或应用已运行，未覆盖原文件。";return}
        helperAuthorizationAttempted=FileManager.default.fileExists(atPath:directory.appendingPathComponent("helper-authorization-requested").path)
        timeline.activate()
        if let store {store.history=profileHistory;do{try CredentialAuthorization.$allowsInteraction.withValue(false) {try profileHistory.initialize(store.catalog)}}catch{historyStatus=profileHistory.lastError}}
        logBuffer.configure(url:directory.appendingPathComponent("diagnostic.log"))
        log("应用启动，正在检查上次恢复记录")
        recoveryPending=proxy.hasRecovery
        core.log={ [weak self] in self?.log($0) }
        proxy.log={ [weak self] in self?.log($0) }
        core.onUnexpectedExit={ [weak self] in guard let self else{return};self.recordEvent(.connection,.failed,.coreExited);if self.wakeIntent==nil && !self.wakeRecovery.active {self.stopTelemetry()};self.coreFailed=true;self.cancelMeasurement();self.drainPendingDisconnect() }
        proxy.onNetworkChange={ [weak self] in guard let self,self.connection == .connected || self.connection == .connecting else{return};self.cancelWakeRecovery();self.recordEvent(.network,.changed,.ownershipChanged);self.networkChanged=true;self.cancelMeasurement();self.drainPendingDisconnect() }
        proxy.onEnvironmentChange={ [weak self] in self?.networkEnvironmentChanged() }
        proxy.startMonitoring()
        for (name,event) in [(NSWorkspace.willSleepNotification,HealthPowerEvent.willSleep),
                             (NSWorkspace.didWakeNotification,.didWake),
                             (NSWorkspace.screensDidSleepNotification,.screensSleep),
                             (NSWorkspace.screensDidWakeNotification,.screensWake)] {
            powerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in
                Task{@MainActor in
                    self?.handleHealthPowerEvent(event)
                    // 补偿屏幕通知缺失或先后顺序不同；后台维护唤醒时实际屏幕仍处于睡眠。
                    if case .didWake=event,CGDisplayIsAsleep(CGMainDisplayID())==0 {self?.handleHealthPowerEvent(.screensWake)}
                }
            })
        }
        shortcuts.action={ [weak self] in Task{@MainActor in guard let self else{return};if self.connection == .connected{await self.disconnect()}else{await self.connect()}}}
        synchronizeShortcut()
        // 只有持有实例锁的应用才清理自己上次遗留的敏感运行文件。
        if let files=try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {for file in files where file.lastPathComponent.hasPrefix("runtime-") || file.lastPathComponent.hasPrefix("check-") {try? FileManager.default.removeItem(at:file)}}
    }
    // 测速或配置更新期间的退出和网络变更延后串行恢复，避免被操作锁跳过。
    func drainPendingDisconnect() {
        guard !busy,!measuring,!loadingFailed else{return}
        if (wakeRecovery.active || wakeIntent != nil) && !stopRequested && !pendingRecovery && !networkChanged {return}
        if pendingRecovery {pendingRecovery=false;Task{await self.performRecovery()};return}
        if stopRequested {busy=true;Task{defer{stopRequested=false;busy=false};do{try await disconnectInternal()}catch{report(error)}};return}
        guard connection == .connected,!recovering else{return}
        if !coreFailed && !networkChanged {
            if healthRefreshPending {healthRefreshPending=false;scheduleHealthRefresh()}
            return
        }
        if coreFailed,helperFailureReason==nil {
            beginRoutineRecovery(reason:.controlUnavailable)
            wakeNeedsRebuild=true
            return
        }
        let failureReason=helperFailureReason;helperFailureReason=nil
        let failed=coreFailed;log(failed ? (failureReason == nil ? "自动断开原因：核心或兼容层退出":"自动断开原因：辅助服务网络恢复失败"):"自动断开原因：网络所有权变化");coreFailed=false;networkChanged=false;busy=true
        Task {defer{busy=false};do{try await disconnectInternal();if failed{connection = .error};errorMessage=failed ? (failureReason.map{"辅助服务停止连接："+$0} ?? "核心异常退出，已恢复系统代理") : "网络服务发生变化，已断开，请重新连接"}catch{report(error)}}
    }
    func label(_ tag:String) -> String {
        if tag=="auto"{return "自动选择"};if tag=="direct"{return "直连"};if tag=="proxy"{return "当前选择"}
        if let node=state.nodes.first(where:{PolicyReference.node($0.id).tag==tag}){return node.name}
        if let group=state.groups.first(where:{PolicyReference.group($0.id).tag==tag}){return group.name}
        return "未知出站"
    }
    func log(_ text:String) {logBuffer.append(text,secrets:core.secrets)}
    func report(_ error:Error) {
        if error is CancellationError{return}
        let detail=Redactor.redact(error.localizedDescription)
        guard errorMessage != detail else{return}
        errorMessage=detail;issueTitle=ConnectionFailureKind.classify(error).label;log(detail)
        noticeTask?.cancel()
        // 连接故障保持可操作入口，已连接时的单次操作错误八秒后收起。
        if connection == .connected,!recoveryPending {
            noticeTask=Task { @MainActor [weak self] in
                do{try await Task.sleep(nanoseconds:8_000_000_000)}catch{return}
                guard let self,self.errorMessage==detail,self.connection == .connected,!self.recoveryPending else{return}
                self.errorMessage=nil
            }
        }
    }

    func persist(_ next:AppState) throws {
        guard let store else {throw ProxyError("配置未加载")}
        defer {historyStatus=profileHistory.lastError}
        try store.commit(next);state=store.state;errorMessage=nil
    }
    private func secrets(_ next:AppState,_ control:CoreControlContext) -> [String] {
        CredentialAuthorization.$allowsInteraction.withValue(false) {
            [control.secret]+next.nodes.flatMap{[(try? credentials.get($0.credentialRef)) ?? "",(try? credentials.get($0.credentialRef+".obfs")) ?? ""]}
        }
    }
    func checkStartup(_ generation:UUID) throws {
        try Task.checkCancellation()
        guard startupGeneration==generation,!stopRequested,!pendingRecovery else {throw CancellationError()}
    }
    private func startupProbes(port:Int?,client:CoreAPIClient,mode:ProxyMode,generation:UUID) async throws -> [ConnectivityResult] {
        let task=Task {await self.connectivityProbe(port,client,mode)}
        startupProbeTask=task
        defer {startupProbeTask=nil}
        let results=await withTaskCancellationHandler(operation:{await task.value},onCancel:{task.cancel()})
        try checkStartup(generation)
        return results
    }
    func startService(_ next:AppState,profileID:UUID?=nil) async throws {
        invalidateDiagnostic();eventSessionID=UUID();recordEvent(.connection,.started,.userRequest,profileID:profileID)
        let generation=UUID();startupGeneration=generation
        let total=DispatchTime.now().uptimeNanoseconds
        startupStartedAt=ProcessInfo.processInfo.systemUptime
        var attempts=0
        var succeeded=false
        defer {
            networkReconnecting=false;startupStage=nil;startupStartedAt=nil
            recordEvent(.connection,succeeded ? .succeeded:.failed,succeeded ? .connected:.startFailed,profileID:profileID)
            log(ConnectionStageTiming(stage:"connectionTotal",milliseconds:Int((DispatchTime.now().uptimeNanoseconds-total)/1_000_000),succeeded:succeeded).summary+" attempts=\(attempts)")
        }
        try await startWithRecovery(next,generation:generation,profileID:profileID) { runtime in
            try self.checkStartup(generation)
            attempts+=1;self.networkReconnecting=false
            self.log("连接准备 attempt=\(attempts) capture=\(runtime.captureMode.rawValue) dns=\(runtime.dnsPreference.rawValue)")
            try await self.startServiceAttempt(runtime,generation:generation,profileID:profileID ?? self.currentProfileID)
        }
        succeeded=true
    }
    private func startServiceAttempt(_ next:AppState,generation:UUID,profileID:UUID?) async throws {
        let timing=ConnectionTiming(),attemptBegan=ProcessInfo.processInfo.systemUptime
        timing.begin("corePreparation");startupStage="准备网络与核心"
        defer {timing.finish(succeeded:false);for sample in timing.samples {log(sample.summary);if !sample.succeeded,let phase=NetworkEventPhase(rawValue:sample.stage) {recordEvent(.connection,.failed,.startFailed,profileID:profileID,phase:phase)}}}
        if next.captureMode == .systemProxy {try NetworkSafety.check()}
        if !wakeRebuilding {NSApplication.shared.activate(ignoringOtherApps:true)}
        let control=try CoreControlContext.make();try PolicyValidator.validate(next)
        core.secrets=secrets(next,control);networkChanged=false;coreFailed=false;helperFailureReason=nil
        await capture.helper.setTimingObserver { [weak self] samples in
            Task {@MainActor in
                guard let self,self.startupGeneration==generation else {return}
                for sample in samples {self.log(sample.summary)}
            }
        }
        await capture.helper.setProgressObserver { [weak self] phase in
            Task { @MainActor in
                guard let self,self.startupGeneration==generation,!self.stopRequested else {return}
                self.startupStage=HelperProgress.label(phase)
            }
        }
        let client=CoreAPIClient(context:control)
        startupClient=client
        defer {startupClient=nil}
        do {
            try self.checkStartup(generation)
            try await capture.start(next,credentials:credentials,control:control)
            try self.checkStartup(generation)
            timing.begin("fallback");startupStage="检查代理通道"
            try await client.waitUntilReady()
            guard CoreController.listening(next.listenPort) else {throw ProxyError("本地代理入口未监听")}
            try self.checkStartup(generation)
            try await client.initializeFallbacks(state: next)
            try self.checkStartup(generation)
            timing.begin("preCaptureProbe")
            let results=try await startupProbes(port:next.listenPort,client:client,mode:next.mode,generation:generation)
            try self.checkStartup(generation)
            connectivityResults=results;reachability=ConnectivityResult.combinedSummary(results)
            for result in results {log(result.summary)}
            if next.dnsPreference == .httpsProxy,results.contains(where:{$0.status == .failed && $0.category == "DNS"}) {throw ConnectionFailure(.dns,"代理 DNS 解析失败")}
            guard StartupConnectivityPolicy.allows(results,mode:next.mode) else {throw wakeStartupError(results)}
            if ConnectivityHealth.evaluate(results) != .healthy {log("连通性探测尚未通过，继续连接并在后台复查；不因网站或测速超时退出")}
            guard !networkChanged,!coreFailed else {throw ProxyError("启动期间核心或网络发生变化")}
            timing.begin("captureActivation");startupStage="应用接管"
            try await capture.activateTunnel()
            log("连接里程碑 captureApplied elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-attemptBegan)*1000))")
            try self.checkStartup(generation)
            if next.captureMode.usesTunnel {
                timing.begin("postCaptureProbe");startupStage="验证实际网络"
                let captured=try await startupProbes(port:nil,client:client,mode:next.mode,generation:generation)
                try self.checkStartup(generation)
                connectivityResults=captured;reachability=ConnectivityResult.combinedSummary(captured)
                for result in captured {log("接管后 · "+result.summary)}
                let status=try await capture.wakeStatus()
                try self.checkStartup(generation)
                guard status.running else {throw ProxyError("TUN 保护流程已停止核心："+status.message)}
                guard status.routesVerified==true,status.dnsVerified==true,status.protectionVerified==true,(next.captureMode != .compatible || status.proxyVerified==true) else {
                    log("接管核验未通过：routes=\(String(describing:status.routesVerified)) dns=\(String(describing:status.dnsVerified)) protection=\(String(describing:status.protectionVerified)) proxy=\(String(describing:status.proxyVerified)) reason=\(status.wakeRecoveryReason?.rawValue ?? "unverified")；"+Redactor.redact(status.message))
                    if status.wakeRecoveryReason == .networkNotReady {throw NetworkEnvironmentNotReady(status.message)}
                    throw ProxyError("接管核验未通过："+status.message+"；"+(status.wakeRecoveryReason?.label ?? "保护状态未验证"))
                }
                if next.dnsPreference == .httpsProxy,captured.contains(where:{$0.status == .failed && $0.category == "DNS"}) {throw ConnectionFailure(.dns,"接管后代理 DNS 解析失败")}
                guard StartupConnectivityPolicy.allows(captured,mode:next.mode) else {throw wakeStartupError(captured)}
            }
            timing.begin("systemProxyActivation")
            try await capture.activateSystemProxy(port:next.listenPort,exceptions:next.bypassProxyExceptions)
            if next.captureMode == .systemProxy {try await proxy.verifyApplied()}
            try self.checkStartup(generation)
            guard capture.running else {throw ProxyError("核心已经退出")}
            timing.finish()
            dependencies.downloader.networkEnvironmentChanged()
            let businessStage=connectivityHealth == .healthy ? "businessVerified":"businessDegraded"
            log("连接里程碑 "+businessStage+" elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-attemptBegan)*1000))")
            // 活跃连接的恢复日志是正常备份，已核验接管成功后不再标记为恢复失败。
            runtimeState=next;connection = .connected;activeBypasses=next.effectiveBypasses;bypassApplyFailure=nil;recoveryPending=false
            startTelemetry(client,profileID:profileID)
        } catch {
            timing.finish(succeeded:false)
            let original=error
            log("启动失败阶段："+(startupStage ?? "未知")+"；原因："+original.localizedDescription)
            startupStage="连接失败，正在恢复自有接管并保留外部网络"
            timing.begin("recovery")
            await client.shutdown()
            // 失败后直接进入恢复，不在恢复前追加一次可能等待整份预算的诊断请求。
            do{try await capture.emergencyRecover(preserveExternal:true);timing.finish()}catch{timing.finish(succeeded:false);recoveryPending=true;throw ProxyError("启动失败："+original.localizedDescription+"；"+error.localizedDescription)}
            throw original
        }
    }
    // 元数据和凭据仅在新配置实际应用成功后提交；失败时恢复原运行配置。
    func apply(_ tx:StoreTransaction,reconfigure:Bool=true,source:String="配置修改",affectedProfileID:UUID?=nil) async throws {
        guard let store else {throw ProxyError("配置未加载")}
        cancelWakeRecovery();invalidateDiagnostic();invalidateOfficeResults();tx.historySource=source
        defer {activeHistoryTransactionID=nil;historyStatus=profileHistory.lastError}
        do {
            try await RuntimeTransaction.apply(tx,connected:reconfigure && connection == .connected,validate:{
                try PolicyValidator.validate(tx.next)
                try store.prepareHistory(tx);self.activeHistoryTransactionID=tx.historyTransactionID
                if reconfigure && self.connection == .connected && !tx.next.nodes.isEmpty {let context=try CoreControlContext.make();try await self.core.validate(config:ConfigBuilder.build(state:tx.next,credentials:self.credentials,control:context))}
            },stop:{if self.capture.running || self.proxy.hasRecovery || self.connection == .connected {try await self.disconnectInternal()}},start:{try await self.startService($0,profileID:tx.nextCatalog?.currentProfileID ?? store.catalog.currentProfileID)},commit:{tx.connectionVerified=reconfigure && self.connection == .connected;try store.commit(tx)},abort:{store.abort(tx)},restartPrevious:{try await self.startService($0,profileID:store.catalog.currentProfileID)})
            state=store.state;errorMessage=nil;invalidateOfficeResults();if connection == .connected {publishOfficeConnectivity()};synchronizeShortcut();recordEvent(.configuration,.succeeded,.configurationApplied,profileID:affectedProfileID)
            if reconfigure && connection == .connected{log("配置已更新，连通性检查通过")};if connection != .connected{connectivityResults=[]}
        }catch{state=store.state;recordEvent(.configuration,.failed,.configurationFailed,profileID:affectedProfileID);report(error);throw error}
    }

    @discardableResult
    func saveManual(_ candidate:Candidate,editingID:UUID?) async -> Bool {guard !locked,let store else{return false};busy=true;defer{busy=false};do{let tx=try store.prepareImport([candidate],replacingID:editingID);try await apply(tx);log("节点已保存");return true}catch{report(error);return false}}
    func deleteNode(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteNode(id))}catch{report(error)}}
    func deleteSubscription(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteSubscription(id))}catch{report(error)}}
    func select(_ id:UUID?) async {guard let id else{return};await selectPolicy(.node(id))}
    func setMode(_ mode:ProxyMode,confirmed:Bool=false) async {
        if state.captureMode == .compatible,connection == .connected,!confirmed {pendingMode=mode;return}
        guard !locked,let store,mode != state.mode else{return};busy=true;defer{busy=false}
        do {var next=state;next.mode=mode;try await apply(store.prepareChange(next));log("模式与 DNS 策略已同步切换为"+mode.label)}catch{report(error)}
    }
    func toggleFavorite(_ id:UUID) {guard !locked else{return};do{var next=state;if next.favorites.contains(id){next.favorites.remove(id)}else{next.favorites.insert(id)};try persist(next)}catch{report(error)}}
    func saveSettings(port:Int,rulesEnabled:Bool) async {await savePort(port);if !locked {await setMode(rulesEnabled ? .rule : .global)}}
    func savePort(_ port:Int) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{guard (1024...65535).contains(port) else {throw ProxyError("监听端口必须为 1024–65535")};var next=state;next.listenPort=port;try await apply(store.prepareChange(next))}catch{report(error)}}
    @discardableResult
    func saveGroup(_ group:PolicyGroup) async -> Bool {guard !locked,let store else{return false};busy=true;defer{busy=false};do{var next=state;next.groups.removeAll{$0.id==group.id};next.groups.append(group);try PolicyValidator.validate(next);try await apply(store.prepareChange(next));return true}catch{report(error);return false}}
    func deleteGroup(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.groups.removeAll{$0.id==id};PolicyValidator.repair(&next);try await apply(store.prepareChange(next))}catch{report(error)}}
    func selectMember(_ group:PolicyGroup,_ ref:PolicyReference) async {
        await changeSelection(ref, in: group)
    }
    func connect() async {
        await CredentialAuthorization.$attempt.withValue(CredentialAuthorization.Attempt()) {await connectWithCredentialSession()}
    }
    private func connectWithCredentialSession() async {
        guard !locked,state.activePolicy != nil || state.mode == .direct else{return}
        cancelWakeRecovery();cancelConnectionWait();userWantsConnection=true;networkReleased=false
        busy=true;connection = .connecting;reachability="尚未检测";connectivityResults=ConnectivityResult.pending;defer{busy=false}
        do {guard !recoveryPending,!proxy.hasRecovery else {throw ProxyError("请先恢复原代理")}
            let status=try? await capture.helperStatus()
            if status?.supportsManagedSystemProxy != true {
                guard CredentialAuthorization.allowsInteraction else {throw ConnectionFailure(.permission,"自动连接需要可复用的辅助服务授权，请手动连接或在设置中安装辅助服务")}
                guard !helperAuthorizationAttempted else {throw ConnectionFailure(.permission,"辅助服务尚未就绪，请在设置中安装或更新；不再自动重复申请授权")}
                helperAuthorizationAttempted=true
                try Data().write(to:directory.appendingPathComponent("helper-authorization-requested"),options:.atomic)
                // 首次安装集中申请管理员授权；日常连接只复用已安装服务。
                await capture.helper.closeChannel()
                try await HelperInstaller.install(app:Bundle.main.bundleURL)
                let installed=try await HelperReadiness.wait{try await self.capture.helperStatus()}
                guard installed.supportsManagedSystemProxy==true else{throw ProxyError("安装后的辅助服务不支持系统代理授权复用")}
            }
            try await startService(state);guard capture.running,!networkChanged else {throw ProxyError("连接期间核心退出或网络变化")};log(reachability)}catch {
            let original=error
            do{try await capture.emergencyRecover(preserveExternal:true);recoveryPending=false}catch{recoveryPending=true;report(error)}
            stopTelemetry();connection = .error;report(original)
            if !recoveryPending {
                do {try await verifyConnectionReleased();networkReleased=true}catch{recoveryPending=true;report(error)}
            }
            if !recoveryPending,userWantsConnection,ConnectionFailureKind.classify(original) == .network {
                wakeNeedsRebuild=true;routineRecovery=true
                wakeIntent=(UUID(),eventSessionID,currentProfileID,epoch)
                networkWaiting=true;beginWakeRecovery()
            } else {userWantsConnection=false}
        }
    }
    func disconnectInternal(preserveExternal:Bool=false) async throws {stableRecoveryTask?.cancel();stableRecoveryTask=nil;runtimeState=nil;activeRecovery=nil;invalidateDiagnostic();activeBypasses=nil;startupGeneration=UUID();startupStage=nil;stopTelemetry();connection = .disconnecting;do{if preserveExternal {try await capture.emergencyRecover(preserveExternal:true)} else {try await capture.stop()};dependencies.downloader.networkEnvironmentChanged()}catch{recoveryPending=true;connection = .error;throw error};recoveryPending=proxy.hasRecovery;connection = .disconnected;connectivityResults=[];reachability="尚未检测";recordEvent(.connection,.succeeded,.disconnected);log("本次连接已停止；本地代理恢复完成，辅助服务是否恢复取决于本次接管状态")}
    func disconnect() async {
        userWantsConnection=false;cancelConnectionWait()
        cancelWakeRecovery()
        guard canStop else{return}
        stableRecoveryTask?.cancel();stableRecoveryTask=nil;startupGeneration=UUID();startupStage=nil;startupProbeTask?.cancel()
        if let startupClient {Task {await startupClient.shutdown()}}
        log("用户请求断开连接");stopTelemetry();cancelMeasurement();stopRequested=true
        if connection == .connecting {await capture.helper.closeChannel()}
        drainPendingDisconnect()
    }
    func recover() async {
        guard !loadingFailed,!recovering else{return}
        userWantsConnection=false;cancelConnectionWait();cancelWakeRecovery()
        stableRecoveryTask?.cancel();stableRecoveryTask=nil;startupGeneration=UUID();startupStage=nil;startupProbeTask?.cancel()
        if let startupClient {Task {await startupClient.shutdown()}}
        if connection == .connecting {await capture.helper.closeChannel()}
        recovering=true;pendingRecovery=true;stopRequested=false
        stopTelemetry();cancelMeasurement();drainPendingDisconnect()
    }
    private func performRecovery() async {
        busy=true;defer{recovering=false;busy=false};connection = .disconnecting
        epoch=UUID();connectivityEpoch=UUID()
        log("应急恢复开始：核对本地代理及已安装辅助服务，与当前模式无关")
        do {
            try await capture.emergencyRecover(preserveExternal:true);stopTelemetry();protectionSummary=[];recoveryPending=false;connection = .disconnected
            connectivityResults=[];helperStatus="汐航接管已清理，外部网络已保留并核对";reachability="尚未检测";errorMessage=nil;log(helperStatus);recordEvent(.recovery,.succeeded,.recoverySucceeded)
        }catch {stopTelemetry();recoveryPending=true;connection = .error;helperStatus="恢复未完成，请查看错误及恢复记录";recordEvent(.recovery,.failed,.recoveryConflict);report(error)}
    }
    func startupRecovery() async {
        guard !started,!loadingFailed else{return};started=true
        let evidence=HelperRecoveryPolicy.inspect()
        if FileManager.default.fileExists(atPath:HelperPaths.socket) {
            do {
                let status=try await capture.helperStatus();helperStatus=status.message
                if (status.recoveryPending ?? status.message.contains("待恢复")) || status.running || evidence.journalPresent {
                    recoveryPending=true;helperStatus="发现恢复记录，请手动恢复并核对结果"
                }
            }catch {
                helperStatus="首次连接将安装或更新辅助服务，后续连接复用授权"
                recoveryPending=proxy.hasRecovery || HelperRecoveryPolicy.requiresRecovery(activeTunnel:false,running:false,journalPresent:evidence.journalPresent,inspectionAvailable:evidence.available)
                log(recoveryPending ? "辅助服务不可用且存在待核对恢复记录，请安装/更新辅助服务":"辅助服务尚未完成授权；未发现恢复记录，首次连接时统一安装")
            }
        }else if evidence.journalPresent || !evidence.available {recoveryPending=true;helperStatus="辅助服务不可用，仍有恢复记录待处理"}
        // 用户开启自动连接后仅尝试一次；恢复记录和无效策略阻止自动接管。
        if state.autoConnect,!recoveryPending,state.activePolicy != nil || state.mode == .direct {await CredentialAuthorization.$allowsInteraction.withValue(false) {await connect()}}
        maintenanceTask=Task{[weak self] in while !Task.isCancelled {await self?.maintenance();try? await Task.sleep(nanoseconds:60_000_000_000)}}
    }
    func measure(_ ids:[UUID]?=nil) {
        guard !locked,!state.nodes.isEmpty else{return};measuring=true;measurementProgress="准备测速"
        let candidates=state.nodes.filter{ids==nil || ids!.contains($0.id)};guard !candidates.isEmpty else {measuring=false;return}
        // 在创建任务前冻结上下文，防止排队期间切换配置后将旧节点结果写入新配置。
        let snapshot=state,measurementEpoch=epoch,measurementProfile=currentProfileID,invalidation=latencyInvalidatedAt
        let live=connection == .connected,client=api
        measurementTask=Task{[weak self] in guard let self else{return};await self.performMeasurement(candidates,snapshot:snapshot,measurementEpoch:measurementEpoch,measurementProfile:measurementProfile,invalidation:invalidation,live:live,initialClient:client)}
    }
    func cancelMeasurement(){if measuring {measurementCancelling=true;measurementProgress="正在取消检测并清理"};measurementTask?.cancel()}
    private func performMeasurement(_ nodes:[Node],snapshot:AppState,measurementEpoch:UUID,measurementProfile:UUID?,invalidation:Date,live:Bool,initialClient:CoreAPIClient?) async {
        var client=initialClient;var result=snapshot
        defer{measurementCancelling=false;measuring=false;measurementProgress="";measurementTask=nil}
        do {
            try Task.checkCancellation()
            guard epoch==measurementEpoch,currentProfileID==measurementProfile else{return}
            if !live {
                let control=try CoreControlContext.make();var test=snapshot;test.mode = .global;test.selectedPolicy = .automatic;test.listenPort=try CoreControlContext.make().port
                let temporary=CoreController(directory:directory);temporary.secrets=secrets(test,control);temporaryCore=temporary
                try await temporary.start(config:ConfigBuilder.build(state:test,credentials:credentials,control:control),port:test.listenPort)
                client=CoreAPIClient(context:control);temporaryAPI=client
            }
            guard let client else {throw ProxyError("测速核心未就绪")};_=try await client.proxies()
            var completed=0
            await withTaskGroup(of:(UUID,LatencyResult).self) {group in
                var next=0
                func enqueue(){let id=nodes[next].id;next+=1;group.addTask{
                    switch await client.measureNode(id) {
                    case .success(let delay):return(id,LatencyResult(milliseconds:delay))
                    case .failure(let categories):return(id,LatencyResult(milliseconds:nil,failure:NodeDetectionFailure.classify(categories)))
                    }
                }}
                for _ in 0..<min(4,nodes.count){enqueue()}
                while let (id,measurement)=await group.next(){if Task.isCancelled{group.cancelAll();break};result.latency[id.uuidString]=measurement;completed+=1;measurementProgress="HTTPS 延迟 \(completed)/\(nodes.count)";if next<nodes.count{enqueue()}}
            }
            if !Task.isCancelled,epoch==measurementEpoch,currentProfileID==measurementProfile,latencyInvalidatedAt==invalidation {latencyClock=Date();try persist(result);log("HTTPS 延迟检测完成")}
        }catch{if !Task.isCancelled{report(error)}}
        if !live {if let client{await client.shutdown()};await temporaryCore?.stop();temporaryAPI=nil;temporaryCore=nil}
    }
    func setAutoConnect(_ value:Bool){guard !locked else{return};do{var next=state;next.autoConnect=value;try persist(next)}catch{report(error)}}
    func setLoginAtStartup(_ value:Bool) {
        guard !locked else{return}
        do {
            if value {guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {throw ProxyError("请先将应用放入 Applications，再启用登录启动")};try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}
            var next=state;next.loginAtStartup=value;try persist(next)
            if SMAppService.mainApp.status == .requiresApproval {errorMessage="请到系统设置中的登录项允许汐航"}
        }catch{report(error)}
    }
    func copyTerminalProxy(){let p=state.listenPort;let value="export http_proxy=http://127.0.0.1:\(p) https_proxy=http://127.0.0.1:\(p) all_proxy=socks5h://127.0.0.1:\(p) HTTP_PROXY=http://127.0.0.1:\(p) HTTPS_PROXY=http://127.0.0.1:\(p) ALL_PROXY=socks5h://127.0.0.1:\(p)";NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string);log("已复制本地终端代理命令，不包含节点凭据")}
    private func synchronizeShortcut(){do{try shortcuts.configure(enabled:state.shortcutEnabled,key:state.shortcutKey,modifiers:state.shortcutModifiers)}catch{log("快捷键冲突，未注册全局快捷键")}}
    func setShortcut(enabled:Bool,key:UInt32,modifiers:UInt32){guard !locked else{return};let old=state;do{guard [UInt32(35),2,15].contains(key),[UInt32(2304),4352,6144,6400].contains(modifiers) else{throw ProxyError("不支持的快捷键组合")};try shortcuts.configure(enabled:enabled,key:key,modifiers:modifiers);var next=state;next.shortcutEnabled=enabled;next.shortcutKey=key;next.shortcutModifiers=modifiers;do{try persist(next)}catch{try? shortcuts.configure(enabled:old.shortcutEnabled,key:old.shortcutKey,modifiers:old.shortcutModifiers);throw error}}catch{report(error)}}
    func applyCaptureSettings(mode:CaptureMode,dns:DNSPreference,family:AddressFamilyPolicy,httpCompatibility:Bool,strictDNS:Bool?=nil) async -> Bool {
        guard !locked,let store else {return false}
        busy=true;defer{busy=false}
        do {
            var next=state;next.strictDNS=strictDNS ?? state.strictDNS;next.captureMode=mode;next.dnsPreference=dns;next.addressFamilyPolicy=family;next.httpCompatibilityEnabled=httpCompatibility
            // 网络绕过统一由分流页管理，此处仅提交接管和 DNS 设置。
            if mode == .compatible {next.ruleFinal = .selected;try DomesticRouting.validate()}
            try await apply(store.prepareChange(next));return true
        } catch {report(error);return false}
    }
    func setCaptureMode(_ mode:CaptureMode) async {guard !locked,let store,state.captureMode != mode else{return};busy=true;defer{busy=false};do{var next=state;next.captureMode=mode;try await apply(store.prepareChange(next))}catch{report(error)}}
    func setAddressFamily(_ policy:AddressFamilyPolicy) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.addressFamilyPolicy=policy;try await apply(store.prepareChange(next))}catch{report(error)}}
    func setDNS(_ mode:DNSPreference) async {guard !locked,let store,state.dnsPreference != mode else{return};busy=true;defer{busy=false};do{var next=state;next.dnsPreference=mode;try await apply(store.prepareChange(next))}catch{report(error)}}
    func installHelper() async {
        guard !locked,!capture.running else{errorMessage="请先断开本次连接再更新辅助服务";return}
        busy=true;defer{busy=false};NSApplication.shared.activate(ignoringOtherApps:true)
        do {
            if let status=try? await capture.helperStatus(),status.ok,status.protocolVersion==5,
               HelperInstaller.componentsMatch(app:Bundle.main.bundleURL) {
                helperStatus="辅助服务已就绪，无需重复安装或管理员授权";log(helperStatus);return
            }
            try await HelperInstaller.install(app:Bundle.main.bundleURL)
            await capture.helper.closeChannel()
            let status=try await HelperReadiness.wait {try await self.capture.helperStatus()}
            guard status.protocolVersion==5 else{throw ProxyError("安装后辅助服务协议仍不匹配")}
            try await capture.emergencyRecover(preserveExternal:true);recoveryPending=false;connection = .disconnected;helperStatus="辅助服务更新完成并已核对";errorMessage=nil;log(helperStatus)
        }catch {helperStatus="辅助服务安装/核对未完成";report(error)}
    }
    func inspectHelper() async {do{helperStatus=try await capture.helperStatus().message}catch{helperStatus=error.localizedDescription}}
    var profiles:[ClientProfile]{store?.catalog.profiles ?? []}
    var currentProfileID:UUID?{store?.catalog.currentProfileID}
    func changeProfile(_ id:UUID) async {
        await cancelWakeRecoveryAndWait()
        guard !locked,let store,id != currentProfileID else{return}
        guard drafts.allowLeaving("切换配置",profile:currentProfileID) else{return};busy=true;defer{busy=false}
        do{try await apply(store.prepareCatalog(ProfileStore.switchTo(id,in:store.catalog)));log("配置切换完成")}catch{report(error)}
    }
    @discardableResult
    func createProfile(name:String,copy:Bool,officeDomains:[String]=[]) async -> Bool {
        guard !locked,let store else{return false};busy=true;defer{busy=false}
        do{let root=try ProfileStore.create(in:store.catalog,name:name,copyID:copy ? currentProfileID:nil,officeDomains:officeDomains);try await apply(store.prepareCatalog(root),reconfigure:false);return true}catch{report(error);return false}
    }
    @discardableResult
    func renameProfile(_ id:UUID,name:String) async -> Bool {
        guard !locked,let store else{return false};busy=true;defer{busy=false}
        do{try await apply(store.prepareCatalog(ProfileStore.rename(id,to:name,in:store.catalog)),reconfigure:false);return true}catch{report(error);return false}
    }
    func deleteProfile(_ id:UUID) async {
        guard !locked,let store else{return}
        guard drafts.allowLeaving("删除配置",profile:id) else{return};busy=true;defer{busy=false}
        do{try await apply(store.prepareCatalog(ProfileStore.remove(id,in:store.catalog)),reconfigure:false)}catch{report(error)}
    }
    func recordBackup(_ url:URL) {guard let store else{return};do{var root=store.catalog;root.backupIndex.append(BackupIndex(fileName:url.lastPathComponent));if root.backupIndex.count>100{root.backupIndex.removeFirst(root.backupIndex.count-100)};try store.commit(store.prepareCatalog(root));state=store.state}catch{report(error)}}
    func migrationSnapshot() throws -> BackupSnapshot {let ref=try String(contentsOf:directory.appendingPathComponent("migration-v3.keyref"),encoding:.utf8);return try BackupService.decrypt(Data(contentsOf:directory.appendingPathComponent("migration-v3.qzb")),password:credentials.get(ref))}
    @discardableResult
    func restoreBackup(_ snapshot:BackupSnapshot) async -> Bool {
        guard !locked,let store else{return false}
        guard drafts.allowLeaving("恢复备份",all:true) else{return false};busy=true;defer{busy=false}
        do{try await apply(store.prepareRestore(snapshot));log("加密备份恢复完成");return true}catch{report(error);return false}
    }
    @discardableResult
    func saveNote(_ id:UUID,note:String) -> Bool {guard !locked else{return false};do{guard note.utf8.count<=4096 else{throw ProxyError("备注不能超过 4096 字节")};var next=state;next.notes[id.uuidString]=note;try persist(next);return true}catch{report(error);return false}}
    func setCompact(_ value:Bool){guard !locked else{return};do{var next=state;next.compactNodes=value;try persist(next)}catch{report(error)}}
    func batchFavorite(_ ids:Set<UUID>,value:Bool){guard !locked else{return};do{var next=state;if value{next.favorites.formUnion(ids)}else{next.favorites.subtract(ids)};try persist(next)}catch{report(error)}}
    func batchDelete(_ ids:Set<UUID>) async{guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteNodes(ids))}catch{report(error)}}
    func handleHealthPowerEvent(_ event:HealthPowerEvent) {
        invalidateOfficeResults(network:true)
        if case .willSleep=event,!healthPower.systemSleeping {
            let connected=connection == .connected || wakeRebuilding || (userWantsConnection && wakeIntent != nil)
            cancelWakeRecovery()
            if connected {let id=UUID();wakeIntent=(id,eventSessionID,currentProfileID,epoch);recordEvent(.network,.changed,.systemSleep,recoveryID:id,originalSessionID:eventSessionID)}
        }
        guard healthPower.receive(event,uptime:healthPowerUptime()) else{return}
        if healthPower.suspended {wakeRecovery.cancel()}
        cancelHealthRefresh()
        failedHealthCycles=0;healthFailures=HealthFailureCounter();fallbackStates=[:]
        latencyInvalidatedAt=Date()
        guard connection == .connected || wakeIntent != nil else{return}
        connectivityResults=ConnectivityResult.pending
        if healthPower.suspended {
            monitor.health="睡眠期间暂停节点健康检查"
            log("电源状态变化：暂停节点健康检查，清除连续失败计数；后台唤醒不判定节点失效")
        } else {
            monitor.health="唤醒后等待网络稳定"
            log("系统与屏幕已唤醒，等待 15 秒运行时间后重新检查节点")
            if wakeIntent != nil {beginWakeRecovery()} else {scheduleHealthRefresh()}
        }
    }
    func healthResultIsCurrent(_ generation:UUID)->Bool {
        !wakeRecovery.active && wakeRecoveryStatus.phase != .manual && healthPower.generation==generation && healthPower.canProbe(uptime:healthPowerUptime()) && healthDisplayAwake()
    }
    func recordNodeHealth(_ statuses:[ProbeStatus],powerGeneration:UUID)->Bool {
        guard healthResultIsCurrent(powerGeneration) else{return false}
        return healthFailures.update(statuses)
    }
    func cancelHealthRefresh() {healthRefreshKey=nil;healthScheduler.cancel();healthChecking=false;connectivityEpoch=UUID()}
    func scheduleHealthRefresh(delay:UInt64=1_000_000_000) {
        guard connection == .connected,!wakeRecovery.active else{return}
        guard !healthPower.suspended else{healthRefreshPending=true;return}
        guard !locked,let client=api else{healthRefreshPending=true;return}
        let key=epoch.uuidString+officeNetworkID.uuidString+(CoreAPIClient.actualTag(proxyInfo) ?? "")+(state.activePolicy?.tag ?? "")+state.mode.rawValue
        if healthRefreshKey==key {return}
        healthRefreshKey=key
        let delay=max(delay,UInt64(healthPower.remaining(uptime:healthPowerUptime())*1_000_000_000))
        healthRefreshPending=false;let token=epoch
        healthScheduler.schedule(delay:delay) { [weak self] in
            guard let self else{return}
            defer {if self.healthRefreshKey==key {self.healthRefreshKey=nil}}
            guard self.epoch==token,!self.locked else{return}
            await self.healthCheck(client,token:token)
            guard !Task.isCancelled,self.epoch==token,!self.locked,self.connection == .connected else{return}
            await self.checkConnectivity()
        }
    }
    private func healthNodeIDs()->Set<UUID> {
        var ids=Set<UUID>(),seen=Set<UUID>()
        func visit(_ reference:PolicyReference?) {
            guard let reference else{return}
            switch reference {
            case .node(let id):ids.insert(id)
            case .automatic:
                if let actual=CoreAPIClient.actualTag(proxyInfo,root:"auto"),actual.hasPrefix("node-"),let id=UUID(uuidString:String(actual.dropFirst(5))) {ids.insert(id)}

            case .group(let id):
                if seen.insert(id).inserted,let group=state.groups.first(where:{$0.id==id}) {
                    if group.kind == .fallback {for member in group.members {visit(member)}}
                    else if let tag=proxyInfo[PolicyReference.group(id).tag]?.now,let member=group.members.first(where:{$0.tag==tag}) {visit(member)}
                    else {visit(group.selected ?? group.members.first)}
                }
            default:break
            }
        }
        visit(state.activePolicy)
        if state.mode == .rule {
            visit(state.ruleFinal)
            for rule in state.rules {visit(rule.target)}
            for source in state.remoteRules {visit(source.target)}
        }
        return ids
    }
    func setHTTPCompatibility(_ enabled:Bool) async {
        guard !locked,let store,enabled != state.httpCompatibilityEnabled else{return};busy=true;defer{busy=false}
        do {guard !enabled || state.shadowrocket != nil else{throw ProxyError("请先导入 HTTP 兼容配置")};var next=state;next.httpCompatibilityEnabled=enabled;try await apply(store.prepareChange(next))}catch{report(error)}
    }
    func healthCheck(_ client:CoreAPIClient,token:UUID) async {
        let powerGeneration=healthPower.generation
        guard !locked,epoch==token,connection == .connected,state.mode != .direct,healthResultIsCurrent(powerGeneration) else{return};healthChecking=true;defer{if epoch==token,healthPower.generation==powerGeneration{healthChecking=false}}
        if automaticRefreshRequested {await refreshAutomaticIfNeeded(client,token:token)}
        guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return}
        let relevant=healthNodeIDs()
        let nodes=state.nodes.filter{relevant.contains($0.id)};var results:[UUID:Bool]=[:];var statuses:[ProbeStatus]=[];var nodeStatuses:[UUID:ProbeStatus]=[:]
        await withTaskGroup(of:(UUID,ProbeStatus).self){group in var cursor=0;func enqueue(){let id=nodes[cursor].id;cursor+=1;group.addTask{(id,await client.probe(id))}};for _ in 0..<min(4,nodes.count){enqueue()};while let (id,status)=await group.next(){guard !Task.isCancelled else{group.cancelAll();break};statuses.append(status);nodeStatuses[id]=status;switch status{case .available:results[id]=true;case .unavailable:results[id]=false;case .unknown:break};if cursor<nodes.count{enqueue()}}}
        guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return}
        // 控制通道和节点健康独立评估，未知节点不阻断其他回退组的判定。
        do {_ = try await client.proxies();guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return};failedHealthCycles=0}
        catch {
            guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return};monitor.health="节点健康暂无法核对";failedHealthCycles+=1;healthFailures=HealthFailureCounter()
            log("健康检查：控制接口失败 category="+ConnectivityResult.category(error)+" consecutive=\(failedHealthCycles)")
            if let apiError=error as? CoreAPIError {if ["超时","取消"].contains(apiError.category) {failedHealthCycles=0};if apiError.category=="鉴权" {beginRoutineRecovery(reason:.authentication);return}}
            if failedHealthCycles>=2 {beginRoutineRecovery(reason:.controlUnavailable)}
            return
        }
        monitor.health = statuses.contains(where:{if case .unknown=$0{return true};return false}) ? "节点健康部分无法确定" : statuses.contains(where:{if case .unavailable=$0{return true};return false}) ? "部分节点检测失败" : nil
        exitHealth.retain(relevant)
        var failedExits=Set<UUID>()
        for (id,status) in nodeStatuses {if exitHealth.update(id,status:status) {failedExits.insert(id)}}
        if usesAutomaticExit(), nodeStatuses.values.contains(where:{if case .unavailable=$0{return true};return false}) {
            await refreshAutomaticIfNeeded(client,token:token)
            guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return}
        }
        for group in state.groups where group.kind == .fallback && group.members.contains(where:{if case .node(let id)=$0{return relevant.contains(id)};return false}) {
            guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return}
            let priority=group.members.compactMap{ref -> UUID? in if case .node(let id)=ref{return id};return nil};let currentTag=proxyInfo[PolicyReference.group(group.id).tag]?.now
            let current=priority.first{PolicyReference.node($0).tag==currentTag} ?? {if case .node(let id)=group.selected{return id};return nil}()
            var controller=fallbackStates[group.id] ?? FallbackController();let decision=controller.evaluate(priority:priority,current:current,results:results);fallbackStates[group.id]=controller
            if decision.unavailable {monitor.health="回退组 \(group.name) 全部不可用";continue}
            if let selected=decision.selected,selected != current {do{try await client.select(.node(selected),group:PolicyReference.group(group.id).tag);guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return};let info=try await client.proxies();guard epoch==token,!Task.isCancelled else{return};publishPolicyInfo(info);log("优先级回退已切换，已有连接保留")}catch{report(error)}}
        }
        if let id=defaultExitNodeID(),failedExits.contains(id) {
            beginRoutineRecovery(reason:.nodeUnavailable)
        } else if !failedExits.isEmpty {monitor.health="部分规则出口不可用，默认出口保持运行"}
    }
    func checkConnectivity() async {
        guard !locked,!Task.isCancelled,let api else{return};let powerGeneration=healthPower.generation;guard healthResultIsCurrent(powerGeneration) else{return};let token=epoch;let probeToken=UUID();connectivityEpoch=probeToken
        // 后台复查保留上次完成的结果，避免每轮检测都闪回“检测中”。
        if connectivityResults.isEmpty {connectivityResults=ConnectivityResult.pending}
        let results=await connectivityProbe(effectiveState.captureMode.usesTunnel ? nil:state.listenPort,api,state.mode)
        guard epoch==token,connectivityEpoch==probeToken,connection == .connected,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return}
        connectivityResults=results
        reachability=ConnectivityResult.combinedSummary(results)
        if currentSelectionStatus?.phase == .unconfirmed,currentSelectionStatus?.groupID == nil,
           SelectionConnectivityPolicy.evaluate(results,requiresNode:state.mode != .direct && state.activePolicy != .direct) == .verified {
            selectionStatus?.phase = .succeeded;selectionStatus?.networkUncertain=false
            selectionStatus?.message="当前选择已通过连通性复查"
        }
        if let selection=currentSelectionStatus,selection.phase == .unconfirmed,let groupID=selection.groupID {
            let groupTag=PolicyReference.group(groupID).tag
            do {
                try await api.verifySelection(selection.target,group:groupTag)
                let target=await ConnectivityProbe.target(client:api,root:groupTag)
                guard epoch==token,connectivityEpoch==probeToken,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration),currentSelectionStatus==selection else{return}
                var checked=results
                if checked.count==3 {checked[1]=target}
                if SelectionConnectivityPolicy.evaluate(checked,requiresNode:selection.target != .direct) == .verified {
                    selectionStatus?.phase = .succeeded;selectionStatus?.networkUncertain=false
                    selectionStatus?.message="策略组当前选择已通过连通性复查"
                }
            }catch{log("策略组选择仍待确认："+Redactor.redact(error.localizedDescription))}
        }
        for result in results {log(result.summary+(result.milliseconds.map{" 耗时=\($0)ms"} ?? ""))}
    }
    func quit() async -> Bool {
        userWantsConnection=false;cancelConnectionWait()
        await cancelWakeRecoveryAndWait()
        guard !busy else {errorMessage="正在更新配置，请稍后退出";return false}
        guard drafts.allowLeaving("退出汐航",all:true) else{return false}
        if loadingFailed{return true}
        cancelHealthRefresh()
        if measuring {cancelMeasurement();await measurementTask?.value}
        guard !busy else {errorMessage="正在更新配置，请稍后退出";return false}
        maintenanceTask?.cancel();guard !recovering else{return false};busy=true;defer{busy=false}
        stopTelemetry();await history.drain();errorMessage=nil
        do {
            try await QuitRecoveryTransaction.run(recover:{
                try await self.capture.emergencyRecover(preserveExternal:true)
            },verifyReleased:{
                try await self.capture.verifyReleasedForQuit()
            },deferredRecovery:{error in
                self.recoveryPending=true
                self.log("退出时已确认汐航不再接管；恢复记录留待下次处理："+Redactor.redact(error.localizedDescription))
            })
            connection = .disconnected
            await timeline.drain()
            return true
        } catch {report(error);return false}
    }
}
