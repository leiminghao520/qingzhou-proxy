import Foundation

public enum FallbackBootstrap {
    public static func groups(in state: AppState) -> [PolicyGroup] {
        guard state.mode != .direct else { return [] }
        let groups = Dictionary(uniqueKeysWithValues: state.groups.map { ($0.id, $0) })
        var visited = Set<UUID>()
        func visit(_ ref: PolicyReference?) {
            guard let ref else { return }
            switch ref {
            case .selected: visit(state.activePolicy)
            case .group(let id):
                guard visited.insert(id).inserted, let group = groups[id] else { return }
                // 选择组的任意成员都可能在运行期被选中，因此遍历整个成员闭包。
                for member in group.members { visit(member) }
            default: break
            }
        }
        visit(state.activePolicy)
        if state.mode == .rule {
            visit(state.ruleFinal)
            for rule in state.rules { visit(rule.target) }
            for source in state.remoteRules { visit(source.target) }
        }
        return state.groups.filter { $0.kind == .fallback && visited.contains($0.id) }
    }

    public static func initialize(
        groups: [PolicyGroup],
        probe: @escaping @Sendable (UUID) async -> ProbeStatus,
        select: (UUID, UUID) async throws -> Void
    ) async throws -> [UUID: UUID] {
        var seen = Set<UUID>()
        let nodes = groups.flatMap(\.members).compactMap { ref -> UUID? in
            guard case .node(let id) = ref, seen.insert(id).inserted else { return nil }
            return id
        }
        var results: [UUID: ProbeStatus] = [:]
        var resolved = Set<UUID>()
        var selected: [UUID: UUID] = [:]
        func resolveGroups() {
            for group in groups where !resolved.contains(group.id) {
                var waiting = false
                for member in group.members {
                    guard case .node(let id) = member else { continue }
                    guard let status = results[id] else { waiting = true; break }
                    switch status {
                    case .unavailable: continue
                    case .available: selected[group.id] = id
                    case .unknown: break
                    }
                    break
                }
                if !waiting { resolved.insert(group.id) }
            }
        }
        try await withThrowingTaskGroup(of: (UUID, ProbeStatus).self) { tasks in
            var cursor = 0
            func enqueue() {
                // 已决定的组不再启动后续探测，共享节点仍可供其他组使用。
                let needed = Set(groups.filter { !resolved.contains($0.id) }.flatMap(\.members))
                while cursor < nodes.count {
                    let id = nodes[cursor]; cursor += 1
                    guard needed.contains(.node(id)) else { continue }
                    tasks.addTask { try Task.checkCancellation(); return (id, await probe(id)) }
                    return
                }
            }
            for _ in 0..<min(4, nodes.count) { enqueue() }
            while let (id, status) = try await tasks.next() {
                try Task.checkCancellation()
                results[id] = status
                resolveGroups()
                if resolved.count == groups.count { tasks.cancelAll(); break }
                enqueue()
            }
        }
        try Task.checkCancellation()
        for group in groups {
            guard let id = selected[group.id] else { continue }
            try Task.checkCancellation()
            try await select(group.id, id)
        }
        return selected
    }
}
