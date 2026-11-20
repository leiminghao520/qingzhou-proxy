import Foundation
import QingzhouKit

extension AppModel {
    var claudeApplicationCandidates: [Node] {
        state.nodes.filter { (try? ClaudeDedicatedProxy.endpoint($0)) != nil }
    }

    func startClaudeApplicationProxy(nodeID: UUID) async {
        guard !locked, !claudeApplicationChanging, !claudeSafetyRetainsProtection else {
            errorMessage = "请先明确解除旧整机保护，再启动 Claude 应用级专用代理"
            return
        }
        claudeApplicationChanging = true
        busy = true
        defer { claudeApplicationChanging = false; busy = false }
        do {
            guard claudeApplicationCore?.isRunning != true,
                  let node = claudeApplicationCandidates.first(where: { $0.id == nodeID }) else {
                throw ProxyError("请先停止专用代理，或重新选择可用的固定 TLS 节点")
            }
            let folder = directory.appendingPathComponent("claude-dedicated")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/" + ClaudeDedicatedProxy.executableName)
            let runner = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/QingzhouRunner")
            let controller = CoreController(directory: folder, binary: binary, supervisor: runner)
            controller.onUnexpectedExit = { [weak self] in
                self?.claudeApplicationRunning = false
                self?.claudeApplicationStatus = "专用代理已停止 · LuLu 规则必须保留，保护状态未自动核验"
            }
            claudeApplicationCore = controller
            let configuration = try ClaudeDedicatedProxy.configuration(node: node, credentials: credentials)
            try await controller.start(config: configuration, port: ClaudeDedicatedProxy.port)
            claudeApplicationNodeID = nodeID
            claudeApplicationRunning = true
            claudeApplicationStatus = "专用代理已启动 · 127.0.0.1:\(ClaudeDedicatedProxy.port) · LuLu 规则需单独核验"
            log("Claude 专用代理已启动；未修改系统代理、DNS、路由或整机防火墙")
        } catch {
            await claudeApplicationCore?.stop()
            claudeApplicationCore = nil
            claudeApplicationRunning = false
            claudeApplicationStatus = "专用代理未启动 · " + error.localizedDescription
            report(error)
        }
    }

    func stopClaudeApplicationProxy() async {
        guard !claudeApplicationChanging else { return }
        claudeApplicationChanging = true
        defer { claudeApplicationChanging = false }
        await claudeApplicationCore?.stop()
        claudeApplicationCore = nil
        claudeApplicationRunning = false
        claudeApplicationStatus = "专用代理已停止 · 未删除 LuLu 的 Claude 阻断规则"
    }
}
