import Foundation
import CryptoKit
import Darwin

// 只记录哈希身份和有限枚举字段，不接受命令参数、凭据或原始错误文本。
public final class RouteAuditLog {
    private let directory:URL
    private let maximum:Int
    private let lock=NSLock()
    private var sequence=0
    public init(directory:URL,maximum:Int=1_048_576) {self.directory=directory;self.maximum=max(1024,maximum)}
    public func operation<T>(transaction:UUID,stage:String,kind:String,identity:String,result:(T)->String={_ in "confirmed"},_ body:() throws -> T) throws -> T {
        lock.lock();sequence+=1;let number=sequence;lock.unlock()
        let stages:Set<String>=["idle","preflight","bootstrapDNS","networkRecheck","bypassSnapshot","addressPlan","coreValidation","dnsBaseline","coreStartup","interfaceReady","prepared","activation","protection","dnsActivation","proxyActivation","active","recovery","restored","networkRetry","networkReconnecting","networkReplan","networkProtectionFailed"]
        let safeStage=stages.contains(stage) ? stage:"other"
        let safeKind=["snapshot","query","write","delete","add"].contains(kind) ? kind:"other"
        let began=DispatchTime.now().uptimeNanoseconds
        let hash=SHA256.hash(data:Data((transaction.uuidString+identity).utf8)).map{String(format:"%02x",$0)}.joined()
        func record(_ state:String) throws {
            try append(["timeUnixMs":Int(Date().timeIntervalSince1970*1000),"transaction":transaction.uuidString,"operation":number,"stage":safeStage,"kind":safeKind,"identityHash":hash,"state":state,"elapsedMs":Int((DispatchTime.now().uptimeNanoseconds-began)/1_000_000)])
        }
        // 开始记录落盘失败时不运行操作；结束记录失败仍保留写前恢复意图。
        try record("begin")
        let value:T
        do {value=try body()}
        catch {
            let state=(error as? RouteBackendError)?.outcomeUnknown==true ? "unknown":(error is CancellationError ? "cancelled":"failed")
            try record(state);throw error
        }
        let state=result(value)
        try record(["confirmed","rejected"].contains(state) ? state:"unknown");return value
    }
    private func append(_ object:[String:Any]) throws {
        lock.lock();defer{lock.unlock()}
        var directoryChanged=false
        let file=directory.appendingPathComponent("route-operations.jsonl"),fm=FileManager.default
        if fm.fileExists(atPath:file.path) {
            let attributes=try fm.attributesOfItem(atPath:file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {throw ProxyError("路由审计文件不是常规文件")}
            if (attributes[.size] as? NSNumber)?.intValue ?? 0 >= maximum {
                let retired=directory.appendingPathComponent("route-operations.previous.jsonl")
                if fm.fileExists(atPath:retired.path) {try fm.removeItem(at:retired)}
                try fm.moveItem(at:file,to:retired);directoryChanged=true
            }
        }
        if !fm.fileExists(atPath:file.path) {
            guard fm.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw ProxyError("路由审计文件创建失败")}
            directoryChanged=true
        }
        let handle=try FileHandle(forWritingTo:file);defer{try? handle.close()}
        try handle.seekToEnd();var data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);data.append(10)
        try handle.write(contentsOf:data);try handle.synchronize()
        if directoryChanged {
            let fd=open(directory.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC)
            guard fd>=0 else {throw ProxyError("路由审计目录无法打开")}
            defer{close(fd)}
            guard fsync(fd)==0 else {throw ProxyError("路由审计目录同步失败")}
        }
    }
}
