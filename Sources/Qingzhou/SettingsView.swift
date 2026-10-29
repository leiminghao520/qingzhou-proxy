import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body:some View {
        SettingsContent(model:model,revision:SettingsRevision(model:model)).equatable().id(model.currentProfileID)
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
    let bypasses:[NetworkBypass]
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
        bypasses=state.effectiveBypasses;rules=state.rules;nodeLabels=Dictionary(state.nodes.map{($0.id,$0.name)},uniquingKeysWith:{$1})
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
    @State private var showingBypasses=false
    @ObservedObject private var draft:SettingsDraft
    init(model:AppModel,revision:SettingsRevision) {
        self.model=model;self.revision=revision
        draft=model.drafts.settings(profile:revision.profileID,state:model.state)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing:16) {
                    XihangMark().frame(width:44,height:48)
                    VStack(alignment:.leading,spacing:4) {
                        Text("汐航 · Xihang").font(.title3.bold())
                        Text("让连接，自然流动").font(.caption).foregroundStyle(Theme.accentBlue)
                    }
                    Spacer()
                    Text("\(BuildVersion.current) (\(BuildVersion.build))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.vertical,8)
            }
            Section("凭据与授权") {
                Text("连接凭据集中保存在系统钥匙串，成功读取后本次运行自动复用。启动、后台更新和自动恢复不弹出凭据密码窗口。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("旧版凭据首次使用时会逐步合并，macOS 仍可能逐项确认。辅助服务安装使用独立的管理员授权；普通连接不重复安装。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("帮助与使用指南") {
                UsageGuideButton(model:model,title:"查看使用指南")
            }

            if draft.dirty {
                Section("未应用的设置草稿") {
                    Text("切换页面会保留草稿；点击各项保存按钮才会生效。")
                    if draft.networkConflict || draft.portConflict || draft.shortcutConflict {Text("配置已在其他位置变化，请撤销冲突草稿后重新编辑。").foregroundStyle(.orange)}
                    Button("撤销设置草稿") {draft.sync(model.state);draft.discard()}.disabled(model.locked)
                }
            }
            OptimizationSettings(model:model)
            Section {
                AppearanceSetting()
            } header: {
                HStack(spacing:4) {Text("界面外观");HelpTip(text:"立即生效，并记住你的选择。跟随系统会随 macOS 外观自动切换。")}
            }

            Section {
                Picker(selection: $draft.network.capture) {
                    Text("系统代理（默认）").tag(CaptureMode.systemProxy)
                    Text("TUN 虚拟网卡（管理员辅助服务）").tag(CaptureMode.tun)
                    Text("完整接管（TUN＋系统代理，需管理员权限）").tag(CaptureMode.compatible)
                } label: {settingLabel("接管方式",help:"系统代理覆盖遵循系统代理设置的应用；各接管方式统一使用辅助服务，首次安装授权后日常连接复用。")}
                .disabled(model.locked)

                Picker(selection:$draft.network.family) {
                    ForEach(AddressFamilyPolicy.allCases,id:\.self){policy in Text(policy.label).tag(policy)}
                } label: {settingLabel("目的地址协议",help:model.state.addressFamilyPolicy == nil ? "旧配置已使用仅 IPv4，避免节点 IPv6 不可达；可在此调整。":"选择核心处理目的地址时使用的 IP 协议。节点 IPv6 不可达时可改为仅 IPv4。")}
                .disabled(model.locked)
                Toggle(isOn:$draft.network.http) {
                    settingLabel("HTTP 兼容模式（User-Agent / URL 重写）",help:(model.state.shadowrocket != nil && !model.state.httpCompatibilityEnabled ? "当前由核心直接代理；User-Agent 和 URL 重写已保留但未启用。":"")+"兼容模式仅处理明文 HTTP，不能读取 HTTPS/SOCKS 的加密内容。开启 HTTP 兼容模式后才使用兼容入口；TUN 与兼容接管仍需独立验收。")
                }.disabled(model.locked || model.state.shadowrocket == nil)
                Picker(selection: $draft.network.dns) {
                    Text("经代理的 HTTPS DNS").tag(DNSPreference.httpsProxy)
                    Text("原系统原生解析").tag(DNSPreference.system)
                } label: {settingLabel("DNS 解析策略",help:"可选择经代理的 HTTPS DNS 或原系统解析；企业域名继续沿用现有网络保护和作用域解析逻辑。")}
                .disabled(model.locked)

                Toggle("严格 DNS（解析失败时不回退系统 DNS）",isOn:$draft.network.strictDNS).disabled(model.locked)

                HStack {
                    settingLabel("网络绕过：已启用 \(model.state.enabledBypasses.count) / \(model.state.effectiveBypasses.count) 项",help:"域名、IP 和网段统一在分流规则页维护，支持批量导入及指定网络出口。系统代理模式下，保护域名绕过汐航，交给系统网络及企业 VPN；所有运行模式均优先保护。核心 DIRECT 仍经过本地核心，与系统代理绕过不同。显式指定 HTTP/SOCKS 代理的命令不一定遵循此清单；TUN 仍使用原有内网保护逻辑。")
                    Spacer()
                    Button("管理网络绕过…") {showingBypasses=true}.disabled(model.locked)
                }
                if draft.network.capture == .compatible {
                    DisclosureGroup("国内目标被显式规则覆盖（需人工确认）",isExpanded:$showingDomesticConflicts) {
                        if showingDomesticConflicts {ForEach(DomesticRouting.conflictingRules(model.state)) {rule in Text(rule.value+" → "+model.state.label(rule.target ?? .selected)).font(.caption)}}
                    }
                }
                Button(model.connection == .connected ? "应用网络设置（重新连接一次）":"保存网络设置") {
                    Task {
                        draft.sync(model.state)
                        guard !draft.networkConflict else {model.errorMessage="网络设置已被其他操作修改，请撤销草稿后重新编辑";return}
                        if await model.applyCaptureSettings(mode:draft.network.capture,dns:draft.network.dns,family:draft.network.family,httpCompatibility:draft.network.http,strictDNS:draft.network.strictDNS) {draft.acceptNetwork(model.state)}
                    }
                }.disabled(model.locked)
                if !model.protectionSummary.isEmpty {DisclosureGroup("生效的内网绕过项") {ForEach(model.protectionSummary,id:\.self){Text($0).font(.caption)}}}
                HStack {
                    settingLabel("辅助服务状态：",help:"系统代理和 TUN 共用辅助服务。首次安装需管理员授权，日常连接、断开复用；更新权限组件或应用签名身份变化时可能需再次批准。")
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
                HStack(spacing:4) {
                    Label("网络接管与管理员辅助服务",systemImage:"shield.lefthalf.filled")
                    HelpTip(text:"接管、DNS、地址族和 HTTP 兼容只编辑草稿，点击应用才生效。"+(draft.network.capture == .compatible ? "规则模式：本机 → 企业 VPN → 显式规则 → 国内域名/IP 直连 → 未知公网代理。保存时默认未命中策略改为当前代理选择。固定国内规则："+DomesticRouting.version+"。完整接管不会自动启用，仍需管理员恢复和实网验收；节点、原用户规则顺序不变。":""))
                }
            }

            Section {
                TextField("本地回环监听端口", text: $draft.port).disabled(model.locked)
                Button("保存端口") { Task {
                    draft.sync(model.state)
                    guard !draft.portConflict else {model.errorMessage="端口已被其他操作修改，请撤销草稿后重新编辑";return}
                    let value=Int(draft.port) ?? 0
                    await model.savePort(value)
                    if model.state.listenPort==value {draft.acceptPort(model.state)}
                } }
                    .disabled(model.locked)

                Toggle("启动应用后自动连接", isOn: Binding(get: { model.state.autoConnect }, set: { model.setAutoConnect($0) }))
                    .disabled(model.locked)
                Toggle("登录 macOS 时自启动", isOn: Binding(get: { model.state.loginAtStartup }, set: { model.setLoginAtStartup($0) }))
                    .disabled(model.locked)
            } header: {
                Label("通用代理与启动", systemImage: "gearshape")
            }

            Section {
                Picker("快捷键主按键", selection: $draft.shortcut.key) {
                    Text("P").tag(UInt32(35))
                    Text("D").tag(UInt32(2))
                    Text("R").tag(UInt32(15))
                }
                Picker("修饰键组合", selection: $draft.shortcut.modifiers) {
                    Text("⌘⌥ (Command + Option)").tag(UInt32(2304))
                    Text("⌘⌃ (Command + Control)").tag(UInt32(4352))
                    Text("⌃⌥ (Control + Option)").tag(UInt32(6144))
                    Text("⌘⌃⌥ (Command + Control + Option)").tag(UInt32(6400))
                }
                Toggle("启用全局连接开关快捷键", isOn: Binding(get: { model.state.shortcutEnabled }, set: { model.setShortcut(enabled: $0, key: model.state.shortcutKey, modifiers: model.state.shortcutModifiers) }))
                    .disabled(model.locked)
                Button("应用快捷键设置") {
                    draft.sync(model.state)
                    guard !draft.shortcutConflict else {model.errorMessage="快捷键已被其他操作修改，请撤销草稿后重新编辑";return}
                    model.setShortcut(enabled: model.state.shortcutEnabled, key: draft.shortcut.key, modifiers: draft.shortcut.modifiers)
                    if model.state.shortcutKey==draft.shortcut.key && model.state.shortcutModifiers==draft.shortcut.modifiers {draft.acceptShortcut(model.state)}
                }
                .disabled(model.locked)
            } header: {
                Label("全局快捷键", systemImage: "keyboard")
            }

            Section {
                Button("恢复原始系统网络与代理设置") { Task { await model.recover() } }
                    .disabled(model.loadingFailed || model.recovering)
            } header: {
                HStack(spacing:4) {Label("应急恢复",systemImage:"arrow.counterclockwise");HelpTip(text:"关闭窗口后菜单栏仍常驻运行。正常退出时将自动清理系统代理。")}
            }
        }
        .sheet(isPresented:$showingBypasses) {
            DraftEditorSheet(draft:model.drafts.bypass(profile:model.currentProfileID,items:model.state.effectiveBypasses,revision:try? model.bypassRevision(),corporateDNS:model.state.trustedCorporateDNS ?? []),store:model.drafts,title:"网络绕过") {
                NetworkBypassView(model:model)
            }.padding(20).frame(minWidth:850,minHeight:650)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {draft.sync(model.state)}
        .onChange(of:revision) {_,_ in draft.sync(model.state)}
    }

    private func settingLabel(_ title:String,help:String) -> some View {
        HStack(spacing:4) {Text(title);HelpTip(text:help)}
    }

    private func copyHelperCommand(_ script: String) {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let resources = Bundle.main.resourceURL!
        let command = "sudo " + quote(resources.appendingPathComponent(script).path) + (script == "install-helper.sh" ? " " + quote(Bundle.main.bundleURL.path) : "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
