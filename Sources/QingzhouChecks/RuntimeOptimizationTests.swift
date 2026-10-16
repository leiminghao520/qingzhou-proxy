import Foundation
import QingzhouKit

private actor BootstrapProbeFixture {
    var calls: [UUID: Int] = [:]
    var active = 0
    var maximum = 0
    let outcomes: [UUID: ProbeStatus]
    let preferred: UUID?
    let gated: Bool
    private var waits: [CheckedContinuation<Void, Never>] = []
    init(_ outcomes: [UUID: ProbeStatus], preferred: UUID? = nil, gated: Bool = false) { self.outcomes = outcomes; self.preferred = preferred; self.gated = gated }
    func release() { let pending = waits; waits = []; for wait in pending { wait.resume() } }
    func probe(_ id: UUID) async -> ProbeStatus {
        calls[id, default: 0] += 1; active += 1; maximum = max(maximum, active)
        if gated { await withCheckedContinuation { waits.append($0) } }
        if let preferred {
            if id != preferred { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        } else { for _ in 0..<20 { await Task.yield() } }
        active -= 1
        return outcomes[id] ?? .unavailable
    }
}

private actor OrderedBootstrapFixture {
    let first: UUID
    var lowerCompleted = false
    var completionOrder: [UUID] = []
    init(first: UUID) { self.first = first }
    func probe(_ id: UUID) async -> ProbeStatus {
        if id == first {
            while !lowerCompleted && !Task.isCancelled { await Task.yield() }
        } else { lowerCompleted = true }
        completionOrder.append(id)
        return .available
    }
}

@MainActor private func waitForOptimization(_ condition: () -> Bool) async {
    for _ in 0..<2000 {
        if condition() { return }
        await Task.yield()
    }
    expectTrue(condition(), "异步测试没有进入预期阶段")
}

@MainActor func runRuntimeOptimizationChecks() async {
    await checkTrafficRecovery()
    await checkTrafficCancellation()
    checkMonitorChannels()
    checkFallbackReachability()
    await checkFallbackBootstrap()
    checkNetworkSamplingAndCoalescing()
}

@MainActor func runTrafficTransportChecks(port: Int) async {
    let client = CoreAPIClient(context: CoreControlContext(port: port, secret: "synthetic-traffic-secret"))
    var received: [Int64] = [], delays: [UInt64] = [], failures = 0
    var task: Task<Void, Never>?
    task = Task { @MainActor in
        await TrafficMonitor.run(connect: { try await client.traffic() }, sleep: { delays.append($0) }, receive: { rate in
            received.append(rate.down)
            if received.count == 2 { task?.cancel() }
        }, disconnected: { failures += 1 })
    }
    await task?.value
    await client.shutdown()
    expectEqual(received, [11, 22]); expectEqual(failures, 1); expectEqual(delays, [1_000_000_000])
    print("RESULT traffic_transport_assertions=\(CheckHarness.assertions) failures=\(CheckHarness.failures)")
}

@MainActor private func checkTrafficRecovery() async {
    var attempts = 0, received: [Int64] = [], delays: [UInt64] = [], failures = 0
    await TrafficMonitor.run(connect: {
        attempts += 1
        if attempts == 3 {
            return AsyncThrowingStream { continuation in
                let rate = try! JSONDecoder().decode(TransferRate.self, from: Data(#"{"up":11,"down":22}"#.utf8))
                continuation.yield(rate); continuation.finish()
            }
        }
        if attempts % 2 == 0 { return AsyncThrowingStream { $0.finish(throwing: ProxyError("模拟断线")) } }
        throw ProxyError("模拟握手失败")
    }, sleep: { delay in
        delays.append(delay)
        if delays.count == 10 { throw CancellationError() }
    }, receive: { received.append($0.down) }, disconnected: { failures += 1 })
    expectEqual(received, [22]); expectEqual(attempts, 10); expectEqual(failures, 10)
    expectEqual(delays.map { $0 / 1_000_000_000 }, [1, 2, 1, 2, 4, 8, 16, 30, 30, 30])
    print("PASS Optimization.trafficBackoffResetAndStreamEnd")
}

@MainActor private func checkTrafficCancellation() async {
    var attempts = 0, waiting = false, failed = 0, writes = 0
    let retry = Task { @MainActor in
        await TrafficMonitor.run(connect: { attempts += 1; throw ProxyError("模拟断线") }, sleep: { _ in
            waiting = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }, receive: { _ in writes += 1 }, disconnected: { failed += 1 })
    }
    await waitForOptimization { waiting }
    retry.cancel(); await retry.value
    expectEqual(attempts, 1); expectEqual(failed, 1); expectEqual(writes, 0)

    var continuation: AsyncThrowingStream<TransferRate, Error>.Continuation?
    let consuming = Task { @MainActor in
        await TrafficMonitor.run(connect: {
            attempts += 1
            return AsyncThrowingStream { continuation = $0 }
        }, receive: { _ in writes += 1 }, disconnected: { failed += 1 })
    }
    await waitForOptimization { continuation != nil }
    consuming.cancel(); await consuming.value
    let rate = try! JSONDecoder().decode(TransferRate.self, from: Data(#"{"up":1,"down":1}"#.utf8))
    continuation?.yield(rate); continuation?.finish()
    expectEqual(attempts, 2); expectEqual(failed, 1); expectEqual(writes, 0)

    // 前一连接取消后，新连接仍能消费；旧流迟到的数据不写入新状态。
    var freshWrites = 0
    await TrafficMonitor.run(connect: { AsyncThrowingStream { $0.yield(rate); $0.finish() } }, sleep: { _ in throw CancellationError() }, receive: { _ in freshWrites += 1 }, disconnected: {})
    expectEqual(freshWrites, 1); expectEqual(writes, 0)
    var defaultRetry: Task<Void, Never>?
    defaultRetry = Task { @MainActor in
        await TrafficMonitor.run(connect: { throw ProxyError("模拟断线") }, receive: { _ in writes += 1 }, disconnected: { defaultRetry?.cancel() })
    }
    await defaultRetry?.value
    let alreadyCancelled = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        await TrafficMonitor.run(connect: { writes += 1; throw ProxyError("不应发起连接") }, receive: { _ in writes += 1 }, disconnected: { writes += 1 })
    }
    await alreadyCancelled.value
    expectEqual(writes, 0)
    print("PASS Optimization.trafficCancelDuringWaitAndReceive")
}

private func checkMonitorChannels() {
    var state = RuntimeMonitorState()
    expectEqual(state.summary, "未连接")
    state.active = true
    expectEqual(state.rateLabel(20, paused: false, format: { "\($0)" }), "不可用")
    state.traffic = .unavailable; state.connections = .available; state.health = "健康未知"
    expectTrue(state.summary.contains("流量通道")); expectTrue(state.summary.contains("健康未知"))
    state.traffic = .available; state.connections = .unavailable
    expectTrue(state.summary.contains("连接列表")); expectTrue(state.summary.contains("健康未知"))
    expectEqual(state.rateLabel(20, paused: false, format: { "\($0)" }), "20")
    expectEqual(state.rateLabel(20, paused: true, format: { "\($0)" }), "不可用")
    state.connections = .available; state.health = nil
    expectEqual(state.summary, "实时监控")
    state.traffic = .pending; expectEqual(state.summary, "监控连接中")
    print("PASS Optimization.independentChannelStatusAndInvalidRate")
}

private func checkFallbackReachability() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let first = PolicyGroup(name: "当前组", kind: .fallback, members: [.node(a)])
    let final = PolicyGroup(name: "最终组", kind: .fallback, members: [.node(b)])
    let remote = PolicyGroup(name: "远程组", kind: .fallback, members: [.node(c)])
    let unused = PolicyGroup(name: "未使用", kind: .fallback, members: [.node(d)])
    let nested = PolicyGroup(name: "嵌套", kind: .select, members: [.group(first.id)])
    var state = AppState(); state.groups = [first, final, remote, unused, nested]; state.selectedPolicy = .group(nested.id)
    expectEqual(FallbackBootstrap.groups(in: state).map(\.id), [first.id])
    state.ruleFinal = .group(final.id)
    state.rules = [RoutingRule(kind: .domain, value: "test.example", action: .proxy, target: .group(first.id))]
    state.remoteRules = [RemoteRuleSource(name: "远程", target: .group(remote.id))]
    expectEqual(FallbackBootstrap.groups(in: state).map(\.id), [first.id, final.id, remote.id])
    state.mode = .global; expectEqual(FallbackBootstrap.groups(in: state).map(\.id), [first.id])
    state.mode = .direct; expectTrue(FallbackBootstrap.groups(in: state).isEmpty)
    print("PASS Optimization.fallbackReachableClosureAndModes")
}

@MainActor private func checkFallbackBootstrap() async {
    let nodes = (0..<10).map { _ in UUID() }
    let groups = nodes.map { PolicyGroup(name: "共享", kind: .fallback, members: [.node($0), .node(nodes[0])]) }
    let fixture = BootstrapProbeFixture(Dictionary(uniqueKeysWithValues: nodes.map { ($0, ProbeStatus.available) }), gated: true)
    var choices: [UUID: UUID] = [:]
    var finished = false
    let bootstrap = Task { @MainActor in
        defer { finished = true }
        return try await FallbackBootstrap.initialize(groups: groups, probe: { await fixture.probe($0) }, select: { choices[$0] = $1 })
    }
    for _ in 0..<2000 {
        if await fixture.active >= 4 { break }
        await Task.yield()
    }
    let firstBatch = await fixture.active
    expectEqual(firstBatch, 4)
    let drain = Task { @MainActor in
        while !finished { await fixture.release(); await Task.yield() }
    }
    do {
        let selected = try await bootstrap.value
        expectEqual(selected.count, groups.count); expectEqual(choices.count, groups.count)
    } catch { CheckHarness.failure("回退组初始化失败", file: #filePath, line: #line) }
    await drain.value
    let maximum = await fixture.maximum, calls = await fixture.calls
    expectEqual(maximum, 4); expectEqual(calls.count, 10); expectTrue(calls.values.allSatisfy { $0 == 1 })
    let group = PolicyGroup(name: "优先级", kind: .fallback, members: [.node(nodes[0]), .node(nodes[1])])
    let ordered = OrderedBootstrapFixture(first: nodes[0])
    do {
        let result = try await FallbackBootstrap.initialize(groups: [group], probe: { await ordered.probe($0) }, select: { _, _ in })
        let order = await ordered.completionOrder
        expectEqual(order.first, nodes[1]); expectEqual(result[group.id], nodes[0])
    } catch { CheckHarness.failure("并发完成顺序不能改变优先级", file: #filePath, line: #line) }
    let longGroup = PolicyGroup(name: "提前结束", kind: .fallback, members: nodes.map { .node($0) })
    let fast = BootstrapProbeFixture([nodes[0]: .available], preferred: nodes[0])
    do {
        let result = try await FallbackBootstrap.initialize(groups: [longGroup], probe: { await fast.probe($0) }, select: { _, _ in })
        let calls = await fast.calls
        expectEqual(result[longGroup.id], nodes[0]); expectTrue(calls.count <= 4, "首批确认优先节点后不再启动尾部探测")
    } catch { CheckHarness.failure("提前结束测试失败", file: #filePath, line: #line) }
    for first in [ProbeStatus.available, .unavailable, .unknown] {
        let probe = BootstrapProbeFixture([nodes[0]: first, nodes[1]: .available])
        do {
            let result = try await FallbackBootstrap.initialize(groups: [group], probe: { await probe.probe($0) }, select: { _, _ in })
            switch first {
            case .available: expectEqual(result[group.id], nodes[0])
            case .unavailable: expectEqual(result[group.id], nodes[1])
            case .unknown: expectNil(result[group.id])
            }
        } catch { CheckHarness.failure("优先级测试失败", file: #filePath, line: #line) }
    }
    do {
        let empty = try await FallbackBootstrap.initialize(groups: [], probe: { _ in CheckHarness.failure("不应探测未使用组", file: #filePath, line: #line); return .available }, select: { _, _ in })
        expectTrue(empty.isEmpty)
        let dead = try await FallbackBootstrap.initialize(groups: [group], probe: { _ in .unavailable }, select: { _, _ in CheckHarness.failure("不可用节点不能被选中", file: #filePath, line: #line) })
        expectTrue(dead.isEmpty)
    } catch { CheckHarness.failure("空组或失败组测试异常", file: #filePath, line: #line) }
    var began = false, selectedAfterCancel = false
    let cancelled = Task { @MainActor in
        try await FallbackBootstrap.initialize(groups: [group], probe: { _ in
            await MainActor.run { began = true }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return .available
        }, select: { _, _ in selectedAfterCancel = true })
    }
    await waitForOptimization { began }
    cancelled.cancel()
    do { _ = try await cancelled.value; CheckHarness.failure("取消应传播", file: #filePath, line: #line) } catch { expectTrue(error is CancellationError) }
    expectFalse(selectedAfterCancel)
    print("PASS Optimization.fallbackDedupConcurrencyPriorityUnknownAndCancel")
}

private func checkNetworkSamplingAndCoalescing() {
    var queued: [() -> Void] = [], runs = 0, reads = 0
    var checks: NetworkCheckScheduler!
    checks = NetworkCheckScheduler(enqueue: { queued.append($0) }, operation: {
        runs += 1
        if runs == 1 { for _ in 0..<100 { checks.request() } }
        do {
            let sample = try NetworkRouteSample(read: {
                reads += 1
                return "Internet:\nDestination Gateway Flags Netif\n10/8 10.0.0.1 UGSc en0\n"
            })
            expectEqual(sample.ownershipRoutes, NetworkSnapshot.parseRoutes(sample.table, includeTransient: true))
            expectEqual(NetworkSnapshot.parseRoutes(sample.table).count, 1)
        } catch { CheckHarness.failure("采样失败", file: #filePath, line: #line) }
    })
    for _ in 0..<100 { checks.request() }
    expectEqual(queued.count, 1)
    queued.removeFirst()(); expectEqual(runs, 1); expectEqual(queued.count, 1)
    queued.removeFirst()(); expectEqual(runs, 2); expectEqual(reads, 2); expectTrue(queued.isEmpty)
    checks.request(); checks.cancel(); queued.removeFirst()()
    checks.request(); expectTrue(queued.isEmpty); expectEqual(runs, 2)
    do {
        let live = try NetworkRouteSample()
        expectFalse(live.table.isEmpty, "真实只读采样应返回路由表")
    } catch { CheckHarness.failure("只读路由适配器失败", file: #filePath, line: #line) }
    print("PASS Optimization.networkEventCoalescingFollowupCancelAndFreshSamples")
}
