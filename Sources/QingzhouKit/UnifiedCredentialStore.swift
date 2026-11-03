import Foundation

// 授权策略跟随异步任务传递，后台任务不能借前台操作弹出系统窗口。
public enum CredentialAuthorization {
    @TaskLocal public static var allowsInteraction = true
    @TaskLocal public static var attempt: Attempt?
    public final class Attempt {
        private let lock=NSLock()
        private var denied=false
        public init() {}
        public var cancelled:Bool {lock.lock();defer{lock.unlock()};return denied}
        public func cancel() {lock.lock();denied=true;lock.unlock()}
    }
}
public struct MissingCredential: LocalizedError {
    public init() {}
    public var errorDescription: String? { KeychainFailure.message(-25300, operation:"读取") }
}

// 凭据集中存放在一个系统钥匙串条目中；不把明文密码写入配置或磁盘文件。
public final class UnifiedCredentialStore: CredentialStore {
    public static let native = UnifiedCredentialStore(legacy:KeychainStore())
    public static let account = "qingzhou.credentials.unified.v1"
    private struct Envelope: Codable {
        var version = 1
        var values: [String:String] = [:]
        var removed: Set<String> = []
    }
    private let legacy: any CredentialStore
    private let lock = NSRecursiveLock()
    private var cached: Envelope?
    public init(legacy: any CredentialStore) { self.legacy = legacy }

    private func load() throws -> Envelope {
        if let cached { return cached }
        let value: String
        do { value = try legacy.get(Self.account) }
        catch is MissingCredential { let empty=Envelope();cached=empty;return empty }
        guard let data=value.data(using:.utf8),data.count<=32*1024*1024,
              let decoded=try? JSONDecoder().decode(Envelope.self,from:data),decoded.version==1,
              decoded.values.count<=150000,decoded.removed.count<=150000,
              decoded.values[Self.account]==nil else {throw ProxyError("合并凭据存储损坏或版本不支持，未覆盖原数据")}
        cached=decoded;return decoded
    }
    private func save(_ envelope: Envelope) throws {
        let data=try JSONEncoder().encode(envelope)
        guard data.count<=32*1024*1024,envelope.values.count<=150000,envelope.removed.count<=150000,
              let value=String(data:data,encoding:.utf8) else {throw ProxyError("合并凭据超过存储上限")}
        // 写入成功后才发布新缓存；失败时仍可读取原条目与原缓存。
        try legacy.set(value,for:Self.account)
        cached=envelope
    }
    public func get(_ ref: String) throws -> String {
        lock.lock();defer{lock.unlock()}
        guard ref != Self.account else {throw ProxyError("不能将内部凭据条目作为节点引用")}
        var envelope=try load()
        if let value=envelope.values[ref] {return value}
        guard !envelope.removed.contains(ref) else {throw MissingCredential()}
        let value=try legacy.get(ref)
        envelope.values[ref]=value
        // 旧条目只读迁移；写入失败不影响已获准的本次读取，也不删除旧凭据。
        try? save(envelope)
        return value
    }
    public func set(_ value: String, for ref: String) throws {
        lock.lock();defer{lock.unlock()}
        guard ref != Self.account else {throw ProxyError("不能写入内部凭据引用")}
        var envelope=try load();envelope.values[ref]=value;envelope.removed.remove(ref)
        try save(envelope)
    }
    public func remove(_ ref: String) throws {
        lock.lock();defer{lock.unlock()}
        guard ref != Self.account else {throw ProxyError("不能移除内部凭据条目")}
        var envelope=try load();envelope.values.removeValue(forKey:ref);envelope.removed.insert(ref)
        // 删除标记持久化，旧版条目即使保留也不能在回退读取时复活。
        try save(envelope)
    }
}
