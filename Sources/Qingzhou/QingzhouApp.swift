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
    @StateObject private var model = AppModel()
    @AppStorage("interfaceMode") private var interfaceMode = InterfaceMode.simple

    var body: some Scene {
        WindowGroup("轻舟代理") {
            ContentView(model: model)
                .tint(Theme.accentBlue)
                .frame(minWidth: interfaceMode == .simple ? 820 : 1040, minHeight: interfaceMode == .simple ? 620 : 700)
                .onAppear { delegate.model = model }
                .task { await model.startupRecovery() }
        }
        .defaultSize(width: 900, height: 680)
        .windowResizability(.contentMinSize)

        MenuBarExtra("轻舟代理", systemImage: model.connection == .connected ? "paperplane.fill" : "paperplane") {
            Text("\(model.connectionSummary) · \(model.state.mode.label)")
            Text(model.actualName + " · " + model.state.captureMode.label)
            if model.connection == .connected {
                Text("↑ \(model.uploadRateText)  ↓ \(model.downloadRateText)")
            }
            Button(model.connection == .connected ? "断开" : model.connection == .connecting ? "取消连接" : "连接") {
                Task {
                    if model.connection == .connected || model.connection == .connecting { await model.disconnect() }
                    else { await model.connect() }
                }
            }
            .disabled(model.stopDisabled || (model.state.activePolicy == nil && model.state.mode != .direct && model.connection != .connected) || (model.recoveryPending && model.connection != .connected))

            if interfaceMode == .simple {
                Menu("线路") {
                    Button("自动选择") { Task { await model.selectPolicy(.automatic) } }
                    ForEach(model.state.groups) { group in
                        Button(group.name) { Task { await model.selectPolicy(.group(group.id)) } }
                    }
                    ForEach(model.state.nodes) { node in
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
            Button("退出轻舟代理") { NSApplication.shared.terminate(nil) }
        }
    }
    @ViewBuilder private var advancedMenuActions: some View {
        Menu("配置") {
            ForEach(model.profiles) { profile in
                Button((model.currentProfileID == profile.id ? "✓ " : "") + profile.name) {
                    Task { await model.changeProfile(profile.id) }
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
            ForEach(model.state.nodes.prefix(30)) { node in
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

        Button("复制终端代理命令") { model.copyTerminalProxy() }
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
    LatencyPresentation.label(model.state.latency[node.id.uuidString],invalidatedAt:model.latencyInvalidatedAt,now:model.latencyClock)
}

// MARK: - Main Content View
struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearancePreference") private var appearance = AppearancePreference.system
    @AppStorage("interfaceMode") private var interfaceMode = InterfaceMode.simple
    @State private var page = AppPage.home
    @State private var utility: UtilityPage?
    @Namespace private var navigationGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importing = false
    @State private var editing: EditorRequest?

    private var navSections: [(title: String, items: [AppPage])] {
        if interfaceMode == .simple {
            return [("日常使用", [.home, .lines, .subscriptions, .settings])]
        }
        return [
            ("核心控制", [.overview, .nodes, .groups]),
            ("规则与配置", [.subscriptions, .rules, .profiles]),
            ("监控与工具", [.connections, .explanation, .diagnostics, .logs]),
            ("系统偏好", [.settings])
        ]
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if let appIcon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1.5)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(
                                    colors: [Theme.accentBlue, Theme.purpleAccent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 38, height: 38)
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("轻舟代理")
                            .font(.headline.weight(.bold))
                        Text("Qingzhou Proxy · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider().opacity(0.6)

                ScrollView(showsIndicators: false) {
                    LiquidGlassGroup(spacing: 6) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(navSections, id: \.title) { section in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(section.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 4)
                                    ForEach(section.items) { item in
                                        let isSelected = page == item
                                        let badgeText: String? = {
                                            if (item == .nodes || item == .lines) {
                                                return "\(model.state.nodes.count)"
                                            } else if item == .connections && !model.connections.isEmpty {
                                                return "\(model.connections.count)"
                                            }
                                            return nil
                                        }()
                                        let badgeColor: Color? = (item == .connections) ? Theme.connectedGreen : nil

                                        SidebarNavItemRow(
                                            name: item.title,
                                            icon: item.icon,
                                            isSelected: isSelected,
                                            badgeText: badgeText,
                                            badgeColor: badgeColor,
                                            selectionNamespace: navigationGlass
                                        ) {
                                            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) { page = item }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                    }
                }

                Divider().opacity(0.6)

                if interfaceMode == .professional {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(model.connection == .connected ? Theme.connectedGreen : Theme.disconnectedGray)
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.recovering ? "正在恢复网络":model.stopRequested ? "等待安全断开":model.networkReconnecting ? "网络恢复中 · 自动重连":model.networkRechecking ? "网络变化 · 检查中":model.connection.rawValue)
                                    .font(.system(size: 11, weight: .bold))
                                    .lineLimit(1)
                                Text(model.connection == .connected ? model.actualName : "尚未连接")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(model.actualName)
                            }

                            Spacer()

                            Button {
                                Task {
                                    if model.connection == .connected { await model.disconnect() }
                                    else { await model.connect() }
                                }
                            } label: {
                                if model.busy && model.connection != .connected {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(model.connection == .connected ? "断开" : "开启")
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(model.connection == .connected ? Theme.dangerRed.opacity(0.15) : Theme.connectedGreen.opacity(0.18))
                                        .foregroundStyle(model.connection == .connected ? Theme.dangerRed : Theme.connectedGreen)
                                        .clipShape(Capsule())
                                        .contentShape(Capsule())
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Capsule())
                            .disabled(model.stopDisabled || (model.state.activePolicy == nil && model.state.mode != .direct && model.connection != .connected) || (model.recoveryPending && model.connection != .connected))
                        }

                        HStack(spacing: 4) {
                            ForEach(ProxyMode.allCases, id: \.self) { mode in
                                let isCurrent = model.state.mode == mode
                                Button {
                                    Task { await model.setMode(mode) }
                                } label: {
                                    Text(mode.label)
                                        .font(.system(size: 11, weight: isCurrent ? .bold : .regular))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(isCurrent ? Theme.accentBlue.opacity(0.2) : Color.secondary.opacity(0.08))
                                        .foregroundStyle(isCurrent ? Theme.accentBlue : Color.secondary)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .contentShape(RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                                .contentShape(RoundedRectangle(cornerRadius: 5))
                                .disabled(model.locked)
                            }
                        }

                        // 接管方式与速率分行，窄侧栏优先保留可操作的连接状态。
                        HStack {
                            Text(model.state.captureMode.label).font(.system(size:10)).fixedSize()
                            Spacer(minLength:4)
                            if model.healthChecking {Text("检测中").font(.system(size:10)).foregroundStyle(.secondary)}
                        }
                        if model.connection == .connected {
                            Text("↑ \(model.uploadRateText)  ↓ \(model.downloadRateText)")
                                .font(.system(size:9,design:.monospaced)).monospacedDigit()
                                .frame(maxWidth:.infinity,alignment:.leading).lineLimit(1).minimumScaleFactor(0.8)
                        }

                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 126, maxHeight: 126)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(model.connection == .connected ? Theme.connectedGreen.opacity(0.3) : Theme.subtleBorder, lineWidth: 1)
                    )
                    .padding(10)
                }
                LiquidModePicker(selection: $interfaceMode)
                    .padding(12)
                AppearanceMenu()
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 250)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if model.loadingFailed {
                    ContentUnavailableView(
                        "配置加载失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text("原配置未被覆盖，请检查错误提示并重启应用。")
                    )
                    .padding(24)
                } else {
                    content
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { LiquidCanvas() }
        }
        .preferredColorScheme(appearance.colorScheme)
        .onAppear {
            page = interfaceMode == .simple ? .home : .overview
        }
        .onChange(of: interfaceMode) { _, mode in
            page = mode == .simple ? .home : .overview
        }
        .sheet(item: $utility) { destination in
            VStack(spacing: 0) {
                HStack {
                    Text(destination.title).font(.headline)
                    Spacer()
                    Button("完成") { utility = nil }.keyboardShortcut(.cancelAction)
                }.padding(20)
                Divider()
                if destination == .settings { SettingsView(model: model) }
                else { DiagnosticsView(model: model).padding(24) }
            }
            .frame(minWidth: 1000, minHeight: 680)
        }
        .confirmationDialog("应用运行模式并重新连接一次？",isPresented:Binding(get:{model.pendingMode != nil},set:{if !$0 {model.pendingMode=nil}})) {
            if let mode=model.pendingMode {
                Button("应用："+mode.label) {model.pendingMode=nil;Task{await model.setMode(mode,confirmed:true)}}
            }
            Button("取消",role:.cancel) {model.pendingMode=nil}
        } message: {Text("企业网络与本机保护保持优先。规则模式按国内外分流；全局代理会让普通国内公网流量也经过代理。")}
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    Task { @MainActor in await model.importFile(url) }
                }
            }
            return true
        }
        .sheet(isPresented: $importing) { ImportSheet(model: model) }
        .sheet(item: $editing) { request in NodeEditor(model: model, node: request.node) }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.cancelPreview() } })) {
            PreviewSheet(model: model)
        }
        .alert("操作提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .home:
            SimpleConnectionView(model: model, onImport: { importing = true }, onLines: { page = .lines }, onSubscriptions: { page = .subscriptions }, onDiagnose: { utility = .diagnostics })
        case .lines:
            SimpleLinesView(model: model, onImport: { importing = true }, onEdit: { editing = EditorRequest(node: $0) }, onProfessional: { interfaceMode = .professional })
        case .overview: OverviewView(model: model)
        case .profiles: ProfilesView(model: model)
        case .explanation: RuleExplanationView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        case .nodes: NodesView(model: model, onEdit: { editing = EditorRequest(node: $0) }, onAdd: { editing = EditorRequest(node: nil) }, onImport: { importing = true })
        case .groups: GroupsView(model: model)
        case .subscriptions:
            if interfaceMode == .simple {
                SimpleSubscriptionsView(model: model, onImport: { importing = true })
            } else { SubscriptionsView(model: model) }
        case .rules: RuleView(model: model)
        case .connections: ConnectionsView(model: model)
        case .logs: RuntimeLogView(buffer: model.logBuffer)
        case .settings:
            if interfaceMode == .simple {
                SimpleSettingsView(model: model, onAdvanced: { utility = .settings }, onDiagnose: { utility = .diagnostics })
            } else { SettingsView(model: model) }
        }
    }
}

// MARK: - Modern Overview View (With Hero Banner)
struct OverviewView: View {
    @ObservedObject var model: AppModel
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Section 1: Top Hero Connection Control Banner
                connectionHeroCard
                
                // Section 2: 4 Modern Stat Cards
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ModernStatCard(
                        title: "实时下载速率",
                        value: model.downloadRateText,
                        icon: "arrow.down.circle.fill",
                        iconColor: Theme.accentBlue
                    )
                    ModernStatCard(
                        title: "实时上传速率",
                        value: model.uploadRateText,
                        icon: "arrow.up.circle.fill",
                        iconColor: Theme.connectedGreen
                    )
                    ModernStatCard(
                        title: "本次会话流量",
                        value: bytes(model.downloadTotal + model.uploadTotal),
                        icon: "chart.pie.fill",
                        iconColor: Theme.purpleAccent,
                        subtitle: "↑ \(bytes(model.uploadTotal))  ↓ \(bytes(model.downloadTotal))"
                    )
                    ModernStatCard(
                        title: "活动连接数",
                        value: String(model.connections.count),
                        icon: "network",
                        iconColor: Theme.amberAccent,
                        subtitle: model.monitorStatus
                    )
                }
                
                // Section 3: Traffic Curve Chart
                RateChart(samples: model.rateHistory)
                
                // Section 4: Quick Action Bar
                VStack(alignment: .leading, spacing: 12) {
                    Text("快捷操作")
                        .font(.headline)
                    
                    HStack(spacing: 12) {
                        Button {
                            Task { await model.selectPolicy(.automatic) }
                        } label: {
                            Label("自动选择最低延迟", systemImage: "bolt.badge.automatic")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.state.nodes.isEmpty || model.locked)
                        
                        Button {
                            model.measure()
                        } label: {
                            Label("检测全部节点延迟", systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.locked || model.state.nodes.isEmpty)
                        
                        Button {
                            Task { await model.refreshAll() }
                        } label: {
                            Label("一键更新订阅与规则", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.locked)
                        
                        Button {
                            model.copyTerminalProxy()
                        } label: {
                            Label("复制终端代理命令", systemImage: "terminal")
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if model.measuring {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.measurementProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("取消测速") { model.cancelMeasurement() }
                                .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .stroke(Theme.subtleBorder, lineWidth: 1)
                )
                
                // Section 5: Traffic Rankings by Node & Destination
                HStack(alignment: .top, spacing: 14) {
                    trafficRankingCard(
                        title: "按节点观测流量 (Top 5)",
                        icon: "server.rack",
                        items: model.trafficByNode.sorted { $0.value > $1.value }.prefix(5).map { (model.label($0.key), $0.value) }
                    )
                    
                    trafficRankingCard(
                        title: "按目标观测流量 (Top 5)",
                        icon: "globe",
                        items: model.trafficByTarget.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
                    )
                }
                
                if model.state.subscriptions.contains(where: { $0.pendingReview }) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .foregroundStyle(Theme.amberAccent)
                        Text("部分订阅更新涉及敏感差异需要人工确认，请前往订阅页进行预览。")
                            .font(.caption)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amberAccent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
    
    // MARK: - Hero Connection Control Banner (Inside Overview)
    private var connectionHeroCard: some View {
        HStack(spacing: 16) {
            // Left Status Glow Ring & Icon
            ZStack {
                Circle()
                    .fill(statusGlowColor.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: statusSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(statusGlowColor)
            }
            
            // Connection Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.connection.rawValue)
                        .font(.title3.bold())
                        .lineLimit(1)
                        .frame(width: 88, alignment: .leading)
                    
                    // Takeover Mode Tag
                    Text(model.state.captureMode.label)
                        .font(.caption2.bold())
                        .foregroundStyle(Theme.accentBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accentBlue.opacity(0.12))
                        .clipShape(Capsule())
                }
                
                HStack(spacing: 8) {
                    Text(model.selectedName)
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(width: 64, alignment: .leading)
                        .help(model.selectedName)
                    if model.connection == .connected {
                        let allPassed = model.connectivityHealth == .healthy
                        let anyFailed = model.connectivityResults.contains { $0.status == .failed }
                        let tipText = model.connectivityResults.map(\.summary).joined(separator: "\n")
                        
                        HStack(spacing: 4) {
                            Circle()
                                .fill(allPassed ? Theme.connectedGreen : (anyFailed ? Theme.amberAccent : Color.secondary))
                                .frame(width: 6, height: 6)
                            Text(model.connectivityHealth == .healthy ? "链路正常" : model.connectivityHealth == .unhealthy ? "链路异常" : model.connectivityHealth == .checking ? "检测中" : "无法确定")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(allPassed ? Theme.connectedGreen : (anyFailed ? Theme.amberAccent : Color.secondary))
                                .lineLimit(1)
                                .frame(width: 48, alignment: .leading)
                            
                            HelpTip(text: tipText)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background((allPassed ? Theme.connectedGreen : (anyFailed ? Theme.amberAccent : Color.secondary)).opacity(0.1))
                        .clipShape(Capsule())
                        .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
            .frame(width: 184, alignment: .leading)
            
            Spacer(minLength: 0)
            
            // Proxy Mode Segmented Picker
            Picker("", selection: Binding(get: { model.state.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                ForEach(ProxyMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(model.locked)
            
            // Recovery Button
            if model.recoveryPending && model.connection != .connected {
                Button("恢复网络") { Task { await model.recover() } }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(model.loadingFailed || model.recovering)
            }
            
            // Big Hero Action Button
            Button {
                Task {
                    if model.connection == .connected { await model.disconnect() }
                    else { await model.connect() }
                }
            } label: {
                HStack(spacing: 6) {
                    if model.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.connection == .connected ? "stop.fill" : "play.fill")
                    }
                    Text(model.connection == .connected ? "断开" : "连接")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(minWidth: 70)
            }
            .liquidAction(prominent: true, tint: model.connection == .connected ? Theme.dangerRed : Theme.accentBlue)
            .controlSize(.large)
            .disabled(model.stopDisabled || (model.state.activePolicy == nil && model.state.mode != .direct && model.connection != .connected) || (model.recoveryPending && model.connection != .connected))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .leading)
        .liquidContentSurface(cornerRadius: Theme.cardCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(model.connection == .connected ? Theme.connectedGreen.opacity(0.3) : Theme.subtleBorder, lineWidth: 1)
        )
    }
    
    private var statusGlowColor: Color {
        switch model.connection {
        case .connected: return Theme.connectedGreen
        case .connecting, .disconnecting: return Theme.connectingYellow
        case .error: return Theme.dangerRed
        case .disconnected: return Theme.disconnectedGray
        }
    }
    
    private var statusSymbol: String {
        switch model.connection {
        case .connected: return "checkmark.shield.fill"
        case .connecting, .disconnecting: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .disconnected: return "power.circle.fill"
        }
    }
    
    private func trafficRankingCard(title: String, icon: String, items: [(String, Int64)]) -> some View {
        let maxVal = items.map(\.1).max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            
            if items.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无流量数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(index + 1). " + item.0)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(bytes(item.1))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.1))
                                        .frame(height: 5)
                                    Capsule()
                                        .fill(Theme.accentBlue)
                                        .frame(width: max(5, geo.size.width * CGFloat(Double(item.1) / Double(max(1, maxVal)))), height: 5)
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Theme.subtleBorder, lineWidth: 1)
        )
    }
}

// MARK: - Modern Nodes View (Spacious Layout)
struct NodesView: View {
    @ObservedObject var model: AppModel
    var onEdit: (Node) -> Void
    var onAdd: () -> Void
    var onImport: () -> Void
    
    @State private var query = ""
    @State private var sort = "HTTPS 延迟"
    @State private var selectedKind: ProxyKind? = nil
    @State private var favoriteOnly = false
    @State private var selection = Set<UUID>()
    @State private var noteNode: Node?
    @State private var note = ""
    @State private var sharing: ShareRequest?
    @State private var deleting = false
    
    private var filteredNodes: [Node] {
        model.state.nodes.filter { node in
            (!favoriteOnly || model.state.favorites.contains(node.id)) &&
            (selectedKind == nil || node.kind == selectedKind) &&
            (query.isEmpty || [node.name, node.server, node.kind.rawValue, model.state.notes[node.id.uuidString] ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }
        .sorted { a, b in
            let fa = model.state.favorites.contains(a.id), fb = model.state.favorites.contains(b.id)
            if fa != fb { return fa }
            if sort == "HTTPS 延迟" {
                let av = LatencyPresentation.sortValue(model.state.latency[a.id.uuidString],invalidatedAt:model.latencyInvalidatedAt,now:model.latencyClock)
                let bv = LatencyPresentation.sortValue(model.state.latency[b.id.uuidString],invalidatedAt:model.latencyInvalidatedAt,now:model.latencyClock)
                if av != bv { return av < bv }
            }
            if sort == "最近使用" {
                let av = model.state.recentUse[a.id.uuidString] ?? .distantPast
                let bv = model.state.recentUse[b.id.uuidString] ?? .distantPast
                if av != bv { return av > bv }
            }
            if sort == "协议", a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Row 1: Header Title & Main Action Buttons
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("代理节点")
                        .font(.title2.bold())
                    Text("\(model.state.nodes.count) 个")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accentBlue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Theme.accentBlue.opacity(0.12))
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                HStack(spacing: 10) {
                    // Ping All Button
                    Button {
                        if model.measuring { model.cancelMeasurement() }
                        else { model.measure() }
                    } label: {
                        Label(model.measuring ? "取消测速" : "一键测速", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.busy || model.state.nodes.isEmpty)
                    
                    // Add & Import Menu
                    Menu {
                        Button { onAdd() } label: {
                            Label("手动添加节点", systemImage: "plus")
                        }
                        Button { chooseFile() } label: {
                            Label("从本地文件导入", systemImage: "doc")
                        }
                        Button { onImport() } label: {
                            Label("从链接 / 订阅导入", systemImage: "link")
                        }
                    } label: {
                        Label("添加节点", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    
                    // Sort Dropdown
                    Picker("排序", selection: $sort) {
                        ForEach(["HTTPS 延迟", "节点名称", "协议", "最近使用"], id: \.self) { Text($0) }
                    }
                    .frame(width: 140)
                    
                    // 保留用户视图偏好，同时明确按钮的当前状态与操作结果。
                    Toggle(isOn: Binding(get: { model.state.compactNodes }, set: { model.setCompact($0) })) {
                        Label(model.state.compactNodes ? "列表" : "卡片",systemImage:model.state.compactNodes ? "list.bullet" : "square.grid.2x2")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel("节点视图")
                    .accessibilityValue(model.state.compactNodes ? "紧凑列表":"卡片")
                    .help(model.state.compactNodes ? "切换到卡片视图":"切换到紧凑列表")
                    .controlSize(.regular)
                }
            }
            
            // Row 2: Search Input & Filter Tags Bar (Spacious & Clean)
            HStack(spacing: 14) {
                // Search Input Field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索节点名称、服务器或备注...", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(width: 260)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // Protocol Filter Chips with guaranteed single-line display
                HStack(spacing: 8) {
                    filterChip("全部", active: selectedKind == nil && !favoriteOnly) {
                        selectedKind = nil; favoriteOnly = false
                    }
                    filterChip("★ 收藏", active: favoriteOnly) {
                        favoriteOnly.toggle()
                    }
                    filterChip("HY2", active: selectedKind == .hysteria2) {
                        toggleKind(.hysteria2)
                    }
                    filterChip("VLESS", active: selectedKind == .vless) {
                        toggleKind(.vless)
                    }
                    filterChip("SS", active: selectedKind == .shadowsocks) {
                        toggleKind(.shadowsocks)
                    }
                    filterChip("Trojan", active: selectedKind == .trojan) {
                        toggleKind(.trojan)
                    }
                }
                
                Spacer()
            }
            
            // Batch Action Toolbar (if items selected)
            if !selection.isEmpty {
                HStack(spacing: 12) {
                    Text("已选择 \(selection.count) 个节点")
                        .font(.caption.bold())
                    Button("设为收藏") { model.batchFavorite(selection, value: true) }
                    Button("取消收藏") { model.batchFavorite(selection, value: false) }
                    Button("批量测速") { model.measure(Array(selection)) }
                    Button("删除所选", role: .destructive) { deleting = true }
                    Spacer()
                    Button("取消多选") { selection.removeAll() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.accentBlue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(model.locked)
            }
            
            if model.measuring {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.measurementProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Nodes Content Grid / List
            if filteredNodes.isEmpty {
                ContentUnavailableView(
                    model.state.nodes.isEmpty ? "还没有任何节点" : "没有找到符合条件的节点",
                    systemImage: "network.slash",
                    description: Text("点击右上角「添加节点」导入节点链接或订阅配置。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.state.compactNodes {
                // Card Grid View (Spacious and breathable)
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 16)], spacing: 16) {
                        ForEach(filteredNodes) { node in
                            nodeCard(node)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                // Compact List View
                List(filteredNodes, selection: $selection) { node in
                    nodeRow(node)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            }
        }
        .sheet(item: $sharing) { request in ShareView(model: model, node: request.node) }
        .sheet(item: $noteNode) { node in
            VStack(spacing: 18) {
                Text("个人备注").font(.headline)
                TextEditor(text: $note).frame(height: 120)
                HStack {
                    Button("取消") { noteNode = nil }
                    Spacer()
                    Button("保存备注") {
                        model.saveNote(node.id, note: note)
                        if model.errorMessage == nil { noteNode = nil }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
        .confirmationDialog("确认删除所选节点？", isPresented: $deleting) {
            Button("确认批量删除", role: .destructive) {
                let ids = selection
                selection = []
                Task { await model.batchDelete(ids) }
            }
        } message: {
            Text("所选节点将从当前配置中彻底移除。")
        }
    }
    
    private func toggleKind(_ kind: ProxyKind) {
        if selectedKind == kind { selectedKind = nil } else { selectedKind = kind }
    }
    
    private func filterChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(active ? Theme.accentBlue.opacity(0.18) : Color.secondary.opacity(0.08))
                .foregroundStyle(active ? Theme.accentBlue : Color.primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(active ? Theme.accentBlue.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }
    
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "选择节点列表或 Clash/Mihomo YAML"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { await model.importFile(url) }
            }
        }
    }
    
    // Modern Node Card
    private func nodeCard(_ node: Node) -> some View {
        let isSelected = model.state.activePolicy == .node(node.id)
        let isFav = model.state.favorites.contains(node.id)
        
        return VStack(alignment: .leading, spacing: 12) {
            // Header: Protocol + Insecure Warning + Star + Checkmark
            HStack(spacing: 8) {
                ProtocolBadge(kind: node.kind)
                
                if node.insecure {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.amberAccent)
                        .help("此节点跳过 TLS 证书验证")
                }
                
                Spacer()
                
                Button {
                    model.toggleFavorite(node.id)
                } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(isFav ? Theme.amberAccent : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.connectedGreen)
                        .font(.system(size: 16))
                }
            }
            
            // Body: Node Name & Server Address
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text("\(node.server):\(node.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let note = model.state.notes[node.id.uuidString], !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.accentBlue)
                        .lineLimit(1)
                }
            }
            
            Divider().opacity(0.5)
            
            // Footer: Latency Pill + Quick Actions
            HStack {
                LatencyBadge(delayText: latency(node, model))
                
                Spacer()
                
                HStack(spacing: 6) {
                    Button {
                        model.measure([node.id])
                    } label: {
                        Image(systemName: "bolt")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Menu {
                        Button("分享节点") { sharing = ShareRequest(node: node) }
                        Button("修改备注") {
                            note = model.state.notes[node.id.uuidString] ?? ""
                            noteNode = node
                        }
                        if node.subscriptionID == nil {
                            Button("编辑节点") { onEdit(node) }
                        }
                        Divider()
                        Button("删除节点", role: .destructive) {
                            Task { await model.deleteNode(node.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .background(isSelected ? Theme.connectedGreen.opacity(0.06) : Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(isSelected ? Theme.connectedGreen.opacity(0.6) : Theme.subtleBorder, lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.select(node.id) }
        }
    }
    
    // List Row
    private func nodeRow(_ node: Node) -> some View {
        let isSelected = model.state.activePolicy == .node(node.id)
        let isFav = model.state.favorites.contains(node.id)
        
        return HStack(spacing: 12) {
            Button {
                Task { await model.select(node.id) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.connectedGreen : .secondary)
            }
            .buttonStyle(.plain)
            
            Button {
                model.toggleFavorite(node.id)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .foregroundStyle(isFav ? Theme.amberAccent : .secondary)
            }
            .buttonStyle(.plain)
            
            ProtocolBadge(kind: node.kind)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).font(.headline)
                Text("\(node.server):\(node.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if node.insecure {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(Theme.amberAccent)
            }
            
            Spacer()
            
            LatencyBadge(delayText: latency(node, model))
            
            Button("测速") { model.measure([node.id]) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            
            Button("分享") { sharing = ShareRequest(node: node) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            
            if node.subscriptionID == nil {
                Button("编辑") { onEdit(node) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            
            Button(role: .destructive) {
                Task { await model.deleteNode(node.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .tag(node.id)
    }
}

// MARK: - Modern Connections View
struct ConnectionsView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var detail: CoreConnection?
    @State private var ruleDraft: RoutingRule?
    @State private var order = "流量"
    @State private var network = "全部"
    
    private var rows: [CoreConnection] {
        model.connections.filter { row in
            (network == "全部" || row.metadata.network?.uppercased() == network) &&
            (query.isEmpty ||
             row.target.localizedCaseInsensitiveContains(query) ||
             (row.metadata.processPath ?? "").localizedCaseInsensitiveContains(query) ||
             row.chains.contains { model.label($0).localizedCaseInsensitiveContains(query) })
        }
        .sorted { a, b in
            if order == "目标" { return a.target.localizedStandardCompare(b.target) == .orderedAscending }
            if order == "持续时间" { return a.start < b.start }
            return a.upload + a.download > b.upload + b.download
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时连接监控")
                        .font(.title2.bold())
                    Text("\(model.monitorPaused ? "刷新已暂停" : model.monitorStatus) · 当前 \(model.connections.count) 条活跃连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(role: .destructive) {
                    Task { await model.closeConnection(nil) }
                } label: {
                    Label("关闭全部连接", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.locked || model.connection != .connected)
            }
            
            // Filters Bar
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索目标、应用路径或出站节点...", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 280)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                Picker("协议", selection: $network) {
                    ForEach(["全部", "TCP", "UDP"], id: \.self) { Text($0) }
                }
                .frame(width: 120)
                
                Picker("排序", selection: $order) {
                    ForEach(["流量", "目标", "持续时间"], id: \.self) { Text($0) }
                }
                .frame(width: 130)
                
                Toggle("暂停刷新", isOn: $model.monitorPaused)
                    .toggleStyle(.checkbox)
                
                Spacer()
            }
            
            if rows.isEmpty {
                ContentUnavailableView(
                    "暂无活动连接",
                    systemImage: "network",
                    description: Text("当代理运行并处理网络请求时，此处将实时展示各连接的流量与路由链路。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(rows.prefix(1000))) { row in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.target)
                                .font(.headline)
                                .lineLimit(1)
                            
                            HStack(spacing: 6) {
                                Text(row.metadata.network?.uppercased() ?? "未知")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                
                                Text(row.chains.map { model.label($0) }.joined(separator: " → "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("↑ \(bytes(row.upload))  ↓ \(bytes(row.download))")
                                .font(.system(size: 11, design: .monospaced))
                            Text(row.duration)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        
                        Button("详情") { detail = row }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        
                        Button("关闭", role: .destructive) {
                            Task { await model.closeConnection(row.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.locked)
                    }
                    .padding(.vertical, 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            }
        }
        .sheet(item: $detail) { row in
            VStack(alignment: .leading, spacing: 14) {
                Text("连接详细信息").font(.title2.bold())
                
                VStack(alignment: .leading, spacing: 8) {
                    detailRow("目标地址", row.target)
                    detailRow("来源进程", row.metadata.processPath?.isEmpty == false ? row.metadata.processPath! : "核心未提供")
                    detailRow("匹配规则", row.rule?.isEmpty == false ? row.rule! : "默认策略")
                    detailRow("出站链路", row.chains.map { model.label($0) }.joined(separator: " → "))
                    detailRow("持续时间", row.duration)
                    detailRow("累计传输", "上传 \(bytes(row.upload)) · 下载 \(bytes(row.download))")
                }
                .padding(14)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                
                HStack {
                    Button("以此目标生成分流规则") {
                        let host = row.metadata.host?.isEmpty == false ? row.metadata.host! : row.metadata.destinationIP ?? ""
                        ruleDraft = RoutingRule(kind: row.metadata.host?.isEmpty == false ? .domain : .cidr, value: host, action: .proxy, target: .selected)
                        detail = nil
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Spacer()
                    Button("关闭") { detail = nil }
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(width: 540)
        }
        .sheet(item: $ruleDraft) { draft in RuleDraftView(model: model, draft: draft) }
    }
    
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Modern Settings View
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var port = "7890"
    @State private var exclusions = ""
    @State private var protectedDomains = ""
    @State private var draftCapture = CaptureMode.systemProxy
    @State private var draftDNS = DNSPreference.httpsProxy
    @State private var draftFamily = AddressFamilyPolicy.ipv4Only
    @State private var draftHTTP = false
    @State private var shortcutKey: UInt32 = 35
    @State private var shortcutModifiers: UInt32 = 2304
    
    private var domainDraft:String {
        model.state.protectedDomains.joined(separator:",")
    }
    private var draftDomainItems:[String] {
        protectedDomains.components(separatedBy:CharacterSet(charactersIn:",\n")).filter{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
    }
    private var missingDraftDomains:[String] {
        (try? ProtectedDomainPolicy.missingTongdunDomains(in:draftDomainItems)) ?? []
    }
    private func completeDomainDraft() {
        do {protectedDomains=try ProtectedDomainPolicy.completingTongdunDomains(draftDomainItems).joined(separator:",")}
        catch {model.errorMessage=error.localizedDescription}
    }
    var body: some View {
        Form {
            Section("界面外观") {
                AppearanceSetting()
                Text("立即生效，并记住你的选择。跟随系统会随 macOS 外观自动切换。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("接管方式", selection: $draftCapture) {
                    Text("系统代理（默认）").tag(CaptureMode.systemProxy)
                    Text("TUN 虚拟网卡（管理员辅助服务）").tag(CaptureMode.tun)
                    Text("完整接管（TUN＋系统代理，需管理员权限）").tag(CaptureMode.compatible)
                }
                .disabled(model.locked)
                
                Picker("目的地址协议",selection:$draftFamily) {
                    ForEach(AddressFamilyPolicy.allCases,id:\.self){policy in Text(policy.label).tag(policy)}
                }.disabled(model.locked)
                if model.state.addressFamilyPolicy == nil {Text("旧配置已使用仅 IPv4，避免节点 IPv6 不可达；可在此调整。").font(.caption).foregroundStyle(.secondary)}
                Toggle("HTTP 兼容模式（User-Agent / URL 重写）",isOn:$draftHTTP).disabled(model.locked || model.state.shadowrocket == nil)
                if model.state.shadowrocket != nil && !model.state.httpCompatibilityEnabled {Text("当前由核心直接代理；User-Agent 和 URL 重写已保留但未启用。兼容模式仅处理明文 HTTP，不能读取 HTTPS/SOCKS 的加密内容。").font(.caption).foregroundStyle(.orange)}
                Text("TUN 与兼容接管仍需独立验收；开启 HTTP 兼容模式后才使用兼容入口。").font(.caption).foregroundStyle(.secondary)
                Picker("DNS 解析策略", selection: $draftDNS) {
                    Text("经代理的 HTTPS DNS").tag(DNSPreference.httpsProxy)
                    Text("原系统原生解析").tag(DNSPreference.system)
                }
                .disabled(model.locked)
                
                TextField("额外直连网段（用逗号分隔）", text: $exclusions)
                Text("排除网段与下方网络设置一起保存并应用。").font(.caption).foregroundStyle(.secondary)
                
                TextField("企业网络保护域名（域名及其子域，用逗号分隔）",text:$protectedDomains)
                Text("已保存的企业保护域名："+(model.state.protectedDomains.isEmpty ? "无":model.state.protectedDomains.joined(separator:"、")))
                    .font(.caption).foregroundStyle(.secondary)
                if protectedDomains != domainDraft {
                    Text("企业保护域名草稿尚未应用，当前连接仍使用原设置。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !missingDraftDomains.isEmpty {
                    Text("同盾企业保护草稿缺少："+missingDraftDomains.joined(separator:"、")+"；登录跳转可能经过这些域名。")
                        .font(.caption).foregroundStyle(.orange)
                    Button("补齐到草稿") {completeDomainDraft()}.disabled(model.locked)
                }
                Text("上述接管、DNS、地址族、HTTP 兼容和企业域名只编辑草稿，点击应用才生效。")
                    .font(.caption).foregroundStyle(.secondary)
                if draftCapture == .compatible {
                    Text("规则模式：本机 → 企业 VPN → 显式规则 → 国内域名/IP 直连 → 未知公网代理。保存时默认未命中策略改为当前代理选择。固定国内规则："+DomesticRouting.version).font(.caption)
                    Text("完整接管尚需管理员恢复和实网验收，不会自动启用。节点、原用户规则顺序不变。")
                        .font(.caption).foregroundStyle(.orange)
                    DisclosureGroup("国内目标被显式规则覆盖（需人工确认）") {
                        ForEach(DomesticRouting.conflictingRules(model.state)) {rule in Text(rule.value+" → "+model.state.label(rule.target ?? .selected)).font(.caption)}
                    }
                }
                Button(model.connection == .connected ? "应用网络设置（重新连接一次）":"保存网络设置") {
                    Task { _ = await model.applyCaptureSettings(mode:draftCapture,dns:draftDNS,family:draftFamily,httpCompatibility:draftHTTP,domains:protectedDomains,exclusions:exclusions) }
                }.disabled(model.locked)
                Text("系统代理模式下，保护域名绕过轻舟，交给系统网络及企业 VPN；所有运行模式均优先保护。核心 DIRECT 仍经过本地核心，与系统代理绕过不同。显式指定 HTTP/SOCKS 代理的命令不一定遵循此清单；TUN 仍使用原有内网保护逻辑。")
                    .font(.caption).foregroundStyle(.secondary)
                if (try? ProtectedDomainPolicy.normalize(draftDomainItems))?.contains(where:{ProtectedDomainPolicy.tongdunDomains.contains($0)}) == false {
                    Button("填入同盾企业域名草稿") {completeDomainDraft()}.disabled(model.locked)
                    Text("建议草稿：tongdun.me、tongdun.cn、tongdun.net；点击保存才会生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.protectionSummary.isEmpty {DisclosureGroup("生效的内网绕过项") {ForEach(model.protectionSummary,id:\.self){Text($0).font(.caption)}}}
                HStack {
                    Text("辅助服务状态：")
                    Text(model.helperStatus)
                        .foregroundStyle(model.helperStatus.contains("通过") ? Theme.connectedGreen : Theme.amberAccent)
                    Spacer()
                    Button("安装 / 更新辅助服务") {Task{await model.installHelper()}}.disabled(model.locked || model.connection == .connected)
                    Button("检查版本") { Task { await model.inspectHelper() } }
                }
                
                HStack(spacing: 8) {
                    Button("复制安装命令") { copyHelperCommand("install-helper.sh") }
                    Button("复制修复命令") { copyHelperCommand("recover-helper.sh") }
                    Button("复制卸载命令") { copyHelperCommand("uninstall-helper.sh") }
                }
            } header: {
                Label("网络接管与管理员辅助服务", systemImage: "shield.lefthalf.filled")
            } footer: {
                Text("TUN 模式需要通过辅助服务获取路由权限。重新构建应用后需要在终端再次批准更新。")
            }
            
            Section {
                TextField("本地回环监听端口", text: $port)
                Button("保存端口") { Task { await model.savePort(Int(port) ?? 0) } }
                    .disabled(model.locked)
                
                Toggle("启动应用后自动连接", isOn: Binding(get: { model.state.autoConnect }, set: { model.setAutoConnect($0) }))
                    .disabled(model.locked)
                Toggle("登录 macOS 时自启动", isOn: Binding(get: { model.state.loginAtStartup }, set: { model.setLoginAtStartup($0) }))
                    .disabled(model.locked)
            } header: {
                Label("通用代理与启动", systemImage: "gearshape")
            }
            
            Section {
                Picker("快捷键主按键", selection: $shortcutKey) {
                    Text("P").tag(UInt32(35))
                    Text("D").tag(UInt32(2))
                    Text("R").tag(UInt32(15))
                }
                Picker("修饰键组合", selection: $shortcutModifiers) {
                    Text("⌘⌥ (Command + Option)").tag(UInt32(2304))
                    Text("⌘⌃ (Command + Control)").tag(UInt32(4352))
                    Text("⌃⌥ (Control + Option)").tag(UInt32(6144))
                    Text("⌘⌃⌥ (Command + Control + Option)").tag(UInt32(6400))
                }
                Toggle("启用全局连接开关快捷键", isOn: Binding(get: { model.state.shortcutEnabled }, set: { model.setShortcut(enabled: $0, key: shortcutKey, modifiers: shortcutModifiers) }))
                    .disabled(model.locked)
                Button("应用快捷键设置") {
                    model.setShortcut(enabled: model.state.shortcutEnabled, key: shortcutKey, modifiers: shortcutModifiers)
                }
                .disabled(model.locked)
            } header: {
                Label("全局快捷键", systemImage: "keyboard")
            }
            
            Section {
                Button("恢复原始系统网络与代理设置") { Task { await model.recover() } }
                    .disabled(model.loadingFailed || model.recovering)
            } header: {
                Label("应急恢复", systemImage: "arrow.counterclockwise")
            } footer: {
                Text("关闭窗口后菜单栏仍常驻运行。正常退出时将自动清理系统代理。")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draftCapture=model.state.captureMode;draftDNS=model.state.dnsPreference;draftFamily=model.state.effectiveAddressFamilyPolicy;draftHTTP=model.state.httpCompatibilityEnabled
            port = String(model.state.listenPort)
            exclusions = model.state.tunExcludedCIDRs.joined(separator: ",")
            protectedDomains = domainDraft
            shortcutKey = model.state.shortcutKey
            shortcutModifiers = model.state.shortcutModifiers
        }
        .onChange(of:model.currentProfileID) {_,_ in
            draftCapture=model.state.captureMode;draftDNS=model.state.dnsPreference;draftFamily=model.state.effectiveAddressFamilyPolicy;draftHTTP=model.state.httpCompatibilityEnabled
            port=String(model.state.listenPort);exclusions=model.state.tunExcludedCIDRs.joined(separator:",")
            protectedDomains=domainDraft;shortcutKey=model.state.shortcutKey;shortcutModifiers=model.state.shortcutModifiers
        }
    }
    
    private func copyHelperCommand(_ script: String) {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let resources = Bundle.main.resourceURL!
        let command = "sudo " + quote(resources.appendingPathComponent(script).path) + (script == "install-helper.sh" ? " " + quote(Bundle.main.bundleURL.path) : "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var node: Node?
}
