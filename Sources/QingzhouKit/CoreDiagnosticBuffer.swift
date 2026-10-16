import Foundation

public final class CoreDiagnosticBuffer:@unchecked Sendable {
    private let lock=NSLock()
    private let framer:LogFramer
    private var entries:[String]=[]
    public init(secrets:[String]){framer=LogFramer(secrets:secrets)}
    public func receive(_ data:Data,end:Bool=false) {
        let batch=framer.receive(data,end:end)
        lock.lock();defer{lock.unlock()}
        for line in batch {
            let plain=line.replacingOccurrences(of:"\u{001B}\\[[0-?]*[ -/]*[@-~]",with:"",options:.regularExpression)
            // 只保留可归因错误，限制内存和控制消息大小；完整凭据先由逐行框架脱敏。
            if plain.range(of:"error|warn|fail|timeout|unreachable|refused",options:[.regularExpression,.caseInsensitive]) != nil {entries.append(String(plain.prefix(1024)))}
        }
        if entries.count>80 {entries.removeFirst(entries.count-80)}
    }
    public var recent:[String] {lock.lock();defer{lock.unlock()};return Array(entries.suffix(20))}
}
