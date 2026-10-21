import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body:some View {
        SettingsContent(model:model,revision:SettingsRevision(model:model)).equatable()
    }
}

// 只让设置实际依赖的数据穿过比较边界，速率和连接列表更新不使整个 Form 失效。
private struct SettingsRevision:Equatable {
    let profileID:UUID?
    let locked:Bool
    let connected:Bool
    let loadingFailed:Bool
    let recovering:Bool
    let helperStatus:String
    let protectionSummary:[String]
    let captureMode:CaptureMode
    let dns:DNSPreference
    let family:AddressFamilyPolicy?
    let http:Bool
    let hasCompatibility:Bool
    let port:Int
    let exclusions:[String]
    let protectedDomains:[String]
    let rules:[RoutingRule]
    let nodeLabels:[UUID:String]
    let groupLabels:[UUID:String]
    let autoConnect:Bool
    let loginAtStartup:Bool
    let shortcutEnabled:Bool
    let shortcutKey:UInt32
    let shortcutModifiers:UInt32
    @MainActor init(model:AppModel) {
        let state=model.state
        profileID=model.currentProfileID;locked=model.locked;connected=model.connection == .connected
        loadingFailed=model.loadingFailed;recovering=model.recovering;helperStatus=model.helperStatus
        protectionSummary=model.protectionSummary;captureMode=state.captureMode;dns=state.dnsPreference
        family=state.addressFamilyPolicy;http=state.httpCompatibilityEnabled;hasCompatibility=state.shadowrocket != nil
        port=state.listenPort;exclusions=state.tunExcludedCIDRs;protectedDomains=state.protectedDomains
        rules=state.rules;nodeLabels=Dictionary(state.nodes.map{($0.id,$0.name)},uniquingKeysWith:{$1})
        groupLabels=Dictionary(state.groups.map{($0.id,$0.name)},uniquingKeysWith:{$1})
        autoConnect=state.autoConnect;loginAtStartup=state.loginAtStartup
        shortcutEnabled=state.shortcutEnabled;shortcutKey=state.shortcutKey;shortcutModifiers=state.shortcutModifiers
    }
}

private struct SettingsContent:View,Equatable {
    let model:AppModel
    let revision:SettingsRevision
    static func ==(lhs:Self,rhs:Self)->Bool {lhs.model === rhs.model && lhs.revision==rhs.revision}
    @State private var showingDomesticConflicts=false
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
            OptimizationSettings(model:model)
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
                    DisclosureGroup("国内目标被显式规则覆盖（需人工确认）",isExpanded:$showingDomesticConflicts) {
                        if showingDomesticConflicts {ForEach(DomesticRouting.conflictingRules(model.state)) {rule in Text(rule.value+" → "+model.state.label(rule.target ?? .selected)).font(.caption)}}
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
