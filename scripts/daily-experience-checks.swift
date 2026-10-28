import Foundation
import AppKit
import SwiftUI
import QingzhouKit

// 模拟控制接口，不监听端口、不访问公网、不修改系统代理。
final class DailyControlProtocol: URLProtocol {
    static let lock = NSLock()
    static var selected = ""
    static var selections: [String] = []
    static var rejected = Set<String>()
    static var slowDelay = false
    private var stopped = false
    private let responseLock = NSLock()
    static func reset(_ tag: String, reject: Set<String> = [], slow: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        selected = tag; selections = []; rejected = reject; slowDelay = slow
    }
    static func calls() -> [String] { lock.lock(); defer { lock.unlock() }; return selections }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        var code = 200
        var body = "{}"
        var slow = false
        if request.httpMethod == "PUT" {
            var bytes = request.httpBody
            if bytes == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
                bytes = data
            }
            let name = ((try? JSONSerialization.jsonObject(with: bytes ?? Data())) as? [String: String])?["name"] ?? ""
            Self.selections.append(name)
            if Self.rejected.contains(name) { code = 500 } else { Self.selected = name }
        } else if request.url!.path.hasSuffix("/delay") {
            body = "{\"delay\":42}"; slow = Self.slowDelay
        } else {
            body = "{\"proxies\":{\"proxy\":{\"type\":\"Selector\",\"name\":\"proxy\",\"now\":\"\(Self.selected)\"}}}"
        }
        Self.lock.unlock()
        let status = code, data = Data(body.utf8)
        let respond = { [self] in
            responseLock.lock(); defer { responseLock.unlock() }
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
        if slow { DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: respond) } else { respond() }
    }
    override func stopLoading() { responseLock.lock(); stopped = true; responseLock.unlock() }
}

@main struct DailyExperienceChecks {
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw ProxyError(label) }; assertions += 1; print("PASS " + label)
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        throw ProxyError("等待隔离任务超时")
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("DAILY_EXPERIENCE_CHECKS_OK assertions=\(assertions)"); exit(0) }
            catch { print("DAILY_EXPERIENCE_CHECKS_FAILED \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }
    @MainActor static func run() async throws {
        let model = AppModel()
        guard let store = model.store else { throw ProxyError("隔离存储不可用") }
        model.setHistoryEnabled(false)
        let first = try NodeParser.parse("trojan://fixture@one.invalid:443#香港")
        let second = try NodeParser.parse("trojan://fixture@two.invalid:443#东京")
        try store.commit(store.prepareImport([first, second])); model.state = store.state
        let one = first.node.id, two = second.node.id
        let old = PolicyReference.node(one), target = PolicyReference.node(two)
        let healthy = [ConnectivityResult("网站", .passed, ""), .init("节点", .passed, ""), .init("入口", .passed, "")]
        let failed = [ConnectivityResult("网站", .failed, "鉴权"), .init("节点", .failed, "鉴权"), .init("入口", .passed, "")]
        let degraded = [ConnectivityResult("网站", .passed, ""), .init("节点", .failed, "超时"), .init("入口", .failed, "代理入口")]
        func reset(connected: Bool = true, reject: Set<String> = [], slow: Bool = false) throws {
            model.busy = false; model.connection = .disconnected; model.selectionStatus = nil
            var state = store.state; state.selectedPolicy = old; state.selectedID = one; state.captureMode = .systemProxy; state.recentUse = [:]
            try model.persist(state)
            model.connection = connected ? .connected : .disconnected
            model.api = CoreAPIClient(context: CoreControlContext(port: 32198, secret: "fixture"), protocolClasses: [DailyControlProtocol.self])
            model.connectivityProbe = { _, _, _ in healthy }
            DailyControlProtocol.reset(old.tag, reject: reject, slow: slow)
        }
        try reset(connected: false)
        await model.selectPolicy(target)
        try check(model.connection == .disconnected && model.state.activePolicy == target && DailyControlProtocol.calls().isEmpty, "离线仅选择，不自动连接或访问核心")
        try check(model.state.recentUse[two.uuidString] != nil && model.selectionStatus?.phase == .succeeded, "离线选择保存最近使用并发布成功")
        try reset()
        var checking = false, release: CheckedContinuation<Void, Never>?
        model.connectivityProbe = { _, _, _ in checking = true; await withCheckedContinuation { release = $0 }; return healthy }
        let task = Task { await model.selectPolicy(target) }
        try await wait { checking }
        try check(model.state.activePolicy == old && store.state.activePolicy == old && model.selectionStatus?.phase == .checking && model.busy, "检查完成前旧节点保持生效标记与持久化选择")
        await model.selectPolicy(.automatic)
        try check(DailyControlProtocol.calls() == [target.tag], "切换期间重复点击不会发出第二次请求")
        release?.resume(); await task.value
        try check(model.state.activePolicy == target && model.selectionStatus?.phase == .succeeded && !model.busy, "切换通过后原子保存目标并解锁")
        try check(model.connectivityResults == healthy && model.verifiedSelectionTag == target.tag && !model.healthRefreshPending, "切换结果复用健康检测并避免重复探测")
        await model.selectPolicy(target)
        try check(DailyControlProtocol.calls().count == 1, "已生效节点重复选择不发送请求")
        await model.selectPolicy(.node(UUID())); await model.selectPolicy(.selected); await model.selectPolicy(.reject)
        try check(DailyControlProtocol.calls().count == 1, "无效和保留策略不能进入切换")
        try reset()
        model.connectivityProbe = { _, _, _ in degraded }
        await model.selectPolicy(target)
        try check(DailyControlProtocol.calls() == [target.tag] && model.state.activePolicy == target, "节点超时和入口探测错误不会回退用户选择")
        try check(model.selectionStatus?.phase == .succeeded && model.connectivityResults == degraded && model.connectivityHealth != .healthy, "换线完成保留真实探测失败，不伪报健康")
        try reset()
        var probes = 0
        model.connectivityProbe = { _, _, _ in probes += 1; return probes == 1 ? failed : healthy }
        await model.selectPolicy(target)
        try check(DailyControlProtocol.calls() == [target.tag, old.tag] && model.state.activePolicy == old, "新节点失败后恢复原选择且不提交候选")
        try check(model.selectionStatus?.message.contains("已恢复原节点") == true && !model.selectionNetworkUncertain && model.connectivityResults == healthy, "回退及检测成功才确认恢复")
        try check(model.state.recentUse[two.uuidString] == nil, "失败切换不污染最近使用")
        try reset(reject: [old.tag])
        model.connectivityProbe = { _, _, _ in failed }
        await model.selectPolicy(target)
        try check(model.selectionNetworkUncertain && model.selectionStatus?.message.contains("已恢复原节点") == false && model.reachability == "网络状态待确认", "核心回退失败明确标记未知且不谎报恢复")
        try check(model.selectionStatus?.phase == .failed && model.state.activePolicy == old, "回退失败保留持久化选择并发布可重试失败")
        try reset()
        model.connectivityProbe = { _, _, _ in failed }
        await model.selectPolicy(target)
        try check(model.selectionNetworkUncertain && model.selectionStatus?.message.contains("恢复未确认") == true, "回退请求成功但连通性失败仍不确认恢复")
        model.connectivityProbe = { _, _, _ in healthy }
        await model.selectPolicy(old)
        try check(model.selectionStatus?.phase == .succeeded && !model.selectionNetworkUncertain, "状态未知时允许重试原节点")
        try reset(reject: [target.tag])
        await model.selectPolicy(target)
        try check(model.selectionStatus?.message.contains("已恢复原节点") == true && DailyControlProtocol.calls() == [target.tag, old.tag], "目标请求失败也尝试确认原节点")
        try reset(); model.api = nil
        await model.selectPolicy(target)
        try check(model.state.activePolicy == old && model.selectionNetworkUncertain && DailyControlProtocol.calls().isEmpty, "连接中缺少控制通道不伪造切换成功")
        try reset()
        checking = false
        model.connectivityProbe = { _, _, _ in checking = true; await withCheckedContinuation { release = $0 }; return healthy }
        let stale = Task { await model.selectPolicy(target) }
        try await wait { checking }; model.epoch = UUID(); release?.resume(); await stale.value
        try check(model.state.activePolicy == old && model.selectionStatus == nil && DailyControlProtocol.calls() == [target.tag], "旧连接代次不提交选择且不向新会话回退")
        try reset()
        await model.selectPolicy(.automatic)
        try check(model.state.activePolicy == .automatic && model.verifiedSelectionTag == nil, "已连接自动选择通过检查且不误标手动节点")
        try reset()
        var missing = model.state; missing.selectedID = nil; missing.selectedPolicy = nil; try model.persist(missing)
        model.connectivityProbe = { _, _, _ in failed }
        await model.selectPolicy(target)
        try check(model.selectionNetworkUncertain && model.selectionStatus?.message.contains("没有可恢复的原线路") == true, "无原节点时不伪造回退成功")
        try reset(); model.connection = .disconnected
        await model.selectPolicy(.automatic)
        try check(model.state.activePolicy == .automatic && model.selectionStatus?.phase == .succeeded, "自动策略保留独立选择语义")

        // 使用真实列表投影验证排序、失效与大列表，不依赖界面文案断言。
        var state = AppState()
        let a = Node(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "同名", kind: .trojan, server: "a.invalid", port: 443)
        let b = Node(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "同名", kind: .trojan, server: "b.invalid", port: 443)
        let c = Node(name: "香港", kind: .trojan, server: "c.invalid", port: 443)
        state.nodes = [b, a, c]
        let page = NodeListViewModel(), now = Date(), invalidated = Date().addingTimeInterval(-30)
        func list() -> [Node] { page.nodes(state: state, invalidatedAt: invalidated, now: now, simple: true) }
        page.sort = "节点名称"
        try check(Array(list().filter { $0.name == "同名" }.map(\.id)) == [a.id, b.id], "同名节点按身份稳定排序")
        state.recentUse[b.id.uuidString] = now; page.sort = "最近使用"
        try check(list().first?.id == b.id, "简洁列表支持最近使用排序")
        state.favorites = [c.id]
        try check(list().first?.id == c.id, "收藏优先于最近使用排序")
        state.favorites = []; page.sort = "HTTPS 延迟"
        state.latency[a.id.uuidString] = LatencyResult(milliseconds: 10, testedAt: now)
        state.latency[b.id.uuidString] = LatencyResult(milliseconds: 50, testedAt: now)
        try check(list().first?.id == a.id, "简洁列表按有效 HTTPS 延迟排序")
        state.latency[a.id.uuidString] = LatencyResult(milliseconds: 1, testedAt: now.addingTimeInterval(-400))
        try check(list().first?.id == b.id, "过期延迟不参与最快排序且缓存同步失效")
        page.query = "没有匹配"
        try check(list().isEmpty, "搜索空结果不显示不匹配节点")
        state.notes[c.id.uuidString] = "办公备用"; page.query = "办公"
        try check(list().map(\.id) == [c.id], "搜索覆盖备注")
        page.query = ""; page.favoriteOnly = true
        try check(list().isEmpty, "收藏过滤为空时不自动显示全部")
        page.clearFilters()
        state.nodes = (0..<5000).map { Node(name: "线路\($0)", kind: .trojan, server: "fixture.invalid", port: 443) }
        page.query = "线路4999"
        let start = Date(); let matches = list()
        try check(matches.count == 1 && matches[0].name == "线路4999", "五千节点搜索返回准确结果")
        print("SEARCH_5000_SECONDS \(Date().timeIntervalSince(start))")

        // 测速使用同一模拟控制接口，取消后等待任务清理，禁止迟到结果覆盖配置。
        try reset(slow: true)
        model.measure([one]); try check(model.measuring && model.locked, "测速开始锁定切换")
        model.cancelMeasurement()
        try check(model.measurementCancelling && model.measuring, "取消后先保持清理状态")
        try await wait { !model.measuring }
        try check(!model.measurementCancelling && !model.locked, "取消收尾释放任务与锁")
        try reset(slow: true)
        let beforeLatency = model.state.latency.mapValues { $0.testedAt }
        model.measure([one]); model.epoch = UUID()
        try await wait { !model.measuring }
        try check(model.state.latency.mapValues { $0.testedAt } == beforeLatency, "旧会话延迟结果不会覆盖当前状态")
        try reset(slow: true)
        model.measure([one])
        let root = try ProfileStore.create(in: store.catalog, name: "隔离新配置", copyID: nil)
        try store.commit(store.prepareCatalog(ProfileStore.switchTo(root.profiles.last!.id, in: root))); model.state = store.state
        let profileLatency = model.state.latency.mapValues { $0.testedAt }
        try await wait { !model.measuring }
        try check(model.state.latency.mapValues { $0.testedAt } == profileLatency, "配置切换后丢弃旧配置测速结果")
        model.selectionStatus = SelectionStatus(target: old, name: "旧配置", epoch: model.epoch, phase: .failed, message: "旧结果", networkUncertain: true, profileID: store.catalog.profiles.first!.id)
        try check(model.currentSelectionStatus == nil && !model.selectionNetworkUncertain, "旧配置的切换提示不污染新配置健康状态")
        model.connection = .disconnected; await model.api?.shutdown(); model.api = nil
        try check(!model.proxy.hasRecovery, "检查未生成系统代理接管记录")
    }
}
