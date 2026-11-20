import SwiftUI
import QingzhouKit

struct ClaudeSafetyControl: View {
    @ObservedObject var model: AppModel
    @State private var confirmsRelease = false

    var body: some View {
        if model.claudeSafetyRetainsProtection {
            VStack(alignment: .leading, spacing: 6) {
                Label("旧版整机保护仍需处理", systemImage: "lock.shield")
                Text(model.claudeSafetyStatus).font(.caption).foregroundStyle(.secondary)
                if model.claudeSafetyLoadFailed {
                    Text("请在设置的应急恢复中处理恢复记录异常。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("解除旧版整机保护…") { confirmsRelease = true }
                        .disabled(model.claudeSafetyControlDisabled)
                }
            }
            .alert("解除整机保护并恢复直连？", isPresented: $confirmsRelease) {
                Button("取消", role: .cancel) {}
                Button("解除保护", role: .destructive) {
                    Task { await model.setClaudeSafetyEnabled(false, releaseProtection: true) }
                }
            } message: {
                Text("将解除汐航的整机阻断并恢复原网络设置，代理保持停止；LuLu 规则不受影响。")
            }
        }
    }
}

struct ClaudeLegacySafetySettings: View {
    @ObservedObject var model: AppModel

    @State private var confirmsRelease = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.claudeSafetyProxyEnabled }, set: { enabled in
                Task { await model.setClaudeSafetyEnabled(enabled) }
            })) {
                Label("旧版整机保护", systemImage: "lock.shield")
            }
            .toggleStyle(.switch)
            .disabled(model.claudeSafetyControlDisabled || model.claudeApplicationRunning)
            .accessibilityIdentifier("claudeSafetyToggle")
            Toggle("旧版整机保护下允许网络绕过", isOn: Binding(
                get: { model.claudeSafetyPreferences.allowNetworkBypasses == true },
                set: { model.setClaudeBypassesAllowed($0) }
            ))
            .disabled(model.claudeSafetyRetainsProtection || model.claudeSafetyControlDisabled)
            .help("允许全部已启用绕过项沿原出口访问；Claude 也能访问这些目标，共享 IP 上的其他服务也可能被放行。更改前需解除保护。")
            if model.claudeSafetyPreferences.allowNetworkBypasses == true {
                Text("例外对所有程序生效。云枢控制连接会在开启前准备并沿原网络访问；内网业务仍通过云枢。首次开启会中断已有连接，云枢需重新建立连接。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(model.claudeSafetyEnabled || model.claudeSafetyLoadFailed ? model.claudeSafetyStatus : "旧版整机保护未开启；LuLu 规则独立管理。")
                .font(.caption)
                .foregroundStyle(model.claudeSafetyEnabled ? Color.orange : Color.secondary)
                .accessibilityIdentifier("claudeSafetyStatus")
            if model.claudeSafetyEnabled {
                Button("解除保护并恢复直连…") { confirmsRelease = true }
                    .disabled(model.claudeSafetyControlDisabled)
            }
            Text(model.claudeSafetyPreferences.allowNetworkBypasses == true ? "暂停代理保留云枢控制连接与公网阻断；未核验的内网业务例外会撤销。" : "断开、关闭代理或退出汐航后仍保留整机阻断。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .help("开启时中断已有连接并固定 VPS；关闭仅停止代理。恢复普通网络需明确解除保护。")
        .alert("解除整机保护并恢复直连？", isPresented: $confirmsRelease) {
            Button("取消", role: .cancel) {}
            Button("解除保护", role: .destructive) {
                Task { await model.setClaudeSafetyEnabled(false, releaseProtection: true) }
            }
        } message: {
            Text("将解除汐航的整机阻断并恢复原网络设置，代理保持停止，自动连接将关闭；LuLu 规则不受影响。")
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
