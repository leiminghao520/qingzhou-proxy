import Foundation
import Darwin
import SwiftUI
import AppKit
import ServiceManagement
import QingzhouKit

@MainActor final class AppModel:ObservableObject {
    enum Connection:String {case disconnected="未连接",connecting="连接中",connected="已连接",disconnecting="断开中",error="错误"}
    @Published var state=AppState()
    @Published var connection=Connection.disconnected
    @Published var reachability="尚未检测"
    @Published var busy=false {didSet{if !busy{drainPendingDisconnect()}}}
    @Published var measuring=false {didSet{if !measuring{drainPendingDisconnect()}}}
    @Published var measurementProgress=""
    @Published var errorMessage:String?
    @Published var logs:[String]=[]
    @Published var preview:ImportPreview?
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
    private var api:CoreAPIClient?
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
    var locked:Bool {busy || measuring || loadingFailed}
    var selected:Node? {if case .node(let id)=state.activePolicy {return state.nodes.first{$0.id==id}};return nil}
    var selectedName:String {state.label(state.activePolicy)}
    var actualName:String {if state.mode == .direct{return "直连"};guard let tag=CoreAPIClient.actualTag(proxyInfo) else {return "尚未检测"};return label(tag)}
    var allNodesUnavailable:Bool { !state.nodes.isEmpty && state.nodes.allSatisfy{proxyInfo[PolicyReference.node($0.id).tag]?.history?.last == nil} }
    init() {
        directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Qingzhou")
        core=CoreController(directory:directory);proxy=SystemProxyController(journal:directory.appendingPathComponent("proxy-recovery.json"))
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            sessionLockFD=open(directory.appendingPathComponent("session.lock").path,O_CREAT|O_RDWR,0o600)
            if sessionLockFD>=0 {_ = fcntl(sessionLockFD,F_SETFD,FD_CLOEXEC)}
            guard sessionLockFD>=0,flock(sessionLockFD,LOCK_EX|LOCK_NB)==0 else {throw ProxyError("应用已经运行")}
            store=try NodeStore(file:directory.appendingPathComponent("state.json"),credentials:credentials);state=store!.state
        } catch {loadingFailed=true;errorMessage="配置无法读取或应用已运行，未覆盖原文件。";return}
        recoveryPending=proxy.hasRecovery
        core.log={ [weak self] in self?.log($0) }
        core.onUnexpectedExit={ [weak self] in guard let self else{return};self.stopTelemetry();self.coreFailed=true;self.cancelMeasurement();self.drainPendingDisconnect() }
        proxy.onNetworkChange={ [weak self] in guard let self,self.connection == .connected || self.connection == .connecting else{return};self.networkChanged=true;self.cancelMeasurement();self.drainPendingDisconnect() }
        proxy.startMonitoring()
        // 只有持有实例锁的应用才清理自己上次遗留的敏感运行文件。
        if let files=try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {for file in files where file.lastPathComponent.hasPrefix("runtime-") || file.lastPathComponent.hasPrefix("check-") {try? FileManager.default.removeItem(at:file)}}
    }
    // 测速或配置更新期间的退出和网络变更延后串行恢复，避免被操作锁跳过。
    private func drainPendingDisconnect() {
        guard !locked,(coreFailed || networkChanged),connection == .connected else{return}
        let failed=coreFailed;coreFailed=false;networkChanged=false;busy=true
        Task {defer{busy=false};do{try await disconnectInternal();if failed{connection = .error};errorMessage=failed ? "核心异常退出，已恢复系统代理" : "网络服务发生变化，已断开，请重新连接"}catch{report(error)}}
    }
    func label(_ tag:String) -> String {
        if tag=="auto"{return "自动选择"};if tag=="direct"{return "直连"};if tag=="proxy"{return "当前选择"}
        if let node=state.nodes.first(where:{PolicyReference.node($0.id).tag==tag}){return node.name}
        if let group=state.groups.first(where:{PolicyReference.group($0.id).tag==tag}){return group.name}
        return "未知出站"
    }
    func log(_ text:String) {let f=DateFormatter();f.dateFormat="HH:mm:ss";for line in text.components(separatedBy:.newlines) where !line.isEmpty {logs.append("\(f.string(from:Date()))  \(Redactor.redact(line))")};if logs.count>500 {logs.removeFirst(logs.count-500)}}
    private func report(_ error:Error) {if error is CancellationError{return};errorMessage=Redactor.redact(error.localizedDescription);log(errorMessage!)}
    private func persist(_ next:AppState) throws {guard let store else {throw ProxyError("配置未加载")};try store.commit(next);state=store.state}
    private func secrets(_ next:AppState,_ control:CoreControlContext) -> [String] {[control.secret]+next.nodes.flatMap{[(try? credentials.get($0.credentialRef)) ?? "",(try? credentials.get($0.credentialRef+".obfs")) ?? ""]}}
    private func startService(_ next:AppState) async throws {
        let control=try CoreControlContext.make();let data=try ConfigBuilder.build(state:next,credentials:credentials,control:control)
        core.secrets=secrets(next,control);networkChanged=false;coreFailed=false
        try await core.start(config:data,port:next.listenPort)
        let client=CoreAPIClient(context:control)
        do {
            _=try await client.proxies()
            guard !networkChanged else {throw ProxyError("启动期间网络发生变化")}
            try proxy.apply(port:next.listenPort)
            guard core.isRunning else {throw ProxyError("核心已经退出")}
            api=client;connection = .connected;recoveryPending=proxy.hasRecovery;startTelemetry(client)
        } catch {
            await client.shutdown()
            if proxy.hasRecovery {do{try proxy.restore()}catch{recoveryPending=true;throw ProxyError("系统代理恢复失败，请使用恢复入口")}}
            await core.stop();throw error
        }
    }
    // 元数据和凭据仅在新配置实际应用成功后提交；失败时恢复原运行配置。
    private func apply(_ tx:StoreTransaction,reconfigure:Bool=true) async throws {
        guard let store else {throw ProxyError("配置未加载")}
        let wasConnected=connection == .connected
        do {
            if reconfigure && !tx.next.nodes.isEmpty {
                let context=try CoreControlContext.make();try await core.validate(config:ConfigBuilder.build(state:tx.next,credentials:credentials,control:context))
            }
            if reconfigure && wasConnected {try await disconnectInternal();if tx.next.activePolicy != nil || tx.next.mode == .direct {try await startService(tx.next)}}
            try store.commit(tx);state=store.state
            if wasConnected && reconfigure && connection == .connected {reachability="配置已更新，新连接生效"}
        } catch {
            if reconfigure && wasConnected {
                do {
                    if core.isRunning || proxy.hasRecovery {try await disconnectInternal()}
                    if tx.previous.activePolicy != nil || tx.previous.mode == .direct {try await startService(tx.previous)}
                    log("新配置未生效，已恢复上一份运行配置")
                } catch {connection = .error;log("上一份配置恢复失败，请检查代理恢复入口")}
            }
            store.abort(tx);state=store.state;throw error
        }
    }
    func importPreview(_ input:String) async {guard !locked else{return};busy=true;defer{busy=false};do{pendingSubscription=nil;preview=try await ImportService.preview(input)}catch{report(error)}}
    func importFile(_ url:URL) async {
        guard !locked else{return};busy=true;defer{busy=false};let granted=url.startAccessingSecurityScopedResource();defer{if granted{url.stopAccessingSecurityScopedResource()}}
        do {let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max)<=2*1024*1024 else {throw ProxyError("文件超过 2 MiB")};let data=try Data(contentsOf:url);guard let text=String(data:data,encoding:.utf8) else {throw ProxyError("文件必须为 UTF-8")};pendingSubscription=nil;preview=try ProfileImporter.parse(text)}catch{report(error)}
    }
    func confirmImport(scope:ImportScope = .nodes) async {
        guard !locked,let preview,let store else{return};busy=true;defer{busy=false}
        do {
            var sub=pendingSubscription
            if sub==nil,let source=preview.source {sub=state.subscriptions.first{(try? credentials.get($0.sourceRef))==source} ?? Subscription(name:"订阅 \(state.subscriptions.count+1)")}
            let tx=try store.prepareImport(preview.candidates,subscription:sub,source:preview.source,profile:preview,scope:scope)
            try await apply(tx);self.preview=nil;pendingSubscription=nil;log("导入已完成")
        } catch {report(error)}
    }
    func cancelPreview(){preview=nil;pendingSubscription=nil}
    func refresh(_ sub:Subscription) async {guard !locked else{return};busy=true;defer{busy=false};do{let result=try await ImportService.preview(credentials.get(sub.sourceRef));pendingSubscription=sub;preview=result}catch{recordSubscriptionFailure(sub.id,error:error);report(error)}}
    func saveManual(_ candidate:Candidate,editingID:UUID?) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{let tx=try store.prepareImport([candidate],replacingID:editingID);try await apply(tx);log("节点已保存")}catch{report(error)}}
    func deleteNode(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteNode(id))}catch{report(error)}}
    func deleteSubscription(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try await apply(store.prepareDeleteSubscription(id))}catch{report(error)}}
    func select(_ id:UUID?) async {guard let id else{return};await selectPolicy(.node(id))}
    func selectPolicy(_ ref:PolicyReference) async {
        guard !locked,ref != state.activePolicy,PolicyValidator.exists(ref,in:state),ref != .selected,ref != .reject else{return};busy=true;defer{busy=false}
        let old=state.activePolicy
        do {
            if let api,connection == .connected {try await api.select(ref)}
            var next=state;next.selectedPolicy=ref;if case .node(let id)=ref {next.selectedID=id}
            do{try persist(next)}catch{if let api,let old{try? await api.select(old)};throw error}
            log("已选择 \(state.label(ref))，已有连接保留")
        } catch {report(error)}
    }
    func setMode(_ mode:ProxyMode) async {
        guard !locked,mode != state.mode else{return};busy=true;defer{busy=false};let old=state.mode
        do {if let api,connection == .connected {try await api.setMode(mode)};var next=state;next.mode=mode;do{try persist(next)}catch{if let api{try? await api.setMode(old)};throw error};log("已切换为\(mode.label)，新连接生效")}catch{report(error)}
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
    func deleteRemote(_ id:UUID) async {guard !locked,let store,let source=state.remoteRules.first(where:{$0.id==id}) else{return};busy=true;defer{busy=false};do{var next=state;next.remoteRules.removeAll{$0.id==id};try await apply(store.prepareChange(next));try? credentials.remove(source.sourceRef)}catch{report(error)}}
    func connect() async {
        guard !locked,state.activePolicy != nil || state.mode == .direct else{return};busy=true;connection = .connecting;reachability="尚未检测";defer{busy=false}
        do {guard !proxy.hasRecovery else {throw ProxyError("请先恢复原代理")};try await startService(state);reachability=await core.probe(port:state.listenPort);guard core.isRunning,!networkChanged else {throw ProxyError("连接期间核心退出或网络变化")};log(reachability)}catch{var restored=true;if proxy.hasRecovery{do{try proxy.restore()}catch{restored=false;log("原代理恢复失败，保留核心及恢复记录")}};if restored{await core.stop();stopTelemetry()};recoveryPending=proxy.hasRecovery;connection = .error;report(error)}
    }
    private func disconnectInternal() async throws {connection = .disconnecting;do{try proxy.restore()}catch{recoveryPending=proxy.hasRecovery;connection = .error;throw error};stopTelemetry();await core.stop();recoveryPending=proxy.hasRecovery;connection = .disconnected;reachability="尚未检测";log("已断开并恢复原代理")}
    func disconnect() async {guard !locked else{return};busy=true;defer{busy=false};do{try await disconnectInternal()}catch{report(error)}}
    func recover() async {await disconnect()}
    func startupRecovery() async {
        guard !started,!loadingFailed else{return};started=true
        if recoveryPending {await recover()};if state.autoConnect && !proxy.hasRecovery {await connect()}
        maintenanceTask=Task{[weak self] in while !Task.isCancelled {await self?.maintenance();try? await Task.sleep(nanoseconds:60_000_000_000)}}
    }
    private func startTelemetry(_ client:CoreAPIClient) {
        stopTelemetry();api=client;let token=UUID();epoch=token;monitorStatus="实时监控"
        telemetryTask=Task{[weak self] in
            while !Task.isCancelled {
                guard let self,self.epoch==token else{return}
                let hidden=NSApplication.shared.isHidden || NSApplication.shared.windows.filter{$0.canBecomeMain}.allSatisfy{!$0.isVisible || $0.isMiniaturized}
                if !self.monitorPaused {
                    do {let snapshot=try await client.connections();let info=try await client.proxies();guard self.epoch==token,!Task.isCancelled else{return};self.connections=snapshot.connections;self.uploadTotal=snapshot.uploadTotal;self.downloadTotal=snapshot.downloadTotal;self.proxyInfo=info;self.monitorStatus="实时监控"}
                    catch {if self.epoch==token,!Task.isCancelled{self.monitorStatus="监控暂不可用"}}
                }
                try? await Task.sleep(nanoseconds:hidden ? 5_000_000_000 : 1_000_000_000)
            }
        }
        trafficTask=Task{[weak self] in
            do {let stream=try await client.traffic();var last=Date.distantPast
                for try await rate in stream {guard let self,!Task.isCancelled,self.epoch==token else{return};let hidden=NSApplication.shared.isHidden || NSApplication.shared.windows.filter{$0.canBecomeMain}.allSatisfy{!$0.isVisible || $0.isMiniaturized};if !self.monitorPaused && Date().timeIntervalSince(last)>=(hidden ? 5 : 0.8){self.uploadRate=max(0,rate.up);self.downloadRate=max(0,rate.down);last=Date()}}
            }catch{if let self,self.epoch==token,!Task.isCancelled{self.monitorStatus="流量通道暂不可用"}}
        }
    }
    private func stopTelemetry() {epoch=UUID();telemetryTask?.cancel();trafficTask?.cancel();telemetryTask=nil;trafficTask=nil;if let old=api{Task{await old.shutdown()}};api=nil;connections=[];proxyInfo=[:];uploadRate=0;downloadRate=0;uploadTotal=0;downloadTotal=0;monitorStatus="未连接"}
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
            if insecure || (sub.scope == .profile && !result.unsupported.isEmpty) || (sub.scope == .nodes && !result.unsupported.filter{!$0.hasPrefix("完整导入") && !$0.hasPrefix("规则") && !$0.hasPrefix("策略")}.isEmpty) {
                var next=state;if let i=next.subscriptions.firstIndex(where:{$0.id==id}){next.subscriptions[i].pendingReview=true;next.subscriptions[i].lastError="更新需要人工预览确认"};try persist(next);log("订阅更新需要人工确认，保留旧节点");return
            }
            let tx=try store.prepareImport(result.candidates,subscription:sub,source:result.source,profile:result,scope:sub.scope);try await apply(tx);log("订阅自动更新成功")
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
    func quit() async -> Bool {
        if loadingFailed{return true}
        if measuring {cancelMeasurement();await measurementTask?.value}
        guard !busy else {errorMessage="正在更新配置，请稍后退出";return false}
        maintenanceTask?.cancel();await disconnect();return !core.isRunning && !proxy.hasRecovery
    }
}
