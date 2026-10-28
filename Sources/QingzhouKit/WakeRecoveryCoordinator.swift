import Foundation

public enum WakeRecoveryReason:String,Codable,Sendable {
    case networkNotReady,controlUnavailable,nodeUnavailable,pathUnavailable,unverified,timeout
    case ownershipConflict,authentication,configuration,exitUnavailable,helperRecovery,retryExhausted,cancelled
    public var terminal:Bool {[Self.ownershipConflict,.authentication,.configuration,.exitUnavailable].contains(self)}
    public var label:String {switch self {
    case .networkNotReady:return "网络尚未就绪"
    case .controlUnavailable:return "控制接口不可达"
    case .nodeUnavailable:return "实际节点通道失败"
    case .pathUnavailable:return "当前规则 HTTPS 路径失败"
    case .unverified:return "实际节点或保护状态未验证"
    case .timeout:return "检测超时，不能确认失效"
    case .ownershipConflict:return "网络所有权冲突，请手动处理"
    case .authentication:return "鉴权失败，请检查凭据"
    case .configuration:return "配置或恢复失败，请手动检查"
    case .exitUnavailable:return "指定出口未就绪，保留拒绝保护，请手动处理"
    case .helperRecovery:return "辅助服务正在重建网络"
    case .retryExhausted:return "自动恢复预算已耗尽"
    case .cancelled:return "恢复任务已撤销"
    }}
}
public enum WakeRecoveryCheck:Equatable,Sendable {
    case healthy,failed(WakeRecoveryReason),inconclusive(WakeRecoveryReason),helperRecovering,stop(WakeRecoveryReason)
}
public struct WakeRecoveryStatus:Equatable,Sendable {
    public enum Phase:String,Sendable {case idle,waiting,checking,retryWaiting,rebuilding,recovered,manual,cancelled}
    public var phase:Phase
    public var attempt:Int
    public var reason:WakeRecoveryReason?
    public init(_ phase:Phase,attempt:Int=0,reason:WakeRecoveryReason?=nil){self.phase=phase;self.attempt=attempt;self.reason=reason}
    public var label:String {switch phase {
    case .idle:return ""
    case .waiting:return "等待网络稳定"
    case .checking:return "连接复查中"
    case .retryWaiting:return "等待自动重连第 \(attempt) 次"
    case .rebuilding:return "自动重连第 \(attempt) 次"
    case .recovered:return "连接已恢复"
    case .manual:return "需手动处理："+(reason?.label ?? "未验证")
    case .cancelled:return "恢复已取消"
    }}
}

// 单一任务拥有等待、确认和重建；时钟与探测均可注入，不持有凭据或改写配置。
@MainActor public final class WakeRecoveryCoordinator {
    public typealias Sleep=(TimeInterval) async throws -> Void
    public private(set) var id:UUID?
    public private(set) var status=WakeRecoveryStatus(.idle)
    public var active:Bool {task != nil}
    private var task:Task<Void,Never>?
    private var generation=UUID()
    private let sleep:Sleep
    public var changed:((WakeRecoveryStatus,UUID)->Void)?
    public init(sleep:@escaping Sleep={try await Task.sleep(nanoseconds:UInt64(max(0,$0)*1_000_000_000))}) {self.sleep=sleep}
    public func cancel() {
        guard let id else{return}
        task?.cancel();task=nil;self.id=nil;generation=UUID()
        status=WakeRecoveryStatus(.cancelled);changed?(status,id)
    }
    public func cancelAndWait() async {let running=task;cancel();await running?.value}
    public func waitUntilFinished() async {let running=task;await running?.value}
    public func start(id token:UUID=UUID(),stableDelay:TimeInterval=15,isCurrent:@escaping ()->Bool,
                      check:@escaping () async -> WakeRecoveryCheck,
                      rebuild:@escaping () async -> WakeRecoveryCheck) {
        guard !active else{return}
        id=token
        let run=UUID();generation=run
        task=Task { [weak self] in
            guard let self else{return}
            @MainActor func current()->Bool {self.generation==run && self.id==token && !Task.isCancelled && isCurrent()}
            @MainActor func publish(_ state:WakeRecoveryStatus) {guard current() else{return};self.status=state;self.changed?(state,token)}
            defer {if self.generation==run && self.id==token {self.task=nil;self.id=nil}}
            do {
                publish(WakeRecoveryStatus(.waiting));try await self.sleep(stableDelay)
                var failures=0,unknown=0,helperWaits=0,attempt=0
                while current() {
                    var pollDelay=3.0
                    publish(WakeRecoveryStatus(.checking,attempt:attempt))
                    let result=await check();guard current() else{return}
                    switch result {
                    case .healthy:publish(WakeRecoveryStatus(.recovered,attempt:attempt));return
                    case .stop(let reason):publish(WakeRecoveryStatus(.manual,attempt:attempt,reason:reason));return
                    case .helperRecovering:
                        failures=0;unknown=0;helperWaits=min(helperWaits+1,10)
                        pollDelay=Double(helperWaits)*3
                    case .inconclusive(let reason):
                        // 未知和超时只继续只读复查，不释放会话，也不据此重建网络。
                        failures=0;helperWaits=0;unknown=min(unknown+1,10)
                        publish(WakeRecoveryStatus(.checking,attempt:attempt,reason:reason))
                        pollDelay=Double(unknown)*3
                    case .failed(let reason):
                        if reason.terminal {publish(WakeRecoveryStatus(.manual,attempt:attempt,reason:reason));return}
                        failures+=1;unknown=0;helperWaits=0
                        if failures>=2 {
                            let nextAttempt=attempt+1
                            publish(WakeRecoveryStatus(.retryWaiting,attempt:nextAttempt,reason:reason))
                            // 持续故障按一、三、十、三十、六十秒退避，直到恢复或用户取消。
                            try await self.sleep([1.0,3,10,30,60][min(attempt,4)]);guard current() else{return}
                            // 退避期间辅助服务可能已完成重建；写操作前重新核对，避免双重重连。
                            let latest=await check();guard current() else{return}
                            if latest == .healthy {publish(WakeRecoveryStatus(.recovered,attempt:attempt));return}
                            if case .stop(let why)=latest {publish(WakeRecoveryStatus(.manual,attempt:attempt,reason:why));return}
                            if case .failed(let why)=latest,why.terminal {publish(WakeRecoveryStatus(.manual,attempt:attempt,reason:why));return}
                            guard case .failed=latest else {failures=0;try await self.sleep(3);continue}
                            attempt=nextAttempt
                            publish(WakeRecoveryStatus(.rebuilding,attempt:attempt))
                            let rebuilt=await rebuild();guard current() else{return}
                            if case .stop(let why)=rebuilt {publish(WakeRecoveryStatus(.manual,attempt:attempt,reason:why));return}
                            if case .failed(let why)=rebuilt,why.terminal {publish(WakeRecoveryStatus(.manual,attempt:attempt,reason:why));return}
                            failures=0
                        }
                    }
                    try await self.sleep(pollDelay)
                }
            } catch {if current() {publish(WakeRecoveryStatus(.manual,reason:.cancelled))}}
        }
    }
}

public struct WakeRecoveryError:LocalizedError,Sendable {
    public let reason:WakeRecoveryReason
    public init(_ reason:WakeRecoveryReason){self.reason=reason}
    public var errorDescription:String? {reason.label}
}

public extension WakeRecoveryCheck {
    // 只读取结构化类别；单次超时和未知节点均不能累计为失效证据。
    static func connectivity(_ results:[ConnectivityResult])->Self {
        if results.contains(where:{$0.status == .failed && $0.category=="鉴权"}) {return .stop(.authentication)}
        if results.contains(where:{$0.status == .failed && ["超时","取消","控制接口缺少实际节点","控制接口节点格式","控制接口响应格式","控制接口","节点测速响应格式","无法确定"].contains($0.category)}) {return .inconclusive(.unverified)}
        if let failed=results.first(where:{$0.status == .failed}) {
            return .failed(failed.category=="节点通道" ? .nodeUnavailable:.pathUnavailable)
        }
        return ConnectivityHealth.evaluate(results) == .healthy ? .healthy:.inconclusive(.unverified)
    }
}
