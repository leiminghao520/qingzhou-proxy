import Foundation

public enum CoreAPIReadiness {
    // 仅在启动阶段重试瞬时传输错误；鉴权和响应格式错误立即交给现有回滚事务。
    public static func wait(timeout:TimeInterval=5,interval:TimeInterval=0.1,uptime:()->TimeInterval={ProcessInfo.processInfo.systemUptime},sleep:(TimeInterval) async throws -> Void={try await Task.sleep(nanoseconds:UInt64($0*1_000_000_000))},query:(TimeInterval) async throws -> Void) async throws {
        guard timeout.isFinite,timeout>0,timeout<=30,interval.isFinite,interval>0 else{throw ProxyError("核心就绪等待预算无效")}
        let deadline=uptime()+timeout
        while true {
            try Task.checkCancellation()
            let remaining=deadline-uptime()
            guard remaining>0 else{throw CoreAPIError("控制接口就绪超时")}
            do {
                try await query(min(1,remaining))
                try Task.checkCancellation()
                guard uptime()<=deadline else{throw CoreAPIError("控制接口就绪超时")}
                return
            }catch let error as CoreAPIError where error.retryableDuringStartup {
                try Task.checkCancellation()
                let remaining=deadline-uptime()
                guard remaining>0 else{throw CoreAPIError("控制接口就绪超时")}
                try await sleep(min(interval,remaining))
            }
        }
    }
}
