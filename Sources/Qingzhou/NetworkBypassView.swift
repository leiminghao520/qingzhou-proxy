import SwiftUI
import QingzhouKit

struct NetworkBypassView:View {
    @ObservedObject var model:AppModel
    var conversion:RoutingRule?
    var body:some View {
        BypassContent(model:model,conversion:conversion,revision:BypassViewRevision(model:model)).equatable().id(model.currentProfileID)
    }
}
private struct BypassViewRevision:Equatable {
    let corporateDNS:[TrustedCorporateDNS]
    let items:[NetworkBypass]
    let rules:[RoutingRule]
    let active:[NetworkBypass]?
    let profile:UUID?
    let locked:Bool
    let connection:AppModel.Connection
    let failure:String?
    let helper:String
    @MainActor init(model:AppModel) {corporateDNS=model.state.trustedCorporateDNS ?? [];items=model.state.effectiveBypasses;rules=model.state.rules;active=model.activeBypasses;profile=model.currentProfileID;locked=model.locked;connection=model.connection;failure=model.bypassApplyFailure;helper=model.helperStatus}
}
private struct BypassContent:View,Equatable {
    let model:AppModel
    let conversion:RoutingRule?
    let revision:BypassViewRevision
    static func ==(lhs:Self,rhs:Self)->Bool {lhs.model === rhs.model && lhs.conversion==rhs.conversion && lhs.revision==rhs.revision}
    @ObservedObject private var session:BypassDraft
    init(model:AppModel,conversion:RoutingRule?,revision:BypassViewRevision) {
        self.model=model;self.conversion=conversion;self.revision=revision
        session=model.drafts.bypass(profile:revision.profile,items:revision.items,revision:try? model.bypassRevision(),corporateDNS:model.state.trustedCorporateDNS ?? [])
    }
    @State private var selection=Set<UUID>()
    @State private var search=""
    @State private var editing:NetworkBypass?
    @State private var bulk=false
    @State private var preview=false
    @State private var previewWarnings:[String]=[]
    @State private var error:String?
    @State private var previewing=false
    @State private var previewGeneration=UUID()
    @State private var diagnostic=false
    private var dirty:Bool {session.dirty}
    private var filtered:[NetworkBypass] {search.isEmpty ? session.items:session.items.filter{$0.value.localizedCaseInsensitiveContains(search) || $0.note.localizedCaseInsensitiveContains(search)}}
    private var status:String {
        if dirty {return revision.connection == .connected ? "草稿尚未应用，当前连接继续使用原配置":"草稿尚未保存"}
        if let failure=revision.failure {return "验证失败："+failure}
        if revision.connection == .connected,revision.active==revision.items {return "配置已生效；目标实际连接请使用路径诊断核对"}
        return "已保存；下次连接时应用"
    }
    private func reload() {
        previewGeneration=UUID();previewing=false
        session.accept(items:model.state.effectiveBypasses,revision:try? model.bypassRevision(),corporateDNS:model.state.trustedCorporateDNS ?? []);selection=[];error=nil
    }
    private func load() {
        session.sync(items:model.state.effectiveBypasses,revision:try? model.bypassRevision(),corporateDNS:model.state.trustedCorporateDNS ?? [])
        if let conversion,!session.converted.contains(conversion.id) {
            do {
                let item=try NetworkBypassPolicy.convert(conversion)
                if let index=session.items.firstIndex(where:{$0.kind==item.kind && $0.value==item.value}) {session.items[index].enabled=true}
                else {session.items.append(item)}
                session.converted.insert(conversion.id)
            }catch{self.error=error.localizedDescription}
        }
    }

    private func update(_ item:NetworkBypass) {
        if let index=session.items.firstIndex(where:{$0.id==item.id}) {session.items[index]=item}
        else {session.items.append(item)}
    }
    private func preparePreview() {
        previewing=true
        let token=UUID();previewGeneration=token
        let source=session.items
        Task {
            do {
                let result=try await Task.detached {let normalized=try NetworkBypassPolicy.normalize(source);return (normalized,NetworkBypassPolicy.coverageWarnings(normalized))}.value
                guard previewGeneration==token else{return}
                session.items=result.0;session.corporateDNS=try TrustedCorporateDNS.normalize(session.corporateDNS);previewWarnings=result.1;preview=true;error=nil
            }catch {if previewGeneration==token {self.error=error.localizedDescription}}
            if previewGeneration==token {previewing=false}
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("绕过轻舟").font(.title2.bold())
            Text("普通直连由核心访问目标；网络绕过优先于普通规则，同步系统代理例外、TUN 和 DNS。显式指定代理的应用可能忽略系统例外。")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("公司网络 DNS") {
                VStack(alignment:.leading,spacing:6) {
                    Text("仅在已确认的公司网络使用这些 DNS；网络服务或 DNS 变化后需要重新确认。此匹配不作为 Wi-Fi 身份认证。适用于 TUN 和组合接管模式。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(session.corporateDNS) {entry in
                        HStack {
                            VStack(alignment:.leading) {
                                Text(entry.name)
                                Text(entry.servers.joined(separator:", ")+" · "+entry.domains.joined(separator:", ")).font(.caption).textSelection(.enabled)
                            }
                            Spacer()
                            Button("移除") {session.corporateDNS.removeAll{$0.id==entry.id}}
                        }
                    }
                    Button("识别当前公司网络…") {
                        do {
                            let domains=session.items.filter{$0.enabled && $0.kind == .suffix}.map(\.value)
                            let entry=try TrustedCorporateDNS.current(domains:domains)
                            session.corporateDNS.removeAll{$0.serviceID==entry.serviceID}
                            session.corporateDNS.append(entry)
                        }catch {self.error=error.localizedDescription}
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.disabled(revision.locked || previewing)
            HStack {
                TextField("搜索目标或备注",text:$search).textFieldStyle(.roundedBorder)
                Button("新增") {editing=NetworkBypass(kind:.cidr,value:"")}
                Button("批量粘贴…") {bulk=true}
                Button("删除所选（\(selection.count)）") {session.items.removeAll{selection.contains($0.id)};selection=[]}.disabled(selection.isEmpty)
            }.disabled(revision.locked || previewing)
            List(selection:$selection) {
                ForEach(filtered) {item in
                    BypassRow(item:item,onToggle:{enabled in var changed=item;changed.enabled=enabled;update(changed)},onEdit:{editing=item})
                        .tag(item.id)
                }
            }.overlay {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(session.items.isEmpty ? "暂无网络绕过项":"没有匹配的绕过项",systemImage:"magnifyingglass")
                    } description: {Text(session.items.isEmpty ? "新增域名或网段后，预览并保存。":"试试其他目标或备注。")}
                    actions: {if !search.isEmpty {Button("清除搜索") {search=""}}}
                }
            }.frame(minHeight:240).disabled(revision.locked || previewing)
            HStack {
                Text("显示 \(filtered.count) / \(session.items.count) 项；已启用 \(session.items.filter(\.enabled).count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("目标路径诊断…") {diagnostic=true}
            }
            Text(status).font(.caption).foregroundStyle(dirty || revision.failure != nil ? .orange:.secondary).textSelection(.enabled)
            if let error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
            HStack {
                if dirty {Button("撤销草稿") {reload()}}
                Spacer()
                if previewing {ProgressView().controlSize(.small)}
                Button(revision.connection == .connected ? "预览并应用（重连一次）":"预览并保存") {preparePreview()}
                    .buttonStyle(.borderedProminent).disabled(!dirty || revision.locked || previewing || session.revision==nil)
            }
        }
        .task {load()}
        .onChange(of:revision) {_,_ in session.sync(items:model.state.effectiveBypasses,revision:try? model.bypassRevision(),corporateDNS:model.state.trustedCorporateDNS ?? [])}
        .sheet(item:$editing) {item in BypassItemEditor(item:item,store:model.drafts,profile:revision.profile) {update($0)}}
        .sheet(isPresented:$bulk) {BypassBulkEditor(existing:session.items,store:model.drafts,profile:revision.profile) {session.items.append(contentsOf:$0)}}
        .sheet(isPresented:$diagnostic) {BypassDiagnosticView(model:model)}
        .sheet(isPresented:$preview) {previewContent}
    }
    private var previewContent:some View {
        let oldIDs=Set(session.original.map(\.id)),newIDs=Set(session.items.map(\.id))
        let modified=session.items.filter{item in session.original.contains{$0.id==item.id && $0 != item}}.count
        return VStack(alignment:.leading,spacing:14) {
            Text("确认绕过变更").font(.title2.bold())
            Text("新增 \(newIDs.subtracting(oldIDs).count) 项，修改 \(modified) 项，删除 \(oldIDs.subtracting(newIDs).count) 项。")
            Text("公司网络 DNS：原 \(session.originalDNS.count) 项 → 新 \(session.corporateDNS.count) 项；保存即批准所列服务、DNS 及企业域名。").font(.caption)
            if !session.converted.isEmpty {Text("将 \(session.converted.count) 条普通 DIRECT 转为绕过，移除原普通规则。绕过优先于所有普通分流规则。").foregroundStyle(.orange)}
            ScrollView {
                LazyVStack(alignment:.leading,spacing:7) {
                    ForEach(session.corporateDNS) {entry in Text(entry.name+" · "+entry.servers.joined(separator:", ")+" · "+entry.domains.joined(separator:", "))}
                    ForEach(session.items) {item in
                        HStack {Text(item.kind.label);Text(item.value).font(.system(.body,design:.monospaced));Spacer();Text(item.enabled ? "启用":"停用");Text(item.exit == .pinned ? "指定网卡及网关":"系统路由")}
                    }
                    ForEach(Array(previewWarnings.enumerated()),id:\.offset) {_,warning in Text(warning).font(.caption).foregroundStyle(.orange)}
                }
            }.frame(minHeight:220)
            Text(revision.connection == .connected ? "应用成功后才保存；失败会尝试恢复原运行配置。":"只保存配置，不修改当前网络。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("返回编辑") {preview=false}.disabled(revision.locked)
                Spacer()
                Button(revision.connection == .connected ? "应用并保存":"保存配置") {
                    guard let baseRevision=session.revision else{return}
                    Task {if await model.applyBypassDraft(session.items,converted:session.converted,revision:baseRevision,corporateDNS:session.corporateDNS) {preview=false;reload()}}
                }.buttonStyle(.borderedProminent).disabled(revision.locked)
            }
            if let failure=revision.failure {Text("验证失败："+failure).font(.caption).foregroundStyle(.red)}
        }.padding(24).frame(minWidth:760,minHeight:450)
    }
}
private struct BypassRow:View {
    let item:NetworkBypass
    let onToggle:(Bool)->Void
    let onEdit:()->Void
    var body:some View {
        HStack(spacing:12) {
            Toggle("启用",isOn:Binding(get:{item.enabled},set:onToggle)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Text(item.kind.label).font(.caption).foregroundStyle(.secondary).frame(width:90,alignment:.leading)
            VStack(alignment:.leading,spacing:3) {
                Text(item.value).font(.system(.body,design:.monospaced)).lineLimit(1).help(item.value)
                if !item.note.isEmpty {Text(item.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)}
            }
            Spacer()
            Text(item.exit == .pinned ? "指定出口":"系统路由").font(.caption).foregroundStyle(item.exit == .pinned ? .orange:.secondary)
            Button("编辑",action:onEdit)
        }.padding(.vertical,3)
    }
}
private struct BypassItemEditor:View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft:EditorValueDraft<NetworkBypass>
    let store:SessionDraftStore
    let profile:UUID?
    @State private var editorID=UUID()
    init(item:NetworkBypass,store:SessionDraftStore,profile:UUID?,onSave:@escaping (NetworkBypass)->Void) {
        _draft=StateObject(wrappedValue:EditorValueDraft(item));self.store=store;self.profile=profile;self.onSave=onSave
    }
    private func cancel() {if !draft.dirty || store.confirm("关闭绕过项编辑器") {draft.discard();dismiss()}}
    let onSave:(NetworkBypass)->Void
    @State private var services:[BypassNetworkService]=[]
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("编辑网络绕过").font(.title2.bold())
            editorForm
            if let error {Text(error).foregroundStyle(.red).font(.caption)}
            HStack {Button("取消") {cancel()};Spacer();Button("加入草稿") {do {onSave(try draft.value.normalized());dismiss()}catch{self.error=error.localizedDescription}}.buttonStyle(.borderedProminent)}
        }.padding(24).frame(width:660,height:490).onAppear{services=BypassNetworkService.read();store.registerEditor(editorID,profile:profile,draft:draft)}
        .onDisappear{store.unregisterEditor(editorID)}
        .interactiveDismissDisabled(draft.dirty)
        .onExitCommand {cancel()}
        .background(EditorCloseGuard { !draft.dirty || store.confirm("关闭绕过项编辑器") })
    }
    private func serviceLabel(_ service:BypassNetworkService)->String {
        let status=service.active ? "可用":"未就绪"
        return "\(service.name)（\(service.interface)，\(status)）"
    }
    private var editorForm:some View {
        Form {
                Picker("目标类型",selection:$draft.value.kind) {ForEach(BypassTargetKind.allCases,id:\.self){Text($0.label).tag($0)}}
                TextField("目标",text:$draft.value.value)
                TextField("备注",text:$draft.value.note)
                Toggle("启用",isOn:$draft.value.enabled)
                Picker("网络出口",selection:$draft.value.exit) {
                    Text("沿用系统路由").tag(BypassExit.system)
                    Text("指定网卡及网关（仅 IP/网段）").tag(BypassExit.pinned)
                }
                if draft.value.exit == .pinned {
                    Picker("网络服务",selection:Binding(get:{draft.value.serviceID ?? ""},set:{draft.value.serviceID=$0})) {
                        Text("请选择网络服务").tag("")
                        ForEach(services) {service in Text(serviceLabel(service)).tag(service.id)}
                        if let id=draft.value.serviceID,!services.contains(where:{$0.id==id}) {Text("原网络服务已不存在："+id).tag(id)}
                    }
                    TextField("网关 IP",text:Binding(get:{draft.value.gateway ?? ""},set:{draft.value.gateway=$0}))
                    Text("指定出口需要辅助服务及可验证的拒绝保护。网卡掉线时拒绝其他出口；环境不兼容会拒绝应用，不覆盖企业 VPN 配置。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.formStyle(.grouped)

    }

}
private struct BypassBulkEditor:View {
    @Environment(\.dismiss) private var dismiss
    let existing:[NetworkBypass]
    let store:SessionDraftStore
    let profile:UUID?
    let onSave:([NetworkBypass])->Void
    @StateObject private var draft=EditorValueDraft("")
    @State private var editorID=UUID()
    private func cancel() {if !draft.dirty || store.confirm("关闭批量绕过编辑器") {draft.discard();dismiss()}}
    @State private var result:BypassInputResult?
    @State private var checking=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("批量添加网络绕过").font(.title2.bold())
            Text("支持逗号或换行。普通域名表示精确匹配；*.example.com 表示该域名及子域。IP 会自动补齐主机前缀。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text:$draft.value).font(.system(.body,design:.monospaced)).frame(minHeight:180).border(.secondary.opacity(0.3)).disabled(checking)
            if let result {
                Text("可添加 \(result.items.count) 项，错误 \(result.issues.count) 项")
                ScrollView {
                    LazyVStack(alignment:.leading) {
                        ForEach(Array(result.issues.enumerated()),id:\.offset) {_,issue in Text("第 \(issue.line) 行："+issue.message).foregroundStyle(.red)}
                        ForEach(Array(result.warnings.enumerated()),id:\.offset) {_,warning in Text(warning).foregroundStyle(.orange)}
                        ForEach(result.items) {Text($0.kind.label+" · "+$0.value)}
                    }.font(.caption)
                }.frame(height:150)
            }
            HStack {
                Button("取消") {cancel()}
                Button(checking ? "校验中…":"校验并预览") {
                    checking=true;let input=draft.value,items=existing
                    Task {result=await Task.detached{NetworkBypassPolicy.parse(input,existing:items)}.value;checking=false}
                }.disabled(checking)
                Spacer()
                Button("加入草稿") {if let result {onSave(result.items);dismiss()}}
                    .buttonStyle(.borderedProminent).disabled(checking || result==nil || result!.items.isEmpty || !result!.issues.isEmpty)
            }
        }.padding(24).frame(width:760,height:570).onChange(of:draft.value){_,_ in result=nil}
        .onAppear {store.registerEditor(editorID,profile:profile,draft:draft)}
        .onDisappear {store.unregisterEditor(editorID)}
        .interactiveDismissDisabled(draft.dirty)
        .onExitCommand {cancel()}
        .background(EditorCloseGuard { !draft.dirty || store.confirm("关闭批量绕过编辑器") })
    }
}
