import Foundation
import Darwin

// 请求等待在工作队列上进行；取消通过 shutdown 唤醒，关闭由持有请求的一方完成，避免描述符复用竞态。
public final class HelperRequestChannel:@unchecked Sendable {
    private let lock=NSLock()
    private var descriptor:Int32
    private var busy=false
    private var cancelled=false
    public init(descriptor:Int32) {self.descriptor=descriptor}
    deinit {cancel()}
    public func cancel() {
        lock.lock();defer{lock.unlock()}
        cancelled=true
        guard descriptor>=0 else{return}
        _=shutdown(descriptor,SHUT_RDWR)
        if !busy {Darwin.close(descriptor);descriptor = -1}
    }
    public func perform<T>(_ body:(Int32) throws -> T) throws -> T {
        lock.lock()
        guard !cancelled,descriptor>=0,!busy else {lock.unlock();throw CancellationError()}
        busy=true;let fd=descriptor;lock.unlock()
        defer {
            lock.lock();busy=false
            if cancelled,descriptor>=0 {Darwin.close(descriptor);descriptor = -1}
            lock.unlock()
        }
        return try body(fd)
    }
    public func exchange(_ request:Data,progress:@escaping @Sendable (String)->Void,timeout:TimeInterval=60) async throws -> TunReply {
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {continuation in
                DispatchQueue.global(qos:.userInitiated).async {
                    do {
                        let reply=try self.perform {fd in
                            try UnixChannel.send(request,fd:fd,deadline:deadline)
                            return try HelperProgress.receive(read:{try JSONDecoder().decode(TunReply.self,from:UnixChannel.receive(fd:fd,deadline:deadline))},progress:progress)
                        }
                        continuation.resume(returning:reply)
                    } catch {continuation.resume(throwing:error)}
                }
            }
        },onCancel:{self.cancel()})
    }
}
