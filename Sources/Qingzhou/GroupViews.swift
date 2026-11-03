import SwiftUI
import QingzhouKit

struct GroupRequest: Identifiable {
    let id = UUID()
    var group: PolicyGroup?
}

struct GroupsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: GroupRequest?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "策略组管理",
                subtitle: "支持手动选择 (Select)、延迟自动优选 (URL-Test) 以及故障回退 (Fallback)。修改选择即刻生效于新连接。",
                actionTitle: "新建策略组",
                actionIcon: "plus.circle.fill"
            ) {
                editing = GroupRequest(group: nil)
            }
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    // Automatic Core Group Card
                    automaticGroupCard
                    
                    // User Custom Groups
                    if model.state.groups.isEmpty {
                        ContentUnavailableView(
                            "暂无自定义策略组",
                            systemImage: "square.stack.3d.up",
                            description: Text("点击右上角「新建策略组」或从 Clash/Mihomo 订阅导入分组。")
                        )
                    } else {
                        ForEach(model.state.groups) { group in
                            groupCard(group)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { request in
            GroupEditor(model: model, group: request.group)
        }
    }
    
    // Automatic Policy Group Card
    private var automaticGroupCard: some View {
        let isSelected = model.state.activePolicy == .automatic
        
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.accentBlue.opacity(0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: "bolt.badge.automatic.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accentBlue)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("系统自动优选 (Auto)")
                            .font(.headline)
                        Text("核心算法")
                            .font(.caption2.bold())
                            .foregroundStyle(Theme.accentBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accentBlue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text("覆盖全部节点 · 每 5 分钟定时测速 · 50 ms 抖动容差")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("当前主选：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.actualName)
                            .font(.caption.bold())
                            .foregroundStyle(Theme.accentBlue)
                    }
                    
                    Button {
                        Task { await model.selectPolicy(.automatic) }
                    } label: {
                        Text(isSelected ? "已选为主策略" : "设为主策略")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentBlue)
                    .controlSize(.small)
                    .disabled(model.locked || model.state.nodes.isEmpty)
                }
            }
        }
        .padding(14)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(isSelected ? Theme.accentBlue.opacity(0.5) : Theme.subtleBorder, lineWidth: isSelected ? 1.5 : 1)
        )
    }
    
    // Custom Policy Group Card
    private func groupCard(_ group: PolicyGroup) -> some View {
        let isSelected = model.state.activePolicy == .group(group.id)
        
        return VStack(alignment: .leading, spacing: 12) {
            // 策略组摘要
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(group.name)
                            .font(.headline)
                        
                        groupKindBadge(group.kind)
                        
                        if group.subscriptionID != nil {
                            Text("订阅来源")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text("\(group.members.count) 个成员" + (group.kind == .fallback ? " · 优先级回退机制" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button {
                        Task { await model.selectPolicy(.group(group.id)) }
                    } label: {
                        Text(isSelected ? "已作为主策略" : "设为主策略")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentBlue)
                    .controlSize(.small)
                    
                    Button("编辑") {
                        editing = GroupRequest(group: group)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(role: .destructive) {
                        Task { await model.deleteGroup(group.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            Divider().opacity(0.5)
            
            // 成员选择
            if group.kind == .select {
                VStack(alignment: .leading, spacing: 6) {
                    Text("点击快速切换组内成员节点：")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    // 成员标签列表
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(group.members, id: \.self) { member in
                                let isMemberActive = (group.selected ?? group.members.first) == member
                                Button {
                                    Task { await model.selectMember(group, member) }
                                } label: {
                                    HStack(spacing: 5) {
                                        if isMemberActive {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Theme.accentBlue)
                                        }
                                        Text(model.state.label(member))
                                            .font(.system(size: 12, weight: isMemberActive ? .semibold : .regular))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(isMemberActive ? Theme.accentBlue.opacity(0.14) : Color.secondary.opacity(0.08))
                                    .foregroundStyle(isMemberActive ? Theme.accentBlue : Color.primary)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(isMemberActive ? Theme.accentBlue.opacity(0.4) : Color.clear, lineWidth: 1)
                                    )
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .contentShape(Capsule())
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text("当前自动选中：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.proxyInfo[PolicyReference.group(group.id).tag]?.now.map { model.label($0) } ?? "测速判定中...")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accentBlue)
                }
            }
        }
        .padding(14)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(isSelected ? Theme.accentBlue.opacity(0.5) : Theme.subtleBorder, lineWidth: isSelected ? 1.5 : 1)
        )
    }
    
    private func groupKindBadge(_ kind: GroupKind) -> some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .select: return ("手动选择", Theme.accentBlue)
            case .urltest: return ("自动优选", Theme.purpleAccent)
            case .fallback: return ("故障回退", Theme.amberAccent)
            }
        }()
        
        return Text(label)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - 策略组编辑器
struct GroupEditor: View {
    @ObservedObject var model: AppModel
    var group: PolicyGroup?
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var kind = GroupKind.select
    @State private var members = Set<PolicyReference>()
    @State private var priority: [PolicyReference] = []
    @State private var error: String?
    
    private var options: [PolicyReference] {
        model.state.nodes.map { .node($0.id) } +
        (kind == .fallback ? [] : model.state.groups.filter { $0.id != group?.id }.map { .group($0.id) } + (!model.state.nodes.isEmpty ? [.automatic] : []) + [.direct])
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(group == nil ? "新建策略组" : "编辑策略组")
                .font(.title2.bold())
            
            VStack(alignment: .leading, spacing: 12) {
                TextField("策略组名称（例如 默认代理、流媒体、游戏等）", text: $name)
                    .textFieldStyle(.roundedBorder)
                
                Picker("策略组调度类型", selection: $kind) {
                    Text("手动选择 (Select)").tag(GroupKind.select)
                    Text("自动优选 (URL-Test 50ms 容差)").tag(GroupKind.urltest)
                    Text("优先级回退 (Fallback 连续失败切换)").tag(GroupKind.fallback)
                }
            }
            
            Text("勾选策略组成员：")
                .font(.headline)
            
            List(options, id: \.self) { ref in
                Toggle(isOn: Binding(
                    get: { members.contains(ref) },
                    set: {
                        if $0 {
                            members.insert(ref)
                            if !priority.contains(ref) { priority.append(ref) }
                        } else {
                            members.remove(ref)
                            priority.removeAll { $0 == ref }
                        }
                    }
                )) {
                    Text(model.state.label(ref))
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            if kind == .fallback {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fallback 成员优先级由上至下（通过上下移动调整）：")
                        .font(.caption.bold())
                    
                    List(priority.filter { members.contains($0) && options.contains($0) }, id: \.self) { ref in
                        HStack {
                            Text(model.state.label(ref))
                            Spacer()
                            Button("上移") { move(ref, -1) }.controlSize(.small)
                            Button("下移") { move(ref, 1) }.controlSize(.small)
                        }
                    }
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            
            if let error {
                Text(error)
                    .foregroundStyle(Theme.dangerRed)
                    .font(.caption)
            }
            
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存策略组") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.locked || members.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 580)
        .onAppear {
            if let group {
                name = group.name
                kind = group.kind
                members = Set(group.members)
                priority = group.members
            }
        }
    }
    
    private func move(_ ref: PolicyReference, _ offset: Int) {
        guard let index = priority.firstIndex(of: ref), priority.indices.contains(index + offset) else { return }
        priority.swapAt(index, index + offset)
    }
    
    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { error = "名称不能为空"; return }
        let ordered = kind == .fallback ? priority.filter { members.contains($0) && options.contains($0) } : options.filter { members.contains($0) }
        var candidate = PolicyGroup(id: group?.id ?? UUID(), name: name, kind: kind, members: ordered, selected: ordered.first, subscriptionID: group?.subscriptionID)
        if let selected = group?.selected, ordered.contains(selected) { candidate.selected = selected }
        var next = model.state
        next.groups.removeAll { $0.id == candidate.id }
        next.groups.append(candidate)
        do {
            try PolicyValidator.validate(next)
        } catch {
            self.error = error.localizedDescription
            return
        }
        Task {
            if await model.saveGroup(candidate) { dismiss() } else { error = model.errorMessage }
        }
    }
}
