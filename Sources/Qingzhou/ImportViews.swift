import SwiftUI
import QingzhouKit

struct ImportSheet:View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input=""
    var body:some View {
        VStack(alignment:.leading,spacing:18){Text("导入节点或配置").font(.title2.bold());Text("粘贴节点链接、HTTPS 订阅、Base64 列表或 Clash/Mihomo YAML。配置会转换成应用模型，不直接执行。").foregroundStyle(.secondary)
            TextEditor(text:$input).font(.system(.body,design:.monospaced)).frame(height:190).border(Color.secondary.opacity(0.2))
            Text("订阅地址与凭据仅保存在本机钥匙串，不写入日志。").font(.caption).foregroundStyle(.secondary)
            HStack{Button("取消"){input="";dismiss()};Spacer();Button("解析并预览"){let value=input;input="";dismiss();Task{await model.importPreview(value)}}.buttonStyle(.borderedProminent).disabled(input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.locked)}
        }.padding(26).frame(width:660)
    }
}
struct PreviewSheet:View {
    @ObservedObject var model:AppModel
    @State private var scope=ImportScope.nodes
    @State private var confirmedInsecure=false
    @State private var confirmedSkipping=false
    private var insecure:Bool {model.preview?.candidates.contains{$0.node.insecure}==true}
    private var issues:[String] {model.preview?.unsupported ?? []}
    var body:some View {
        VStack(alignment:.leading,spacing:14){
            Text("确认导入").font(.title2.bold())
            if let diff=model.previewDiff{DisclosureGroup("更新差异：新增 \(diff.added.count) · 删除 \(diff.removed.count) · 变化 \(diff.changed.count)"){ScrollView{VStack(alignment:.leading){Text("新增："+diff.added.joined(separator:"、"));Text("删除："+diff.removed.joined(separator:"、"));Text("参数/名称变化："+diff.changed.joined(separator:"、"));Text("证书验证变化："+diff.certificateChanges.joined(separator:"、"));Text("策略变化："+(diff.strategyChanges ? "是":"否")+" · 规则变化："+(diff.ruleChanges ? "是":"否"));if diff.removesSelection{Text("当前节点将移除，需重新选择").foregroundStyle(.orange)}}.font(.caption)}.frame(maxHeight:110)}}
            Picker("导入范围",selection:$scope){Text("仅兼容节点").tag(ImportScope.nodes);Text("节点、策略和规则").tag(ImportScope.profile)}.pickerStyle(.segmented)
            Text("\(model.preview?.candidates.count ?? 0) 个兼容节点 · \(model.preview?.groups.count ?? 0) 个策略组 · \(model.preview?.rules.count ?? 0) 条规则").foregroundStyle(.secondary)
            List(model.preview?.candidates ?? [],id:\.node.id){c in VStack(alignment:.leading,spacing:4){Text(c.node.name).font(.headline);Text("\(c.node.kind.rawValue) · \(c.node.server):\(c.node.port)").font(.caption);if c.node.insecure{Text("此节点跳过 TLS 证书验证").foregroundStyle(.orange).font(.caption)}}}.frame(height:170)
            if !issues.isEmpty {
                Text("以下内容不兼容，完整导入不可用").font(.headline).foregroundStyle(.orange)
                ScrollView{Text(issues.joined(separator:"\n")).font(.caption).frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:90)
                if scope == .nodes{Toggle("仅导入兼容节点，确认跳过以上内容",isOn:$confirmedSkipping)}
            }
            if let ignored=model.preview?.ignored,!ignored.isEmpty {DisclosureGroup("未接管的配置项"){Text(ignored.joined(separator:"\n")).font(.caption)}}
            if insecure{Toggle("确认保留链接中的跳过证书验证设置",isOn:$confirmedInsecure)}
            Text(scope == .nodes ? "不导入配置中的策略和规则；更新订阅会替换其节点。" : "兼容策略和规则将并入应用，端口及外部控制项保持应用设置。").font(.caption).foregroundStyle(.secondary)
            HStack{Button("取消"){model.cancelPreview()}.disabled(model.busy);Spacer();Button("确认导入"){Task{await model.confirmImport(scope:scope)}}.buttonStyle(.borderedProminent).disabled(model.locked || model.preview?.candidates.isEmpty != false || (insecure && !confirmedInsecure) || (scope == .profile && !issues.isEmpty) || (scope == .nodes && !issues.isEmpty && !confirmedSkipping))}
        }.padding(26).frame(width:680)
    }
}
struct SubscriptionsView:View {
    @ObservedObject var model:AppModel
    @State private var editing:Subscription?
    @State private var name=""
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{Text("自动更新只在应用运行时执行，每 24 小时一次。").font(.caption).foregroundStyle(.secondary);Spacer();Button("更新全部"){Task{await model.refreshAll()}}.disabled(model.locked)}
            if model.state.subscriptions.isEmpty{ContentUnavailableView("还没有订阅",systemImage:"arrow.triangle.2.circlepath",description:Text("在节点页导入 HTTPS 订阅地址"))}
            else{List(model.state.subscriptions){sub in VStack(alignment:.leading,spacing:8){
                HStack{Text(sub.name).font(.headline);Text(sub.scope == .nodes ? "节点订阅":"配置订阅").font(.caption).foregroundStyle(.secondary);Spacer();Toggle("自动更新",isOn:Binding(get:{sub.autoUpdate},set:{model.updateSubscription(sub.id,auto:$0)})).toggleStyle(.checkbox);Button("改名"){name=sub.name;editing=sub};Button(sub.pendingReview ? "预览并确认":"更新并预览"){Task{await model.refresh(sub)}};Button(role:.destructive){Task{await model.deleteSubscription(sub.id)}}label:{Image(systemName:"trash")}}
                Text("\(model.state.nodes.filter{$0.subscriptionID==sub.id}.count) 个节点 · 更新于 \(sub.updatedAt.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary)
                Text(usage(sub.usage)).font(.caption)
                if let error=sub.lastError{Text(error).font(.caption).foregroundStyle(.orange)}
            }.padding(.vertical,8).disabled(model.locked)}}
        }.sheet(item:$editing){sub in VStack(alignment:.leading,spacing:18){Text("编辑订阅名称").font(.title2.bold());TextField("名称",text:$name);HStack{Button("取消"){editing=nil};Spacer();Button("保存"){model.updateSubscription(sub.id,name:name);if model.errorMessage==nil{editing=nil}}.buttonStyle(.borderedProminent)}}.padding(26).frame(width:420)}
    }
    private func usage(_ value:UsageInfo?) -> String {
        guard let value else{return "用量 / 额度 / 到期：服务端未提供"}
        let used:String
        if let u=value.upload,let d=value.download {let sum=u.addingReportingOverflow(d);used=sum.overflow ? "未知":bytes(Int64(clamping:sum.partialValue))}else{used="未知"}
        let total=value.total.map{bytes(Int64(clamping:$0))} ?? "未知"
        let expiry=value.expire.flatMap{$0.isFinite && $0>0 ? Date(timeIntervalSince1970:$0).formatted(date:.abbreviated,time:.omitted):nil} ?? "未知"
        return "已用 \(used) / 额度 \(total) · 到期 \(expiry)"
    }
}
