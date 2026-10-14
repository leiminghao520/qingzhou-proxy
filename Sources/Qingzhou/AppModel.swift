import Foundation
import Darwin
import SwiftUI
import AppKit
import CoreImage
import ServiceManagement
import QingzhouKit

@MainActor final class AppModel:ObservableObject {
    enum Connection:String {case disconnected="未连接",connecting="连接中",connected="已连接",disconnecting="断开中",error="错误"}
    @Published var state=AppState()
    @Published var connection=Connection.disconnected
    @Published var reachability="尚未检测"
    @Published var connectivityResults=ConnectivityResult.pending
    @Published var busy=false {didSet{if !busy{drainPendingDisconnect()}}}
    @Published var measuring=false {didSet{if !measuring{drainPendingDisconnect()}}}
    @Published var measurementProgress=""
    @Published var errorMessage:String?
    @Published var logs:[String]=[]
    @Published var preview:ImportPreview?
    @Published var previewDiff:UpdateDiff?
    @Published var rateHistory:[RateSample]=[]
    @Published var trafficByNode:[String:Int64]=[:]
    @Published var trafficByTarget:[String:Int64]=[:]
    private var observedConnections:[String:Int64]=[:]
    private let shortcuts=ShortcutController()
    @Published var diagnosticRows:[DiagnosticResult]=[]
    @Published var diagnosing=false
    private var fallbackStates:[UUID:FallbackController]=[:]
    private var healthTask:Task<Void,Never>?
    private var failedHealthCycles=0
    private var healthFailures=HealthFailureCounter()
    @Published var recoveryPending=false
    @Published var loadingFailed=false
    @Published var uploadRate:Int64=0
    @Published var downloadRate:Int64=0
    @Published var uploadTotal:Int64=0
    @Published var downloadTotal:Int64=0
    @Published var connections:[CoreConnection]=[]
    @Published var proxyInfo:[String:ProxyInfo]=[:]
    @Published var monitorPaused=false
    @Published var monitorStatus="未连接"
    private(set) var store:NodeStore?
    let credentials=KeychainStore()
    let core:CoreController
    let proxy:SystemProxyController
    let directory:URL
    lazy var capture=CaptureController(core:core,proxy:proxy)
    @Published var helperStatus="未检测"
    @Published var protectionSummary:[String]=[]
    private var api:CoreAPIClient?
    private var connectivityEpoch=UUID()
    private var telemetryTask:Task<Void,Never>?
    private var trafficTask:Task<Void,Never>?
    private var maintenanceTask:Task<Void,Never>?
    private var measurementTask:Task<Void,Never>?
    private var temporaryCore:CoreController?
    private var temporaryAPI:CoreAPIClient?
    private var epoch=UUID()
    private var networkChanged=false
    private var coreFailed=false
    private var sessionLockFD:Int32 = -1
    private var pendingSubscription:Subscription?
    private var started=false
    private var diagnosticLog:DiagnosticLog?
    private var diagnosticLogFailed=false
    var locked:Bool {busy || measuring || loadingFailed}
    var selected:Node? {if case .node(let id)=state.activePolicy {return state.nodes.first{$0.id==id}};return nil}
    var selectedName:String {state.label(state.activePolicy)}
    var actualName:String {if state.mode == .direct{return "直连"};guard let tag=CoreAPIClient.actualTag(proxyInfo) else {return "尚未检测"};return label(tag)}
    var allNodesUnavailable:Bool { !state.nodes.isEmpty && state.nodes.allSatisfy{proxyInfo[PolicyReference.node($0.id).tag]?.history?.last == nil} }
    init() {
        // 独立测试目录由启动参数显式指定，不改变日常配置位置。
        if let index=CommandLine.arguments.firstIndex(of:"--test-directory"),index+1<CommandLine.arguments.count,CommandLine.arguments[index+1].hasPrefix("/") {
            directory=URL(fileURLWithPath:CommandLine.arguments[index+1])
        }else{directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Qingzhou")}
        core=CoreController(directory:directory);proxy=SystemProxyController(journal:directory.appendingPathComponent("proxy-recovery.json"))
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            sessionLockFD=open(directory.appendingPathComponent("session.lock").path,O_CREAT|O_RDWR,0o600)
            if sessionLockFD>=0 {_ = fcntl(sessionLockFD,F_SETFD,FD_CLOEXEC)}
            guard sessionLockFD>=0,flock(sessionLockFD,LOCK_EX|LOCK_NB)==0 else {throw ProxyError("应用已经运行")}
            store=try NodeStore(file:directory.appendingPathComponent("state.json"),credentials:credentials);state=store!.state
        } catch {loadingFailed=true;errorMessage="配置无法读取或应用已运行，未覆盖原文件。";return}
        diagnosticLog=DiagnosticLog(url:directory.appendingPathComponent("diagnostic.log"))
        log("应用启动，正在检查上次恢复记录")
        recoveryPending=proxy.hasRecovery
        core.log={ [weak self] in self?.log($0) }
        proxy.log={ [weak self] in self?.log($0) }
        core.onUnexpectedExit={ [weak self] in guard let self else{return};self.stopTelemetry();self.coreFailed=true;self.cancelMeasurement();self.drainPendingDisconnect() }
        proxy.onNetworkChange={ [weak self] in guard let self,self.connection == .connected || self.connection == .connecting else{return};self.networkChanged=true;self.cancelMeasurement();self.drainPendingDisconnect() }
        proxy.startMonitoring()
        shortcuts.action={ [weak self] in Task{@MainActor in guard let self else{return};if self.connection == .connected{await self.disconnect()}else{await self.connect()}}}
        synchronizeShortcut()
        // 只有持有实例锁的应用才清理自己上次遗留的敏感运行文件。
        if let files=try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {for file in files where file.lastPathComponent.hasPrefix("runtime-") || file.lastPathComponent.hasPrefix("check-") {try? FileManager.default.removeItem(at:file)}}
    }
    // 测速或配置更新期间的退出和网络变更延后串行恢复，避免被操作锁跳过。
    private func drainPendingDisconnect() {
        guard !locked,(coreFailed || networkChanged),connection == .connected else{return}
        let failed=coreFailed;log(failed ? "自动断开原因：核心或兼容层退出":"自动断开原因：网络所有权变化");coreFailed=false;networkChanged=false;busy=true
        Task {defer{busy=false};do{try await disconnectInternal();if failed{connection = .error};errorMessage=failed ? "核心异常退出，已恢复系统代理" : "网络服务发生变化，已断开，请重新连接"}catch{report(error)}}
    }
    func label(_ tag:String) -> String {
        if tag=="auto"{return "自动选择"};if tag=="direct"{return "直连"};if tag=="proxy"{return "当前选择"}
        if let node=state.nodes.first(where:{PolicyReference.node($0.id).tag==tag}){return node.name}
        if let group=state.groups.first(where:{PolicyReference.group($0.id).tag==tag}){return group.name}
        return "未知出站"
    }
    func log(_ text:String) {let f=DateFormatter();f.dateFormat="HH:mm:ss";for line in text.components(separatedBy:.newlines) where !line.isEmpty {let safe="\(f.string(from:Date()))  \(Redactor.redact(line,secrets:core.secrets))";logs.append(safe);do{try diagnosticLog?.append(safe)}catch{if !diagnosticLogFailed{diagnosticLogFailed=true;logs.append("诊断日志保存失败，请检查用户目录权限")}}};if logs.count>500 {logs.removeFirst(logs.count-500)}}
    private func report(_ error:Error) {if error is CancellationError{return};errorMessage=Redactor.redact(error.localizedDescription);log(errorMessage!)}
    private func persist(_ next:AppState) throws {guard let store else {throw ProxyError("配置未加载")};try store.commit(next);state=store.state}
    private func secrets(_ next:AppState,_ control:CoreControlContext) -> [String] {[control.secret]+next.nodes.flatMap{[(try? credentials.get($0.credentialRef)) ?? "",(try? credentials.get($0.credentialRef+".obfs")) ?? ""]}}
    private func startService(_ next:AppState) async throws {
        if next.captureMode == .systemProxy {try NetworkSafety.check()}
        NSApplication.shared.activate(ignoringOtherApps:true)
        let control=try CoreControlContext.make();_=try ConfigBuilder.build(state:next,credentials:credentials,control:control)
        core.secrets=secrets(next,control);networkChanged=false;coreFailed=false
        try await capture.start(next,credentials:credentials,control:control)
        let client=CoreAPIClient(context:control)
        do {
            _=try await client.proxies()
            guard !networkChanged else {throw ProxyError("启动期间网络发生变化")}
            try capture.activateSystemProxy(port:next.listenPort)
            guard capture.running else {throw ProxyError("核心已经退出")}
            connection = .connected;recoveryPending=proxy.hasRecovery;startTelemetry(client)
        } catch {
            await client.shutdown()
            let original=error
            do{try await capture.emergencyRecover()}catch{recoveryPending=true;throw ProxyError("启动失败："+original.localizedDescription+"；"+error.localizedDescription)}
            throw original
        }
    }
    // 元数据和凭据仅在新配置实际应用成功后提交；失败时恢复原运行配置。
    private func apply(_ tx:StoreTransaction,reconfigure:Bool=true) async throws {
        guard let store else {throw ProxyError("配置未加载")}
        do {
            try await RuntimeTransaction.apply(tx,connected:reconfigure && connection == .connected,validate:{
                try PolicyValidator.validate(tx.next)
                if reconfigure && self.connection == .connected && !tx.next.nodes.isEmpty {let context=try CoreControlContext.make();try await self.core.validate(config:ConfigBuilder.build(state:tx.next,credentials:self.credentials,control:context))}
            },stop:{if self.capture.running || self.proxy.hasRecovery || self.connection == .connected {try await self.disconnectInternal()}},start:{try await self.startService($0)},commit:{try store.commit(tx)},abort:{store.abort(tx)})
            state=store.state;synchronizeShortcut()
            if reconfigure && connection == .connected{reachability="配置已更新，新连接生效"}
        }catch{state=store.state;report(error);throw error}
    }

    func importPreview(_ input:String) async {guard !locked else{return};busy=true;defer{busy=false};do{pendingSubscription=nil;previewDiff=nil;preview=try await ImportService.preview(input)}catch{report(error)}}
    func importFile(_ url:URL) async {
        guard !locked else{return};busy=true;defer{busy=false};let granted=url.startAccessingSecurityScopedResource();defer{if granted{url.stopAccessingSecurityScopedResource()}}
        do {let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max)<=2*1024*1024 else {throw ProxyError("文件超过 2 MiB")};let data=try Data(contentsOf:url);let text:String
            if ["png","jpg","jpeg","heic","tiff","gif"].contains(url.pathExtension.lowercased()) {
                guard let image=CIImage(data:data),image.extent.width*image.extent.height<=20_000_000,let detector=CIDetector(ofType:CIDetectorTypeQRCode,context:CIContext(),options:[CIDetectorAccuracy:CIDetectorAccuracyHigh]) else{throw ProxyError("二维码图片无效或尺寸过大")}
                let links=detector.features(in:image).compactMap{($0 as? CIQRCodeFeature)?.messageString};guard !links.isEmpty,links.count<=20 else{throw ProxyError("未识别到二维码或二维码数量超过限制")};text=links.joined(separator:"\n")
            }else{guard let decoded=String(data:data,encoding:.utf8) else{throw ProxyError("文件必须为 UTF-8 或本地二维码图片")};text=decoded}
            pendingSubscription=nil;previewDiff=nil;preview=try ProfileImporter.parse(text)}catch{report(error)}
    }
    func confirmImport(scope:ImportScope = .nodes) async {
        guard !locked,let preview,let store else{return};busy=true;defer{busy=false}
        do {
            var sub=pendingSubscription
            if sub==nil,let source=preview.source {sub=state.subscriptions.first{(try? credentials.get($0.sourceRef))==source} ?? Subscription(name:"订阅 \(state.subscriptions.count+1)")}
            let effectiveScope:ImportScope=preview.fullConfiguration != nil ? .profile:scope
            let tx=try store.prepareImport(preview.candidates,subscription:sub,source:preview.source,profile:preview,scope:effectiveScope)
            try await apply(tx);self.preview=nil;pendingSubscription=nil;log("导入已完成")
        } catch {report(error)}
    }
    func cancelPreview(){preview=nil;previewDiff=nil;pendingSubscription=nil}
    func refresh(_ sub:Subscription) async {guard !locked else{return};busy=true;defer{busy=false};do{let result=try await ImportService.preview(credentials.get(sub.sourceRef));pendingSubscription=sub;previewDiff=UpdateDiff.compare(old:state,preview:result,subscriptionID:sub.id,credentials:credentials);preview=result}catch{recordSubscriptionFailure(sub.id,error:error);report(error)}}
    func saveManual(_ candidate:Candidate,editingID:UUID?) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{let tx=try store.prepareImport([candidate],replacingID:editingID);try await apply(tx);log("节点已保存")}catch{report(error)}}
    func deleteNode(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteNode(id))}catch{report(error)}}
    func deleteSubscription(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteSubscription(id))}catch{report(error)}}
    func select(_ id:UUID?) async {guard let id else{return};await selectPolicy(.node(id))}
    func selectPolicy(_ ref:PolicyReference) async {
        guard !locked,ref != state.activePolicy,PolicyValidator.exists(ref,in:state),ref != .selected,ref != .reject else{return};busy=true;defer{busy=false}
        let old=state.activePolicy
        do {
            if let api,connection == .connected {try await api.select(ref)}
            var next=state;next.selectedPolicy=ref;if case .node(let id)=ref {next.selectedID=id;next.recentUse[id.uuidString]=Date()}
            do{try persist(next)}catch{if let api,let old{try? await api.select(old)};throw error}
            log("已选择 \(state.label(ref))，已有连接保留");if connection == .connected{await checkConnectivity()}
        } catch {report(error)}
    }
    func setMode(_ mode:ProxyMode) async {
        guard !locked,mode != state.mode else{return};busy=true;defer{busy=false};let old=state.mode
        do {if let api,connection == .connected {try await api.setMode(mode)};var next=state;next.mode=mode;do{try persist(next)}catch{if let api{try? await api.setMode(old)};throw error};log("已切换为\(mode.label)，新连接生效");if connection == .connected{await checkConnectivity()}}catch{report(error)}
    }
    func toggleFavorite(_ id:UUID) {guard !locked else{return};do{var next=state;if next.favorites.contains(id){next.favorites.remove(id)}else{next.favorites.insert(id)};try persist(next)}catch{report(error)}}
    func saveSettings(port:Int,rulesEnabled:Bool) async {await savePort(port);if !locked {await setMode(rulesEnabled ? .rule : .global)}}
    func savePort(_ port:Int) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{guard (1024...65535).contains(port) else {throw ProxyError("监听端口必须为 1024–65535")};var next=state;next.listenPort=port;try await apply(store.prepareChange(next))}catch{report(error)}}
    func updateSubscription(_ id:UUID,name:String?=nil,auto:Bool?=nil) {guard !locked else{return};do{var next=state;guard let i=next.subscriptions.firstIndex(where:{$0.id==id}) else{return};if let name{guard !name.trimmingCharacters(in:.whitespaces).isEmpty else {throw ProxyError("订阅名称不能为空")};next.subscriptions[i].name=name};if let auto{next.subscriptions[i].autoUpdate=auto;next.subscriptions[i].retryCount=0;next.subscriptions[i].retryAfter=nil};try persist(next)}catch{report(error)}}
    func addRule(_ rule:RoutingRule) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try ConfigBuilder.validate(rule);var next=state;next.rules.append(rule);try await apply(store.prepareChange(next))}catch{report(error)}}
    func setRuleFinal(_ ref:PolicyReference) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.ruleFinal=ref;try await apply(store.prepareChange(next))}catch{report(error)}}
    func removeRule(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.rules.removeAll{$0.id==id};try await apply(store.prepareChange(next))}catch{report(error)}}
    func moveRule(_ id:UUID,by offset:Int) async {guard !locked,let store,let i=state.rules.firstIndex(where:{$0.id==id}),state.rules.indices.contains(i+offset) else{return};busy=true;defer{busy=false};do{var next=state;next.rules.swapAt(i,i+offset);try await apply(store.prepareChange(next))}catch{report(error)}}
    func saveGroup(_ group:PolicyGroup) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.groups.removeAll{$0.id==group.id};next.groups.append(group);try PolicyValidator.validate(next);try await apply(store.prepareChange(next))}catch{report(error)}}
    func deleteGroup(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.groups.removeAll{$0.id==id};PolicyValidator.repair(&next);try await apply(store.prepareChange(next))}catch{report(error)}}
    func selectMember(_ group:PolicyGroup,_ ref:PolicyReference) async {
        guard !locked,group.kind == .select,group.members.contains(ref) else{return};busy=true;defer{busy=false}
        do {if let api{try await api.select(ref,group:PolicyReference.group(group.id).tag)};var next=state;guard let i=next.groups.firstIndex(where:{$0.id==group.id}) else{return};next.groups[i].selected=ref;do{try persist(next)}catch{if let api,let previous=group.selected{try? await api.select(previous,group:PolicyReference.group(group.id).tag)};throw error}}catch{report(error)}
    }
    func addRemote(name:String,url:String,target:PolicyReference) async {
        guard !locked,!name.isEmpty,let store else{return};busy=true;defer{busy=false};var source=RemoteRuleSource(name:name,target:target)
        do {source.rules=try await downloadRules(url);source.updatedAt=Date();try credentials.set(url,for:source.sourceRef);var next=state;next.remoteRules.append(source);do{try await apply(store.prepareChange(next))}catch{try? credentials.remove(source.sourceRef);throw error}}catch{report(error)}
    }
    private func downloadRules(_ source:String) async throws -> [RoutingRule] {guard let url=URL(string:source),url.scheme=="https" else {throw ProxyError("规则地址必须使用 HTTPS")};let data=try await BoundedDownload.fetch(url);guard let text=String(data:data,encoding:.utf8) else {throw ProxyError("规则必须为 UTF-8")};return try RemoteRulesParser.parse(text)}
    func refreshRemote(_ id:UUID,automatic:Bool=false) async {
        guard !locked,let store,let source=state.remoteRules.first(where:{$0.id==id}) else{return};busy=true;defer{busy=false}
        do {let rules=try await downloadRules(credentials.get(source.sourceRef));var next=state;guard let i=next.remoteRules.firstIndex(where:{$0.id==id}) else{return};next.remoteRules[i].rules=rules;next.remoteRules[i].updatedAt=Date();next.remoteRules[i].lastError=nil;next.remoteRules[i].retryCount=0;next.remoteRules[i].retryAfter=nil;try await apply(store.prepareChange(next));log("远程规则更新成功")}
        catch {var next=state;if let i=next.remoteRules.firstIndex(where:{$0.id==id}) {let count=next.remoteRules[i].retryCount>=4 ? 1 : next.remoteRules[i].retryCount+1;next.remoteRules[i].retryCount=count;next.remoteRules[i].retryAfter=UpdateSchedule.nextRetry(count) ?? Date().addingTimeInterval(86400);next.remoteRules[i].lastError=Redactor.redact(error.localizedDescription);try? persist(next)};if !automatic{report(error)}else{log("规则自动更新失败，保留旧缓存")}}
    }
    func updateRemote(_ id:UUID,auto:Bool?=nil,target:PolicyReference?=nil) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;guard let i=next.remoteRules.firstIndex(where:{$0.id==id}) else{return};if let auto{next.remoteRules[i].autoUpdate=auto;next.remoteRules[i].retryCount=0;next.remoteRules[i].retryAfter=nil};if let target{next.remoteRules[i].target=target};try await apply(store.prepareChange(next),reconfigure:target != nil)}catch{report(error)}}
    func moveRemote(_ id:UUID,by offset:Int) async {guard !locked,let store,let i=state.remoteRules.firstIndex(where:{$0.id==id}),state.remoteRules.indices.contains(i+offset) else{return};busy=true;defer{busy=false};do{var next=state;next.remoteRules.swapAt(i,i+offset);try await apply(store.prepareChange(next))}catch{report(error)}}
    func deleteRemote(_ id:UUID) async {guard !locked,let store,let source=state.remoteRules.first(where:{$0.id==id}) else{return};busy=true;defer{busy=false};do{var next=state;next.remoteRules.removeAll{$0.id==id};try await apply(store.prepareChange(next));if !store.catalog.credentialRefs.contains(source.sourceRef){try? credentials.remove(source.sourceRef)}}catch{report(error)}}
    func connect() async {
        guard !locked,state.activePolicy != nil || state.mode == .direct else{return};busy=true;connection = .connecting;reachability="尚未检测";connectivityResults=ConnectivityResult.pending;defer{busy=false}
        do {guard !proxy.hasRecovery else {throw ProxyError("请先恢复原代理")};try await startService(state);await checkConnectivity();guard capture.running,!networkChanged else {throw ProxyError("连接期间核心退出或网络变化")};if state.captureMode.usesTunnel && !reachability.contains("正常"){try await disconnectInternal();throw ProxyError("公网接管 HTTPS 验收失败，原网络已恢复；请查看诊断中的具体检测结果")};log(reachability)}catch {
            let original=error
            do{try await capture.emergencyRecover();recoveryPending=false}catch{recoveryPending=true;report(error)}
            stopTelemetry();connection = .error;report(original)
        }
    }
    private func disconnectInternal() async throws {connection = .disconnecting;do{try await capture.stop()}catch{recoveryPending=true;connection = .error;throw error};stopTelemetry();recoveryPending=proxy.hasRecovery;connection = .disconnected;connectivityResults=ConnectivityResult.pending;reachability="尚未检测";log("本次连接已停止；本地代理恢复完成，辅助服务是否恢复取决于本次接管状态")}
    func disconnect() async {guard !locked else{return};busy=true;defer{busy=false};do{try await disconnectInternal()}catch{report(error)}}
    func recover() async {
        guard !locked else{return};busy=true;defer{busy=false};connection = .disconnecting
        log("应急恢复开始：核对本地代理及已安装辅助服务，与当前模式无关")
        do {
            try await capture.emergencyRecover();stopTelemetry();protectionSummary=[];recoveryPending=false;connection = .disconnected
            helperStatus="轻舟拥有的网络设置已恢复并核对";reachability="尚未检测";log(helperStatus)
        }catch {stopTelemetry();recoveryPending=true;connection = .error;helperStatus="恢复未完成，请查看错误及恢复记录";report(error)}
    }
    func startupRecovery() async {
        guard !started,!loadingFailed else{return};started=true
        if FileManager.default.fileExists(atPath:HelperPaths.socket){do{let status=try await capture.helperStatus();helperStatus=status.message;if status.message.contains("待恢复") || status.running{recoveryPending=true;try await capture.recoverHelper();recoveryPending=proxy.hasRecovery}}catch{helperStatus=error.localizedDescription;recoveryPending=true}}
        if recoveryPending {await recover()};if state.autoConnect && !proxy.hasRecovery && !recoveryPending {await connect()}
        maintenanceTask=Task{[weak self] in while !Task.isCancelled {await self?.maintenance();try? await Task.sleep(nanoseconds:60_000_000_000)}}
    }
    private func startTelemetry(_ client:CoreAPIClient) {
        stopTelemetry();healthFailures=HealthFailureCounter();rateHistory=[];trafficByNode=[:];trafficByTarget=[:];observedConnections=[:];fallbackStates=[:];failedHealthCycles=0;api=client;let token=UUID();epoch=token;monitorStatus="实时监控"
        healthTask=Task{[weak self] in while !Task.isCancelled{await self?.healthCheck(client,token:token);try? await Task.sleep(nanoseconds:60_000_000_000)}}
        telemetryTask=Task{[weak self] in
            while !Task.isCancelled {
                guard let self,self.epoch==token else{return}
                let hidden=NSApplication.shared.isHidden || NSApplication.shared.windows.filter{$0.canBecomeMain}.allSatisfy{!$0.isVisible || $0.isMiniaturized}
                if !self.monitorPaused {
                    do {if self.capture.activeMode?.usesTunnel == true {let status=try await self.capture.helperStatus();self.helperStatus=status.message;self.protectionSummary=status.protectionSummary ?? [];if !status.running {self.log(status.message);self.coreFailed=true;self.drainPendingDisconnect();return}}
                    let snapshot=try await client.connections();let info=try await client.proxies();guard self.epoch==token,!Task.isCancelled else{return};self.aggregate(snapshot.connections);self.connections=snapshot.connections;self.uploadTotal=snapshot.uploadTotal;self.downloadTotal=snapshot.downloadTotal;let changed=CoreAPIClient.actualTag(self.proxyInfo) != CoreAPIClient.actualTag(info);self.proxyInfo=info;self.monitorStatus="实时监控";if changed,self.connectivityResults != ConnectivityResult.pending {Task{await self.checkConnectivity()}}}
                    catch {if self.epoch==token,!Task.isCancelled{self.monitorStatus="监控暂不可用"}}
                }
                try? await Task.sleep(nanoseconds:hidden ? 5_000_000_000 : 1_000_000_000)
            }
        }
        trafficTask=Task{[weak self] in
            do {let stream=try await client.traffic();var last=Date.distantPast
                for try await rate in stream {guard let self,!Task.isCancelled,self.epoch==token else{return};let hidden=NSApplication.shared.isHidden || NSApplication.shared.windows.filter{$0.canBecomeMain}.allSatisfy{!$0.isVisible || $0.isMiniaturized};if !self.monitorPaused && Date().timeIntervalSince(last)>=(hidden ? 5 : 0.8){self.uploadRate=max(0,rate.up);self.downloadRate=max(0,rate.down);last=Date();self.rateHistory.append(RateSample(upload:self.uploadRate,download:self.downloadRate));self.rateHistory.removeAll{Date().timeIntervalSince($0.time)>1800}}}
            }catch{if let self,self.epoch==token,!Task.isCancelled{self.monitorStatus="流量通道暂不可用"}}
        }
    }
    private func stopTelemetry() {epoch=UUID();healthTask?.cancel();healthTask=nil;telemetryTask?.cancel();trafficTask?.cancel();telemetryTask=nil;trafficTask=nil;if let old=api{Task{await old.shutdown()}};api=nil;connections=[];proxyInfo=[:];uploadRate=0;downloadRate=0;uploadTotal=0;downloadTotal=0;monitorStatus="未连接"}
    func closeConnection(_ id:String?) async {guard !locked,let api else{return};do{if let id{try await api.closeConnection(id)}else{try await api.closeAllConnections()}}catch{report(error)}}
    func measure(_ ids:[UUID]?=nil) {
        guard !locked,!state.nodes.isEmpty else{return};measuring=true;measurementProgress="准备测速"
        let candidates=state.nodes.filter{ids==nil || ids!.contains($0.id)};guard !candidates.isEmpty else {measuring=false;return}
        measurementTask=Task{[weak self] in guard let self else{return};await self.performMeasurement(candidates)}
    }
    func cancelMeasurement(){measurementTask?.cancel()}
    private func performMeasurement(_ nodes:[Node]) async {
        let live=connection == .connected;var client=api;var result=state
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
            if !Task.isCancelled {try persist(result);log("HTTPS 延迟检测完成")}
        }catch{if !Task.isCancelled{report(error)}}
        if !live {if let client{await client.shutdown()};await temporaryCore?.stop();temporaryAPI=nil;temporaryCore=nil}
    }
    private func recordSubscriptionFailure(_ id:UUID,error:Error) {var next=state;guard let i=next.subscriptions.firstIndex(where:{$0.id==id}) else{return};let count=next.subscriptions[i].retryCount>=4 ? 1 : next.subscriptions[i].retryCount+1;next.subscriptions[i].retryCount=count;next.subscriptions[i].retryAfter=UpdateSchedule.nextRetry(count) ?? Date().addingTimeInterval(86400);next.subscriptions[i].lastError=Redactor.redact(error.localizedDescription);try? persist(next)}
    private func automaticRefresh(_ id:UUID) async {
        guard !locked,let sub=state.subscriptions.first(where:{$0.id==id}),let store else{return};busy=true;defer{busy=false}
        do {
            let result=try await ImportService.preview(credentials.get(sub.sourceRef))
            let old=state.nodes.filter{$0.subscriptionID==id}
            let insecure=result.candidates.contains{candidate in candidate.node.insecure && !old.contains{$0.fingerprint==candidate.node.fingerprint && $0.insecure}}
            if insecure || UpdateDiff.compare(old:state,preview:result,subscriptionID:id,credentials:credentials).requiresReview || (sub.scope == .profile && !result.unsupported.isEmpty) || (sub.scope == .nodes && !result.unsupported.filter{!$0.hasPrefix("完整导入") && !$0.hasPrefix("规则") && !$0.hasPrefix("策略")}.isEmpty) {
                var next=state;if let i=next.subscriptions.firstIndex(where:{$0.id==id}){next.subscriptions[i].pendingReview=true;next.subscriptions[i].lastError="更新需要人工预览确认"};try persist(next);log("订阅更新需要人工确认，保留旧节点");return
            }
            let tx=try store.prepareImport(result.candidates,subscription:sub,source:result.source,profile:result,scope:result.fullConfiguration != nil ? .profile:sub.scope);try await apply(tx);log("订阅自动更新成功")
        }catch{recordSubscriptionFailure(id,error:error);log("订阅自动更新失败，保留旧节点")}
    }
    private func maintenance() async {
        guard !locked else{return}
        let subs=state.subscriptions.filter{UpdateSchedule.due(updatedAt:$0.updatedAt,enabled:$0.autoUpdate,pending:$0.pendingReview,retryCount:$0.retryCount,retryAfter:$0.retryAfter)}.map(\.id)
        for id in subs {if Task.isCancelled{return};await automaticRefresh(id)}
        let sources=state.remoteRules.filter{UpdateSchedule.due(updatedAt:$0.updatedAt,enabled:$0.autoUpdate,retryCount:$0.retryCount,retryAfter:$0.retryAfter)}.map(\.id)
        for id in sources {if Task.isCancelled{return};await refreshRemote(id,automatic:true)}
    }
    func refreshAll() async {guard !locked else{return};for id in state.subscriptions.map(\.id){await automaticRefresh(id)};for id in state.remoteRules.map(\.id){await refreshRemote(id)}}
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
    private func aggregate(_ rows:[CoreConnection]) {
        for row in rows{let total=max(0,row.upload)+max(0,row.download);let delta=max(0,total-(observedConnections[row.id] ?? 0));observedConnections[row.id]=total
            let node=row.chains.first{ $0.hasPrefix("node-") } ?? "未提供";if trafficByNode.count<2000 || trafficByNode[node] != nil{trafficByNode[node,default:0]+=delta}
            let target=row.metadata.host?.isEmpty==false ? row.metadata.host! : row.metadata.destinationIP ?? "未提供";if trafficByTarget.count<2000 || trafficByTarget[target] != nil{trafficByTarget[target,default:0]+=delta}
        };let active=Set(rows.map(\.id));observedConnections=observedConnections.filter{active.contains($0.key)}
    }
    private func synchronizeShortcut(){do{try shortcuts.configure(enabled:state.shortcutEnabled,key:state.shortcutKey,modifiers:state.shortcutModifiers)}catch{log("快捷键冲突，未注册全局快捷键")}}
    func setShortcut(enabled:Bool,key:UInt32,modifiers:UInt32){guard !locked else{return};let old=state;do{guard [UInt32(35),2,15].contains(key),[UInt32(2304),4352,6144,6400].contains(modifiers) else{throw ProxyError("不支持的快捷键组合")};try shortcuts.configure(enabled:enabled,key:key,modifiers:modifiers);var next=state;next.shortcutEnabled=enabled;next.shortcutKey=key;next.shortcutModifiers=modifiers;do{try persist(next)}catch{try? shortcuts.configure(enabled:old.shortcutEnabled,key:old.shortcutKey,modifiers:old.shortcutModifiers);throw error}}catch{report(error)}}
    func saveTunExclusions(_ input:String) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.tunExcludedCIDRs=input.components(separatedBy:CharacterSet(charactersIn:",\n")).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty};try PolicyValidator.validate(next);try await apply(store.prepareChange(next))}catch{report(error)}}
    func saveProtectedDomains(_ input:String) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.protectedDomains=input.components(separatedBy:CharacterSet(charactersIn:",\n")).map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}.filter{!$0.isEmpty};try PolicyValidator.validate(next);try await apply(store.prepareChange(next))}catch{report(error)}}
    func setCaptureMode(_ mode:CaptureMode) async {guard !locked,let store,state.captureMode != mode else{return};busy=true;defer{busy=false};do{var next=state;next.captureMode=mode;try await apply(store.prepareChange(next))}catch{report(error)}}
    func setAddressFamily(_ policy:AddressFamilyPolicy) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.addressFamilyPolicy=policy;try await apply(store.prepareChange(next))}catch{report(error)}}
    func setDNS(_ mode:DNSPreference) async {guard !locked,let store,state.dnsPreference != mode else{return};busy=true;defer{busy=false};do{var next=state;next.dnsPreference=mode;try await apply(store.prepareChange(next))}catch{report(error)}}
    func inspectHelper() async {do{helperStatus=try await capture.helperStatus().message}catch{helperStatus=error.localizedDescription}}
    var profiles:[ClientProfile]{store?.catalog.profiles ?? []}
    var currentProfileID:UUID?{store?.catalog.currentProfileID}
    func changeProfile(_ id:UUID) async {
        guard !locked,let store,id != currentProfileID else{return};busy=true;defer{busy=false}
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
        guard !locked,let store else{return};busy=true;defer{busy=false}
        do{try await apply(store.prepareCatalog(ProfileStore.remove(id,in:store.catalog)),reconfigure:false)}catch{report(error)}
    }
    func recordBackup(_ url:URL) {guard let store else{return};do{var root=store.catalog;root.backupIndex.append(BackupIndex(fileName:url.lastPathComponent));if root.backupIndex.count>100{root.backupIndex.removeFirst(root.backupIndex.count-100)};try store.commit(store.prepareCatalog(root));state=store.state}catch{report(error)}}
    func migrationSnapshot() throws -> BackupSnapshot {let ref=try String(contentsOf:directory.appendingPathComponent("migration-v3.keyref"),encoding:.utf8);return try BackupService.decrypt(Data(contentsOf:directory.appendingPathComponent("migration-v3.qzb")),password:credentials.get(ref))}
    func restoreBackup(_ snapshot:BackupSnapshot) async {
        guard !locked,let store else{return};busy=true;defer{busy=false}
        do{try await apply(store.prepareRestore(snapshot));log("加密备份恢复完成")}catch{report(error)}
    }
    func saveNote(_ id:UUID,note:String){guard !locked else{return};do{guard note.utf8.count<=4096 else{throw ProxyError("备注不能超过 4096 字节")};var next=state;next.notes[id.uuidString]=note;try persist(next)}catch{report(error)}}
    func setCompact(_ value:Bool){guard !locked else{return};do{var next=state;next.compactNodes=value;try persist(next)}catch{report(error)}}
    func batchFavorite(_ ids:Set<UUID>,value:Bool){guard !locked else{return};do{var next=state;if value{next.favorites.formUnion(ids)}else{next.favorites.subtract(ids)};try persist(next)}catch{report(error)}}
    func batchDelete(_ ids:Set<UUID>) async{guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteNodes(ids))}catch{report(error)}}
    private func healthCheck(_ client:CoreAPIClient,token:UUID) async {
        guard !locked,epoch==token,connection == .connected,state.mode != .direct else{return};busy=true;defer{busy=false}
        let nodes=state.nodes;var results:[UUID:Bool]=[:];var statuses:[ProbeStatus]=[]
        await withTaskGroup(of:(UUID,ProbeStatus).self){group in var cursor=0;func enqueue(){let id=nodes[cursor].id;cursor+=1;group.addTask{(id,await client.probe(id))}};for _ in 0..<min(4,nodes.count){enqueue()};while let (id,status)=await group.next(){guard !Task.isCancelled else{group.cancelAll();break};statuses.append(status);switch status{case .available:results[id]=true;case .unavailable:results[id]=false;case .unknown:break};if cursor<nodes.count{enqueue()}}}
        guard epoch==token,!Task.isCancelled else{return}
        if statuses.contains(where:{if case .unknown=$0{return true};return false}) {
            healthFailures=HealthFailureCounter()
            // 测速目标失败不能代表核心退出，先独立核对本地控制通道。
            do {
                _=try await client.proxies()
                guard epoch==token,!Task.isCancelled else{return}
                failedHealthCycles=0
                monitorStatus="测速暂未完成，代理连接保留"
                log("健康检查：节点测速未确定，核心控制接口正常，保留当前连接")
            }catch{
                guard epoch==token,!Task.isCancelled else{return}
                failedHealthCycles+=1
                log("健康检查：核心控制接口复核失败 category="+ConnectivityResult.category(error)+" consecutive=\(failedHealthCycles)")
                if failedHealthCycles>=2 {
                    stopTelemetry()
                    do{try await disconnectInternal();connection = .error;errorMessage="核心控制接口连续不可达，已退出本次代理接管"}catch{report(error)}
                }
            }
            return
        }
        failedHealthCycles=0
        if healthFailures.update(statuses) {do{try await disconnectInternal();connection = .error;errorMessage="全部节点不可用，代理已失效，原网络已恢复"}catch{report(error)};return}
        for group in state.groups where group.kind == .fallback {
            let priority=group.members.compactMap{ref -> UUID? in if case .node(let id)=ref{return id};return nil};let currentTag=proxyInfo[PolicyReference.group(group.id).tag]?.now
            let current=priority.first{PolicyReference.node($0).tag==currentTag} ?? {if case .node(let id)=group.selected{return id};return nil}()
            var controller=fallbackStates[group.id] ?? FallbackController();let decision=controller.evaluate(priority:priority,current:current,results:results);fallbackStates[group.id]=controller
            if decision.unavailable {monitorStatus="回退组 \(group.name) 全部不可用";if state.activePolicy == .group(group.id){do{try await disconnectInternal();connection = .error;errorMessage="回退组全部不可用，代理已失效，原网络已恢复"}catch{report(error)}};continue}
            if let selected=decision.selected,selected != current {do{try await client.select(.node(selected),group:PolicyReference.group(group.id).tag);log("优先级回退已切换，已有连接保留")}catch{report(error)}}
        }
    }
    private func checkConnectivity() async {
        guard let api else{return};let token=epoch;let probeToken=UUID();connectivityEpoch=probeToken;connectivityResults=ConnectivityResult.pending
        let results=await ConnectivityProbe.all(port:state.captureMode.usesTunnel ? nil:state.listenPort,client:api,mode:state.mode)
        guard epoch==token,connectivityEpoch==probeToken,connection == .connected else{return}
        connectivityResults=results
        reachability=results[0].status == .passed ? "按当前规则的 HTTPS 连通性正常":results[0].summary
        for result in results {log(result.summary+(result.milliseconds.map{" 耗时=\($0)ms"} ?? ""))}
    }
    func diagnose() async {
        guard !locked,!diagnosing else{return};diagnosing=true;defer{diagnosing=false}
        diagnosticRows=DiagnosticService.local(state:state,corePath:core.binary.path,connected:connection == .connected)
        if state.captureMode.usesTunnel{do{let status=try await capture.helper.request(TunRequest(operation:"status",verifyNetwork:true));diagnosticRows.append(DiagnosticResult("管理员权限/辅助服务","通过","已通过固定客户端身份认证："+status.message));diagnosticRows.append(DiagnosticResult("TUN 路由",status.routesVerified==true ? "通过":status.running ? "失败":"未验证",status.running ? "核对四条接管路由及其接口、网关":"未启用接管"));protectionSummary=status.protectionSummary ?? [];diagnosticRows.append(DiagnosticResult("内网保护",status.protectionVerified==true ? "通过":status.running ? "失败":"未验证",protectionSummary.joined(separator:"；")));if state.captureMode == .compatible {diagnosticRows.append(DiagnosticResult("代理入口",status.proxyVerified==true ? "通过":"失败","核对兼容接管拥有的系统代理字段"))};diagnosticRows.append(DiagnosticResult("TUN DNS",status.dnsVerified==true ? "通过":status.running ? "失败":"未验证","核对当前 DNS 与本次所有权记录"))}catch{diagnosticRows.append(DiagnosticResult("管理员权限/辅助服务","失败",Redactor.redact(error.localizedDescription)))}}else{diagnosticRows.append(DiagnosticResult("系统代理权限","未验证","需要在连接时完成系统管理员授权；诊断不会自动申请"))}
        diagnosticRows.append(DiagnosticResult("系统代理恢复",proxy.hasRecovery ? "需检查":"通过",proxy.hasRecovery ? "保留恢复记录，可使用恢复入口":"没有待恢复记录"))
        if let node=selected ?? state.nodes.first{diagnosticRows.append(await DiagnosticService.dns(node.server))}else{diagnosticRows.append(DiagnosticResult("节点 DNS","未验证","尚未选择节点"))}
        if connection == .connected {await checkConnectivity();diagnosticRows += connectivityResults.map{DiagnosticResult($0.title,$0.status.rawValue,$0.category)}}else{diagnosticRows.append(DiagnosticResult("TLS / HTTPS","未验证","请连接后检测真实代理路径；诊断不会自动接管网络"))}
    }
    func quit() async -> Bool {
        if loadingFailed{return true}
        if measuring {cancelMeasurement();await measurementTask?.value}
        guard !busy else {errorMessage="正在更新配置，请稍后退出";return false}
        maintenanceTask?.cancel();await disconnect();return !capture.running && !proxy.hasRecovery && !recoveryPending
    }
}
