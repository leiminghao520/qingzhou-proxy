import SwiftUI
import AppKit
import QingzhouKit

@main
struct InterfaceChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if let resources = Bundle.main.resourceURL, let icon = NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns")) {
            app.applicationIconImage = icon
        }
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
        var screenshotCount = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ProxyError(message) }
            checks += 1
            print("PASS " + message)
        }
        // 监控失效时所有速率入口显示不可用，列表成功不覆盖通道或健康错误。
        model.monitor.active = true
        model.monitor.traffic = .unavailable
        model.monitor.connections = .available
        model.monitor.health = "节点健康部分无法确定"
        model.uploadRate = 100; model.downloadRate = 200
        try check(model.uploadRateText == "不可用" && model.downloadRateText == "不可用", "失效速率不显示历史值")
        try check(model.monitorStatus.contains("流量通道") && model.monitorStatus.contains("节点健康"), "列表成功不掩盖流量与健康错误")
        model.monitor.traffic = .available
        try check(model.downloadRateText == formatRate(200), "流量恢复后显示新速率")
        model.monitorPaused = true
        try check(model.uploadRateText == "不可用", "暂停期间不显示历史速率")
        model.monitorPaused = false; model.monitor = RuntimeMonitorState()
        model.uploadRate = 0; model.downloadRate = 0
        try check(preferences.string(forKey: "interfaceMode") == nil, "首次使用没有模式偏好，使用简洁默认值")
        try check(preferences.string(forKey: "appearancePreference") == nil, "首次使用默认跟随系统外观")
        let root = ContentView(model: model).defaultAppStorage(preferences).tint(Theme.accentBlue)
        let host = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        func settle() async {
            try? await Task.sleep(nanoseconds: 600_000_000)
            host.layoutSubtreeIfNeeded()
        }
        func capture(_ name: String, _ appearance: NSAppearance.Name = .aqua) async throws {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.appearance = NSAppearance(named: appearance)
            await settle()
            try screenshot(window, to: output.appendingPathComponent(name + ".png"))
            screenshotCount += 1
        }
        if CommandLine.arguments.contains("--protection-only") {
            model.state.captureMode = .compatible
            model.state.nodes=[Node(name:"隔离连接进度",kind:.shadowsocks,server:"fixture.invalid",port:443)]
            model.state.selectedPolicy = .node(model.state.nodes[0].id)
            model.connection = .connecting;model.busy=true
            model.startupStartedAt=ProcessInfo.processInfo.systemUptime-38
            model.startupStage=HelperProgress.label("protection")
            try await capture("protection-simple-light")
            try await capture("protection-simple-dark",.darkAqua)
            host.rootView=AnyView(OverviewView(model:model).padding(24))
            try await capture("protection-overview-light")
            try await capture("protection-overview-dark",.darkAqua)
            model.startupStage=HelperProgress.label("dnsActivation")
            try await capture("protection-dns-progress")
            try check(model.startupStage=="应用并核验 DNS","辅助服务阶段映射正确")
            model.connection = .disconnected;model.busy=false;model.startupStage=nil;model.startupStartedAt=nil
            try await capture("protection-finished")
            print("PROTECTION_INTERFACE_CHECKS_OK checks=\(checks) screenshots=\(screenshotCount)")
            return
        }
        let vps=VPSCenter(directory:output.appendingPathComponent("isolated-vps"),refreshEnabled:false)
        vps.binding=VPSCenter.Binding(endpoint:"https://fixture.invalid/api/client/v1",subscription:UUID(),tokenRef:"fixture")
        vps.owner=true
        vps.status = .object(["state":.string("fresh"),"captured_at":.number(Date().timeIntervalSince1970),"data":.object(["hysteria":.string("active"),"auth":.string("active"),"nginx":.string("active")])])
        vps.billing = .object(["state":.string("fresh"),"data":.object(["configured":.bool(true),"charge_type":.string("BANDWIDTH_PREPAID"),"packages":.array([.object(["total_gb":.number(100),"remaining_gb":.number(35)])])])])
        vps.devices = .object(["devices":.array([.object(["name":.string("隔离测试 Mac"),"platform":.string("macOS"),"enabled":.number(1)])])])
        vps.usage = .object(["today":.object(["upload":.number(1048576),"download":.number(8388608),"complete":.bool(false)])])
        host.rootView=AnyView(VPSView(model:model,center:vps))
        try await capture("vps-linked-light")
        try await capture("vps-linked-dark",.darkAqua)
        func scrollView(_ view:NSView)->NSScrollView? {
            if let scroll=view as? NSScrollView{return scroll}
            for child in view.subviews {if let scroll=scrollView(child){return scroll}}
            return nil
        }
        if let scroll=scrollView(host),let document=scroll.documentView {
            scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,document.bounds.height-scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await capture("vps-tools-light")
            try await capture("vps-tools-dark",.darkAqua)
            vps.billing = .object(["state":.string("fresh"),"captured_at":.number(Date().timeIntervalSince1970),"data":.object([
                "configured":.bool(true),"charge_type":.string("TRAFFIC_POSTPAID_BY_HOUR"),
                "expires":.string("2027-09-15T13:22:51Z"),"bills":.array([]),
                "packages":.array([.object(["scope":.string("instance_package"),"unit":.string("GiB"),
                    "total_gb":.number(1536),"remaining_gb":.number(1496.01)])])])])
            scroll.contentView.scroll(to:NSPoint(x:0,y:350))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await capture("vps-lighthouse-light")
            try await capture("vps-lighthouse-dark",.darkAqua)
        }else{throw ProxyError("VPS 滚动容器不可用")}
        vps.startSpeed(model:model)
        try check(!vps.speedRunning,"断开时不能运行 VPS 测速")
        try check(VPSCenter.isBackupName("backup-20261021T000000Z.tar.age") && !VPSCenter.isBackupName("../foreign.age"),"备份清理仅匹配受管文件名")
        vps.binding=nil
        try await capture("vps-pairing-light")
        host.rootView=AnyView(root)
        try await capture("simple-empty-light")
        try await capture("simple-empty-dark", .darkAqua)
        // 只在独立检查程序中注入 SDK 的环境存储值，不改变系统辅助功能设置。
        host.rootView = AnyView(root.environment(\._accessibilityReduceTransparency, true))
        try await capture("simple-reduced-transparency-light")
        try await capture("simple-reduced-transparency-dark", .darkAqua)
        host.rootView = AnyView(root.environment(\._accessibilityReduceMotion, true))
        try await capture("simple-reduced-motion")
        host.rootView = AnyView(root.environment(\._colorSchemeContrast, .increased))
        try await capture("simple-increased-contrast")
        host.rootView = AnyView(root)
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
        let appearanceState = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.state)) as! NSDictionary
        preferences.set(AppearancePreference.light.rawValue, forKey: "appearancePreference")
        await settle()
        try check(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "白天外观应用到窗口")
        try await capture("appearance-day", .darkAqua)
        preferences.set(AppearancePreference.dark.rawValue, forKey: "appearancePreference")
        await settle()
        try check(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "夜间外观应用到窗口")
        try await capture("appearance-night", .aqua)
        preferences.synchronize()
        try check(UserDefaults(suiteName: suite)?.string(forKey: "appearancePreference") == "dark", "外观偏好持久保存")
        preferences.set(AppearancePreference.system.rawValue, forKey: "appearancePreference")
        window.appearance = NSAppearance(named: .darkAqua)
        await settle()
        try check(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "跟随系统恢复深色继承")
        try await capture("appearance-system-dark", .darkAqua)
        window.appearance = NSAppearance(named: .aqua)
        await settle()
        try check(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "跟随系统响应浅色继承")
        try await capture("appearance-system-light")
        let afterAppearanceState = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.state)) as! NSDictionary
        try check(appearanceState == afterAppearanceState && model.connection == connection, "外观切换不改变代理配置和连接状态")
        let after = try JSONEncoder().encode(model.state)
        // JSON 对象比较不受字典键输出顺序影响。
        let beforeObject = try JSONSerialization.jsonObject(with: before) as! NSDictionary
        let afterObject = try JSONSerialization.jsonObject(with: after) as! NSDictionary
        try check(beforeObject == afterObject && model.connection == connection, "双向切换保留全部业务状态与连接状态")
        try check(UserDefaults(suiteName: suite)?.string(forKey: "interfaceMode") == "simple", "重新读取偏好保留用户选择")
        func component<V: View>(_ view: V, _ name: String, width: CGFloat = 550, height:CGFloat = 620, appearance:NSAppearance.Name = .aqua) async throws {
            let view = NSHostingView(rootView: view.padding(24).frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            panel.contentView = view
            panel.appearance = NSAppearance(named: appearance)
            panel.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 600_000_000)
            view.layoutSubtreeIfNeeded()
            try screenshot(panel, to: output.appendingPathComponent(name + ".png"))
            screenshotCount += 1
            panel.orderOut(nil)
        }
        try await component(SimpleLinesView(model: model, onImport: {}, onEdit: { _ in }, onProfessional: {}), "simple-lines")
        try await component(SimpleSubscriptionsView(model: model, onImport: {}), "simple-subscriptions")
        try await component(SimpleSettingsView(model: model, onAdvanced: {}, onDiagnose: {}).defaultAppStorage(preferences), "simple-settings")
        try await component(SettingsView(model:model).defaultAppStorage(preferences),"professional-settings",width:1060,height:760)
        try await component(SettingsView(model:model).defaultAppStorage(preferences),"professional-settings-dark",width:1060,height:760,appearance:.darkAqua)
        try check(!preferences.bool(forKey:"clipboardRecognitionEnabled"),"剪贴板识别默认关闭")
        let ruleText="DOMAIN,example.com,DIRECT\nIP-CIDR,192.0.2.0/24,PROXY,no-resolve\nMATCH,REJECT"
        let rules=RuleTextCodec.parse(ruleText,state:model.state).rules
        try await component(RuleTextEditor(app:model,text:ruleText,rules:rules,accept:{_ in}),"rule-text-editor",width:820,height:740)
        try await component(RuleTextEditor(app:model,text:ruleText,rules:rules,accept:{_ in}),"rule-text-editor-dark",width:820,height:740,appearance:.darkAqua)
        try await component(TrafficHistoryView(model:model,history:model.history),"traffic-history-empty",width:820)
        try await component(TrafficHistoryView(model:model,history:model.history),"traffic-history-dark",width:820,appearance:.darkAqua)
        let historySnapshot=try JSONDecoder().decode(ConnectionSnapshot.self,from:Data("{\"uploadTotal\":2500000,\"downloadTotal\":10000000,\"connections\":[]}".utf8))
        if let profileID=model.currentProfileID {model.history.receive(historySnapshot,profileID:profileID)}
        await model.history.drain()
        try? await Task.sleep(nanoseconds:200_000_000)
        try check(!model.history.rows.isEmpty,"历史汇总写入后可在界面读取")
        try await component(TrafficHistoryView(model:model,history:model.history),"traffic-history-populated",width:820)
        try await component(TrafficHistoryView(model:model,history:model.history),"traffic-history-populated-dark",width:820,appearance:.darkAqua)
        model.history.clear();await model.history.drain()
        try? await Task.sleep(nanoseconds:200_000_000)
        try check(model.history.rows.isEmpty,"历史清空后界面同步为空")
        let invalid=RuleTextEditorModel(text:"DOMAIN,x.example,不存在",state:model.state,previous:[])
        try? await Task.sleep(nanoseconds:500_000_000)
        try check(!invalid.validating && invalid.result.issues.first?.line==1,"规则文本异步校验定位到错误行")
        invalid.text=ruleText;invalid.validate()
        try? await Task.sleep(nanoseconds:500_000_000)
        try check(!invalid.validating && invalid.result.issues.isEmpty,"规则文本修复后校验通过")
        try check(model.connection==connection,"新增界面未改变连接状态")
        try check(!FileManager.default.fileExists(atPath: model.directory.appendingPathComponent("proxy-recovery.json").path), "截图未创建代理接管记录")
        print("INTERFACE_CHECKS_OK assertions=\(checks) screenshots=\(screenshotCount)")
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
