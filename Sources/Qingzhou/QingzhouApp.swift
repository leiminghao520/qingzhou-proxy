import SwiftUI
import AppKit
import QingzhouKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var readyToQuit = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit { return .terminateNow }
        guard let model else {return .terminateNow}
        Task { let safe = await model.quit(); readyToQuit = safe; sender.reply(toApplicationShouldTerminate:safe) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct QingzhouApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("轻舟代理") {
            ContentView(model:model)
                .frame(minWidth:900,minHeight:620)
                .onAppear { delegate.model = model }
                .task { await model.startupRecovery() }
        }.defaultSize(width:1020,height:700)
        MenuBarExtra("轻舟代理",systemImage:model.connection == .connected ? "paperplane.fill" : "paperplane") {
            Text(model.connection.rawValue)
            Text(model.selected?.name ?? "未选择节点")
            Button(model.connection == .connected ? "断开连接" : "连接") { Task { if model.connection == .connected { await model.disconnect() } else { await model.connect() } } }.disabled(model.busy || model.selected == nil)
            Button("恢复原代理") {Task {await model.recover()}}.disabled(model.busy)
            Divider()
            Button("显示主窗口") { NSApplication.shared.activate(ignoringOtherApps:true); NSApplication.shared.windows.first(where: {$0.canBecomeMain})?.makeKeyAndOrderFront(nil) }
            Button("退出轻舟代理") {NSApplication.shared.terminate(nil)}
        }
    }
}
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var page = "节点"
    @State private var importing = false
    @State private var editing: EditorRequest?
    @State private var portText = "7890"
    @State private var rulesEnabled = true
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:24) {
                Label("轻舟代理",systemImage:"paperplane.fill").font(.title2.bold()).padding(.top,20)
                Text("让连接更轻盈").font(.caption).foregroundStyle(.secondary)
                ForEach(["节点","订阅","分流规则","运行日志","设置"],id:\.self) { value in
                    Button { page = value } label: {
                        Label(value,systemImage:icon(value)).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(page == value ? Color.accentColor.opacity(0.13) : Color.clear).clipShape(RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("系统代理 · sing-box 1.14.3").font(.caption).foregroundStyle(.secondary)
            }.padding(18).navigationSplitViewColumnWidth(210)
        } detail: {
            VStack(alignment:.leading,spacing:20) {
                connectionCard
                HStack { Text(page).font(.title2.bold()); Spacer(); if page == "节点" {
                    Button("手动添加",systemImage:"plus") {editing = EditorRequest(node:nil)}
                    Button("链接导入",systemImage:"link") {importing = true}.buttonStyle(.borderedProminent)
                }}
                if model.loadingFailed { ContentUnavailableView("配置加载失败",systemImage:"exclamationmark.triangle",description:Text("原配置未被覆盖，请查看错误提示")) }
                else { pageContent }
                Spacer(minLength:0)
            }.padding(28).background(Color(nsColor:.windowBackgroundColor))
        }
        .disabled(model.loadingFailed)
        .sheet(isPresented:$importing) { ImportSheet(model:model) }
        .sheet(item:$editing) { request in NodeEditor(model:model,node:request.node) }
        .sheet(isPresented:Binding(get:{model.preview != nil},set:{if !$0 {model.cancelPreview()}})) { PreviewSheet(model:model) }
        .alert("操作提示",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage = nil}})) { Button("知道了") {model.errorMessage = nil} } message: {Text(model.errorMessage ?? "")}
        .onAppear {portText = String(model.state.listenPort); rulesEnabled = model.state.rulesEnabled}
    }
    private func icon(_ value: String) -> String { switch value {case "节点":return "network";case "订阅":return "arrow.triangle.2.circlepath";case "分流规则":return "arrow.triangle.branch";case "运行日志":return "text.alignleft";default:return "gearshape"} }
    private var connectionCard: some View {
        HStack(spacing:18) {
            Image(systemName:model.connection == .connected ? "paperplane.circle.fill" : "paperplane.circle").font(.system(size:44)).foregroundStyle(model.connection == .connected ? .green : .secondary)
            VStack(alignment:.leading,spacing:5) {
                Text(model.connection.rawValue).font(.title3.bold())
                Text(model.selected?.name ?? "导入节点，开始连接").lineLimit(1)
                Text(model.reachability).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy {ProgressView().controlSize(.small)}
            if model.recoveryPending && model.connection != .connected { Button("恢复原代理") {Task {await model.recover()}}.disabled(model.busy) }
            Button(model.connection == .connected ? "断开" : "连接") {Task {if model.connection == .connected {await model.disconnect()} else {await model.connect()}}}.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.selected == nil || (model.recoveryPending && model.connection != .connected))
        }.padding(20).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:16))
    }
    @ViewBuilder private var pageContent: some View {
        switch page {
        case "节点":
            if model.state.nodes.isEmpty { ContentUnavailableView("还没有节点",systemImage:"link",description:Text("粘贴 Hysteria2 节点或设备专用 HTTPS 订阅链接")) }
            else {
                List(model.state.nodes) { node in
                    HStack(spacing:12) {
                        Button {Task {await model.select(node.id)}} label: {Image(systemName:model.state.selectedID == node.id ? "checkmark.circle.fill" : "circle").foregroundStyle(model.state.selectedID == node.id ? Color.accentColor : .secondary)}.buttonStyle(.plain)
                        VStack(alignment:.leading,spacing:5) {Text(node.name).font(.headline); Text("\(node.kind.rawValue.uppercased()) · \(node.server):\(node.port)").font(.caption).foregroundStyle(.secondary)}
                        if node.insecure {Label("未验证证书",systemImage:"exclamationmark.shield").font(.caption).foregroundStyle(.orange)}
                        Spacer()
                        if node.subscriptionID == nil {Button("编辑") {editing = EditorRequest(node:node)}}
                        Button(role:.destructive) {Task {await model.deleteNode(node.id)}} label: {Image(systemName:"trash")}
                    }.padding(.vertical,8).disabled(model.busy)
                }.listStyle(.inset)
            }
        case "订阅":
            if model.state.subscriptions.isEmpty {ContentUnavailableView("还没有订阅",systemImage:"arrow.triangle.2.circlepath",description:Text("在链接导入中粘贴设备专用 HTTPS 订阅地址"))}
            else {List(model.state.subscriptions) {sub in HStack {VStack(alignment:.leading,spacing:6) {Text(sub.name).font(.headline); Text("\(model.state.nodes.filter {$0.subscriptionID == sub.id}.count) 个节点 · \(sub.updatedAt.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary)}; Spacer(); Button("更新并预览") {Task {await model.refresh(sub)}}; Button("删除",role:.destructive) {Task {await model.deleteSubscription(sub.id)}}}.padding(.vertical,8).disabled(model.busy)}}
        case "分流规则": RuleView(model:model)
        case "运行日志":
            HStack {Text("日志仅保留最近 500 行，凭据已隐藏").font(.caption).foregroundStyle(.secondary);Spacer();Button("清空") {model.logs = []}}
            ScrollView {Text(model.logs.joined(separator:"\n")).font(.system(.caption,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled).padding(12)}.background(Color(nsColor:.textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:10))
        default:
            Form {
                Section("连接设置") {
                    TextField("本地监听端口",text:$portText)
                    Toggle("规则模式（关闭后全部代理）",isOn:$rulesEnabled)
                    Button("保存设置") {Task {await model.saveSettings(port:Int(portText) ?? 0,rulesEnabled:rulesEnabled)}}.disabled(model.busy)
                    Text("保存设置会断开当前连接，重新连接后生效。").font(.caption).foregroundStyle(.secondary)
                }
                Section("恢复与说明") {
                    Button("恢复原代理") {Task {await model.recover()}}.disabled(model.busy)
                    Text("系统代理仅覆盖遵循代理设置的应用，不接管全机 UDP 或 DNS。关闭窗口后菜单栏仍运行；退出应用会恢复原代理。").font(.caption)
                    Text("凭据保存在 macOS 钥匙串；配置和恢复记录位于 Application Support/Qingzhou。").font(.caption)
                }
            }.formStyle(.grouped)
        }
    }
}
struct EditorRequest: Identifiable {let id = UUID(); var node: Node?}
struct ImportSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("导入节点或订阅").font(.title2.bold())
            Text("支持 hy2 / hysteria2 / ss / trojan / vless 链接，以及返回节点列表的 HTTPS 订阅。完整 YAML、JSON 或 Shadowrocket 配置暂不支持。").foregroundStyle(.secondary)
            TextEditor(text:$input).font(.system(.body,design:.monospaced)).frame(height:160).border(Color.secondary.opacity(0.2))
            Text("链接可能包含凭据，仅在本机处理，订阅地址保存到钥匙串。").font(.caption).foregroundStyle(.secondary)
            HStack {Button("取消") {input = "";dismiss()};Spacer();Button("解析并预览") {let value = input; input = ""; dismiss(); Task {await model.importPreview(value)}}.buttonStyle(.borderedProminent).disabled(input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.busy)}
        }.padding(26).frame(width:600)
    }
}
struct PreviewSheet: View {
    @ObservedObject var model: AppModel
    @State private var confirmedInsecure = false
    private var insecure: Bool {model.preview?.candidates.contains {$0.node.insecure} == true}
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("确认导入").font(.title2.bold())
            Text(model.preview?.source != nil ? "订阅下载成功，确认后保存节点。更新订阅会替换其原有节点。" : "节点解析成功，确认后保存到本机。").foregroundStyle(.secondary)
            List(model.preview?.candidates ?? [],id:\.node.id) { c in VStack(alignment:.leading,spacing:5) {Text(c.node.name).font(.headline);Text("\(c.node.kind.rawValue) · \(c.node.server):\(c.node.port)").font(.caption);if c.node.insecure {Text("此节点跳过 TLS 证书验证").font(.caption).foregroundStyle(.orange)}}}.frame(height:220)
            if insecure {Toggle("我确认保留链接中的跳过证书验证设置",isOn:$confirmedInsecure)}
            HStack {Button("取消") {model.cancelPreview()}.disabled(model.busy);Spacer();Button("确认导入") {Task {await model.confirmImport()}}.buttonStyle(.borderedProminent).disabled(model.busy || (insecure && !confirmedInsecure))}
        }.padding(26).frame(width:600)
    }
}
struct NodeEditor: View {
    @ObservedObject var model: AppModel
    let node: Node?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = ProxyKind.hysteria2
    @State private var host = ""
    @State private var port = "443"
    @State private var secret = ""
    @State private var method = "aes-128-gcm"
    @State private var parameters = ""
    @State private var obfsSecret = ""
    @State private var error: String?
    @State private var insecureConfirmed = false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(node == nil ? "手动添加节点" : "编辑节点").font(.title2.bold())
            Form {
                TextField("名称",text:$name)
                Picker("协议",selection:$kind) {ForEach(ProxyKind.allCases,id:\.self) {Text($0.rawValue).tag($0)}}
                TextField("服务器",text:$host)
                TextField("端口",text:$port)
                if kind == .shadowsocks {Picker("加密方法",selection:$method) {ForEach(["aes-128-gcm","aes-256-gcm","chacha20-ietf-poly1305"],id:\.self) {Text($0).tag($0)}}}
                SecureField(kind == .vless ? "UUID" : "认证 / 密码",text:$secret)
                SecureField("混淆密码（仅 Hysteria2）",text:$obfsSecret)
                Text("高级参数，每行 key=value；例如 sni=example.com。密码请填上面的安全输入框。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text:$parameters).font(.system(.caption,design:.monospaced)).frame(height:100)
                Toggle("若配置跳过证书验证，我确认保留该设置",isOn:$insecureConfirmed)
            }
            if let error {Text(error).foregroundStyle(.red).font(.caption)}
            HStack {Button("取消") {dismiss()};Spacer();Button("保存") {save()}.buttonStyle(.borderedProminent).disabled(model.busy)}
        }.padding(26).frame(width:590)
        .onAppear {
            guard let node else {return}
            name = node.name;kind = node.kind;host = node.server;port = String(node.port);method = node.parameters["method"] ?? "aes-128-gcm"
            parameters = node.parameters.filter {$0.key != "method"}.sorted {$0.key < $1.key}.map {"\($0.key)=\($0.value)"}.joined(separator:"\n")
            do {secret = try model.credentials.get(node.credentialRef);obfsSecret = (try? model.credentials.get(node.credentialRef + ".obfs")) ?? ""} catch {self.error = error.localizedDescription}
        }
    }
    private func save() {
        do {
            var c = URLComponents();c.scheme = kind == .shadowsocks ? "ss" : kind.rawValue;c.host = host;c.port = Int(port);c.fragment = name
            if kind == .shadowsocks {c.user = method;c.password = secret} else {c.user = secret}
            var items: [URLQueryItem] = []
            for line in parameters.components(separatedBy:.newlines).filter({!$0.trimmingCharacters(in:.whitespaces).isEmpty}) {guard let i = line.firstIndex(of:"=") else {throw ProxyError("高级参数必须为 key=value")};items.append(URLQueryItem(name:String(line[..<i]).trimmingCharacters(in:.whitespaces),value:String(line[line.index(after:i)...]).trimmingCharacters(in:.whitespaces)))}
            if !obfsSecret.isEmpty {items.append(URLQueryItem(name:"obfs-password",value:obfsSecret))}
            if !items.isEmpty {c.queryItems = items}
            guard let uri = c.string else {throw ProxyError("节点输入无效")}
            let candidate = try NodeParser.parse(uri)
            guard !candidate.node.insecure || insecureConfirmed else {throw ProxyError("请确认跳过证书验证设置")}
            Task {await model.saveManual(candidate,editingID:node?.id); if model.errorMessage == nil {dismiss()}}
        } catch {self.error = error.localizedDescription}
    }
}
struct RuleView: View {
    @ObservedObject var model: AppModel
    @State private var kind = RuleKind.domain
    @State private var value = ""
    @State private var action = RuleAction.direct
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("本机和私网优先直连，其余按下方顺序匹配；未命中时代理。规则修改在下次连接生效。").font(.caption).foregroundStyle(.secondary)
            HStack {Picker("类型",selection:$kind) {Text("域名").tag(RuleKind.domain);Text("域名后缀").tag(RuleKind.suffix);Text("IP/CIDR").tag(RuleKind.cidr)}.frame(width:170);TextField("example.com 或 192.0.2.0/24",text:$value);Picker("动作",selection:$action) {Text("直连").tag(RuleAction.direct);Text("代理").tag(RuleAction.proxy);Text("拒绝").tag(RuleAction.reject)}.frame(width:130);Button("添加") {model.addRule(RoutingRule(kind:kind,value:value,action:action)); if model.errorMessage == nil {value = ""}}.disabled(model.busy)}
            List(model.state.rules) {rule in HStack {Text(rule.kind == .domain ? "域名" : rule.kind == .suffix ? "后缀" : "IP/CIDR").frame(width:70,alignment:.leading);Text(rule.value);Spacer();Text(rule.action == .direct ? "直连" : rule.action == .proxy ? "代理" : "拒绝");Button {model.moveRule(rule.id,by:-1)} label:{Image(systemName:"arrow.up")};Button {model.moveRule(rule.id,by:1)} label:{Image(systemName:"arrow.down")};Button(role:.destructive) {model.removeRule(rule.id)} label:{Image(systemName:"trash")}}.disabled(model.busy)}
        }
    }
}
