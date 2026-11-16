import SwiftUI
import QingzhouKit

struct ClaudeSafetyControl: View {
    @ObservedObject var model: AppModel

    @State private var confirmsRelease = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.claudeSafetyProxyEnabled }, set: { enabled in
                Task { await model.setClaudeSafetyEnabled(enabled) }
            })) {
                Label("Claude 安全模式", systemImage: "lock.shield")
            }
            .toggleStyle(.switch)
            .disabled(model.claudeSafetyControlDisabled)
            .accessibilityIdentifier("claudeSafetyToggle")
            Text(model.claudeSafetyStatus)
                .font(.caption)
                .foregroundStyle(model.claudeSafetyEnabled ? Color.orange : Color.secondary)
                .accessibilityIdentifier("claudeSafetyStatus")
            if model.claudeSafetyEnabled {
                Button("解除保护并恢复直连…") { confirmsRelease = true }
                    .disabled(model.claudeSafetyControlDisabled)
            }
            Text("断开、关闭代理或退出汐航后仍保留整机阻断。云枢暂不保证可用。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .help("开启时中断已有连接并固定 VPS；关闭仅停止代理。恢复普通网络需明确解除保护。")
        .alert("解除整机保护并恢复直连？", isPresented: $confirmsRelease) {
            Button("取消", role: .cancel) {}
            Button("解除保护", role: .destructive) {
                Task { await model.setClaudeSafetyEnabled(false, releaseProtection: true) }
            }
        } message: {
            Text("仍在运行的 Claude 网页、桌面端和 Code 将允许直连。原网络设置及原连接状态将恢复。")
        }
    }
}

struct ClaudeSafetyNodePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择 Claude 安全节点").font(.headline)
            Text("只需选择一次。安全模式将固定此节点，代理异常时阻断公网直连。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.claudeSafetyCandidates) { node in
                        Button {
                            Task { await model.setClaudeSafetyEnabled(true, nodeID: node.id) }
                        } label: {
                            HStack {
                                Label(node.name, systemImage: "server.rack")
                                Spacer()
                                Text(node.kind.rawValue).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity)
                        }.disabled(model.claudeSafetyControlDisabled)
                    }
                }
            }.frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("取消") { model.claudeSafetyChoosingNode = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 430)
    }
}
