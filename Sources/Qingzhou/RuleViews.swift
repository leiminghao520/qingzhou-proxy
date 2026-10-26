import SwiftUI
import QingzhouKit

struct RuleTargetPicker: View {
    var state: AppState
    @Binding var target: PolicyReference
    
    var body: some View {
        Picker("目标动作", selection: $target) {
            Text("当前代理选择").tag(PolicyReference.selected)
            Text("普通直连 (DIRECT)").tag(PolicyReference.direct)
            Text("拦截丢弃 (Reject)").tag(PolicyReference.reject)
            Divider()
            ForEach(state.groups) { group in
                Text("策略组: \(group.name)").tag(PolicyReference.group(group.id))
            }
        }
    }
}

struct RuleView: View {
    @ObservedObject var model: AppModel
    @State private var tab = "自定义规则"
    @State private var conversion:RoutingRule?
    @State private var addingRemote = false
    @State private var showingText=false
    @State private var textError:String?
    @ObservedObject private var draft:RulesDraft
    init(model:AppModel) {self.model=model;draft=model.drafts.rules(profile:model.currentProfileID)}
    private var displayedRules:[RoutingRule] {draft.rules ?? model.state.rules}
    private func beginDraft() {draft.begin(state:model.state,revision:try? model.ruleRevision())}
    private func resetDraft() {draft.discard();textError=nil}
    private func previewMove(from source:IndexSet,to destination:Int) {
        guard source.allSatisfy({displayedRules.indices.contains($0)}),(0...displayedRules.count).contains(destination) else {return}
        beginDraft();draft.rules!.move(fromOffsets:source,toOffset:destination)
    }
    private func previewStep(_ id:UUID,by offset:Int) {
        guard let index=displayedRules.firstIndex(where:{$0.id==id}),displayedRules.indices.contains(index+offset) else {return}
        previewMove(from:IndexSet(integer:index),to:index+offset+(offset>0 ? 1:0))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("规则来源", selection: $tab) {
                Text("自定义分流规则 (\(model.state.rules.count))").tag("自定义规则")
                Text("远程分流规则集 (\(model.state.remoteRules.count))").tag("远程规则源")
                Text("绕过轻舟 (\(model.state.effectiveBypasses.count))").tag("网络绕过")
            }
            .pickerStyle(.segmented)
            
            if tab == "网络绕过" {
                NetworkBypassView(model:model)
            } else if tab == "自定义规则" {
                HStack {
                    Button("批量文本编辑…") {
                        do {
                            if draft.text==nil {let text=try RuleTextCodec.encode(displayedRules);draft.text=text;draft.textBaseline=text;if draft.rules==nil {draft.revision=try model.ruleRevision()}}
                            showingText=true;textError=nil
                        }
                        catch {textError=error.localizedDescription}
                    }.disabled(model.locked)
                    if let textError {Text(textError).font(.caption).foregroundStyle(Theme.dangerRed)}
                }
                // 添加规则草稿
                HStack(spacing: 10) {
                    Picker("规则类型", selection: $draft.kind) {
                        Text("域名 (DOMAIN)").tag(RuleKind.domain)
                        Text("后缀 (SUFFIX)").tag(RuleKind.suffix)
                        Text("关键词 (KEYWORD)").tag(RuleKind.keyword)
                        Text("IP / CIDR").tag(RuleKind.cidr)
                    }
                    .frame(width: 160)
                    
                    TextField("匹配内容（如 google.com, 10.0.0.0/8）", text: $draft.input)
                        .textFieldStyle(.roundedBorder)
                    
                    RuleTargetPicker(state: model.state, target: $draft.target)
                        .frame(width: 190)
                    
                    Button {
                        let rule = RoutingRule(
                            kind: draft.kind,
                            value: draft.input.trimmingCharacters(in: .whitespaces),
                            action: draft.target == .direct ? .direct : draft.target == .reject ? .reject : .proxy,
                            target: draft.target
                        )
                        beginDraft();draft.rules!.append(rule);draft.input=""
                    } label: {
                        Label("加入草稿", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.locked || draft.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(model.locked)
                
                // 默认未命中兜底策略
                HStack(spacing: 10) {
                    Text("默认未命中兜底策略：")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    RuleTargetPicker(
                        state: model.state,
                        target: Binding(
                            get: { draft.final ?? model.state.ruleFinal ?? .selected },
                            set: { ref in beginDraft();draft.final=ref }
                        )
                    )
                    .frame(width: 220)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .disabled(model.locked)
                
                // 所有自定义规则修改先留在草稿中，点击应用时统一重连一次。
                HStack {
                    Text(draft.rules == nil ? "拖动、添加和删除仅修改草稿，不影响当前连接；越靠上越先匹配。":"规则草稿尚未应用，当前代理继续使用原配置。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let rules=draft.rules,let revision=draft.revision {
                        Button("撤销草稿") {resetDraft()}.disabled(model.locked)
                        Button(model.connection == .connected ? "应用规则（重新连接一次）":"保存规则") {
                            let final=draft.final ?? .selected
                            Task {if await model.applyRuleDraft(rules,final:final,revision:revision) {resetDraft()}}
                        }.buttonStyle(.borderedProminent).disabled(model.locked)
                    }
                }
                if displayedRules.isEmpty {
                    ContentUnavailableView("暂无自定义规则",systemImage:"arrow.triangle.branch",description:Text("在上方添加规则草稿后点击保存。"))
                } else {
                    List {
                        ForEach(displayedRules) { rule in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .help("拖动此行调整规则顺序")
                                .accessibilityLabel("拖动调整规则顺序")
                            ruleKindBadge(rule.kind)
                            
                            Text(rule.value)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            
                            Spacer()
                            
                            ruleTargetBadge(rule.target ?? (rule.action == .direct ? .direct : rule.action == .reject ? .reject : .selected))
                            
                            HStack(spacing: 4) {
                                if (rule.target ?? (rule.action == .direct ? .direct:.selected)) == .direct,[RuleKind.domain,.suffix,.cidr].contains(rule.kind) {
                                    Button("转为绕过…") {conversion=rule}
                                        .disabled(draft.rules != nil)
                                        .help("先应用或撤销普通规则草稿，再转换已保存的规则")
                                }

                                Button {
                                    previewStep(rule.id,by:-1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                
                                Button {
                                    previewStep(rule.id,by:1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                
                                Button(role: .destructive) {
                                    beginDraft();draft.rules!.removeAll{$0.id==rule.id}
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                        .disabled(model.locked)
                        }
                        .onMove { source, destination in
                            previewMove(from:source,to:destination)
                        }
                        .moveDisabled(model.locked)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                }
            } else {
                // Remote Rule Providers View
                HStack {
                    Text("远程规则集支持域名/IP列表、Clash YAML payload 以及兼容的 sing-box rule-set。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addingRemote = true
                    } label: {
                        Label("添加远程规则集", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.locked)
                }
                
                if model.state.remoteRules.isEmpty {
                    ContentUnavailableView(
                        "暂无远程规则集",
                        systemImage: "link",
                        description: Text("点击右上角添加远程 HTTPS 规则文件源。")
                    )
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(model.state.remoteRules) { source in
                                remoteRuleCard(source)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented:$showingText) {
            if let text=draft.text {
                RuleTextEditor(app:model,text:text,rules:displayedRules,final:draft.final,baselineText:draft.textBaseline,onTextChange:{draft.text=$0},onDiscard:{draft.discardText()}) {rules in
                    beginDraft();draft.rules=rules;draft.discardText()
                }
            }
        }
        .sheet(item:$conversion) {rule in
            DraftEditorSheet(draft:model.drafts.bypass(profile:model.currentProfileID,items:model.state.effectiveBypasses,revision:try? model.bypassRevision(),corporateDNS:model.state.trustedCorporateDNS ?? []),store:model.drafts,title:"转换网络绕过") {
                NetworkBypassView(model:model,conversion:rule)
            }.padding(20).frame(minWidth:850,minHeight:650)
        }
        .sheet(isPresented: $addingRemote) { RemoteEditor(model: model) }
    }
    
    private func ruleKindBadge(_ kind: RuleKind) -> some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .domain: return ("DOMAIN", Theme.accentBlue)
            case .suffix: return ("SUFFIX", Theme.purpleAccent)
            case .keyword: return ("KEYWORD", Theme.cyanAccent)
            case .cidr: return ("IP-CIDR", Theme.amberAccent)
            case .match: return ("MATCH", Theme.connectedGreen)
            case .geoip: return ("GEOIP", Theme.connectedGreen)
            case .asn: return ("IP-ASN", Theme.amberAccent)
            case .userAgent: return ("USER-AGENT", Theme.purpleAccent)
            }
        }()
        
        return Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(width: 75, alignment: .center)
    }
    
    private func ruleTargetBadge(_ target: PolicyReference) -> some View {
        let (label, color): (String, Color) = {
            switch target {
            case .direct: return ("直接连接", Theme.connectedGreen)
            case .reject: return ("拦截丢弃", Theme.dangerRed)
            case .selected: return ("当前代理", Theme.accentBlue)
            case .group: return (model.state.label(target), Theme.purpleAccent)
            default: return (model.state.label(target), Color.secondary)
            }
        }()
        
        return Text(label)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
    
    private func remoteRuleCard(_ source: RemoteRuleSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(source.name).font(.headline)
                        Text("\(source.rules.count) 条规则")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    Text("最近更新：\(source.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未更新")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Toggle("自动更新", isOn: Binding(get: { source.autoUpdate }, set: { auto in Task { await model.updateRemote(source.id, auto: auto) } }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    
                    Button {
                        Task { await model.refreshRemote(source.id) }
                    } label: {
                        Label("立即更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button {
                        Task { await model.moveRemote(source.id, by: -1) }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button {
                        Task { await model.moveRemote(source.id, by: 1) }
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(role: .destructive) {
                        Task { await model.deleteRemote(source.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            HStack(spacing: 8) {
                Text("规则集命中动作：")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                RuleTargetPicker(
                    state: model.state,
                    target: Binding(get: { source.target }, set: { ref in Task { await model.updateRemote(source.id, target: ref) } })
                )
                .frame(width: 240)
            }
            
            if let error = source.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                }
                .font(.caption)
                .foregroundStyle(Theme.amberAccent)
            }
        }
        .padding(14)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Theme.subtleBorder, lineWidth: 1)
        )
    }
}

// MARK: - Modern Remote Editor
struct RemoteEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var url = ""
    @State private var target = PolicyReference.selected
    @State private var error: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加远程规则集").font(.title2.bold())
            
            VStack(spacing: 12) {
                TextField("规则集名称（例如 去广告、直连域名列表等）", text: $name)
                    .textFieldStyle(.roundedBorder)
                SecureField("HTTPS 规则集下载地址", text: $url)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Text("统一生效策略：")
                    RuleTargetPicker(state: model.state, target: $target)
                }
            }
            
            Text("规则文件上限 2 MiB / 50,000 条规则。文件 URL 将加密存储在钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.dangerRed)
            }
            
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(model.busy)
                Spacer()
                Button("下载并添加") {
                    Task {
                        await model.addRemote(name: name, url: url, target: target)
                        if model.errorMessage == nil { dismiss() } else { error = model.errorMessage }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.locked || name.isEmpty || url.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 560)
    }
}
