import SwiftUI
import QingzhouKit

struct RuleTargetPicker:View {
    var state:AppState
    @Binding var target:PolicyReference
    var body:some View {Picker("动作 / 策略",selection:$target){Text("当前代理").tag(PolicyReference.selected);Text("直连").tag(PolicyReference.direct);Text("拒绝").tag(PolicyReference.reject);ForEach(state.groups){Text($0.name).tag(PolicyReference.group($0.id))}}}
}
struct RuleView:View {
    @ObservedObject var model:AppModel
    @State private var tab="自定义规则"
    @State private var kind=RuleKind.domain
    @State private var value=""
    @State private var target=PolicyReference.selected
    @State private var addingRemote=false
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            Picker("规则来源",selection:$tab){Text("自定义规则").tag("自定义规则");Text("远程规则源").tag("远程规则源")}.pickerStyle(.segmented)
            Text("规则模式：本机/私网直连 → 自定义规则 → 下方排列的远程规则源 → 默认策略。修改后执行受控重连。").font(.caption).foregroundStyle(.secondary)
            if tab=="自定义规则"{
                HStack{Picker("类型",selection:$kind){Text("域名").tag(RuleKind.domain);Text("后缀").tag(RuleKind.suffix);Text("关键词").tag(RuleKind.keyword);Text("IP/CIDR").tag(RuleKind.cidr)}.frame(width:160);TextField("匹配内容",text:$value);RuleTargetPicker(state:model.state,target:$target).frame(width:200);Button("添加"){let rule=RoutingRule(kind:kind,value:value,action:target == .direct ? .direct:target == .reject ? .reject:.proxy,target:target);Task{await model.addRule(rule);if model.errorMessage==nil{value=""}}}.disabled(model.locked)}
                HStack{Text("默认策略").font(.caption);RuleTargetPicker(state:model.state,target:Binding(get:{model.state.ruleFinal ?? .selected},set:{ref in Task{await model.setRuleFinal(ref)}})).frame(width:250);Spacer()}.disabled(model.locked)
                List(model.state.rules){rule in HStack{Text(rule.kind == .domain ? "域名":rule.kind == .suffix ? "后缀":rule.kind == .keyword ? "关键词":"IP/CIDR").frame(width:65,alignment:.leading);Text(rule.value);Spacer();Text(model.state.label(rule.target ?? (rule.action == .direct ? .direct:rule.action == .reject ? .reject:.selected))).font(.caption);Button{Task{await model.moveRule(rule.id,by:-1)}}label:{Image(systemName:"arrow.up")};Button{Task{await model.moveRule(rule.id,by:1)}}label:{Image(systemName:"arrow.down")};Button(role:.destructive){Task{await model.removeRule(rule.id)}}label:{Image(systemName:"trash")}}.disabled(model.locked)}
            }else{
                HStack{Text("规则源动作统一使用此处选择，不执行文件中的脚本或控制项。").font(.caption).foregroundStyle(.secondary);Spacer();Button("添加规则源",systemImage:"plus"){addingRemote=true}.disabled(model.locked)}
                if model.state.remoteRules.isEmpty{ContentUnavailableView("还没有远程规则源",systemImage:"link",description:Text("支持域名/IP列表、Clash 文本、YAML payload 和兼容的 sing-box JSON"))}
                else{List(model.state.remoteRules){source in VStack(alignment:.leading,spacing:8){
                    HStack{Text(source.name).font(.headline);Spacer();Toggle("自动更新",isOn:Binding(get:{source.autoUpdate},set:{auto in Task{await model.updateRemote(source.id,auto:auto)}})).toggleStyle(.checkbox);Button("更新"){Task{await model.refreshRemote(source.id)}};Button{Task{await model.moveRemote(source.id,by:-1)}}label:{Image(systemName:"arrow.up")};Button{Task{await model.moveRemote(source.id,by:1)}}label:{Image(systemName:"arrow.down")};Button(role:.destructive){Task{await model.deleteRemote(source.id)}}label:{Image(systemName:"trash")}}
                    HStack{RuleTargetPicker(state:model.state,target:Binding(get:{source.target},set:{ref in Task{await model.updateRemote(source.id,target:ref)}})).frame(width:260);Spacer();Text("\(source.rules.count) 条 · \(source.updatedAt?.formatted(date:.abbreviated,time:.shortened) ?? "未更新")").font(.caption).foregroundStyle(.secondary)}
                    if let error=source.lastError{Text(error).font(.caption).foregroundStyle(.orange)}
                }.padding(.vertical,8).disabled(model.locked)}}
            }
        }.sheet(isPresented:$addingRemote){RemoteEditor(model:model)}
    }
}
struct RemoteEditor:View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var url=""
    @State private var target=PolicyReference.selected
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18){Text("添加远程规则源").font(.title2.bold());TextField("名称",text:$name);SecureField("HTTPS 规则文件地址",text:$url);RuleTargetPicker(state:model.state,target:$target);Text("最多 2 MiB / 50000 条规则。地址保存在钥匙串；下载与解析失败不会修改现有规则。").font(.caption).foregroundStyle(.secondary);if let error{Text(error).font(.caption).foregroundStyle(.red)};HStack{Button("取消"){dismiss()}.disabled(model.busy);Spacer();Button("下载并添加"){Task{await model.addRemote(name:name,url:url,target:target);if model.errorMessage==nil{dismiss()}else{error=model.errorMessage}}}.buttonStyle(.borderedProminent).disabled(model.locked || name.isEmpty || url.isEmpty)}}.padding(26).frame(width:560)
    }
}
