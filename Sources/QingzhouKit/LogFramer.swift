import Foundation

// 先拼接完整日志行再脱敏，避免凭据被底层管道分成两段后泄漏。
public final class LogFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var dropping = false
    private let secrets: [String]
    public init(secrets: [String]) { self.secrets = secrets }
    public func receive(_ data: Data, end: Bool = false) -> [String] {
        lock.lock();defer {lock.unlock()}
        var lines: [String] = []
        for byte in data {
            if byte == 10 {
                if !dropping { lines.append(Redactor.redact(String(decoding:pending,as:UTF8.self),secrets:secrets)) }
                pending.removeAll(keepingCapacity:true);dropping = false
            } else if !dropping {
                if pending.count < 8192 {pending.append(byte)} else {pending.removeAll(keepingCapacity:true);dropping = true}
            }
        }
        if end {if !dropping && !pending.isEmpty {lines.append(Redactor.redact(String(decoding:pending,as:UTF8.self),secrets:secrets))};pending.removeAll();dropping = false}
        return lines
    }
}
