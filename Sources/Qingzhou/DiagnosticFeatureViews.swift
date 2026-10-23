import SwiftUI
import AppKit
import QingzhouKit

func saveDiagnosticData(_ data:Data?,name:String) {
    guard let data else{return}
    let panel=NSSavePanel();panel.nameFieldStringValue=name
    panel.begin {response in
        guard response == .OK,let url=panel.url else{return}
        do {try SecureFile.write(data,to:url)}catch {let alert=NSAlert();alert.messageText="导出失败";alert.informativeText="请检查目标目录权限和可用空间";alert.runModal()}
    }
}
struct DiagnosticsView:View {
    @ObservedObject var model:AppModel
    @State private var tab=0
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Picker("诊断类型",selection:$tab) {
                Text("综合诊断").tag(0)
                Text("目标路径").tag(1)
                Text("事件时间线").tag(2)
            }.pickerStyle(.segmented)
            Group {
                switch tab {
                case 1:TargetPathPanel(model:model)
                case 2:NetworkTimelineView(timeline:model.timeline,profiles:model.profiles)
                default:ComprehensiveDiagnosticsView(model:model)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }.padding()
    }
}
struct TargetPathPanel:View {
    @ObservedObject var model:AppModel
    @State private var target=""
    @State private var session:DiagnosticSession?
    @State private var task:Task<Void,Never>?
    @State private var generation=UUID()
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("目标路径诊断").font(.title2.bold())
            Text("配置预期与系统实际结果分开呈现；只读查询不代表业务连接已验证。").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("域名或 IP",text:$target).textFieldStyle(.roundedBorder)
                Button("查询") {inspect()}.disabled(target.isEmpty || model.locked)
                Button("停止诊断") {task?.cancel()}.disabled(task==nil)
                Menu("导出脱敏报告") {
                    Button("文本") {saveDiagnosticData(try? session?.export(json:false),name:"轻舟目标路径.txt")}
                    Button("JSON") {saveDiagnosticData(try? session?.export(json:true),name:"轻舟目标路径.json")}
                }.disabled(session==nil)
            }
            ScrollView {LazyVStack(alignment:.leading,spacing:10) {
                ForEach(session?.results ?? []) {row in
                    VStack(alignment:.leading) {
                        Text(row.stage+" · "+row.status).font(.headline)
                        Text(row.checkedAt.formatted()+" · "+(row.milliseconds.map{String($0)+" ms"} ?? "耗时未取得")).font(.caption2).foregroundStyle(.secondary)
                        Text(row.detail).textSelection(.enabled)
                    }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(Theme.cardBackground)
                }
            }}
        }.onChange(of:target){_,_ in invalidate()}
        .onChange(of:model.currentProfileID){_,_ in invalidate()}
        .onChange(of:model.connection){_,_ in invalidate()}
        .onChange(of:model.diagnosticGeneration){_,_ in invalidate()}
        .onDisappear {invalidate()}
    }
    private func invalidate() {generation=UUID();task?.cancel();task=nil;session=nil}
    private func inspect() {
        model.cancelDiagnostic();invalidate()
        let token=generation,input=target,state=model.state,profile=model.currentProfileID,epoch=model.epoch
        let active=model.connection == .connected && model.activeBypasses==state.effectiveBypasses
        let executor=model.dependencies.diagnosticExecutor,helper=model.dependencies.diagnosticHelper
        let tag=state.mode == .direct ? nil:model.connection == .connected ? CoreAPIClient.actualTag(model.proxyInfo):state.activePolicy?.tag
        let nodeID=tag.flatMap{$0.hasPrefix("node-") ? UUID(uuidString:String($0.dropFirst(5))):nil}
        let frozen=DiagnosticSession(profileID:profile,connectionID:epoch,nodeID:nodeID)
        let cancellation=DiagnosticCancellation()
        let job=DiagnosticJob("目标路径") {
            let tunnel=state.captureMode.usesTunnel ? (try? await helper().tunnelInterface):nil
            return await withTaskCancellationHandler(operation:{
                await DiagnosticWorkPool.dns.run(stage:"目标路径",timeout:3) {
                    let expected=try RuleEvaluator.explain(input,state:state)
                    let actual=try BypassDiagnostics.inspect(input,state:state,active:active,ownedTunnel:tunnel,cancelled:{cancellation.cancelled})
                    return [DiagnosticResult("配置预期","通过",(expected.steps+["预期策略："+state.label(expected.target)]+(expected.uncertainty.map{[$0]} ?? [])).joined(separator:"\n"),code:"ruleSimulation"),DiagnosticResult("系统实际路径",actual.hasFailure ? "失败":"未验证",actual.rows.joined(separator:"\n"),code:actual.hasFailure ? "pathMismatch":"businessUnverified")]
                }
            },onCancel:{cancellation.cancel()})
        }
        task=Task {
            let value=await executor.run(frozen,jobs:[job])
            guard generation==token,model.epoch==epoch,model.currentProfileID==profile else{return}
            session=value;task=nil
        }
    }
}
struct NetworkTimelineView:View {
    @ObservedObject var timeline:NetworkTimelineModel
    let profiles:[ClientProfile]
    @State private var profile:UUID?
    @State private var session:UUID?
    @State private var failures=false
    @State private var confirmingClear=false
    private var filtered:[NetworkEvent] {timeline.rows.filter{(profile==nil || $0.profileID==profile) && (session==nil || $0.sessionID==session || $0.originalSessionID==session) && (!failures || $0.outcome == .failed)}}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Picker("配置",selection:$profile) {
                    Text("全部配置").tag(UUID?.none)
                    ForEach(profiles){Text($0.name).tag(Optional($0.id))}
                    ForEach(Array(Set(timeline.rows.compactMap(\.profileID)).subtracting(profiles.map(\.id))).sorted{$0.uuidString<$1.uuidString},id:\.self) {id in Text("已删除配置 "+String(id.uuidString.prefix(8))).tag(Optional(id))}
                }
                Picker("会话",selection:$session) {
                    Text("全部会话").tag(UUID?.none)
                    ForEach(Array(Set(timeline.rows.map(\.sessionID))).sorted{$0.uuidString<$1.uuidString},id:\.self){Text(String($0.uuidString.prefix(8))).tag(Optional($0))}
                }
                Toggle("仅异常",isOn:$failures)
                Menu("脱敏导出") {
                    Button("文本") {saveDiagnosticData(try? NetworkEventStore.export(filtered,json:false),name:"轻舟网络事件.txt")}
                    Button("JSON") {saveDiagnosticData(try? NetworkEventStore.export(filtered,json:true),name:"轻舟网络事件.json")}
                }
                Button("清空") {confirmingClear=true}
            }
            if let error=timeline.error {Text(error).foregroundStyle(.orange)}
            if timeline.dropped>0 {Text("事件过密，已丢弃 \(timeline.dropped) 条待写入事件").font(.caption)}
            List(filtered.reversed()) {event in
                HStack {
                    Text(event.lastTime.formatted()).font(.caption)
                    Text(event.category.label+" · "+event.outcome.label)
                    VStack(alignment:.leading,spacing:2) {
                        Text(event.reason.label)
                        if let reason=event.recoveryReason {Text(reason.label).font(.caption).foregroundStyle(.secondary)}
                    }.help(event.recoveryDetails)
                    if let attempt=event.recoveryAttempt,attempt>0 {Text("第 \(attempt)/3 次").font(.caption)}
                    if let phase=event.phase {Text(phase.label).font(.caption)}
                    Spacer()
                    if event.count>1 {Text("×\(event.count)")}
                    Text(String(event.sessionID.uuidString.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }.confirmationDialog("清空网络事件？",isPresented:$confirmingClear) {Button("清空",role:.destructive){Task{await timeline.clear()}}}
    }
}
struct ProfileHistoryView:View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model:AppModel
    let profileID:UUID?
    @State private var versions:[ProfileHistoryVersion]=[]
    @State private var selected:ProfileHistoryVersion?
    @State private var differences:[String]=[]
    @State private var expectedRevision:Data?
    @State private var message=""
    @State private var enabled=true
    @State private var confirming=false
    @State private var requiresReconnect=false
    @State private var clearing=false
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("配置历史").font(.title2.bold());Spacer()
                Toggle("自动历史",isOn:$enabled).disabled(model.locked).onChange(of:enabled){_,value in model.setHistoryEnabled(value);reload()}
                Button("清空全部历史") {clearing=true}.disabled(model.locked)
                Button("关闭") {dismiss()}
            }
            Text("每份配置最多 20 个版本、30 天；总计最多 100 MiB。凭据随历史独立加密保存。").font(.caption).foregroundStyle(.secondary)
            if let status=model.historyStatus {Text(status).foregroundStyle(.orange)}
            if !message.isEmpty {Text(message).foregroundStyle(.orange)}
            HSplitView {
                List(versions) {version in
                    Button {preview(version)} label:{VStack(alignment:.leading) {
                        Text(version.name+" · "+version.source)
                        Text(version.date.formatted()).font(.caption)
                        Text(version.connectionVerified ? "已保存 · 连接验证通过":"已保存 · 连接未验证").font(.caption2)
                    }}.buttonStyle(.plain)
                }.frame(minWidth:280)
                VStack(alignment:.leading,spacing:12) {
                    Text("恢复差异预览").font(.headline)
                    ForEach(Array(differences.enumerated()),id:\.offset){Text($0.element)}
                    Spacer()
                    Button("恢复此版本") {requiresReconnect=selected?.profileID==model.currentProfileID && model.connection == .connected;confirming=true}.disabled(selected==nil || model.locked)
                }.padding().frame(minWidth:300)
            }
        }.padding(24).frame(width:880,height:560).onAppear {enabled=model.profileHistory.enabled;reload()}
        .confirmationDialog(requiresReconnect ? "恢复当前运行配置将重新连接，是否继续？":"确认恢复选中的单份配置？其他配置和当前选择保持不变。",isPresented:$confirming) {
            Button("确认恢复") {guard let selected else{return};Task {if await model.restoreHistory(selected,expectedRevision:expectedRevision,confirmedReconnect:requiresReconnect) {self.selected=nil;differences=[];reload()}}}
        }
        .confirmationDialog("清空全部历史？当前配置、节点凭据和手工备份保留。",isPresented:$clearing) {
            Button("清空历史",role:.destructive) {guard !model.locked else{message="配置正在应用，请完成后再清空历史";return};do {try model.profileHistory.clear();selected=nil;differences=[];reload()}catch {message="历史清理失败，请检查目录权限"}}
        }
    }
    private func reload() {
        do {versions=try model.profileHistory.versions().filter{profileID==nil || $0.profileID==profileID};message=""}catch {message="历史未就绪：无法读取历史或密钥";versions=[]}
    }
    private func preview(_ version:ProfileHistoryVersion) {
        do {
            let current=model.profiles.first{$0.id==version.profileID}
            differences=ProfileHistoryDiff.rows(current:current,snapshot:try model.profileHistory.snapshot(version),credentials:model.credentials)
            expectedRevision=try current.map{try ProfileHistoryStore.revision($0)};selected=version;message=""
        }catch {selected=nil;differences=[];message="历史快照损坏或密钥不可用，未修改配置"}
    }
}
