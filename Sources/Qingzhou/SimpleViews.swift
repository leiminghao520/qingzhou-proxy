import SwiftUI
import AppKit
import QingzhouKit

enum InterfaceMode: String {
    case simple, professional
}

enum AppPage: String, Identifiable {
    case home, lines, subscriptions, settings, overview, nodes, groups, rules, profiles
    case connections, explanation, diagnostics, logs
    var id: Self { self }
    var title: String {
        switch self {
        case .home: return "连接"
        case .lines: return "线路"
        case .subscriptions: return "订阅"
        case .settings: return "设置"
        case .overview: return "概览"
        case .nodes: return "节点"
        case .groups: return "策略组"
        case .rules: return "分流规则"
        case .profiles: return "配置"
        case .connections: return "连接"
        case .explanation: return "规则解释"
        case .diagnostics: return "诊断"
        case .logs: return "运行日志"
        }
    }
    var icon: String {
        switch self {
        case .home: return "power"
        case .lines, .nodes: return "network"
        case .subscriptions: return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape"
        case .overview: return "chart.line.uptrend.xyaxis"
        case .groups: return "square.stack.3d.up"
        case .rules: return "arrow.triangle.branch"
        case .profiles: return "slider.horizontal.3"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .explanation: return "magnifyingglass.circle"
        case .diagnostics: return "stethoscope"
        case .logs: return "terminal"
        }
    }
}

enum UtilityPage: String, Identifiable {
    case settings, diagnostics
    var id: Self { self }
    var title: String { self == .settings ? "高级设置" : "网络诊断" }
}

struct SimpleCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidContentSurface()
    }
}

struct SimpleConnectionView: View {
    @ObservedObject var model: AppModel
    var onImport: () -> Void
    var onLines: () -> Void
    var onSubscriptions: () -> Void
    var onDiagnose: () -> Void

    private var status: String {
        if model.recovering { return "正在恢复网络" }
        if model.stopRequested { return "等待安全断开" }
        if model.networkReconnecting { return "网络恢复中，正在自动重连" }
        if model.networkRechecking { return "网络变化，正在重新检查" }
        return model.connection == .connected ? "代理已连接" : model.connection.rawValue
    }
    private var transitioning: Bool {
        model.recovering || model.stopRequested || model.networkRechecking || model.connection == .connecting || model.connection == .disconnecting
    }
    private var needsSelection: Bool {
        guard model.state.mode != .direct else { return false }
        guard let policy = model.state.activePolicy else { return true }
        return !PolicyValidator.exists(policy, in: model.state)
    }
    private var needsImport: Bool { model.state.nodes.isEmpty && model.state.mode != .direct }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("连接").font(.largeTitle.bold())
                if model.recoveryPending {
                    SimpleCard {
                        Label("网络设置尚未恢复", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.amberAccent)
                        Text("请先恢复原网络设置，再开始新的连接。").font(.callout)
                        Button("恢复网络") { Task { await model.recover() } }
                            .disabled(model.loadingFailed || model.recovering)
                    }
                }
                SimpleCard {
                    VStack(spacing: 18) {
                        ZStack {
                            if transitioning { ProgressView().controlSize(.large) }
                            else {
                                Image(systemName: model.connection == .connected ? "paperplane.fill" : "power")
                                    .font(.system(size: 30, weight: .medium))
                                    .foregroundStyle(Theme.accentBlue)
                            }
                        }
                        .frame(width: 80, height: 80)
                        .liquidControl(in: Circle(), tint: Theme.accentBlue.opacity(0.1), interactive: false)
                        .accessibilityHidden(true)
                        Text(status).font(.title2.bold()).multilineTextAlignment(.center)
                        if model.connection == .connecting,let stage=model.startupStage {
                            Text(stage).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("connectionStage")
                        }
                        if needsImport && model.connection != .connected {
                            Text("添加订阅或节点，开始使用轻舟。")
                                .foregroundStyle(.secondary)
                            Button("添加订阅或节点", action: onImport)
                                .liquidAction(prominent: true).controlSize(.large)
                                .disabled(model.locked)
                        } else if needsSelection && model.connection != .connected {
                            Text("选择一条线路后即可连接。").foregroundStyle(.secondary)
                            Button("选择线路", action: onLines).liquidAction(prominent: true).disabled(model.locked)
                        } else {
                            Button {
                                Task {
                                    if model.connection == .connected || model.connection == .connecting { await model.disconnect() }
                                    else { await model.connect() }
                                }
                            } label: {
                                Text(model.connection == .connected ? "断开连接" : model.connection == .connecting ? "取消连接" : "连接")
                                    .fontWeight(.semibold).frame(minWidth: 140)
                            }
                            .liquidAction(prominent: true, tint: model.connection == .connected ? Theme.dangerRed : Theme.accentBlue).controlSize(.large)
                            .disabled(model.stopDisabled || (model.recoveryPending && model.connection != .connected))
                            .accessibilityIdentifier("primaryConnectionButton")
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    Divider()
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("当前线路").font(.caption).foregroundStyle(.secondary)
                            Text(model.state.mode == .direct ? "直连" : model.selectedName)
                                .font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if model.connection == .connected {
                                Text("实际使用：" + model.actualName).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 12)
                        Button("更换", action: onLines).liquidAction().disabled(model.locked)
                    }
                    if model.connection == .connected {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if model.healthChecking { ProgressView().controlSize(.small) }
                                Text(model.healthChecking ? "正在检测网络…" : ConnectivityResult.combinedSummary(model.connectivityResults))
                                    .font(.callout)
                            }
                            ForEach(model.connectivityResults, id: \.title) { result in
                                Label(result.summary, systemImage: result.status == .passed ? "checkmark.circle" : result.status == .failed ? "exclamationmark.circle" : "circle.dotted")
                                    .font(.caption)
                                    .foregroundStyle(result.status == .failed ? Theme.amberAccent : Color.secondary)
                            }
                            Text("↑ \(model.uploadRateText)    ↓ \(model.downloadRateText)")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.state.subscriptions.contains(where: \.pendingReview) {
                    SimpleCard {
                        Label("订阅更新需要确认", systemImage: "exclamationmark.bubble")
                        Text("部分线路或配置有重要变化，请预览后决定是否更新。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("查看订阅", action: onSubscriptions)
                    }
                }
                DisclosureGroup("连接选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("代理运行模式", selection: Binding(get: { model.state.mode }, set: { mode in
                            Task { await model.setMode(mode) }
                        })) {
                            ForEach(ProxyMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                        }.disabled(model.locked)
                        Text("接管方式：" + model.state.captureMode.label).font(.caption).foregroundStyle(.secondary)
                        Text("这里调整实际代理行为；简洁与专业仅切换界面。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                }
                HStack {
                    Button("网络诊断", action: onDiagnose)
                    Spacer()
                    if !model.recoveryPending {
                        Button("恢复网络") { Task { await model.recover() } }
                            .disabled(model.loadingFailed || model.recovering)
                    }
                }.buttonStyle(.borderless)
            }.padding(2)
        }
    }
}

struct SimpleLinesView: View {
    @ObservedObject var model: AppModel
    var onImport: () -> Void
    var onEdit: (Node) -> Void
    var onProfessional: () -> Void
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var detail: Node?
    @State private var pendingEdit: Node?

    private var nodes: [Node] {
        model.state.nodes.filter {
            (!favoritesOnly || model.state.favorites.contains($0.id)) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || (model.state.notes[$0.id.uuidString] ?? "").localizedCaseInsensitiveContains(query))
        }.sorted {
            let a = model.state.favorites.contains($0.id), b = model.state.favorites.contains($1.id)
            return a != b ? a : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("线路").font(.largeTitle.bold())
                Spacer()
                Button("添加", action: onImport).disabled(model.locked)
            }
            if case .group = model.state.activePolicy {
                SimpleCard {
                    Text("当前策略组：" + model.selectedName).font(.headline)
                    Button("在专业模式中管理策略组", action: onProfessional)
                }
            }
            HStack {
                TextField("搜索线路或备注", text: $query).textFieldStyle(.roundedBorder)
                Toggle("收藏", isOn: $favoritesOnly).toggleStyle(.button)
            }
            Button { Task { await model.selectPolicy(.automatic) } } label: {
                HStack {
                    Label("自动选择", systemImage: "bolt.badge.automatic")
                    Spacer()
                    if model.state.activePolicy == .automatic { Image(systemName: "checkmark.circle.fill") }
                }.padding(12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).liquidControl(in: RoundedRectangle(cornerRadius: 14), tint: Theme.accentBlue.opacity(0.08))
            .disabled(model.locked || model.state.nodes.isEmpty)
            .accessibilityLabel("自动选择线路")
            if model.state.nodes.isEmpty {
                ContentUnavailableView {
                    Label("还没有线路", systemImage: "network")
                } description: { Text("添加订阅或节点后，线路会出现在这里。") }
                actions: { Button("添加订阅或节点", action: onImport).disabled(model.locked) }
            } else if nodes.isEmpty {
                ContentUnavailableView("没有匹配的线路", systemImage: "magnifyingglass", description: Text("试试其他关键词，或关闭收藏筛选。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(nodes) { node in line(node) }
                    }
                }
            }
            HStack {
                Text("延迟来自 HTTPS 检测，并非下载速度。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.measuring ? "取消检测" : "检测延迟") {
                    if model.measuring { model.cancelMeasurement() } else { model.measure() }
                }.disabled(model.busy || model.state.nodes.isEmpty)
            }
            if model.measuring { Text(model.measurementProgress).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(item: $detail, onDismiss: {
            if let node = pendingEdit { pendingEdit = nil; onEdit(node) }
        }) { node in
            VStack(alignment: .leading, spacing: 20) {
                Text(node.name).font(.title2.bold()).textSelection(.enabled)
                LabeledContent("协议", value: node.kind.rawValue.uppercased())
                LabeledContent("服务器", value: node.server)
                LabeledContent("端口", value: String(node.port))
                if let note = model.state.notes[node.id.uuidString], !note.isEmpty { Text(note) }
                HStack {
                    Button("编辑线路") { pendingEdit = node; detail = nil }.disabled(model.locked)
                    Spacer()
                    Button("完成") { detail = nil }.keyboardShortcut(.cancelAction)
                }
            }.padding(24).frame(width: 480)
        }
    }
    private func line(_ node: Node) -> some View {
        HStack(spacing: 10) {
            Button { Task { await model.select(node.id) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.state.activePolicy == .node(node.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.state.activePolicy == .node(node.id) ? Theme.accentBlue : Color.secondary)
                    Text(node.name).font(.body.weight(.medium)).lineLimit(2).help(node.name)
                    Spacer(minLength: 8)
                    LatencyBadge(delayText: latency(node, model))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.locked)
                .accessibilityLabel("选择线路：" + node.name)
                .accessibilityValue(model.state.activePolicy == .node(node.id) ? "已选中" : "未选中")
            Button { model.toggleFavorite(node.id) } label: {
                Image(systemName: model.state.favorites.contains(node.id) ? "star.fill" : "star")
                    .foregroundStyle(model.state.favorites.contains(node.id) ? Theme.amberAccent : Color.secondary)
            }.buttonStyle(.borderless).disabled(model.locked)
                .accessibilityLabel((model.state.favorites.contains(node.id) ? "取消收藏：" : "收藏：") + node.name)
            Button { detail = node } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).accessibilityLabel("线路详情：" + node.name)
        }
        .padding(14).liquidContentSurface(cornerRadius: 14)
    }
}

struct SimpleSubscriptionsView: View {
    @ObservedObject var model: AppModel
    var onImport: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("订阅").font(.largeTitle.bold())
                    Spacer()
                    Button("添加订阅", action: onImport).liquidAction(prominent: true).disabled(model.locked)
                }
                Text("粘贴服务商提供的订阅链接，更新后即可选择线路。")
                    .font(.callout).foregroundStyle(.secondary)
                if model.state.subscriptions.isEmpty {
                    ContentUnavailableView("还没有订阅", systemImage: "link", description: Text("点击右上角添加订阅。已有单条节点也可以直接使用。"))
                }
                ForEach(model.state.subscriptions) { sub in
                    SimpleCard {
                        Text(sub.name).font(.headline)
                        Text("\(model.state.nodes.filter { $0.subscriptionID == sub.id }.count) 条线路 · 最近更新：\(sub.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if sub.pendingReview {
                            Label("更新有重要变化，请先预览确认", systemImage: "exclamationmark.bubble")
                                .font(.callout).foregroundStyle(Theme.amberAccent)
                        }
                        if let error = sub.lastError {
                            Text("更新失败：" + error).font(.callout).foregroundStyle(Theme.amberAccent)
                        }
                        HStack {
                            Toggle("自动更新", isOn: Binding(get: { sub.autoUpdate }, set: { model.updateSubscription(sub.id, auto: $0) }))
                                .toggleStyle(.switch).controlSize(.small)
                            Spacer()
                            Button(sub.pendingReview ? "预览更新" : "检查更新") { Task { await model.refresh(sub) } }
                        }.disabled(model.locked)
                    }
                }
            }.padding(2)
        }
    }
}

struct SimpleSettingsView: View {
    @ObservedObject var model: AppModel
    var onAdvanced: () -> Void
    var onDiagnose: () -> Void
    @AppStorage("interfaceMode") private var interfaceMode = InterfaceMode.simple
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.largeTitle.bold())
            Form {
                Section("启动") {
                    Toggle("启动应用后自动连接", isOn: Binding(get: { model.state.autoConnect }, set: { model.setAutoConnect($0) }))
                    Toggle("登录 macOS 时启动", isOn: Binding(get: { model.state.loginAtStartup }, set: { model.setLoginAtStartup($0) }))
                }.disabled(model.locked)
                Section("界面") {
                    AppearanceSetting()
                    Picker("界面模式", selection: $interfaceMode) {
                        Text("简洁").tag(InterfaceMode.simple)
                        Text("专业").tag(InterfaceMode.professional)
                    }
                    Text("两种界面共用配置，切换不会断开连接。").font(.caption).foregroundStyle(.secondary)
                }
                Section("网络与帮助") {
                    LabeledContent("当前接管方式", value: model.state.captureMode.label)
                    Button("高级设置…", action: onAdvanced)
                    Button("网络诊断…", action: onDiagnose)
                    Button("恢复网络设置") { Task { await model.recover() } }
                        .disabled(model.loadingFailed || model.recovering)
                }
                Section("关于轻舟") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
                    Text("关闭窗口后，可在菜单栏继续使用轻舟。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }
}
