import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
            Text(model.actualName+" · "+(model.state.captureMode == .tun ? "TUN":"系统代理"))
            if model.connection == .connected {Text("↑ \(bytes(model.uploadRate))/s  ↓ \(bytes(model.downloadRate))/s")}
            Button(model.connection == .connected ? "断开" : "连接"){Task{if model.connection == .connected{await model.disconnect()}else{await model.connect()}}}.disabled(model.locked || (model.state.activePolicy==nil && model.state.mode != .direct))
            Menu("配置"){ForEach(model.profiles){profile in Button((model.currentProfileID==profile.id ? "✓ ":"")+profile.name){Task{await model.changeProfile(profile.id)}}}}.disabled(model.locked)
            Button("暂停代理"){Task{await model.disconnect()}}.disabled(model.locked || model.connection != .connected)
            Button("一键诊断"){Task{await model.diagnose()}}.disabled(model.locked)
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
    private let pages=["概览","配置","节点","策略组","订阅","分流规则","连接","规则解释","诊断","运行日志","设置"]
    var body:some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:12){
                Label("轻舟代理",systemImage:"paperplane.fill").font(.title2.bold()).padding(.top,18)
                Text("完整日常体验 · 0.3 开发版").font(.caption).foregroundStyle(.secondary).padding(.bottom,14)
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
        .onDrop(of:[UTType.fileURL],isTargeted:nil){providers in guard let provider=providers.first else{return false};provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil){item,_ in if let data=item as? Data,let url=URL(dataRepresentation:data,relativeTo:nil){Task{@MainActor in await model.importFile(url)}}};return true}
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
        case "配置":ProfilesView(model:model)
        case "规则解释":RuleExplanationView(model:model)
        case "诊断":DiagnosticsView(model:model)
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
            RateChart(samples:model.rateHistory)
            HStack(spacing:12){card("上传速率",bytes(model.uploadRate)+"/s","arrow.up");card("下载速率",bytes(model.downloadRate)+"/s","arrow.down");card("当前连接",String(model.connections.count),"network")}
            HStack(spacing:12){card("本次上传",bytes(model.uploadTotal),"arrow.up.circle");card("本次下载",bytes(model.downloadTotal),"arrow.down.circle");card("默认代理实际选择",model.actualName,"checkmark.circle")}
            VStack(alignment:.leading,spacing:10){Text("快速操作").font(.headline);HStack{Button("自动选择"){Task{await model.selectPolicy(.automatic)}}.disabled(model.state.nodes.isEmpty || model.locked);Button("检测全部节点延迟"){model.measure()}.disabled(model.locked || model.state.nodes.isEmpty);Button("更新订阅和规则"){Task{await model.refreshAll()}}.disabled(model.locked);Button("复制终端代理命令"){model.copyTerminalProxy()}}}.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:12))
            if model.measuring{HStack{ProgressView().controlSize(.small);Text(model.measurementProgress);Button("取消"){model.cancelMeasurement()}}}
            if model.connection == .connected && model.state.activePolicy == .automatic && model.allNodesUnavailable {Label("尚无成功的节点检测结果；不会自动降级直连",systemImage:"exclamationmark.triangle").foregroundStyle(.orange)}
            HStack(alignment:.top){VStack(alignment:.leading){Text("按节点观测流量").font(.caption.bold());ForEach(model.trafficByNode.sorted{$0.value>$1.value}.prefix(5),id:\.key){Text(model.label($0.key)+" · "+bytes($0.value)).font(.caption)}};Spacer();VStack(alignment:.leading){Text("按目标观测流量").font(.caption.bold());ForEach(model.trafficByTarget.sorted{$0.value>$1.value}.prefix(5),id:\.key){Text($0.key+" · "+bytes($0.value)).font(.caption).lineLimit(1)}}}
            Text("聚合仅包含轮询时观测到的连接，短连接可能未计入；不写入磁盘。").font(.caption).foregroundStyle(.secondary)
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
    @State private var selection=Set<UUID>()
    @State private var noteNode:Node?
    @State private var note=""
    @State private var sharing:ShareRequest?
    @State private var deleting=false
    private var nodes:[Node] {model.state.nodes.filter{(!favoriteOnly || model.state.favorites.contains($0.id)) && (query.isEmpty || [$0.name,$0.server,$0.kind.rawValue,model.state.notes[$0.id.uuidString] ?? ""].contains{$0.localizedCaseInsensitiveContains(query)})}.sorted{a,b in
        let fa=model.state.favorites.contains(a.id),fb=model.state.favorites.contains(b.id);if fa != fb{return fa}
        if sort=="HTTPS 延迟" {let av=model.state.latency[a.id.uuidString]?.milliseconds ?? Int.max,bv=model.state.latency[b.id.uuidString]?.milliseconds ?? Int.max;if av != bv{return av<bv}}
        if sort=="最近使用"{let av=model.state.recentUse[a.id.uuidString] ?? .distantPast,bv=model.state.recentUse[b.id.uuidString] ?? .distantPast;if av != bv{return av>bv}}
        if sort=="协议",a.kind != b.kind{return a.kind.rawValue<b.kind.rawValue};if a.name != b.name{return a.name.localizedStandardCompare(b.name) == .orderedAscending};return a.id.uuidString<b.id.uuidString
    }}
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{TextField("搜索名称、服务器或协议",text:$query);Toggle("仅收藏",isOn:$favoriteOnly).toggleStyle(.checkbox);Picker("排序",selection:$sort){ForEach(["名称","协议","HTTPS 延迟","最近使用"],id:\.self){Text($0)}}.frame(width:170);Button(model.measuring ? "取消测速":"检测全部"){if model.measuring{model.cancelMeasurement()}else{model.measure()}}.disabled(model.busy || model.state.nodes.isEmpty)}
            HStack{Text("已选 \(selection.count)");Button("收藏"){model.batchFavorite(selection,value:true)};Button("取消收藏"){model.batchFavorite(selection,value:false)};Button("批量测速"){model.measure(Array(selection))};Button("删除所选",role:.destructive){deleting=true};Spacer();Toggle("紧凑视图",isOn:Binding(get:{model.state.compactNodes},set:{model.setCompact($0)})).toggleStyle(.checkbox)}.disabled(model.locked)
            if model.measuring{Text(model.measurementProgress).font(.caption).foregroundStyle(.secondary)}
            if nodes.isEmpty{ContentUnavailableView(model.state.nodes.isEmpty ? "还没有节点":"没有匹配节点",systemImage:"link",description:Text("支持链接、Base64 列表和 Clash/Mihomo YAML"))}
            else if model.state.compactNodes{ScrollView{LazyVGrid(columns:[GridItem(.adaptive(minimum:280),spacing:12)],spacing:12){ForEach(nodes){node in VStack(alignment:.leading,spacing:10){HStack{Toggle("多选",isOn:Binding(get:{selection.contains(node.id)},set:{if $0{selection.insert(node.id)}else{selection.remove(node.id)}})).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("多选节点 \(node.name)");Text(node.name).font(.headline).lineLimit(1);Spacer();Text(latency(node,model)).font(.caption)};Text(node.kind.rawValue.uppercased()+" · "+node.server).font(.caption).lineLimit(1);if let note=model.state.notes[node.id.uuidString]{Text(note).font(.caption).lineLimit(1)};HStack{Button("选择"){Task{await model.select(node.id)}};Button("测速"){model.measure([node.id])};Button("分享"){sharing=ShareRequest(node:node)};Button(model.state.favorites.contains(node.id) ? "★":"☆"){model.toggleFavorite(node.id)}}}.padding(14).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:10)).disabled(model.locked)}}}}
            else{List(nodes,selection:$selection){node in HStack(spacing:10){
                Button{Task{await model.select(node.id)}}label:{Image(systemName:model.state.activePolicy == .node(node.id) ? "checkmark.circle.fill":"circle")}.buttonStyle(.plain).accessibilityLabel("选择节点")
                Button{model.toggleFavorite(node.id)}label:{Image(systemName:model.state.favorites.contains(node.id) ? "star.fill":"star").foregroundStyle(model.state.favorites.contains(node.id) ? Color.orange:Color.secondary)}.buttonStyle(.plain).accessibilityLabel(model.state.favorites.contains(node.id) ? "取消收藏" : "收藏节点")
                VStack(alignment:.leading,spacing:5){Text(node.name).font(.headline);Text("\(node.kind.rawValue.uppercased()) · \(node.server):\(node.port)").font(.caption).foregroundStyle(.secondary);if let note=model.state.notes[node.id.uuidString],!note.isEmpty{Text(note).font(.caption).lineLimit(1)}}
                if node.insecure{Image(systemName:"exclamationmark.shield").foregroundStyle(.orange).help("此节点跳过证书验证")}
                Spacer();Text(latency(node,model)).font(.system(.caption,design:.monospaced)).frame(width:85)
                Button("分享"){sharing=ShareRequest(node:node)};Button("备注"){note=model.state.notes[node.id.uuidString] ?? "";noteNode=node};Button("测速"){model.measure([node.id])};if node.subscriptionID==nil{Button("编辑"){onEdit(node)}}
                Button(role:.destructive){Task{await model.deleteNode(node.id)}}label:{Image(systemName:"trash")}.accessibilityLabel("删除节点")
            }.accessibilityElement(children:.contain).padding(.vertical,model.state.compactNodes ? 1:7).disabled(model.locked).tag(node.id)}}
        }.sheet(item:$sharing){request in ShareView(model:model,node:request.node)}.sheet(item:$noteNode){node in VStack(spacing:18){Text("个人备注").font(.headline);TextEditor(text:$note).frame(height:120);HStack{Button("取消"){noteNode=nil};Button("保存"){model.saveNote(node.id,note:note);if model.errorMessage==nil{noteNode=nil}}}}.padding(26).frame(width:480)}.confirmationDialog("删除所选节点？",isPresented:$deleting){Button("确认删除",role:.destructive){let ids=selection;selection=[];Task{await model.batchDelete(ids)}}}message:{Text("所选节点将从当前配置移除。")}
    }
}
struct ConnectionsView:View {
    @ObservedObject var model:AppModel
    @State private var query=""
    @State private var detail:CoreConnection?
    @State private var ruleDraft:RoutingRule?
    @State private var order="流量"
    @State private var network="全部"
    private var rows:[CoreConnection]{model.connections.filter{row in (network=="全部" || row.metadata.network?.uppercased()==network) && (query.isEmpty || row.target.localizedCaseInsensitiveContains(query) || (row.metadata.processPath ?? "").localizedCaseInsensitiveContains(query) || row.chains.contains{model.label($0).localizedCaseInsensitiveContains(query)})}.sorted{a,b in if order=="目标"{return a.target.localizedStandardCompare(b.target) == .orderedAscending};if order=="持续时间"{return a.start<b.start};return a.upload+a.download>b.upload+b.download}}
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{TextField("搜索目标、应用路径或出站",text:$query);Picker("协议",selection:$network){ForEach(["全部","TCP","UDP"],id:\.self){Text($0)}}.frame(width:120);Picker("排序",selection:$order){ForEach(["流量","目标","持续时间"],id:\.self){Text($0)}}.frame(width:130);Toggle("暂停刷新",isOn:$model.monitorPaused).toggleStyle(.checkbox);Button("关闭全部连接",role:.destructive){Task{await model.closeConnection(nil)}}.disabled(model.locked || model.connection != .connected)}
            Text("\(model.monitorPaused ? "刷新已暂停" : model.monitorStatus) · 当前 \(model.connections.count) 条连接；界面最多显示 1000 条。应用信息仅在核心提供时显示。").font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty{ContentUnavailableView("暂无连接",systemImage:"network",description:Text("连接代理后，在应用中发起请求"))}
            else{List(Array(rows.prefix(1000))){row in HStack{VStack(alignment:.leading,spacing:5){Text(row.target).font(.headline).lineLimit(1);Text("\(row.metadata.network?.uppercased() ?? "未知") · \(row.chains.map{model.label($0)}.joined(separator:" → "))").font(.caption).foregroundStyle(.secondary)};Spacer();Text("↑ \(bytes(row.upload))  ↓ \(bytes(row.download))").font(.caption);Text(row.duration).font(.caption);Button("详情"){detail=row};Button("关闭",role:.destructive){Task{await model.closeConnection(row.id)}}.disabled(model.locked)}}}
        }.sheet(item:$detail){row in VStack(alignment:.leading,spacing:12){Text("连接详情").font(.title2.bold());Text(row.target).textSelection(.enabled);Text("应用：\(row.metadata.processPath?.isEmpty==false ? row.metadata.processPath! : "未提供")");Text("规则：\(row.rule?.isEmpty==false ? row.rule! : "未提供")");Text("出站链：\(row.chains.map{model.label($0)}.joined(separator:" → "))");Text("持续时间：\(row.duration)");Text("上传 \(bytes(row.upload)) · 下载 \(bytes(row.download))");Button("由目标生成待确认规则"){let host=row.metadata.host?.isEmpty==false ? row.metadata.host!:row.metadata.destinationIP ?? "";ruleDraft=RoutingRule(kind:row.metadata.host?.isEmpty==false ? .domain:.cidr,value:host,action:.proxy,target:.selected);detail=nil};Button("关闭详情"){detail=nil}}.padding(26).frame(width:560)}.sheet(item:$ruleDraft){draft in RuleDraftView(model:model,draft:draft)}
    }
}
struct SettingsView:View {
    @ObservedObject var model:AppModel
    @State private var port="7890"
    @State private var exclusions=""
    @State private var shortcutKey:UInt32=35
    @State private var shortcutModifiers:UInt32=2304
    var body:some View {
        Form{
            Section("接管方式与管理员辅助服务"){
                Picker("接管方式",selection:Binding(get:{model.state.captureMode},set:{value in Task{await model.setCaptureMode(value)}})){Text("系统代理（默认）").tag(CaptureMode.systemProxy);Text("TUN（管理员服务）").tag(CaptureMode.tun)}.disabled(model.locked)
                Picker("TUN DNS",selection:Binding(get:{model.state.dnsPreference},set:{value in Task{await model.setDNS(value)}})){Text("经代理的 HTTPS DNS").tag(DNSPreference.httpsProxy);Text("原系统解析").tag(DNSPreference.system)}.disabled(model.locked)
                TextField("额外直连网段，用逗号分隔",text:$exclusions);Button("保存 TUN 排除网段"){Task{await model.saveTunExclusions(exclusions)}}.disabled(model.locked)
                Text(model.helperStatus).font(.caption)
                HStack{Button("检查版本"){Task{await model.inspectHelper()}};Button("复制安装 / 修复命令"){copyHelperCommand("install-helper.sh")};Button("复制卸载命令"){copyHelperCommand("uninstall-helper.sh")};Button("复制管理员恢复命令"){copyHelperCommand("recover-helper.sh")}}
                Text("安装、升级和卸载需要你在终端完成管理员批准。辅助服务固定客户端身份和组件哈希；重新构建应用后必须再次批准更新。真实 TUN 路由与异常恢复尚需本机管理员验收。").font(.caption).foregroundStyle(.secondary)
            }
            Section("代理与启动"){
                TextField("回环监听端口",text:$port);Button("保存端口"){Task{await model.savePort(Int(port) ?? 0)}}.disabled(model.locked)
                Toggle("启动应用后自动连接",isOn:Binding(get:{model.state.autoConnect},set:{model.setAutoConnect($0)})).disabled(model.locked)
                Toggle("登录 macOS 时启动应用",isOn:Binding(get:{model.state.loginAtStartup},set:{model.setLoginAtStartup($0)})).disabled(model.locked)
                Text("登录启动需要把应用放入 Applications。两个启动选项独立，默认关闭。").font(.caption).foregroundStyle(.secondary)
            }
            Section("全局连接开关快捷键"){
                Picker("按键",selection:$shortcutKey){Text("P").tag(UInt32(35));Text("D").tag(UInt32(2));Text("R").tag(UInt32(15))}
                Picker("组合",selection:$shortcutModifiers){Text("⌘⌥").tag(UInt32(2304));Text("⌘⌃").tag(UInt32(4352));Text("⌃⌥").tag(UInt32(6144));Text("⌘⌃⌥").tag(UInt32(6400))}
                Toggle("启用全局快捷键（默认关闭）",isOn:Binding(get:{model.state.shortcutEnabled},set:{model.setShortcut(enabled:$0,key:shortcutKey,modifiers:shortcutModifiers)})).disabled(model.locked)
                Button("应用快捷键组合"){model.setShortcut(enabled:model.state.shortcutEnabled,key:shortcutKey,modifiers:shortcutModifiers)}.disabled(model.locked)
                Text("注册前检查系统占用；冲突时保留原设置并提示。快捷键切换连接，不切换配置。").font(.caption)
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
        }.formStyle(.grouped).onAppear{port=String(model.state.listenPort);exclusions=model.state.tunExcludedCIDRs.joined(separator:",");shortcutKey=model.state.shortcutKey;shortcutModifiers=model.state.shortcutModifiers}
    }
    private func copyHelperCommand(_ script:String){func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"};let resources=Bundle.main.resourceURL!;let command="sudo "+quote(resources.appendingPathComponent(script).path)+(script=="install-helper.sh" ? " "+quote(Bundle.main.bundleURL.path):"");NSPasteboard.general.clearContents();NSPasteboard.general.setString(command,forType:.string)}
}
struct EditorRequest:Identifiable {let id=UUID();var node:Node?}
