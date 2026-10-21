import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

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
        .modifier(ClipboardImportView(model:model))
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

// MARK: - 总览视图
