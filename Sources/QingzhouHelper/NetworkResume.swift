import Foundation
import QingzhouKit

// 仅保留当前已授权连接的模型和控制通道，不写入磁盘，也不用于应用重启后自动连接。
final class NetworkResumeSession {
    let request: TunRequest
    let owner: Int32
    var backoff = NetworkResumeBackoff()
    init(request: TunRequest, owner: Int32) {
        self.request = request
        self.owner = owner
    }
}

extension Service {
    func cancelNetworkResume() {
        networkResumeWork?.cancel()
        networkResumeWork = nil
        networkResumeSession = nil
    }

    func beginNetworkResume(_ request: TunRequest, fd: Int32) {
        cancelNetworkResume()
        // 指定出口拒绝保护不能在网络重建间隙被撤销；无法原位更新时等待用户重新连接。
        if request.state?.pinnedBypasses.isEmpty == false {
            suspendCorporateQueries();phase="networkRetry"
            lastFailure="指定出口保护仍保留；主网络变化需要重新连接以核验新路径"
            return
        }
        var resumed=request
        if var state=resumed.state {
            // 已学习到的企业域名只沿用当前连接，不写回用户配置；重建期间仍不能落入公网解析。
            do {try state.setBypasses(state.effectiveBypasses+NetworkBypassPolicy.migrate(domains:Array(knownProtectedDomains.subtracting(state.bypassDomains)),cidrs:[]))}
            catch {lastFailure="网络重建保护配置无效："+error.localizedDescription;phase="networkProtectionFailed";return}
            resumed.state=state
        }
        let session = NetworkResumeSession(request: resumed, owner: fd)
        networkResumeSession = session
        attemptNetworkResume(session)
    }

    private func attemptNetworkResume(_ session: NetworkResumeSession) {
        guard networkResumeSession === session else { return }
        // 串行队列内的内部恢复不取消本次会话；用户停止命令始终取消它。
        performingNetworkResume = true
        defer { performingNetworkResume = false }
        networkResumeWork = nil
        do {
            phase = "networkReplan"
            try stop()
            try start(session.request, fd: session.owner)
            guard let activate = activatePrepared else { throw ProxyError("网络重规划未完成") }
            try activate()
            activatePrepared = nil
            phase = "active"
            lastFailure = nil
            cancelNetworkResume()
        } catch {
            let original = error
            do { try stop() }
            catch {
                cancelNetworkResume()
                lastFailure = "网络自动恢复已停止：恢复冲突：" + error.localizedDescription
                phase = "networkProtectionFailed"
                return
            }
            guard original is NetworkEnvironmentNotReady,
                  let delay = session.backoff.nextDelay() else {
                cancelNetworkResume()
                lastFailure = "网络自动恢复已停止：" + original.localizedDescription + "；原网络已恢复"
                phase = "networkProtectionFailed"
                return
            }
            phase = "networkReconnecting"
            // 控制通道关闭时，服务仍能识别并取消此连接的待重试任务。
            owner = session.owner
            lastFailure = "网络重新连接中，第 \(session.backoff.attempts) 次等待：" + original.localizedDescription
            let work = DispatchWorkItem { [weak self, weak session] in
                guard let self, let session else { return }
                self.attemptNetworkResume(session)
            }
            networkResumeWork = work
            if let networkResumeSchedule { networkResumeSchedule(delay, { work.perform() }) }
            else { queue.asyncAfter(deadline: .now() + delay, execute: work) }
        }
    }
}
