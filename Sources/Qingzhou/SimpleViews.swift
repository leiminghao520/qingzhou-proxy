import SwiftUI
import AppKit
import QingzhouKit

enum InterfaceMode: String {
    case simple, professional
}

enum AppPage: String, Identifiable {
    case home, lines, subscriptions, settings, overview, nodes, groups, rules, profiles
    case connections, explanation, diagnostics, logs, vps
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
        case .vps: return "VPS 联动"
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
        case .vps: return "server.rack"
        }
    }
}

enum UtilityPage: String, Identifiable {
    case settings, diagnostics, developer
    var id: Self { self }
    var title: String {switch self {case .settings:return "高级设置";case .diagnostics:return "网络诊断";case .developer:return "开发工具代理助手"}}
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
    var onEdit: (Node) -> Void = { _ in }
    var onProfessional: () -> Void = {}

    var body: some View {
        ScrollView(showsIndicators:false) {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("连接").font(.title2.bold())
                Spacer()
                UsageGuideButton(model:model)
                XihangModeMenu(model:model)
            }
            FirstConnectionGuide(model:model,onImport:onImport)
            XihangConnectionHeader(model:model,onImport:onImport,onLines:onLines)
            XihangTrafficPanel(display:model.trafficDisplay,connected:model.connection == .connected,available:model.monitor.traffic == .available && !model.monitorPaused,total:model.downloadTotal + model.uploadTotal,connections:model.connections.count,expanded:false)
            if model.state.subscriptions.contains(where:\.pendingReview) {
                HStack {
                    Label("订阅更新需要确认",systemImage:"exclamationmark.bubble").font(.caption).foregroundStyle(Theme.amberAccent)
                    Spacer(); Button("查看订阅",action:onSubscriptions)
                }
            }
            DailyLinesView(model:model,onImport:onImport,onEdit:onEdit,onProfessional:onProfessional)
                .frame(height:360)
            HStack {
                Button("网络诊断",action:onDiagnose)
                Spacer()
                Button("订阅 · \(model.state.subscriptions.count)",action:onSubscriptions)
                if !model.recoveryPending { Button("恢复网络") {Task {await model.recover()}}.disabled(model.loadingFailed || model.recovering) }
            }.buttonStyle(.borderless).font(.caption)
        }.padding(2)
        }
    }
}

struct SimpleLinesView: View {
    @ObservedObject var model: AppModel
    var onImport: () -> Void
    var onEdit: (Node) -> Void
    var onProfessional: () -> Void
    var body: some View {
        DailyLinesView(model: model, onImport: onImport, onEdit: onEdit, onProfessional: onProfessional)
    }
}

struct SimpleSubscriptionsView: View {
    @ObservedObject var model: AppModel
    var onImport: () -> Void
    var body: some View {
        ScrollView(showsIndicators:false) {
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
                        HStack {
                            Image(systemName:"square.stack.3d.up.fill").foregroundStyle(Theme.accentBlue).padding(9).background(Theme.accentBlue.opacity(0.1),in:RoundedRectangle(cornerRadius:10))
                            Text(sub.name).font(.headline)
                            Spacer()
                            XihangStatusPill(title:sub.pendingReview ? "待确认" : sub.lastError != nil ? "更新异常" : "已导入",color:sub.pendingReview || sub.lastError != nil ? Theme.amberAccent : Theme.accentBlue)
                        }
                        Text("\(model.state.nodes.filter { $0.subscriptionID == sub.id }.count) 条线路 · 最近更新：\(sub.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        SubscriptionHealthSummary(sub:sub)
                        XihangSubscriptionUsage(usage:sub.usage)
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
                OptimizationSettings(model:model)
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
                    LabeledContent("当前接管方式", value: model.effectiveState.captureMode.label)
                    Button("高级设置…", action: onAdvanced)
                    Button("网络诊断…", action: onDiagnose)
                    Button("开发工具代理助手…") {model.office.developerRequested=true}
                    Button("恢复网络设置") { Task { await model.recover() } }
                        .disabled(model.loadingFailed || model.recovering)
                }
                Section("帮助与使用指南") {
                    UsageGuideButton(model:model,title:"查看使用指南")
                }
                Section("关于汐航") {
                    LabeledContent("名称", value: "汐航 · Xihang")
                    Text("让连接，自然流动").foregroundStyle(Theme.accentBlue)
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
                    Text("关闭窗口后，可在菜单栏继续使用汐航。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }
}
