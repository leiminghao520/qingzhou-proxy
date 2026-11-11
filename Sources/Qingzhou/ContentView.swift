import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var vpsCenter:VPSCenter
    init(model:AppModel) {
        self.model=model
        _vpsCenter=StateObject(wrappedValue:VPSCenter(directory:model.directory.appendingPathComponent("VPS")))
    }
    @AppStorage("appearancePreference") private var appearance = AppearancePreference.system
    @AppStorage("interfaceMode") private var interfaceMode = InterfaceMode.simple
    @State private var page = AppPage.home
    @State private var utility: UtilityPage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importing = false
    @State private var editing: EditorRequest?

    private func allowClosingSettings()->Bool {
        let draft=model.drafts.settings(profile:model.currentProfileID,state:model.state)
        guard !draft.dirty || model.drafts.confirm("关闭高级设置") else{return false}
        draft.discard();return true
    }

    private var navSections: [(title: String, items: [AppPage])] {
        if interfaceMode == .simple {
            return [("日常使用", [.home, .lines, .subscriptions, .vps, .settings])]
        }
        return [
            ("核心控制", [.overview, .nodes, .groups]),
            ("规则与配置", [.subscriptions, .rules, .profiles]),
            ("监控与工具", [.connections, .explanation, .diagnostics, .vps, .logs]),
            ("系统偏好", [.settings])
        ]
    }

    private var sidebar: some View {
    // 原生侧栏：系统负责选中高亮、键盘导航与深浅色适配。
    List(selection: Binding<AppPage?>(get: { page }, set: { if let value = $0 { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = value } } })) {
        ForEach(navSections, id: \.title) { section in
            Section(section.title) {
                ForEach(section.items) { item in
                    Label(item.title, systemImage: item.icon)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }
        }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .top, spacing: 0) {
        HStack(spacing: 10) {
            XihangMark().frame(width: 20, height: 22).padding(6)
                .background(Color(red: 0.05, green: 0.09, blue: 0.17), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("汐航").font(.headline)
                Text(interfaceMode == .simple ? "简洁模式" : "专业模式").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
        // 侧栏底部只保留一行连接状态，操作统一放在工具栏。
        HStack(spacing: 8) {
            Circle().fill(model.statusTint).frame(width: 7, height: 7)
            Text(model.connectionTitle).font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            if model.connection == .connected {
                Text(model.state.mode.label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
    }

    private func badge(for item: AppPage) -> Int {
        if item == .nodes || item == .lines { return model.state.nodes.count }
        if item == .connections { return model.connections.count }
        return 0
    }

    private var subtitle: String {
        model.connection == .connected && model.state.mode != .direct ? model.connectionTitle + " · " + model.actualName : model.connectionTitle
    }

    // 窗口骨架单独拆出，降低 body 类型推断复杂度。
    private var chrome: some View {
        NavigationSplitView {
            sidebar
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
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
                    if page != .home && page != .overview,model.connection == .connecting,let stage=model.startupStage {
                        ConnectionProgressView(stage:stage,startedAt:model.startupStartedAt)
                            .padding(.horizontal,24).padding(.top,16)
                    }
                    content
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { LiquidCanvas() }
            .overlay(alignment: .bottom) {
                if interfaceMode == .professional, model.visibleSelectionStatus != nil {
                    SelectionFeedbackView(model: model)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(16)
                }
            }
        }
        .navigationTitle(page.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            MainToolbar(model: model, interfaceMode: $interfaceMode, onImport: { importing = true },
                        onDiagnose: { utility = .diagnostics }, onSubscriptions: { page = .subscriptions })
        }
    }

    var body: some View {
        chrome
        .preferredColorScheme(appearance.colorScheme)
        .scrollIndicators(.hidden)
        .onAppear {
            page = interfaceMode == .simple ? .home : .overview
        }
        .onReceive(model.office.$importRequested) {requested in
            if requested {model.office.importRequested=false;importing=true}
        }
        .onReceive(model.office.$diagnosticRequested) {requested in
            if requested {Task {@MainActor in model.office.diagnosticRequested=false;utility = .diagnostics;NSApplication.shared.activate(ignoringOtherApps:true);NSApplication.shared.windows.first{$0.canBecomeMain}?.makeKeyAndOrderFront(nil)}}
        }
        .onReceive(model.office.$linesRequested) {requested in
            if requested {Task {@MainActor in model.office.linesRequested=false;page=interfaceMode == .simple ? .lines:.nodes;NSApplication.shared.activate(ignoringOtherApps:true);NSApplication.shared.windows.first{$0.canBecomeMain}?.makeKeyAndOrderFront(nil)}}
        }
        .onReceive(model.office.$developerRequested) {requested in
            if requested {Task {@MainActor in model.office.developerRequested=false;utility = .developer;NSApplication.shared.activate(ignoringOtherApps:true);NSApplication.shared.windows.first{$0.canBecomeMain}?.makeKeyAndOrderFront(nil)}}
        }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in model.requestOfficeRefresh()}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didResignActiveNotification)) {_ in model.requestOfficeRefresh()}
        .onChange(of: interfaceMode) { _, mode in
            page = mode == .simple ? .home : .overview
        }
        .sheet(item: $utility) { destination in
            VStack(spacing: 0) {
                HStack {
                    Text(destination.title).font(.headline)
                    Spacer()
                    Button("完成") {
                        if destination != .settings || allowClosingSettings() {utility=nil}
                    }.keyboardShortcut(.cancelAction)
                }.padding(20)
                Divider()
                if destination == .settings { SettingsView(model: model) }
                else if destination == .developer {DeveloperProxyAssistantView(port:model.state.listenPort,configuredDomains:model.state.protectedDomains,cidrs:model.state.tunExcludedCIDRs)}
                else { DiagnosticsView(model: model).padding(24) }
            }
            .frame(minWidth: 1000, minHeight: 680)
            .interactiveDismissDisabled(destination == .settings)
            .onExitCommand {if destination != .settings || allowClosingSettings() {utility=nil}}
            .background(EditorCloseGuard {destination != .settings || allowClosingSettings()})
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
        .safeAreaInset(edge:.top,spacing:0) {ConnectionNoticeView(model:model)}

    }

    @ViewBuilder private var content: some View {
        switch page {
        case .home:
            SimpleConnectionView(model: model, onImport: { importing = true }, onLines: { page = .lines }, onSubscriptions: { page = .subscriptions }, onDiagnose: { utility = .diagnostics }, onEdit: { editing = EditorRequest(node: $0) }, onProfessional: { interfaceMode = .professional })
        case .lines:
            SimpleLinesView(model: model, onImport: { importing = true }, onEdit: { editing = EditorRequest(node: $0) }, onProfessional: { interfaceMode = .professional })
        case .overview: OverviewView(model: model, onLines: { page = .nodes }, onSubscriptions: { page = .subscriptions })
        case .profiles: ProfilesView(model: model)
        case .explanation: RuleExplanationView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        case .nodes: NodesView(model: model, onEdit: { editing = EditorRequest(node: $0) }, onAdd: { editing = EditorRequest(node: nil) }, onImport: { importing = true })
        case .groups: GroupsView(model: model)
        case .subscriptions:
            if interfaceMode == .simple {
                SimpleSubscriptionsView(model: model, onImport: { importing = true })
            } else { SubscriptionsView(model: model) }
        case .vps: VPSView(model:model,center:vpsCenter)
        case .rules: RuleView(model: model).id(model.currentProfileID)
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
