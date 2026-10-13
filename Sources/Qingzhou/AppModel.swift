import Foundation
import Darwin
import SwiftUI
import QingzhouKit

@MainActor final class AppModel: ObservableObject {
    enum Connection: String { case disconnected = "未连接", connecting = "连接中", connected = "已连接", disconnecting = "断开中", error = "错误" }
    @Published var state = AppState()
    @Published var connection = Connection.disconnected
    @Published var reachability = "尚未检测"
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var logs: [String] = []
    @Published var preview: ImportPreview?
    @Published var recoveryPending = false
    @Published var loadingFailed = false
    private var store: NodeStore?
    let credentials = KeychainStore()
    let core: CoreController
    let proxy: SystemProxyController
    private var networkChanged = false
    private var sessionLockFD: Int32 = -1
    private var pendingSubscription: Subscription?
    let directory: URL
    var selected: Node? { state.nodes.first {$0.id == state.selectedID} }
    init() {
        directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Qingzhou")
        core = CoreController(directory:directory)
        proxy = SystemProxyController(journal:directory.appendingPathComponent("proxy-recovery.json"))
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            sessionLockFD = open(directory.appendingPathComponent("session.lock").path,O_CREAT | O_RDWR,0o600)
            if sessionLockFD >= 0 {_ = fcntl(sessionLockFD,F_SETFD,FD_CLOEXEC)}
            guard sessionLockFD >= 0, flock(sessionLockFD,LOCK_EX | LOCK_NB) == 0 else {throw ProxyError("轻舟代理已经运行，请使用菜单栏入口")}
            store = try NodeStore(file:directory.appendingPathComponent("state.json"),credentials:credentials); state = store!.state }
        catch { loadingFailed = true; errorMessage = "配置无法读取或应用已运行，未覆盖原文件。"; return }
        recoveryPending = proxy.hasRecovery
        core.log = { [weak self] in self?.log($0) }
        core.onUnexpectedExit = { [weak self] in
            guard let self else {return}
            if !self.busy { Task { await self.disconnect(); self.connection = .error } }
        }
        proxy.onNetworkChange = { [weak self] in
            guard let self, self.connection == .connected || self.connection == .connecting else {return}
            if self.busy {self.networkChanged = true;return}
            Task { await self.disconnect(); self.errorMessage = "网络服务发生变化，已断开，请重新连接" }
        }
        proxy.startMonitoring()
        // 启动时删除上次崩溃遗留的运行配置，不读取其凭据内容。
        if let files = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) { for file in files where file.lastPathComponent.hasPrefix("runtime-") { try? FileManager.default.removeItem(at:file) } }
    }
    func log(_ text: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        for line in text.components(separatedBy:.newlines) where !line.isEmpty { logs.append("\(formatter.string(from:Date()))  \(Redactor.redact(line))") }
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }
    private func report(_ error: Error) { errorMessage = Redactor.redact(error.localizedDescription); log(errorMessage!) }
    private func persist(_ next: AppState) throws { guard let store else { throw ProxyError("配置未加载，无法保存") }; try store.commit(next); state = store.state }
    func importPreview(_ input: String) async {
        guard !busy, !loadingFailed else { return }; busy = true; defer {busy = false}
        do { pendingSubscription = nil; preview = try await ImportService.preview(input) } catch { report(error) }
    }
    func confirmImport() async {
        guard !busy, let preview, let store else { return }; busy = true; defer {busy = false}
        do {
            var sub = pendingSubscription
            if sub == nil, let source = preview.source { sub = state.subscriptions.first { (try? credentials.get($0.sourceRef)) == source } ?? Subscription(name:"订阅 \(state.subscriptions.count+1)") }
            let reconnect = connection == .connected && sub != nil && selected?.subscriptionID == sub?.id
            if reconnect {try await disconnectInternal()}
            let count = try store.importNodes(preview.candidates,subscription:sub,source:preview.source)
            state = store.state; self.preview = nil; pendingSubscription = nil; log("已导入 \(count) 个节点")
            if reconnect && selected != nil {busy = false;await connect()}
        } catch { report(error) }
    }
    func cancelPreview() { preview = nil; pendingSubscription = nil }
    func refresh(_ sub: Subscription) async {
        guard !busy else { return }; busy = true; defer {busy = false}
        do { let source = try credentials.get(sub.sourceRef); let result = try await ImportService.preview(source); pendingSubscription = sub; preview = result }
        catch { report(error) }
    }
    func saveManual(_ candidate: Candidate, editingID: UUID?) async {
        guard !busy, let store else { return }; busy = true; defer {busy = false}
        do {
            let reconnect = connection == .connected && editingID == state.selectedID
            if reconnect {try await disconnectInternal()}
            let count = try store.importNodes([candidate],replacingID:editingID);state = store.state;log("已保存 \(count) 个节点")
            if reconnect {busy = false;await connect()}
        } catch { report(error) }
    }
    func select(_ id: UUID?) async {
        guard !busy, id != state.selectedID else {return}
        let reconnect = connection == .connected
        busy = true;defer {busy = false}
        do {
            if reconnect {try await disconnectInternal()}
            var next = state;next.selectedID = id;try persist(next)
            if reconnect && selected != nil {busy = false;await connect()}
        } catch {report(error)}
    }
    func deleteNode(_ id: UUID) async {
        guard !busy, let store else { return }; busy = true; defer {busy = false}
        do { if id == state.selectedID && connection == .connected { try await disconnectInternal() }; try store.deleteNode(id); state = store.state } catch { report(error) }
    }
    func deleteSubscription(_ id: UUID) async {
        guard !busy, let store else { return }; busy = true; defer {busy = false}
        do { if selected?.subscriptionID == id && connection == .connected { try await disconnectInternal() }; try store.deleteSubscription(id); state = store.state } catch { report(error) }
    }
    func saveSettings(port: Int, rulesEnabled: Bool) async {
        guard !busy else { return }; busy = true; defer {busy = false}
        do { guard (1024...65535).contains(port) else { throw ProxyError("监听端口必须为 1024–65535") }; if connection == .connected { try await disconnectInternal() }; var next = state; next.listenPort = port; next.rulesEnabled = rulesEnabled; try persist(next); log("设置已保存") } catch { report(error) }
    }
    func addRule(_ rule: RoutingRule) { guard !busy else { return }; do { try ConfigBuilder.validate(rule); var next = state; next.rules.append(rule); try persist(next); log("规则已保存，下次连接生效") } catch {report(error)} }
    func removeRule(_ id: UUID) { guard !busy else {return}; do { var next = state; next.rules.removeAll {$0.id == id}; try persist(next) } catch {report(error)} }
    func moveRule(_ id: UUID, by offset: Int) { guard !busy, let i = state.rules.firstIndex(where: {$0.id == id}), state.rules.indices.contains(i+offset) else {return}; do { var next = state; next.rules.swapAt(i,i+offset); try persist(next) } catch {report(error)} }
    func connect() async {
        guard !busy, !loadingFailed, let node = selected else {return}; busy = true; networkChanged = false; connection = .connecting; reachability = "尚未检测"; defer {busy = false}
        do {
            guard !proxy.hasRecovery else { throw ProxyError("请先恢复原代理，再连接") }
            let config = try ConfigBuilder.build(node:node,state:state,credentials:credentials)
            core.secrets = [try credentials.get(node.credentialRef), (try? credentials.get(node.credentialRef + ".obfs")) ?? ""]
            try await core.start(config:config,port:state.listenPort)
            guard !networkChanged else {throw ProxyError("连接期间网络服务发生变化，请重新连接")}
            try proxy.apply(port:state.listenPort)
            guard core.isRunning else { throw ProxyError("代理核心已退出") }
            recoveryPending = proxy.hasRecovery; connection = .connected; log("系统代理已开启")
            reachability = await core.probe(port:state.listenPort)
            guard core.isRunning else { throw ProxyError("代理核心已退出") }
            guard !networkChanged else {throw ProxyError("连接期间网络服务发生变化，请重新连接")}
            log(reachability)
        } catch {
            var restored = true
            if proxy.hasRecovery {do {try proxy.restore()} catch {restored = false;log("原代理恢复失败，请使用恢复入口；仍保留可运行核心，避免本地代理失效")}}
            if restored {await core.stop()}
            recoveryPending = proxy.hasRecovery;connection = .error;report(error)
        }
    }
    private func disconnectInternal() async throws {
        connection = .disconnecting
        do { try proxy.restore() } catch { recoveryPending = proxy.hasRecovery; connection = .error; throw error }
        await core.stop(); recoveryPending = proxy.hasRecovery; connection = .disconnected; reachability = "尚未检测"; log("已断开并恢复原代理")
    }
    func disconnect() async { guard !busy else {return}; busy = true; defer {busy = false}; do { try await disconnectInternal() } catch {report(error)} }
    func recover() async { await disconnect() }
    func startupRecovery() async { if !loadingFailed && recoveryPending { await recover() } }
    func quit() async -> Bool { if loadingFailed {return true}; guard !busy else {errorMessage = "正在执行操作，请稍后退出"; return false}; await disconnect(); return !core.isRunning && !proxy.hasRecovery }
}
