import SwiftUI
import QingzhouKit

// 主连接操作的展示文案集中在视图层，工具栏与首页状态卡共用，避免两处判断不一致。
extension AppModel {
    var primaryActionTitle: String {
        networkWaiting ? "停止自动重连" : connection == .connected ? "断开连接" : connection == .connecting ? "取消连接" : connection == .disconnecting ? "正在断开" : "连接"
    }
    var primaryActionDisabled: Bool {
        let needsSelection = state.mode != .direct && (state.activePolicy.map { !PolicyValidator.exists($0, in: state) } ?? true)
        return stopDisabled || (!hasConnectionActivity && (needsSelection || recoveryPending))
    }
    var needsFirstImport: Bool { state.nodes.isEmpty && state.mode != .direct }
    var statusTint: Color {
        connectionAvailable ? Theme.connectedGreen : hasConnectionActivity || recoveryPending ? Theme.amberAccent : Color.secondary
    }
    func togglePrimaryConnection() async {
        if hasConnectionActivity { await disconnect() } else { await connect() }
    }
}

// 窗口统一工具栏：连接开关、代理模式、常用工具与界面模式，两种界面共用。
struct MainToolbar: ToolbarContent {
    @ObservedObject var model: AppModel
    @Binding var interfaceMode: InterfaceMode
    var onImport: () -> Void
    var onDiagnose: () -> Void
    var onSubscriptions: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.needsFirstImport && !model.hasConnectionActivity {
                Button(action: onImport) { Label("添加订阅", systemImage: "plus") }
                    .disabled(model.locked)
                    .help("添加订阅或节点")
            } else {
                Button { Task { await model.togglePrimaryConnection() } } label: {
                    Label(model.primaryActionTitle, systemImage: model.hasConnectionActivity ? "stop.circle" : "power")
                        .foregroundStyle(model.connectionAvailable ? Theme.connectedGreen : Color.primary)
                }
                .disabled(model.primaryActionDisabled)
                .help(model.primaryActionTitle)
                .accessibilityIdentifier("toolbarConnectionButton")
            }

            Menu {
                Picker("代理模式", selection: Binding(get: { model.state.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                    ForEach(ProxyMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.inline)
            } label: {
                Label(model.state.mode.label, systemImage: "arrow.triangle.branch")
            }
            .disabled(model.locked)
            .help("代理模式：" + model.state.mode.label)
            .accessibilityLabel("代理模式：" + model.state.mode.label)

            Menu {
                Button("添加订阅或节点…", action: onImport).disabled(model.locked)
                Button("订阅管理", action: onSubscriptions)
                Divider()
                Button("网络诊断…", action: onDiagnose)
                Button("开发工具代理助手…") { model.office.developerRequested = true }
                Divider()
                Button("恢复网络设置") { Task { await model.recover() } }
                    .disabled(model.loadingFailed || model.recovering)
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .help("更多操作")

            Picker("界面模式", selection: $interfaceMode) {
                Text("简洁").tag(InterfaceMode.simple)
                Text("专业").tag(InterfaceMode.professional)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("切换简洁或专业界面，不影响连接")
            .accessibilityIdentifier("interfaceModePicker")
        }
    }
}
