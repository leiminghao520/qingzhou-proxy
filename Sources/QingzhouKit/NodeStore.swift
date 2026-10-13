import Foundation

public final class NodeStore {
    public private(set) var state: AppState
    public let credentials: CredentialStore
    public let file: URL
    public init(file: URL, credentials: CredentialStore) throws {
        self.file = file; self.credentials = credentials
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: file))
            guard state.schemaVersion == 1 else { throw ProxyError("配置版本暂不支持") }
        } else { state = AppState() }
    }
    public func commit(_ next: AppState) throws {
        let data = try JSONEncoder().encode(next)
        try SecureFile.write(data, to: file)
        state = next
    }
    @discardableResult public func importNodes(_ candidates: [Candidate], subscription: Subscription? = nil, source: String? = nil, replacingID: UUID? = nil) throws -> Int {
        guard !candidates.isEmpty else { throw ProxyError("没有可导入节点") }
        var next = state; var written: [String] = []; var count = 0
        let oldSourceRef = subscription.flatMap { sub in state.subscriptions.first {$0.id == sub.id}?.sourceRef }
        let oldNodes = subscription.map { sub in state.nodes.filter {$0.subscriptionID == sub.id} } ?? replacingID.map { id in state.nodes.filter {$0.id == id} } ?? []
        if let sub = subscription { next.nodes.removeAll {$0.subscriptionID == sub.id} }
        if let id = replacingID { next.nodes.removeAll {$0.id == id} }
        var seen: [String:Candidate] = [:]
        do {
            for c in candidates {
                let fingerprint = c.node.fingerprint
                if let previous = seen[fingerprint] {
                    guard previous.secret == c.secret && previous.obfsSecret == c.obfsSecret else { throw ProxyError("同一服务器参数包含冲突凭据，请分开导入") }
                    continue
                }
                seen[fingerprint] = c
                if subscription == nil && replacingID == nil, let existing = next.nodes.first(where: {$0.subscriptionID == nil && $0.fingerprint == fingerprint}), (try? credentials.get(existing.credentialRef)) == c.secret, (try? credentials.get(existing.credentialRef + ".obfs")) == c.obfsSecret { continue }
                var node = c.node
                if let id = replacingID { node.id = id }
                else if let old = oldNodes.first(where: {$0.fingerprint == fingerprint}) { node.id = old.id }
                node.subscriptionID = subscription?.id
                node.credentialRef = UUID().uuidString
                written.append(node.credentialRef); try credentials.set(c.secret, for: node.credentialRef)
                if let obfs = c.obfsSecret { written.append(node.credentialRef + ".obfs"); try credentials.set(obfs, for: node.credentialRef + ".obfs") }
                next.nodes.append(node); count += 1
            }
            if var sub = subscription {
                sub.updatedAt = Date()
                if let source { sub.sourceRef = UUID().uuidString; written.append(sub.sourceRef); try credentials.set(source, for: sub.sourceRef) }
                next.subscriptions.removeAll {$0.id == sub.id}; next.subscriptions.append(sub)
            }
            if let selected = next.selectedID, !next.nodes.contains(where: {$0.id == selected}) { next.selectedID = nil }
            if state.nodes.isEmpty { next.selectedID = next.nodes.first?.id }
            try commit(next)
        } catch {
            for ref in written { try? credentials.remove(ref) }
            throw error
        }
        for node in oldNodes { try? credentials.remove(node.credentialRef); try? credentials.remove(node.credentialRef + ".obfs") }
        if source != nil, let old = oldSourceRef { try? credentials.remove(old) }
        return count
    }
    public func deleteNode(_ id: UUID) throws {
        guard let node = state.nodes.first(where: {$0.id == id}) else { return }
        var next = state; next.nodes.removeAll {$0.id == id}; if next.selectedID == id { next.selectedID = nil }; try commit(next)
        try? credentials.remove(node.credentialRef); try? credentials.remove(node.credentialRef + ".obfs")
    }
    public func deleteSubscription(_ id: UUID) throws {
        let nodes = state.nodes.filter {$0.subscriptionID == id}; let sub = state.subscriptions.first {$0.id == id}
        var next = state; next.nodes.removeAll {$0.subscriptionID == id}; next.subscriptions.removeAll {$0.id == id}; if let selected = next.selectedID, nodes.contains(where: {$0.id == selected}) { next.selectedID = nil }; try commit(next)
        for node in nodes { try? credentials.remove(node.credentialRef); try? credentials.remove(node.credentialRef + ".obfs") }
        if let sub { try? credentials.remove(sub.sourceRef) }
    }
}
