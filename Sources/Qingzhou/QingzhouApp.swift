import SwiftUI
import AppKit
import QingzhouKit

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    weak var model:AppModel?
    private var readyToQuit=false
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit{return .terminateNow};guard let model else{return .terminateNow}
        Task{let safe=await model.quit();readyToQuit=safe;sender.reply(toApplicationShouldTerminate:safe)};return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool {false}
}
@main struct QingzhouApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model=AppModel()
    var body:some Scene {
        WindowGroup("轻舟代理") {ContentView(model:model).frame(minWidth:1000,minHeight:680).onAppear{delegate.model=model}.task{await model.startupRecovery()}}.defaultSize(width:1120,height:760)
        MenuBarExtra("轻舟代理",systemImage:model.connection == .connected ? "paperplane.fill" : "paperplane") {
            Text("\(model.connection.rawValue) · \(model.state.mode.label)")
            Text(model.selectedName)
            if model.connection == .connected {Text("↑ \(bytes(model.uploadRate))/s  ↓ \(bytes(model.downloadRate))/s")}
            Button(model.connection == .connected ? "断开" : "连接"){Task{if model.connection == .connected{await model.disconnect()}else{await model.connect()}}}.disabled(model.locked || (model.state.activePolicy==nil && model.state.mode != .direct))
            Menu("代理模式"){ForEach(ProxyMode.allCases,id:\.self){mode in Button((mode==model.state.mode ? "✓ " : "")+mode.label){Task{await model.setMode(mode)}}}}.disabled(model.locked)
            Menu("节点与策略"){
                Button("自动选择"){Task{await model.selectPolicy(.automatic)}}.disabled(model.state.nodes.isEmpty)
                ForEach(model.state.groups){group in Button(group.name){Task{await model.selectPolicy(.group(group.id))}}}
                Divider()
                ForEach(model.state.nodes.prefix(30)){node in Button((model.state.favorites.contains(node.id) ? "★ " : "")+node.name){Task{await model.select(node.id)}}}
            }.disabled(model.locked)
            Button(model.measuring ? "取消测速" : "检测全部节点 HTTPS 延迟"){if model.measuring{model.cancelMeasurement()}else{model.measure()}}.disabled(model.busy || model.state.nodes.isEmpty)
            Button("更新订阅和规则"){Task{await model.refreshAll()}}.disabled(model.locked)
            Button("复制终端代理命令"){model.copyTerminalProxy()}
            Button("恢复原代理"){Task{await model.recover()}}.disabled(model.locked)
            Divider()
            Button("显示主窗口"){NSApplication.shared.activate(ignoringOtherApps:true);NSApplication.shared.windows.first{$0.canBecomeMain}?.makeKeyAndOrderFront(nil)}
            Button("退出轻舟代理"){NSApplication.shared.terminate(nil)}
        }
    }
}
func bytes(_ value:Int64) -> String {ByteCountFormatter.string(fromByteCount:max(0,value),countStyle:.binary)}
@MainActor func latency(_ node:Node,_ model:AppModel) -> String {
    if let result=model.state.latency[node.id.uuidString]{return result.milliseconds.map{"\($0) ms"} ?? "检测失败"}
    if let delay=model.proxyInfo[PolicyReference.node(node.id).tag]?.history?.last?.delay,delay>0{return "\(delay) ms"};return "未检测"
}
struct ContentView:View {
    @ObservedObject var model:AppModel
    @State private var page="概览"
    @State private var importing=false
    @State private var editing:EditorRequest?
    private let pages=["概览","节点","策略组","订阅","分流规则","连接","运行日志","设置"]
    var body:some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:12){
                Label("轻舟代理",systemImage:"paperplane.fill").font(.title2.bold()).padding(.top,18)
                Text("日常使用增强版 · 0.2").font(.caption).foregroundStyle(.secondary).padding(.bottom,14)
                ForEach(pages,id:\.self){value in Button{page=value}label:{Label(value,systemImage:icon(value)).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(page==value ? Color.accentColor.opacity(0.14):Color.clear).clipShape(RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)}
                Spacer()
                Text("系统代理 · sing-box 1.14.3").font(.caption).foregroundStyle(.secondary)
            }.padding(18).navigationSplitViewColumnWidth(210)
        } detail:{
            VStack(alignment:.leading,spacing:18){
                connectionCard
                HStack{Text(page).font(.title2.bold());Spacer();if page=="节点"{Button("手动添加",systemImage:"plus"){editing=EditorRequest(node:nil)};Button("文件导入",systemImage:"doc"){chooseFile()};Button("链接导入",systemImage:"link"){importing=true}.buttonStyle(.borderedProminent)}}
                if model.loadingFailed{ContentUnavailableView("配置加载失败",systemImage:"exclamationmark.triangle",description:Text("原配置未被覆盖，请检查提示"))}else{content}
                Spacer(minLength:0)
            }.padding(24).background(Color(nsColor:.windowBackgroundColor))
        }
        .sheet(isPresented:$importing){ImportSheet(model:model)}
        .sheet(item:$editing){request in NodeEditor(model:model,node:request.node)}
        .sheet(isPresented:Binding(get:{model.preview != nil},set:{if !$0{model.cancelPreview()}})){PreviewSheet(model:model)}
        .alert("操作提示",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0{model.errorMessage=nil}})){Button("知道了"){model.errorMessage=nil}}message:{Text(model.errorMessage ?? "")}
    }
    private func icon(_ value:String) -> String {switch value{case "概览":return "chart.bar";case "节点":return "network";case "策略组":return "square.stack.3d.up";case "订阅":return "arrow.triangle.2.circlepath";case "分流规则":return "arrow.triangle.branch";case "连接":return "point.3.connected.trianglepath.dotted";case "运行日志":return "text.alignleft";default:return "gearshape"}}
    private func chooseFile(){let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.title="选择节点列表或 Clash/Mihomo YAML";panel.begin{response in if response == .OK,let url=panel.url{Task{await model.importFile(url)}}}}
    private var connectionCard:some View {
        HStack(spacing:16){Image(systemName:model.connection == .connected ? "paperplane.circle.fill":"paperplane.circle").font(.system(size:40)).foregroundStyle(model.connection == .connected ? Color.green:Color.secondary)
            VStack(alignment:.leading,spacing:5){Text(model.connection.rawValue).font(.title3.bold());Text(model.selectedName).lineLimit(1);Text(model.reachability).font(.caption).foregroundStyle(.secondary)}
            Spacer()
            Picker("模式",selection:Binding(get:{model.state.mode},set:{mode in Task{await model.setMode(mode)}})){ForEach(ProxyMode.allCases,id:\.self){Text($0.label).tag($0)}}.frame(width:180).disabled(model.locked)
            if model.busy{ProgressView().controlSize(.small)}
            if model.recoveryPending && model.connection != .connected{Button("恢复原代理"){Task{await model.recover()}}.disabled(model.locked)}
            Button(model.connection == .connected ? "断开":"连接"){Task{if model.connection == .connected{await model.disconnect()}else{await model.connect()}}}.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.locked || (model.state.activePolicy==nil && model.state.mode != .direct) || (model.recoveryPending && model.connection != .connected))
        }.padding(18).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:14))
    }
    @ViewBuilder private var content:some View {
        switch page {
        case "概览":OverviewView(model:model)
        case "节点":NodesView(model:model,onEdit:{editing=EditorRequest(node:$0)})
        case "策略组":GroupsView(model:model)
        case "订阅":SubscriptionsView(model:model)
        case "分流规则":RuleView(model:model)
        case "连接":ConnectionsView(model:model)
        case "运行日志":
            HStack{Text("最近 500 行 · 链接、密码及令牌已隐藏").font(.caption).foregroundStyle(.secondary);Spacer();Button("清空"){model.logs=[]}}
            ScrollView{Text(model.logs.joined(separator:"\n")).font(.system(.caption,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled).padding(12)}.background(Color(nsColor:.textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:10))
        default:SettingsView(model:model)
        }
    }
}
struct OverviewView:View {
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            HStack(spacing:12){card("上传速率",bytes(model.uploadRate)+"/s","arrow.up");card("下载速率",bytes(model.downloadRate)+"/s","arrow.down");card("当前连接",String(model.connections.count),"network")}
            HStack(spacing:12){card("本次上传",bytes(model.uploadTotal),"arrow.up.circle");card("本次下载",bytes(model.downloadTotal),"arrow.down.circle");card("默认代理实际选择",model.actualName,"checkmark.circle")}
            VStack(alignment:.leading,spacing:10){Text("快速操作").font(.headline);HStack{Button("自动选择"){Task{await model.selectPolicy(.automatic)}}.disabled(model.state.nodes.isEmpty || model.locked);Button("检测全部节点延迟"){model.measure()}.disabled(model.locked || model.state.nodes.isEmpty);Button("更新订阅和规则"){Task{await model.refreshAll()}}.disabled(model.locked);Button("复制终端代理命令"){model.copyTerminalProxy()}}}.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:12))
            if model.measuring{HStack{ProgressView().controlSize(.small);Text(model.measurementProgress);Button("取消"){model.cancelMeasurement()}}}
            if model.connection == .connected && model.state.activePolicy == .automatic && model.allNodesUnavailable {Label("尚无成功的节点检测结果；不会自动降级直连",systemImage:"exclamationmark.triangle").foregroundStyle(.orange)}
            Text("\(model.monitorStatus) · 统计只覆盖经过核心的流量，核心重启后重新计数。系统代理不会接管全机 UDP/DNS。").font(.caption).foregroundStyle(.secondary)
            if model.state.subscriptions.contains(where:{$0.pendingReview}){Label("部分订阅更新需要人工确认，请到订阅页预览",systemImage:"exclamationmark.bubble").foregroundStyle(.orange)}
        }
    }
    private func card(_ title:String,_ value:String,_ icon:String) -> some View {VStack(alignment:.leading,spacing:10){Label(title,systemImage:icon).font(.caption).foregroundStyle(.secondary);Text(value).font(.title3.bold()).lineLimit(1)}.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:12))}
}
struct NodesView:View {
    @ObservedObject var model:AppModel
    var onEdit:(Node)->Void
    @State private var query=""
    @State private var sort="名称"
    @State private var favoriteOnly=false
    private var nodes:[Node] {model.state.nodes.filter{(!favoriteOnly || model.state.favorites.contains($0.id)) && (query.isEmpty || [$0.name,$0.server,$0.kind.rawValue].contains{$0.localizedCaseInsensitiveContains(query)})}.sorted{a,b in
        let fa=model.state.favorites.contains(a.id),fb=model.state.favorites.contains(b.id);if fa != fb{return fa}
        if sort=="HTTPS 延迟" {let av=model.state.latency[a.id.uuidString]?.milliseconds ?? Int.max,bv=model.state.latency[b.id.uuidString]?.milliseconds ?? Int.max;if av != bv{return av<bv}}
        if sort=="协议",a.kind != b.kind{return a.kind.rawValue<b.kind.rawValue};if a.name != b.name{return a.name.localizedStandardCompare(b.name) == .orderedAscending};return a.id.uuidString<b.id.uuidString
    }}
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{TextField("搜索名称、服务器或协议",text:$query);Toggle("仅收藏",isOn:$favoriteOnly).toggleStyle(.checkbox);Picker("排序",selection:$sort){ForEach(["名称","协议","HTTPS 延迟"],id:\.self){Text($0)}}.frame(width:170);Button(model.measuring ? "取消测速":"检测全部"){if model.measuring{model.cancelMeasurement()}else{model.measure()}}.disabled(model.busy || model.state.nodes.isEmpty)}
            if model.measuring{Text(model.measurementProgress).font(.caption).foregroundStyle(.secondary)}
            if nodes.isEmpty{ContentUnavailableView(model.state.nodes.isEmpty ? "还没有节点":"没有匹配节点",systemImage:"link",description:Text("支持链接、Base64 列表和 Clash/Mihomo YAML"))}
            else{List(nodes){node in HStack(spacing:10){
                Button{Task{await model.select(node.id)}}label:{Image(systemName:model.state.activePolicy == .node(node.id) ? "checkmark.circle.fill":"circle")}.buttonStyle(.plain).accessibilityLabel("选择节点")
                Button{model.toggleFavorite(node.id)}label:{Image(systemName:model.state.favorites.contains(node.id) ? "star.fill":"star").foregroundStyle(model.state.favorites.contains(node.id) ? Color.orange:Color.secondary)}.buttonStyle(.plain).accessibilityLabel(model.state.favorites.contains(node.id) ? "取消收藏" : "收藏节点")
                VStack(alignment:.leading,spacing:5){Text(node.name).font(.headline);Text("\(node.kind.rawValue.uppercased()) · \(node.server):\(node.port)").font(.caption).foregroundStyle(.secondary)}
                if node.insecure{Image(systemName:"exclamationmark.shield").foregroundStyle(.orange).help("此节点跳过证书验证")}
                Spacer();Text(latency(node,model)).font(.system(.caption,design:.monospaced)).frame(width:85)
                Button("测速"){model.measure([node.id])};if node.subscriptionID==nil{Button("编辑"){onEdit(node)}}
                Button(role:.destructive){Task{await model.deleteNode(node.id)}}label:{Image(systemName:"trash")}.accessibilityLabel("删除节点")
            }.accessibilityElement(children:.contain).padding(.vertical,7).disabled(model.locked)}}
        }
    }
}
struct ConnectionsView:View {
    @ObservedObject var model:AppModel
    @State private var query=""
    @State private var detail:CoreConnection?
    private var rows:[CoreConnection]{model.connections.filter{query.isEmpty || $0.target.localizedCaseInsensitiveContains(query) || ($0.metadata.processPath ?? "").localizedCaseInsensitiveContains(query) || $0.chains.contains{model.label($0).localizedCaseInsensitiveContains(query)}}}
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{TextField("搜索目标、应用路径或出站",text:$query);Toggle("暂停刷新",isOn:$model.monitorPaused).toggleStyle(.checkbox);Button("关闭全部连接",role:.destructive){Task{await model.closeConnection(nil)}}.disabled(model.locked || model.connection != .connected)}
            Text("\(model.monitorPaused ? "刷新已暂停" : model.monitorStatus) · 当前 \(model.connections.count) 条连接；界面最多显示 1000 条。应用信息仅在核心提供时显示。").font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty{ContentUnavailableView("暂无连接",systemImage:"network",description:Text("连接代理后，在应用中发起请求"))}
            else{List(Array(rows.prefix(1000))){row in HStack{VStack(alignment:.leading,spacing:5){Text(row.target).font(.headline).lineLimit(1);Text("\(row.metadata.network?.uppercased() ?? "未知") · \(row.chains.map{model.label($0)}.joined(separator:" → "))").font(.caption).foregroundStyle(.secondary)};Spacer();Text("↑ \(bytes(row.upload))  ↓ \(bytes(row.download))").font(.caption);Text(row.duration).font(.caption);Button("详情"){detail=row};Button("关闭",role:.destructive){Task{await model.closeConnection(row.id)}}.disabled(model.locked)}}}
        }.sheet(item:$detail){row in VStack(alignment:.leading,spacing:12){Text("连接详情").font(.title2.bold());Text(row.target).textSelection(.enabled);Text("应用：\(row.metadata.processPath?.isEmpty==false ? row.metadata.processPath! : "未提供")");Text("规则：\(row.rule?.isEmpty==false ? row.rule! : "未提供")");Text("出站链：\(row.chains.map{model.label($0)}.joined(separator:" → "))");Text("持续时间：\(row.duration)");Text("上传 \(bytes(row.upload)) · 下载 \(bytes(row.download))");Button("关闭详情"){detail=nil}}.padding(26).frame(width:560)}
    }
}
struct SettingsView:View {
    @ObservedObject var model:AppModel
    @State private var port="7890"
    var body:some View {
        Form{
            Section("代理与启动"){
                TextField("回环监听端口",text:$port);Button("保存端口"){Task{await model.savePort(Int(port) ?? 0)}}.disabled(model.locked)
                Toggle("启动应用后自动连接",isOn:Binding(get:{model.state.autoConnect},set:{model.setAutoConnect($0)})).disabled(model.locked)
                Toggle("登录 macOS 时启动应用",isOn:Binding(get:{model.state.loginAtStartup},set:{model.setLoginAtStartup($0)})).disabled(model.locked)
                Text("登录启动需要把应用放入 Applications。两个启动选项独立，默认关闭。").font(.caption).foregroundStyle(.secondary)
            }
            Section("更新与测速"){
                Text("订阅和规则源默认每 24 小时更新，应用关闭时不运行；失败最多退避重试 3 次，再等待下一周期。新增跳过证书验证的节点需要人工确认。").font(.caption)
                Text("测速为 HTTPS 延迟，8 秒超时、最多 4 个并发；自动选择每 5 分钟检测，50 ms 容差。并非下载带宽测速。").font(.caption)
            }
            Section("恢复与说明"){
                Button("恢复原代理"){Task{await model.recover()}}.disabled(model.locked)
                Text("关闭窗口后菜单栏仍运行。退出应用会恢复原代理；异常退出后核心监护会停止核心，下次启动恢复残留系统代理。").font(.caption)
                Text("凭据和订阅地址保存在 macOS 钥匙串。元数据、迁移备份与恢复记录位于 Application Support/Qingzhou。").font(.caption)
                Text("程序只处理声明支持的配置，不执行下载的脚本、覆写或外部控制设置。").font(.caption)
            }
        }.formStyle(.grouped).onAppear{port=String(model.state.listenPort)}
    }
}
struct EditorRequest:Identifiable {let id=UUID();var node:Node?}
