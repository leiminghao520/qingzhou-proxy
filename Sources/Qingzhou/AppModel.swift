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
    @Published var state=AppState()
    @Published var connection=Connection.disconnected {didSet{if connection != oldValue {invalidateDiagnostic()}}}
    @Published var startupStage:String?
    @Published var startupStartedAt:TimeInterval?
    private(set) var startupGeneration=UUID()
    private var startupClient:CoreAPIClient?
    private var startupProbeTask:Task<[ConnectivityResult],Never>?
    @Published var wakeRecoveryStatus=WakeRecoveryStatus(.idle)
    var wakeRecovery=WakeRecoveryCoordinator()
    var wakeIntent:(id:UUID,session:UUID,profile:UUID?,epoch:UUID)?
    var wakeRebuilding=false
    var wakeNeedsRebuild=false
    var wakeCheckOverride:(() async -> WakeRecoveryCheck)?
    var wakeHTTPSProbe:(Int?) async -> ConnectivityResult = {await ConnectivityProbe.https(port:$0,entry:false)}
    var wakeNetworkReady:()->Bool = {BypassNetworkService.read().contains{$0.active && !CapturePlan.isVPN($0.interface) && $0.interface != "lo0"}}
    var wakeRebuildOverride:(() async -> WakeRecoveryCheck)?
    @Published var reachability="尚未检测"
    @Published var connectivityResults:[ConnectivityResult]=[]
    var connectivityHealth:ConnectivityHealth {ConnectivityHealth.evaluate(connectivityResults)}
    @Published var networkReconnecting = false {didSet{if networkReconnecting != oldValue {invalidateDiagnostic()}}}
    var networkRechecking:Bool {networkReconnecting || (connection == .connected && state.captureMode.usesTunnel && helperStatus == "网络变化，正在重新检查")}
    var connectionSummary:String {
        if wakeRecovery.active || wakeRecoveryStatus.phase == .manual {return wakeRecoveryStatus.label}
        if connection == .connecting {return "连接中 · "+(startupStage ?? "准备网络与核心")}
        if networkReconnecting {return "网络恢复中 · 正在自动重连"}
        if networkRechecking {return "已连接 · 网络变化，正在重新检查"}
        return connection.rawValue+" · 连通性"+connectivityHealth.rawValue
    }
    @Published var busy=false {didSet{if busy{cancelHealthRefresh();healthRefreshPending=true}else{drainPendingDisconnect()}}}
    @Published var healthChecking=false
    @Published var recovering=false
    @Published var stopRequested=false
    @Published var latencyInvalidatedAt=Date()
    @Published var latencyClock=Date()
    private let healthScheduler=HealthRefreshScheduler()
    private var pendingRecovery=false
    var canStop:Bool {!loadingFailed && !recovering && !stopRequested && connection != .disconnecting}
    var stopDisabled:Bool {connection == .connected || connection == .connecting ? !canStop:locked}
    @Published var measuring=false {didSet{if !measuring{drainPendingDisconnect()}}}
    @Published var measurementProgress=""
    @Published var errorMessage:String?
    let drafts=SessionDraftStore()
    let logBuffer = RuntimeLogBuffer()
    @Published var preview:ImportPreview?
    @Published var previewDiff:UpdateDiff?
    @Published var rateHistory:[RateSample]=[]
    @Published var trafficByNode:[String:Int64]=[:]
    @Published var trafficByTarget:[String:Int64]=[:]
    var observedConnections:[String:Int64]=[:]
    private let shortcuts=ShortcutController()
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
    @Published var recoveryPending=false
    @Published var loadingFailed=false
    @Published var uploadRate:Int64=0
    @Published var downloadRate:Int64=0
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
    var connectivityEpoch=UUID()
    var telemetryTask:Task<Void,Never>?
    var trafficTask:Task<Void,Never>?
    private var maintenanceTask:Task<Void,Never>?
    var nextHistoryMaintenance=Date.distantPast
    private var measurementTask:Task<Void,Never>?
    private var temporaryCore:CoreController?
    private var temporaryAPI:CoreAPIClient?
    var epoch=UUID() {didSet {if epoch != oldValue {invalidateDiagnostic();if !wakeRebuilding {cancelWakeRecovery()}}}}
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
        timeline.activate()
        if let store {store.history=profileHistory;do{try profileHistory.initialize(store.catalog)}catch{historyStatus=profileHistory.lastError}}
        logBuffer.configure(url:directory.appendingPathComponent("diagnostic.log"))
        log("应用启动，正在检查上次恢复记录")
        recoveryPending=proxy.hasRecovery
        core.log={ [weak self] in self?.log($0) }
        proxy.log={ [weak self] in self?.log($0) }
        core.onUnexpectedExit={ [weak self] in guard let self else{return};self.recordEvent(.connection,.failed,.coreExited);if self.wakeIntent==nil && !self.wakeRecovery.active {self.stopTelemetry()};self.coreFailed=true;self.cancelMeasurement();self.drainPendingDisconnect() }
        proxy.onNetworkChange={ [weak self] in guard let self,self.connection == .connected || self.connection == .connecting else{return};self.cancelWakeRecovery();self.recordEvent(.network,.changed,.ownershipChanged);self.networkChanged=true;self.cancelMeasurement();self.drainPendingDisconnect() }
        proxy.onEnvironmentChange={ [weak self] in self?.recordEvent(.network,.changed,.environmentChanged);self?.dependencies.downloader.networkEnvironmentChanged();self?.latencyInvalidatedAt=Date();self?.scheduleHealthRefresh() }
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
    func report(_ error:Error) {if error is CancellationError{return};errorMessage=Redactor.redact(error.localizedDescription);log(errorMessage!)}
    func persist(_ next:AppState) throws {
        guard let store else {throw ProxyError("配置未加载")}
        defer {historyStatus=profileHistory.lastError}
        try store.commit(next);state=store.state
    }
    private func secrets(_ next:AppState,_ control:CoreControlContext) -> [String] {[control.secret]+next.nodes.flatMap{[(try? credentials.get($0.credentialRef)) ?? "",(try? credentials.get($0.credentialRef+".obfs")) ?? ""]}}
    func checkStartup(_ generation:UUID) throws {
        try Task.checkCancellation()
        guard startupGeneration==generation,!stopRequested,!pendingRecovery else {throw CancellationError()}
    }
    private func startupProbes(port:Int?,client:CoreAPIClient,mode:ProxyMode,generation:UUID) async throws -> [ConnectivityResult] {
        let task=Task {await ConnectivityProbe.all(port:port,client:client,mode:mode)}
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
        try await NetworkPreparationRetry.run(operation:{
            try self.checkStartup(generation)
            attempts+=1;self.networkReconnecting=false
            self.log("连接准备 attempt=\(attempts)")
            try await self.startServiceAttempt(next,generation:generation,profileID:profileID ?? self.currentProfileID)
        },shouldContinue:{self.startupGeneration==generation && !self.stopRequested && !self.pendingRecovery},wait:{delay in
            try self.checkStartup(generation)
            self.networkReconnecting=true
            self.connectivityResults=ConnectivityResult.pending
            self.startupStage="第 \(attempts+1) 次准备，\(Int(delay)) 秒后重试"
            self.reachability="网络变化，正在重新准备连接"
            self.log("连接重试 attempt=\(attempts+1) waitSeconds=\(Int(delay))")
            for _ in 0..<Int(delay*4) {
                try self.checkStartup(generation)
                try await Task.sleep(nanoseconds:250_000_000)
            }
        })
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
            try self.checkStartup(generation)
            try await client.initializeFallbacks(state: next)
            try self.checkStartup(generation)
            timing.begin("preCaptureProbe")
            let results=try await startupProbes(port:next.listenPort,client:client,mode:next.mode,generation:generation)
            try self.checkStartup(generation)
            connectivityResults=results;reachability=ConnectivityResult.combinedSummary(results)
            for result in results {log(result.summary)}
            guard ConnectivityHealth.evaluate(results) == .healthy else {throw wakeStartupError(results)}
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
                let status=try await capture.helperStatus()
                try self.checkStartup(generation)
                guard status.running else {throw ProxyError("TUN 保护流程已停止核心："+status.message)}
                guard ConnectivityHealth.evaluate(captured) == .healthy else {throw wakeStartupError(captured)}
            }
            timing.begin("systemProxyActivation")
            try capture.activateSystemProxy(port:next.listenPort,exceptions:next.bypassProxyExceptions)
            if next.captureMode == .systemProxy {try await proxy.verifyApplied()}
            try self.checkStartup(generation)
            guard capture.running else {throw ProxyError("核心已经退出")}
            timing.finish()
            dependencies.downloader.networkEnvironmentChanged()
            log("连接里程碑 businessVerified elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime-attemptBegan)*1000))")
            connection = .connected;activeBypasses=next.effectiveBypasses;bypassApplyFailure=nil;recoveryPending=proxy.hasRecovery
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
        cancelWakeRecovery();invalidateDiagnostic();tx.historySource=source
        defer {activeHistoryTransactionID=nil;historyStatus=profileHistory.lastError}
        do {
            try await RuntimeTransaction.apply(tx,connected:reconfigure && connection == .connected,validate:{
                try PolicyValidator.validate(tx.next)
                try store.prepareHistory(tx);self.activeHistoryTransactionID=tx.historyTransactionID
                if reconfigure && self.connection == .connected && !tx.next.nodes.isEmpty {let context=try CoreControlContext.make();try await self.core.validate(config:ConfigBuilder.build(state:tx.next,credentials:self.credentials,control:context))}
            },stop:{if self.capture.running || self.proxy.hasRecovery || self.connection == .connected {try await self.disconnectInternal()}},start:{try await self.startService($0,profileID:tx.nextCatalog?.currentProfileID ?? store.catalog.currentProfileID)},commit:{tx.connectionVerified=reconfigure && self.connection == .connected;try store.commit(tx)},abort:{store.abort(tx)},restartPrevious:{try await self.startService($0,profileID:store.catalog.currentProfileID)})
            state=store.state;synchronizeShortcut();recordEvent(.configuration,.succeeded,.configurationApplied,profileID:affectedProfileID)
            if reconfigure && connection == .connected{log("配置已更新，连通性检查通过")};if connection != .connected{connectivityResults=[]}
        }catch{state=store.state;recordEvent(.configuration,.failed,.configurationFailed,profileID:affectedProfileID);report(error);throw error}
    }

    func saveManual(_ candidate:Candidate,editingID:UUID?) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{let tx=try store.prepareImport([candidate],replacingID:editingID);try await apply(tx);log("节点已保存")}catch{report(error)}}
    func deleteNode(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteNode(id))}catch{report(error)}}
    func deleteSubscription(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteSubscription(id))}catch{report(error)}}
    func select(_ id:UUID?) async {guard let id else{return};await selectPolicy(.node(id))}
    func selectPolicy(_ ref:PolicyReference) async {
        guard !locked,ref != state.activePolicy,PolicyValidator.exists(ref,in:state),ref != .selected,ref != .reject else{return};cancelWakeRecovery();busy=true;defer{busy=false}
        invalidateDiagnostic()
        let old=state.activePolicy
        var next=state;next.selectedPolicy=ref;if case .node(let id)=ref {next.selectedID=id;next.recentUse[id.uuidString]=Date()}
        guard let store else{return};let tx=store.prepareChange(next);tx.historySource="节点选择"
        defer {historyStatus=profileHistory.lastError}
        do {
            try store.prepareHistory(tx)
            if let api,connection == .connected {
                try await api.select(ref)
                let checked=await ConnectivityProbe.all(port:state.captureMode.usesTunnel ? nil:state.listenPort,client:api,mode:state.mode)
                guard ConnectivityHealth.evaluate(checked) == .healthy else {if let old{try? await api.select(old)};throw ProxyError("新节点连通性检查失败，已恢复原选择")}
            }
            do{tx.connectionVerified=connection == .connected;try store.commit(tx);state=store.state}catch{if let api,let old{try? await api.select(old)};throw error}
            recordEvent(.node,.changed,.nodeSelected)
            log("已选择 \(state.label(ref))，已有连接保留");if connection == .connected{await checkConnectivity()}
        } catch {store.abort(tx);report(error)}
    }
    func setMode(_ mode:ProxyMode,confirmed:Bool=false) async {
        if state.captureMode == .compatible,connection == .connected,!confirmed {pendingMode=mode;return}
        guard !locked,let store,mode != state.mode else{return};busy=true;defer{busy=false}
        do {var next=state;next.mode=mode;try await apply(store.prepareChange(next));log("模式与 DNS 策略已同步切换为"+mode.label)}catch{report(error)}
    }
    func toggleFavorite(_ id:UUID) {guard !locked else{return};do{var next=state;if next.favorites.contains(id){next.favorites.remove(id)}else{next.favorites.insert(id)};try persist(next)}catch{report(error)}}
    func saveSettings(port:Int,rulesEnabled:Bool) async {await savePort(port);if !locked {await setMode(rulesEnabled ? .rule : .global)}}
    func savePort(_ port:Int) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{guard (1024...65535).contains(port) else {throw ProxyError("监听端口必须为 1024–65535")};var next=state;next.listenPort=port;try await apply(store.prepareChange(next))}catch{report(error)}}
    func saveGroup(_ group:PolicyGroup) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.groups.removeAll{$0.id==group.id};next.groups.append(group);try PolicyValidator.validate(next);try await apply(store.prepareChange(next))}catch{report(error)}}
    func deleteGroup(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.groups.removeAll{$0.id==id};PolicyValidator.repair(&next);try await apply(store.prepareChange(next))}catch{report(error)}}
    func selectMember(_ group:PolicyGroup,_ ref:PolicyReference) async {
        guard !locked,group.kind == .select,group.members.contains(ref),let store else{return}
        cancelWakeRecovery();invalidateDiagnostic();busy=true;defer{busy=false;historyStatus=profileHistory.lastError}
        var next=state;guard let i=next.groups.firstIndex(where:{$0.id==group.id}) else{return};next.groups[i].selected=ref
        let tx=store.prepareChange(next);tx.historySource="策略组选择"
        do {
            try store.prepareHistory(tx)
            if let api {try await api.select(ref,group:PolicyReference.group(group.id).tag)}
            do {try store.commit(tx);state=store.state}
            catch {if let api,let previous=group.selected {try? await api.select(previous,group:PolicyReference.group(group.id).tag)};throw error}
            recordEvent(.node,.changed,.nodeSelected)
        }catch {store.abort(tx);report(error)}
    }
    func connect() async {
        cancelWakeRecovery()
        guard !locked,state.activePolicy != nil || state.mode == .direct else{return};busy=true;connection = .connecting;reachability="尚未检测";connectivityResults=ConnectivityResult.pending;defer{busy=false}
        do {guard !recoveryPending,!proxy.hasRecovery else {throw ProxyError("请先恢复原代理")};try await startService(state);guard capture.running,!networkChanged else {throw ProxyError("连接期间核心退出或网络变化")};if state.captureMode.usesTunnel && !reachability.contains("正常"){try await disconnectInternal();throw ProxyError("公网接管 HTTPS 验收失败，原网络已恢复；请查看诊断中的具体检测结果")};log(reachability)}catch {
            let original=error
            do{try await capture.emergencyRecover(preserveExternal:true);recoveryPending=false}catch{recoveryPending=true;report(error)}
            stopTelemetry();connection = .error;report(original)
        }
    }
    func disconnectInternal() async throws {invalidateDiagnostic();activeBypasses=nil;startupGeneration=UUID();startupStage=nil;stopTelemetry();connection = .disconnecting;do{try await capture.stop();dependencies.downloader.networkEnvironmentChanged()}catch{recoveryPending=true;connection = .error;throw error};recoveryPending=proxy.hasRecovery;connection = .disconnected;connectivityResults=[];reachability="尚未检测";recordEvent(.connection,.succeeded,.disconnected);log("本次连接已停止；本地代理恢复完成，辅助服务是否恢复取决于本次接管状态")}
    func disconnect() async {
        cancelWakeRecovery()
        guard canStop else{return}
        startupGeneration=UUID();startupStage=nil;startupProbeTask?.cancel()
        if let startupClient {Task {await startupClient.shutdown()}}
        log("用户请求断开连接");stopTelemetry();cancelMeasurement();stopRequested=true
        if connection == .connecting {await capture.helper.closeChannel()}
        drainPendingDisconnect()
    }
    func recover() async {
        guard !loadingFailed,!recovering else{return}
        startupGeneration=UUID();startupStage=nil;startupProbeTask?.cancel()
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
            connectivityResults=[];helperStatus="轻舟接管已清理，外部网络已保留并核对";reachability="尚未检测";errorMessage=nil;log(helperStatus);recordEvent(.recovery,.succeeded,.recoverySucceeded)
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
                helperStatus="辅助服务需要安装/更新；系统代理模式可独立使用"
                recoveryPending=proxy.hasRecovery || HelperRecoveryPolicy.requiresRecovery(activeTunnel:false,running:false,journalPresent:evidence.journalPresent,inspectionAvailable:evidence.available)
                log(recoveryPending ? "辅助服务不可用且存在待核对恢复记录，请安装/更新辅助服务":"辅助服务身份尚未更新；未发现辅助服务恢复记录，不阻塞系统代理模式")
            }
        }else if evidence.journalPresent || !evidence.available {recoveryPending=true;helperStatus="辅助服务不可用，仍有恢复记录待处理"}
        // 用户开启自动连接后仅尝试一次；恢复记录和无效策略阻止自动接管。
        if state.autoConnect,!recoveryPending,state.activePolicy != nil || state.mode == .direct {await connect()}
        maintenanceTask=Task{[weak self] in while !Task.isCancelled {await self?.maintenance();try? await Task.sleep(nanoseconds:60_000_000_000)}}
    }
    func measure(_ ids:[UUID]?=nil) {
        guard !locked,!state.nodes.isEmpty else{return};measuring=true;measurementProgress="准备测速"
        let candidates=state.nodes.filter{ids==nil || ids!.contains($0.id)};guard !candidates.isEmpty else {measuring=false;return}
        measurementTask=Task{[weak self] in guard let self else{return};await self.performMeasurement(candidates)}
    }
    func cancelMeasurement(){measurementTask?.cancel()}
    private func performMeasurement(_ nodes:[Node]) async {
        let live=connection == .connected;let measurementEpoch=epoch;let invalidation=latencyInvalidatedAt;var client=api;var result=state
        defer{measuring=false;measurementProgress="";measurementTask=nil}
        do {
            if !live {
                let control=try CoreControlContext.make();var test=state;test.mode = .global;test.selectedPolicy = .automatic;test.listenPort=try CoreControlContext.make().port
                let temporary=CoreController(directory:directory);temporary.secrets=secrets(test,control);temporaryCore=temporary
                try await temporary.start(config:ConfigBuilder.build(state:test,credentials:credentials,control:control),port:test.listenPort)
                client=CoreAPIClient(context:control);temporaryAPI=client
            }
            guard let client else {throw ProxyError("测速核心未就绪")};_=try await client.proxies()
            var completed=0
            await withTaskGroup(of:(UUID,Int?).self) {group in
                var next=0
                func enqueue(){let id=nodes[next].id;next+=1;group.addTask{if Task.isCancelled{return(id,nil)};let delay=try? await client.delay(id);return(id,delay)}}
                for _ in 0..<min(4,nodes.count){enqueue()}
                while let (id,delay)=await group.next(){if Task.isCancelled{group.cancelAll();break};result.latency[id.uuidString]=LatencyResult(milliseconds:delay);completed+=1;measurementProgress="HTTPS 延迟 \(completed)/\(nodes.count)";if next<nodes.count{enqueue()}}
            }
            if !Task.isCancelled,epoch==measurementEpoch,latencyInvalidatedAt==invalidation {latencyClock=Date();try persist(result);log("HTTPS 延迟检测完成")}
        }catch{if !Task.isCancelled{report(error)}}
        if !live {if let client{await client.shutdown()};await temporaryCore?.stop();temporaryAPI=nil;temporaryCore=nil}
    }
    func setAutoConnect(_ value:Bool){guard !locked else{return};do{var next=state;next.autoConnect=value;try persist(next)}catch{report(error)}}
    func setLoginAtStartup(_ value:Bool) {
        guard !locked else{return}
        do {
            if value {guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {throw ProxyError("请先将应用放入 Applications，再启用登录启动")};try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}
            var next=state;next.loginAtStartup=value;try persist(next)
            if SMAppService.mainApp.status == .requiresApproval {errorMessage="请到系统设置中的登录项允许轻舟代理"}
        }catch{report(error)}
    }
    func copyTerminalProxy(){let p=state.listenPort;let value="export http_proxy=http://127.0.0.1:\(p) https_proxy=http://127.0.0.1:\(p) all_proxy=socks5h://127.0.0.1:\(p) HTTP_PROXY=http://127.0.0.1:\(p) HTTPS_PROXY=http://127.0.0.1:\(p) ALL_PROXY=socks5h://127.0.0.1:\(p)";NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string);log("已复制本地终端代理命令，不包含节点凭据")}
    private func synchronizeShortcut(){do{try shortcuts.configure(enabled:state.shortcutEnabled,key:state.shortcutKey,modifiers:state.shortcutModifiers)}catch{log("快捷键冲突，未注册全局快捷键")}}
    func setShortcut(enabled:Bool,key:UInt32,modifiers:UInt32){guard !locked else{return};let old=state;do{guard [UInt32(35),2,15].contains(key),[UInt32(2304),4352,6144,6400].contains(modifiers) else{throw ProxyError("不支持的快捷键组合")};try shortcuts.configure(enabled:enabled,key:key,modifiers:modifiers);var next=state;next.shortcutEnabled=enabled;next.shortcutKey=key;next.shortcutModifiers=modifiers;do{try persist(next)}catch{try? shortcuts.configure(enabled:old.shortcutEnabled,key:old.shortcutKey,modifiers:old.shortcutModifiers);throw error}}catch{report(error)}}
    func applyCaptureSettings(mode:CaptureMode,dns:DNSPreference,family:AddressFamilyPolicy,httpCompatibility:Bool) async -> Bool {
        guard !locked,let store else {return false}
        busy=true;defer{busy=false}
        do {
            var next=state;next.captureMode=mode;next.dnsPreference=dns;next.addressFamilyPolicy=family;next.httpCompatibilityEnabled=httpCompatibility
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
            try await HelperInstaller.install(app:Bundle.main.bundleURL)
            await capture.helper.closeChannel()
            let status=try await HelperReadiness.wait {try await self.capture.helperStatus()}
            guard status.protocolVersion==5 else{throw ProxyError("安装后辅助服务协议仍不匹配")}
            try await capture.emergencyRecover(preserveExternal:true);recoveryPending=false;connection = .disconnected;helperStatus="辅助服务更新完成并已核对";log(helperStatus)
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
    func createProfile(name:String,copy:Bool,officeDomains:[String]=[]) async {
        guard !locked,let store else{return};busy=true;defer{busy=false}
        do{let root=try ProfileStore.create(in:store.catalog,name:name,copyID:copy ? currentProfileID:nil,officeDomains:officeDomains);try await apply(store.prepareCatalog(root),reconfigure:false)}catch{report(error)}
    }
    func renameProfile(_ id:UUID,name:String) async {
        guard !locked,let store else{return};busy=true;defer{busy=false}
        do{try await apply(store.prepareCatalog(ProfileStore.rename(id,to:name,in:store.catalog)),reconfigure:false)}catch{report(error)}
    }
    func deleteProfile(_ id:UUID) async {
        guard !locked,let store else{return}
        guard drafts.allowLeaving("删除配置",profile:id) else{return};busy=true;defer{busy=false}
        do{try await apply(store.prepareCatalog(ProfileStore.remove(id,in:store.catalog)),reconfigure:false)}catch{report(error)}
    }
    func recordBackup(_ url:URL) {guard let store else{return};do{var root=store.catalog;root.backupIndex.append(BackupIndex(fileName:url.lastPathComponent));if root.backupIndex.count>100{root.backupIndex.removeFirst(root.backupIndex.count-100)};try store.commit(store.prepareCatalog(root));state=store.state}catch{report(error)}}
    func migrationSnapshot() throws -> BackupSnapshot {let ref=try String(contentsOf:directory.appendingPathComponent("migration-v3.keyref"),encoding:.utf8);return try BackupService.decrypt(Data(contentsOf:directory.appendingPathComponent("migration-v3.qzb")),password:credentials.get(ref))}
    func restoreBackup(_ snapshot:BackupSnapshot) async {
        guard !locked,let store else{return}
        guard drafts.allowLeaving("恢复备份",all:true) else{return};busy=true;defer{busy=false}
        do{try await apply(store.prepareRestore(snapshot));log("加密备份恢复完成")}catch{report(error)}
    }
    func saveNote(_ id:UUID,note:String){guard !locked else{return};do{guard note.utf8.count<=4096 else{throw ProxyError("备注不能超过 4096 字节")};var next=state;next.notes[id.uuidString]=note;try persist(next)}catch{report(error)}}
    func setCompact(_ value:Bool){guard !locked else{return};do{var next=state;next.compactNodes=value;try persist(next)}catch{report(error)}}
    func batchFavorite(_ ids:Set<UUID>,value:Bool){guard !locked else{return};do{var next=state;if value{next.favorites.formUnion(ids)}else{next.favorites.subtract(ids)};try persist(next)}catch{report(error)}}
    func batchDelete(_ ids:Set<UUID>) async{guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteNodes(ids))}catch{report(error)}}
    func handleHealthPowerEvent(_ event:HealthPowerEvent) {
        if case .willSleep=event,!healthPower.systemSleeping {
            let connected=connection == .connected || wakeRebuilding
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
    func cancelHealthRefresh() {healthScheduler.cancel();healthChecking=false;connectivityEpoch=UUID()}
    func scheduleHealthRefresh(delay:UInt64=1_000_000_000) {
        guard connection == .connected,!wakeRecovery.active else{return}
        guard !healthPower.suspended else{healthRefreshPending=true;return}
        guard !locked,let client=api else{healthRefreshPending=true;return}
        let delay=max(delay,UInt64(healthPower.remaining(uptime:healthPowerUptime())*1_000_000_000))
        healthRefreshPending=false;let token=epoch
        healthScheduler.schedule(delay:delay) { [weak self] in
            guard let self,self.epoch==token,!self.locked else{return}
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
                if let actual=CoreAPIClient.actualTag(proxyInfo),actual.hasPrefix("node-"),let id=UUID(uuidString:String(actual.dropFirst(5))) {ids.insert(id)}
                else if let first=state.nodes.first {ids.insert(first.id)}
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
    private func healthCheck(_ client:CoreAPIClient,token:UUID) async {
        let powerGeneration=healthPower.generation
        guard !locked,epoch==token,connection == .connected,state.mode != .direct,healthResultIsCurrent(powerGeneration) else{return};healthChecking=true;defer{if epoch==token,healthPower.generation==powerGeneration{healthChecking=false}}
        let relevant=healthNodeIDs()
        let nodes=state.nodes.filter{relevant.contains($0.id)};var results:[UUID:Bool]=[:];var statuses:[ProbeStatus]=[]
        await withTaskGroup(of:(UUID,ProbeStatus).self){group in var cursor=0;func enqueue(){let id=nodes[cursor].id;cursor+=1;group.addTask{(id,await client.probe(id))}};for _ in 0..<min(4,nodes.count){enqueue()};while let (id,status)=await group.next(){guard !Task.isCancelled else{group.cancelAll();break};statuses.append(status);switch status{case .available:results[id]=true;case .unavailable:results[id]=false;case .unknown:break};if cursor<nodes.count{enqueue()}}}
        guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return}
        // 控制通道和节点健康独立评估，未知节点不阻断其他回退组的判定。
        do {_ = try await client.proxies();guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return};failedHealthCycles=0}
        catch {
            guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return};monitor.health="节点健康暂无法核对";failedHealthCycles+=1
            log("健康检查：控制接口失败 category="+ConnectivityResult.category(error)+" consecutive=\(failedHealthCycles)")
            if failedHealthCycles>=2 {log("自动断开原因：清醒状态下核心控制接口连续不可达");busy=true;defer{busy=false};do{try await disconnectInternal();connection = .error;errorMessage="核心控制接口连续不可达，已恢复网络"}catch{report(error)}}
            return
        }
        monitor.health = statuses.contains(where:{if case .unknown=$0{return true};return false}) ? "节点健康部分无法确定" : statuses.contains(where:{if case .unavailable=$0{return true};return false}) ? "部分节点检测失败" : nil
        if recordNodeHealth(statuses,powerGeneration:powerGeneration) {log("自动断开原因：清醒状态下全部相关节点连续两轮不可用");busy=true;defer{busy=false};do{try await disconnectInternal();connection = .error;errorMessage="全部节点不可用，代理已失效，原网络已恢复"}catch{report(error)};return}
        for group in state.groups where group.kind == .fallback && group.members.contains(where:{if case .node(let id)=$0{return relevant.contains(id)};return false}) {
            guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return}
            let priority=group.members.compactMap{ref -> UUID? in if case .node(let id)=ref{return id};return nil};let currentTag=proxyInfo[PolicyReference.group(group.id).tag]?.now
            let current=priority.first{PolicyReference.node($0).tag==currentTag} ?? {if case .node(let id)=group.selected{return id};return nil}()
            var controller=fallbackStates[group.id] ?? FallbackController();let decision=controller.evaluate(priority:priority,current:current,results:results);fallbackStates[group.id]=controller
            if decision.unavailable {monitor.health="回退组 \(group.name) 全部不可用";if state.activePolicy == .group(group.id){log("自动断开原因：清醒状态下当前回退组全部不可用");busy=true;defer{busy=false};do{try await disconnectInternal();connection = .error;errorMessage="回退组全部不可用，代理已失效，原网络已恢复"}catch{report(error)}};continue}
            if let selected=decision.selected,selected != current {do{try await client.select(.node(selected),group:PolicyReference.group(group.id).tag);guard epoch==token,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return};log("优先级回退已切换，已有连接保留")}catch{report(error)}}
        }
    }
    func checkConnectivity() async {
        guard !locked,!Task.isCancelled,let api else{return};let powerGeneration=healthPower.generation;guard healthResultIsCurrent(powerGeneration) else{return};let token=epoch;let probeToken=UUID();connectivityEpoch=probeToken
        // 后台复查保留上次完成的结果，避免每轮检测都闪回“检测中”。
        if connectivityResults.isEmpty {connectivityResults=ConnectivityResult.pending}
        let results=await ConnectivityProbe.all(port:state.captureMode.usesTunnel ? nil:state.listenPort,client:api,mode:state.mode)
        guard epoch==token,connectivityEpoch==probeToken,connection == .connected,!Task.isCancelled,!locked,healthResultIsCurrent(powerGeneration) else{return}
        connectivityResults=results
        reachability=ConnectivityResult.combinedSummary(results)
        for result in results {log(result.summary+(result.milliseconds.map{" 耗时=\($0)ms"} ?? ""))}
    }
    func quit() async -> Bool {
        await cancelWakeRecoveryAndWait()
        guard !busy else {errorMessage="正在更新配置，请稍后退出";return false}
        guard drafts.allowLeaving("退出轻舟",all:true) else{return false}
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
                self.log("退出时已确认轻舟不再接管；恢复记录留待下次处理："+Redactor.redact(error.localizedDescription))
            })
            connection = .disconnected
            await timeline.drain()
            return true
        } catch {report(error);return false}
    }
}
