import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var readyToQuit = false
    private var quitTask: Task<Void,Never>?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit { return .terminateNow }
        guard let model else { return .terminateNow }
        guard quitTask==nil else{return .terminateLater}
        quitTask=Task {
            let safe = await model.quit()
            readyToQuit = safe
            sender.reply(toApplicationShouldTerminate: safe)
            quitTask=nil
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct QingzhouApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() { _model = StateObject(wrappedValue: AppModel(dependencies: AppDependencies())) }
    @State private var showingAbout = false
    @AppStorage("interfaceMode") private var interfaceMode = InterfaceMode.simple

    var body: some Scene {
        WindowGroup("汐航") {
            ContentView(model: model)
                .tint(Theme.accentBlue)
                .frame(minWidth: interfaceMode == .simple ? 820 : 1040, minHeight: interfaceMode == .simple ? 620 : 700)
                .onAppear { delegate.model = model }
                .sheet(isPresented:$showingAbout) { VStack { XihangAboutView(); Button("完成") { showingAbout=false }.keyboardShortcut(.cancelAction).padding(.bottom,24) } }
                .task { await model.startupRecovery() }
        }
        .defaultSize(width: 900, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing:.appInfo) { Button("关于汐航") { showingAbout=true } }
        }

        MenuBarExtra {
            Text("\(model.connectionSummary) · \(model.state.mode.label)")
            Text(model.actualName + " · " + model.effectiveState.captureMode.label)
            if model.activeRecovery != nil {
                Text(model.effectivePathSummary)
                Button("重试原方案"){Task{await model.retryOriginal()}}.disabled(model.locked)
                Button("采用当前方案"){model.adoptRecovery()}.disabled(model.locked)
            }
            if let title=model.issueTitle {Text(title)}
            OfficeMenuHealth(office:model.office,hasCorporate:!model.state.protectedDomains.isEmpty || !model.state.enabledBypasses.isEmpty)
            if !(model.state.savedDiagnosticTargets ?? []).isEmpty {
                Menu("常用目标路径检查") {
                    ForEach(Array((model.state.savedDiagnosticTargets ?? []).prefix(5))) {target in
                        Button(target.name) {model.inspectSavedTarget(target);model.office.diagnosticRequested=true}
                    }
                    Button("全部目标与诊断") {model.office.diagnosticRequested=true}
                }.disabled(model.locked)
            }
            Button(model.networkWaiting ? "停止自动重连" : model.connection == .connected ? "断开" : model.connection == .connecting ? "取消连接" : "连接") {
                Task {
                    if model.hasConnectionActivity { await model.disconnect() }
                    else { await model.connect() }
                }
            }
            .disabled(model.stopDisabled || (model.state.activePolicy == nil && model.state.mode != .direct && model.connection != .connected) || (model.recoveryPending && !model.hasConnectionActivity))

            if interfaceMode == .simple {
                Menu("线路") {
                    Button("自动选择") { Task { await model.selectPolicy(.automatic) } }
                    ForEach(model.state.groups) { group in
                        Button(group.name) { Task { await model.selectPolicy(.group(group.id)) } }
                    }
                    Button("更多线路") {model.office.linesRequested=true}
                    ForEach(OfficeTelemetryCadence.menuNodes(model.state,actualTag:CoreAPIClient.actualTag(model.proxyInfo))) { node in
                        Button((model.state.activePolicy == .node(node.id) ? "✓ " : "") + node.name) {
                            Task { await model.select(node.id) }
                        }
                    }
                }
                .disabled(model.locked || model.state.nodes.isEmpty)
                Button("恢复网络") { Task { await model.recover() } }
                    .disabled(model.loadingFailed || model.recovering)
                Menu("更多") { advancedMenuActions }
            } else {
                advancedMenuActions
            }

            Divider()
            Button("显示主窗口") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            Button("退出汐航") { NSApplication.shared.terminate(nil) }
        } label: {
            OfficeMenuBarLabel(connected:model.connectionAvailable,status:model.connectionSummary)
        }
    }
    @ViewBuilder private var advancedMenuActions: some View {
        Menu("配置") {
            ForEach(model.profiles) { profile in
                Button((model.currentProfileID == profile.id ? "✓ " : "") + profile.name) {
                    Task { await model.requestProfileChange(profile.id) }
                }
            }
        }
        .disabled(model.locked)

        Button("暂停代理") { Task { await model.disconnect() } }
            .disabled(!model.canStop || model.connection != .connected)

        Button("一键诊断") { Task { await model.diagnose() } }
            .disabled(model.locked)

        Menu("代理模式") {
            ForEach(ProxyMode.allCases, id: \.self) { mode in
                Button((mode == model.state.mode ? "✓ " : "") + mode.label) {
                    Task { await model.setMode(mode) }
                }
            }
        }
        .disabled(model.locked)

        Menu("节点与策略") {
            Button("自动选择") { Task { await model.selectPolicy(.automatic) } }
                .disabled(model.state.nodes.isEmpty)
            ForEach(model.state.groups) { group in
                Button(group.name) { Task { await model.selectPolicy(.group(group.id)) } }
            }
            Divider()
            Button("更多线路") {model.office.linesRequested=true}
            ForEach(OfficeTelemetryCadence.menuNodes(model.state,actualTag:CoreAPIClient.actualTag(model.proxyInfo))) { node in
                Button((model.state.favorites.contains(node.id) ? "★ " : "") + node.name) {
                    Task { await model.select(node.id) }
                }
            }
        }
        .disabled(model.locked)

        Button(model.measuring ? "取消测速" : "检测全部节点 HTTPS 延迟") {
            if model.measuring { model.cancelMeasurement() }
            else { model.measure() }
        }
        .disabled(model.busy || model.state.nodes.isEmpty)

        Button("更新订阅和规则") { Task { await model.refreshAll() } }
            .disabled(model.locked)

        Button("开发工具代理助手") {model.office.developerRequested=true}
        Button("恢复原代理") { Task { await model.recover() } }
            .disabled(model.loadingFailed || model.recovering)
    }
}

func bytes(_ value: Int64) -> String {
    let v = max(0, value)
    if v == 0 {
        return "0 B"
    } else if v < 1024 {
        return "\(v) B"
    } else if v < 1024 * 1024 {
        let kb = Double(v) / 1024.0
        return kb >= 100 ? String(format: "%.0f KB", kb) : String(format: "%.1f KB", kb)
    } else if v < 1024 * 1024 * 1024 {
        let mb = Double(v) / 1048576.0
        return mb >= 100 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
    } else {
        let gb = Double(v) / 1073741824.0
        return String(format: "%.2f GB", gb)
    }
}

func formatRate(_ value: Int64) -> String {
    "\(bytes(value))/s"
}

@MainActor func latency(_ node: Node, _ model: AppModel) -> String {
    LatencyPresentation.label(model.state.latency[node.id.uuidString],invalidatedAt:model.latencyInvalidatedAt,now:max(model.latencyClock,Date()))
}

// MARK: - 主内容视图
