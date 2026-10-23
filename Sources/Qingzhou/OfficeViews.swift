import SwiftUI
import AppKit
import QingzhouKit

struct OfficeMenuHealth:View {
    @ObservedObject var office:OfficeDashboardModel
    let hasCorporate:Bool
    var body:some View {Text("外网："+office.label("external")+" · 内网路由："+(hasCorporate ? office.label("routes"):"未配置"))}
}

struct OfficeHealthPanel:View {
    @ObservedObject var office:OfficeDashboardModel
    let hasCorporate:Bool
    var onDiagnose:()->Void
    private func color(_ status:OfficeHealthStatus)->Color {status == .healthy ? Theme.connectedGreen:status == .failed ? Theme.amberAccent:.secondary}
    var body:some View {
        TimelineView(.periodic(from:.now,by:30)) {clock in
            VStack(alignment:.leading,spacing:8) {
                HStack {Text("网络健康").font(.headline);Spacer();Button("详细诊断",action:onDiagnose).controlSize(.small)}
                ForEach([("external","外网 HTTPS"),("corporateDNS","企业 DNS"),("routes","内网保护路由")],id:\.0) {id,title in
                    let row=office.health.first{$0.id==id}
                    let current=row?.isCurrent(office.context,now:clock.date)==true
                    HStack(alignment:.top) {
                        Text(title).frame(width:110,alignment:.leading)
                        VStack(alignment:.leading,spacing:3) {
                            if id != "external" && !hasCorporate {Text("未配置").foregroundStyle(.secondary)}
                            else if let row {
                                Text(current ? row.status.rawValue:"未验证 · 历史结果").foregroundStyle(current ? color(row.status):.secondary)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                Text(row.checkedAt.formatted(date:.omitted,time:.standard)).font(.caption2).foregroundStyle(.secondary)
                            } else {Text("未验证").foregroundStyle(.secondary)}
                        }
                        Spacer(minLength:0)
                        if current,row?.status == .failed {Button("查看原因",action:onDiagnose).controlSize(.small)}
                    }.font(.callout)
                }
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Theme.cardBackground,in:RoundedRectangle(cornerRadius:12))
        }
    }
}

struct SavedTargetsPanel:View {
    let model:AppModel
    let targets:[SavedDiagnosticTarget]
    @ObservedObject var office:OfficeDashboardModel
    var locked:Bool
    var showAll=false
    @State private var editing=false
    @State private var selected:SavedDiagnosticTarget?
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {Text("常用目标").font(.headline);Spacer();Button("管理目标") {editing=true}.disabled(locked)}
            if targets.isEmpty {Text("添加 Horizon、内部仓库等常用目标；默认检查路径，测试连接需单独点击。").font(.caption).foregroundStyle(.secondary)}
            ForEach(showAll ? targets:Array(targets.prefix(5))) {target in
                ViewThatFits(in:.horizontal) {
                    HStack {targetLabel(target);Spacer();actions(target)}
                    VStack(alignment:.leading) {targetLabel(target);actions(target)}
                }
            }
            if !showAll,targets.count>5 {Button("查看全部目标") {office.diagnosticRequested=true}}
        }
        .sheet(isPresented:$editing) {
            SavedTargetsEditor(model:model,draft:model.drafts.targets(profile:model.currentProfileID,state:model.state))
        }
        .sheet(item:$selected) {target in
            TargetResultSheet(office:office,target:target)
        }
    }
    private func targetLabel(_ target:SavedDiagnosticTarget)->some View {
        VStack(alignment:.leading,spacing:2) {
            Text(target.name).font(.callout.bold()).lineLimit(1).help(target.host)
            Text(office.label("target-"+target.id.uuidString)).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func actions(_ target:SavedDiagnosticTarget)->some View {
        HStack(spacing:8) {
            if office.running.contains(target.id) {ProgressView().controlSize(.small);Button("取消") {office.cancel(target.id)}}
            else {
                Button("检查路径") {model.inspectSavedTarget(target);selected=target}.disabled(locked)
                Button("测试连接") {model.inspectSavedTarget(target,connect:true);selected=target}.disabled(locked)
            }
            if office.sessions[target.id] != nil {Button("结果") {selected=target}}
        }.controlSize(.small)
    }
}

struct TargetResultSheet:View {
    @ObservedObject var office:OfficeDashboardModel
    let target:SavedDiagnosticTarget
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text(target.name+" · 最近检查").font(.headline);Spacer();Button("完成") {dismiss()}}
            Text(office.label("target-"+target.id.uuidString)).font(.caption).foregroundStyle(.secondary)
            if office.running.contains(target.id) {HStack {ProgressView();Button("停止") {office.cancel(target.id)}}}
            ScrollView {LazyVStack(alignment:.leading,spacing:12) {
                ForEach(office.sessions[target.id]?.results ?? []) {row in
                    VStack(alignment:.leading,spacing:4) {
                        Text(row.stage+" · "+row.status).font(.headline)
                        Text(row.checkedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                        Text(row.detail).font(.callout).textSelection(.enabled)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }}
            Menu("导出脱敏报告") {
                Button("文本") {saveDiagnosticData(try? office.sessions[target.id]?.export(json:false),name:"轻舟目标检查.txt")}
                Button("JSON") {saveDiagnosticData(try? office.sessions[target.id]?.export(json:true),name:"轻舟目标检查.json")}
            }.disabled(office.sessions[target.id]==nil)
        }.padding(20).frame(minWidth:600,minHeight:420)
    }
}

struct SavedTargetsEditor:View {
    let model:AppModel
    @ObservedObject var draft:SavedTargetsDraft
    @State private var failure:String?
    var body:some View {
        DraftEditorSheet(draft:draft,store:model.drafts,title:"常用目标") {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    ForEach($draft.values) {$target in
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                TextField("名称",text:$target.name)
                                TextField("域名或 IP",text:$target.host)
                                TextField("端口（默认 443）",value:$target.port,format:.number.grouping(.never)).frame(width:140)
                            }
                            HStack {
                                Picker("连接测试",selection:$target.test) {ForEach(TargetConnectionTest.allCases,id:\.self){Text($0.label).tag($0)}}
                                Picker("预期路径",selection:$target.expectedPath) {ForEach(TargetExpectedPath.allCases,id:\.self){Text($0.label).tag($0)}}
                                Button("删除",role:.destructive) {draft.values.removeAll{$0.id==target.id}}
                            }
                        }.padding(10).background(Theme.cardBackground,in:RoundedRectangle(cornerRadius:10))
                    }
                }
            }
            if let failure {Text(failure).foregroundStyle(.orange)}
            HStack {
                Button("添加目标") {draft.values.append(SavedDiagnosticTarget(name:"新目标",host:""))}.disabled(draft.values.count>=100)
                Spacer()
                Button("重新载入") {draft.accept(model.state.savedDiagnosticTargets ?? []);failure=nil}
                Button("保存") {
                    do {guard draft.profileID==model.currentProfileID else {throw ProxyError("配置已切换，请关闭后重新编辑目标")};try model.saveDiagnosticTargets(draft.values,expected:draft.revision);draft.accept(model.state.savedDiagnosticTargets ?? []);failure=nil}
                    catch {failure=error.localizedDescription}
                }.buttonStyle(.borderedProminent).disabled(model.locked || !draft.dirty)
            }
        }.padding(20).frame(minWidth:760,minHeight:440)
    }
}

struct DeveloperProxyAssistantView:View {
    let port:Int
    let configuredDomains:[String]
    let cidrs:[String]
    @State private var domains=""
    @State private var confirmed=false
    @State private var results:[String]=[]
    @State private var error:String?
    private var commands:DeveloperProxyCommands? {try? DeveloperProxyCommands(port:port,domains:domains.split(whereSeparator:{$0=="," || $0=="\n"}).map{String($0)})}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("开发工具代理助手").font(.title2.bold())
            Text("本地端口：\(port) · 仅预览和复制，不修改终端、Git 或 Maven 配置。").font(.caption)
            TextField("确认绕过的内网域名（逗号分隔）",text:$domains).textFieldStyle(.roundedBorder)
            Toggle("已确认这些域名应绕过代理",isOn:$confirmed)
            if !cidrs.isEmpty {Text("配置含 CIDR；各工具支持不同，此处不自动写入绕过列表。").font(.caption).foregroundStyle(.secondary)}
            if let commands {
                ScrollView {VStack(alignment:.leading,spacing:14) {
                    snippet("启用当前终端代理",commands.enable)
                    snippet("取消当前终端代理",commands.disable)
                    Text("取消命令会移除当前终端已有的代理和绕过变量，不恢复先前值。").font(.caption).foregroundStyle(.orange)
                    snippet("Git 单次调用",commands.gitOnce)
                    snippet("Git 当前仓库配置",commands.gitRepository)
                    snippet("Maven settings.xml 片段",commands.maven)
                    Text("绕过列表包含所确认域名及其子域名。终端与 Git/libcurl 使用逗号分隔；Maven 使用 | 分隔和 *.域名。请按实际工具版本核对匹配行为。").font(.caption)
                }}
            } else {Text("域名或端口无效，不能生成命令").foregroundStyle(.orange)}
            HStack {
                Button("检查应用环境") {results=DeveloperToolInspector.environment(ProcessInfo.processInfo.environment)}
                Button("检查 Git 配置文件") {inspect("git")}
                Button("检查 Maven 配置文件") {inspect("maven")}
                Button("检查本地端口") {Task {
                    let target=SavedDiagnosticTarget(name:"本地端口",host:"127.0.0.1",port:port,test:.tcp,expectedPath:.system)
                    let result=await TargetConnectionProbe.run(target,evidence:TargetPathEvidence(rows:[],addresses:["127.0.0.1"],corporate:false),state:AppState(),connected:true)
                    results=[result.status+"："+result.detail,"端口可连接不证明监听进程属于轻舟。"]
                }}
            }.controlSize(.small)
            ForEach(Array(results.enumerated()),id:\.offset) {_,result in Text(result).font(.caption).textSelection(.enabled)}
            if let error {Text(error).foregroundStyle(.orange)}
        }.padding(20).frame(minWidth:780,minHeight:560)
        .onAppear {if domains.isEmpty {domains=configuredDomains.joined(separator:",")}}
        .onChange(of:domains){_,_ in confirmed=false}
    }
    private func snippet(_ title:String,_ text:String)->some View {
        VStack(alignment:.leading,spacing:4) {
            HStack {Text(title).font(.headline);Spacer();Button("复制") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}.disabled(!confirmed)}
            Text(text).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private func inspect(_ kind:String) {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.showsHiddenFiles=true
        panel.begin {response in
            guard response == .OK,let url=panel.url else{return}
            do {
                let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size<=2*1024*1024 else {throw ProxyError("所选配置超过 2 MiB")}
                results=DeveloperToolInspector.configuration(try Data(contentsOf:url),kind:kind);error=nil
            }catch {self.error="无法读取所选配置，未输出文件原文"}
        }
    }
}
