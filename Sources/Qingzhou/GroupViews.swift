import SwiftUI
import QingzhouKit

struct GroupRequest:Identifiable {let id=UUID();var group:PolicyGroup?}
struct GroupsView:View {
    @ObservedObject var model:AppModel
    @State private var editing:GroupRequest?
    var body:some View {
        VStack(alignment:.leading,spacing:14){
            HStack{Text("选择策略影响新连接；已有连接保留。自动选择不会在全部节点失败后降级直连。").font(.caption).foregroundStyle(.secondary);Spacer();Button("新建分组",systemImage:"plus"){editing=GroupRequest(group:nil)}.disabled(model.locked)}
            HStack{VStack(alignment:.leading,spacing:6){Text("自动选择").font(.headline);Text("全部节点 · 每 5 分钟检测 · 50 ms 防抖容差").font(.caption).foregroundStyle(.secondary)};Spacer();Text(model.actualName).font(.caption);Button(model.state.activePolicy == .automatic ? "已选择":"选择"){Task{await model.selectPolicy(.automatic)}}.disabled(model.locked || model.state.nodes.isEmpty)}.padding(16).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:12))
            if model.state.groups.isEmpty{ContentUnavailableView("还没有自定义分组",systemImage:"square.stack.3d.up",description:Text("按用途分组，或从 Clash/Mihomo 配置导入"))}
            else{List(model.state.groups){group in VStack(alignment:.leading,spacing:8){
                HStack{Text(group.name).font(.headline);Text(group.kind == .select ? "手动选择":group.kind == .fallback ? "优先级回退":"自动选择").font(.caption).foregroundStyle(.secondary);Spacer();Button(model.state.activePolicy == .group(group.id) ? "已选择":"使用"){Task{await model.selectPolicy(.group(group.id))}};Button("编辑"){editing=GroupRequest(group:group)};Button(role:.destructive){Task{await model.deleteGroup(group.id)}}label:{Image(systemName:"trash")}}
                if group.kind == .select{Picker("组内选择",selection:Binding(get:{group.selected ?? group.members.first ?? .direct},set:{ref in Task{await model.selectMember(group,ref)}})){ForEach(group.members,id:\.self){Text(model.state.label($0)).tag($0)}}}
                else{Text("实际选择：\(model.proxyInfo[PolicyReference.group(group.id).tag]?.now.map{model.label($0)} ?? "尚未检测")").font(.caption)}
                Text("\(group.members.count) 个成员"+(group.subscriptionID != nil ? " · 订阅更新可能覆盖此组":"")).font(.caption).foregroundStyle(.secondary)
            }.accessibilityElement(children:.contain).padding(.vertical,8).disabled(model.locked)}}
        }.sheet(item:$editing){request in GroupEditor(model:model,group:request.group)}
    }
}
struct GroupEditor:View {
    @ObservedObject var model:AppModel
    var group:PolicyGroup?
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var kind=GroupKind.select
    @State private var members=Set<PolicyReference>()
    @State private var priority:[PolicyReference]=[]
    @State private var error:String?
    private var options:[PolicyReference]{model.state.nodes.map{.node($0.id)}+(kind == .fallback ? []:model.state.groups.filter{$0.id != group?.id}.map{.group($0.id)}+(!model.state.nodes.isEmpty ? [.automatic]:[])+[.direct])}
    var body:some View {
        VStack(alignment:.leading,spacing:16){Text(group==nil ? "新建策略组":"编辑策略组").font(.title2.bold());TextField("名称",text:$name);Picker("策略类型",selection:$kind){Text("手动选择").tag(GroupKind.select);Text("自动选择").tag(GroupKind.urltest);Text("优先级回退").tag(GroupKind.fallback)}
            List(options,id:\.self){ref in Toggle(model.state.label(ref),isOn:Binding(get:{members.contains(ref)},set:{if $0{members.insert(ref);if !priority.contains(ref){priority.append(ref)}}else{members.remove(ref);priority.removeAll{$0==ref}}}))}.frame(height:260)
            if kind == .fallback {List(priority.filter{members.contains($0) && options.contains($0)},id:\.self){ref in HStack{Text(model.state.label(ref));Spacer();Button("上移"){move(ref,-1)};Button("下移"){move(ref,1)}}}.frame(height:140);Text("优先级由上到下；60 秒检测，连续失败两次切换，连续成功两次切回，切换间隔至少 60 秒。无直连后备。").font(.caption)}
            Text("自动选择使用 HTTPS 延迟，5 分钟检测一次，50 ms 容差。引用其他组时会校验循环。").font(.caption).foregroundStyle(.secondary)
            if let error{Text(error).foregroundStyle(.red).font(.caption)}
            HStack{Button("取消"){dismiss()};Spacer();Button("保存"){save()}.buttonStyle(.borderedProminent).disabled(model.locked || members.isEmpty)}
        }.padding(26).frame(width:560).onAppear{if let group{name=group.name;kind=group.kind;members=Set(group.members);priority=group.members}}
    }
    private func move(_ ref:PolicyReference,_ offset:Int){guard let index=priority.firstIndex(of:ref),priority.indices.contains(index+offset) else{return};priority.swapAt(index,index+offset)}
    private func save(){
        guard !name.trimmingCharacters(in:.whitespaces).isEmpty else {error="名称不能为空";return}
        let ordered=kind == .fallback ? priority.filter{members.contains($0) && options.contains($0)}:options.filter{members.contains($0)};var candidate=PolicyGroup(id:group?.id ?? UUID(),name:name,kind:kind,members:ordered,selected:ordered.first,subscriptionID:group?.subscriptionID)
        if let selected=group?.selected,ordered.contains(selected){candidate.selected=selected}
        var next=model.state;next.groups.removeAll{$0.id==candidate.id};next.groups.append(candidate)
        do{try PolicyValidator.validate(next)}catch{self.error=error.localizedDescription;return}
        Task{await model.saveGroup(candidate);if model.errorMessage==nil{dismiss()}else{error=model.errorMessage}}
    }
}
