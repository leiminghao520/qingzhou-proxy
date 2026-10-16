import SwiftUI
import AppKit
import QingzhouKit

@main
struct InterfaceChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("INTERFACE_CHECKS_FAILED \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func screenshot(_ window: NSWindow, to url: URL) throws {
        // 窗口截图保留原生侧栏与材质；视图缓存截图会漏掉独立合成的侧栏。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProxyError("窗口截图失败，请检查屏幕录制权限") }
    }

    @MainActor static func run() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--output") else { throw ProxyError("缺少输出目录") }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "cn.qingzhou.interface-checks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            preferences.synchronize()
        }
        let model = AppModel()
        guard !model.loadingFailed, !model.state.autoConnect else { throw ProxyError("隔离模型初始化失败") }
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ProxyError(message) }
            checks += 1
            print("PASS " + message)
        }
        try check(preferences.string(forKey: "interfaceMode") == nil, "首次使用没有模式偏好，使用简洁默认值")
        let root = ContentView(model: model).defaultAppStorage(preferences).tint(Theme.accentBlue)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        func settle() async {
            try? await Task.sleep(nanoseconds: 250_000_000)
            host.layoutSubtreeIfNeeded()
        }
        func capture(_ name: String, _ appearance: NSAppearance.Name = .aqua) async throws {
            window.appearance = NSAppearance(named: appearance)
            await settle()
            try screenshot(window, to: output.appendingPathComponent(name + ".png"))
        }
        try await capture("simple-empty-light")
        try await capture("simple-empty-dark", .darkAqua)
        let first = Node(name: "香港 · 日常线路", kind: .shadowsocks, server: "example.invalid", port: 443)
        let long = Node(name: "日本 · 东京 · 这是一条用于检查窄窗口中文长名称和英文 Tokyo Premium Route 的测试线路", kind: .trojan, server: "example.invalid", port: 443)
        model.state.nodes = [first, long]
        model.state.selectedPolicy = nil
        model.state.selectedID = nil
        try await capture("simple-needs-selection")
        model.state.selectedPolicy = .node(long.id)
        try await capture("simple-ready-long-name")
        model.connection = .connecting
        model.busy = true
        try await capture("simple-connecting")
        model.busy = false
        model.connection = .connected
        model.connectivityResults = [.init("HTTPS 连通性", .failed, "超时")]
        try await capture("simple-connected-failed")
        model.connectivityResults = ConnectivityResult.pending
        model.healthChecking = true
        try await capture("simple-health-checking")
        model.healthChecking = false
        model.connectivityResults = [.init("HTTPS 连通性", .passed, "测试状态")]
        try await capture("simple-connected-healthy")
        model.connection = .disconnecting
        model.busy = true
        try await capture("simple-disconnecting")
        model.busy = false
        model.connection = .error
        model.recoveryPending = true
        try await capture("simple-recovery-pending")
        model.recovering = true
        try await capture("simple-recovering")
        model.recovering = false
        model.recoveryPending = false
        model.connection = .disconnected
        var subscription = Subscription(name: "日常订阅 · 测试数据")
        subscription.pendingReview = true
        subscription.lastError = "上次更新超时，已保留原线路"
        model.state.subscriptions = [subscription]
        try await capture("simple-subscription-review")
        let before = try JSONEncoder().encode(model.state)
        let connection = model.connection
        preferences.set(InterfaceMode.professional.rawValue, forKey: "interfaceMode")
        window.setContentSize(NSSize(width: 1140, height: 760))
        try await capture("professional-light")
        try await capture("professional-dark", .darkAqua)
        preferences.set(InterfaceMode.simple.rawValue, forKey: "interfaceMode")
        window.setContentSize(NSSize(width: 820, height: 620))
        try await capture("simple-after-switch")
        let after = try JSONEncoder().encode(model.state)
        // JSON 对象比较不受字典键输出顺序影响。
        let beforeObject = try JSONSerialization.jsonObject(with: before) as! NSDictionary
        let afterObject = try JSONSerialization.jsonObject(with: after) as! NSDictionary
        try check(beforeObject == afterObject && model.connection == connection, "双向切换保留全部业务状态与连接状态")
        try check(UserDefaults(suiteName: suite)?.string(forKey: "interfaceMode") == "simple", "重新读取偏好保留用户选择")
        func component<V: View>(_ view: V, _ name: String, width: CGFloat = 550) async throws {
            let view = NSHostingView(rootView: view.padding(24).frame(width: width, height: 620).background(Color(nsColor: .windowBackgroundColor)))
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            panel.contentView = view
            panel.appearance = NSAppearance(named: .aqua)
            panel.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 250_000_000)
            view.layoutSubtreeIfNeeded()
            try screenshot(panel, to: output.appendingPathComponent(name + ".png"))
            panel.orderOut(nil)
        }
        try await component(SimpleLinesView(model: model, onImport: {}, onEdit: { _ in }, onProfessional: {}), "simple-lines")
        try await component(SimpleSubscriptionsView(model: model, onImport: {}), "simple-subscriptions")
        try await component(SimpleSettingsView(model: model, onAdvanced: {}, onDiagnose: {}).defaultAppStorage(preferences), "simple-settings")
        try check(!FileManager.default.fileExists(atPath: model.directory.appendingPathComponent("proxy-recovery.json").path), "截图未创建代理接管记录")
        print("INTERFACE_CHECKS_OK assertions=\(checks) screenshots=18")
        if CommandLine.arguments.contains("--interactive") {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            print("INTERACTIVE_READY")
            fflush(stdout)
            let finish = output.appendingPathComponent("finish-interactive")
            for _ in 0..<600 {
                if FileManager.default.fileExists(atPath: finish.path) { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
