import SwiftUI
import QingzhouKit

// MARK: - Modern Import Sheet
struct ImportSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("导入节点或订阅配置", systemImage: "link.badge.plus")
                    .font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Text("支持粘贴单节点链接 (ss://, vless://, hysteria2://, trojan://)、HTTPS 订阅 URL、Base64 编码列表或完整的 Clash / Mihomo YAML。")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextEditor(text: $input)
                .font(.system(.body, design: .monospaced))
                .frame(height: 200)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.subtleBorder, lineWidth: 1)
                )
            
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.connectedGreen)
                    Text("订阅 URL 及节点凭据安全保存在系统钥匙串，不写入磁盘明文或日志。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button("取消") {
                    input = ""
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Button("智能解析并预览") {
                    let value = input
                    input = ""
                    dismiss()
                    Task { await model.importPreview(value) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.locked)
            }
        }
        .padding(26)
        .frame(width: 660)
    }
}

// MARK: - Modern Preview Sheet
struct PreviewSheet: View {
    @ObservedObject var model: AppModel
    @State private var scope = ImportScope.nodes
    @State private var confirmedInsecure = false
    @State private var confirmedSkipping = false
    
    private var insecure: Bool { model.preview?.candidates.contains { $0.node.insecure } == true }
    private var issues: [String] { model.preview?.unsupported ?? [] }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("配置变更确认与预览")
                    .font(.title2.bold())
                Spacer()
                Text("\(model.preview?.candidates.count ?? 0) 个兼容节点 · \(model.preview?.groups.count ?? 0) 个策略组")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accentBlue.opacity(0.12))
                    .clipShape(Capsule())
            }
            
            if let diff = model.previewDiff {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Theme.accentBlue)
                        Text("检测到版本差异：新增 \(diff.added.count) · 移除 \(diff.removed.count) · 参数变更 \(diff.changed.count)")
                            .font(.caption.bold())
                    }
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if !diff.added.isEmpty {
                                Text("新增节点：" + diff.added.joined(separator: "、")).font(.caption)
                            }
                            if !diff.removed.isEmpty {
                                Text("移除节点：" + diff.removed.joined(separator: "、")).font(.caption).foregroundStyle(Theme.dangerRed)
                            }
                            if !diff.changed.isEmpty {
                                Text("更新节点：" + diff.changed.joined(separator: "、")).font(.caption)
                            }
                            if !diff.ambiguousNodes.isEmpty {Text("节点身份有歧义，不继承个人信息："+diff.ambiguousNodes.joined(separator:"、")).font(.caption).foregroundStyle(Theme.amberAccent)}
                            if diff.ruleChanges {Text("规则行为发生变化（包含 no-resolve），将按新规则顺序生效。").font(.caption)}
                            if diff.strategyChanges {Text("策略组发生变化。").font(.caption)}
                            if diff.compatibilityChanges {Text("HTTP 重写、兼容配置或规则资产发生变化；兼容模式开关保留当前设置。").font(.caption).foregroundStyle(Theme.amberAccent)}
                            if diff.removesSelection {
                                Text("当前选中节点将在更新后被移除，系统将提示重新选择。").font(.caption.bold()).foregroundStyle(Theme.amberAccent)
                            }
                        }
                    }
                    .frame(maxHeight: 90)
                }
                .padding(12)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            Picker("导入范围", selection: $scope) {
                Text("仅导入兼容节点").tag(ImportScope.nodes)
                Text("完整导入（包含策略组与规则）").tag(ImportScope.profile)
            }
            .pickerStyle(.segmented)
            
            List(model.preview?.candidates ?? [], id: \.node.id) { c in
                HStack(spacing: 8) {
                    ProtocolBadge(kind: c.node.kind)
                    Text(c.node.name).font(.subheadline.bold())
                    Spacer()
                    Text("\(c.node.server):\(c.node.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if c.node.insecure {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(Theme.amberAccent)
                    }
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("检测到不支持或不兼容的配置项（已自动忽略）：", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.amberAccent)
                    ScrollView {
                        Text(issues.joined(separator: "\n"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: 70)
                    
                    if scope == .nodes {
                        Toggle("仅导入兼容节点，确认忽略不支持的项", isOn: $confirmedSkipping)
                            .font(.caption)
                    }
                }
                .padding(10)
                .background(Theme.amberAccent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            if insecure {
                Toggle("我已知悉部分节点跳过 TLS 证书校验，并确认保留该设置", isOn: $confirmedInsecure)
                    .font(.caption)
                    .foregroundStyle(Theme.amberAccent)
            }
            
            HStack {
                Button("取消") { model.cancelPreview() }
                    .buttonStyle(.bordered)
                    .disabled(model.busy)
                
                Spacer()
                
                Button("确认导入并应用") {
                    Task { await model.confirmImport(scope: scope) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.locked ||
                    model.preview?.candidates.isEmpty != false ||
                    (insecure && !confirmedInsecure) ||
                    (scope == .profile && !issues.isEmpty) ||
                    (scope == .nodes && !issues.isEmpty && !confirmedSkipping)
                )
            }
        }
        .padding(26)
        .frame(width: 680)
    }
}

// MARK: - Modern Subscriptions View
struct SubscriptionsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: Subscription?
    @State private var name = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "订阅管理",
                subtitle: "支持 HTTPS 远程订阅定时自动更新（默认每 24 小时检查一次）。",
                actionTitle: "更新全部订阅",
                actionIcon: "arrow.clockwise"
            ) {
                Task { await model.refreshAll() }
            }
            
            if model.state.subscriptions.isEmpty {
                ContentUnavailableView(
                    "暂无远程订阅",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("请在节点页面点击「链接导入」粘贴 HTTPS 订阅链接。")
                )
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(model.state.subscriptions) { sub in
                            subscriptionCard(sub)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { sub in
            VStack(alignment: .leading, spacing: 18) {
                Text("修改订阅名称").font(.title2.bold())
                TextField("订阅名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("取消") { editing = nil }
                    Spacer()
                    Button("保存") {
                        model.updateSubscription(sub.id, name: name)
                        if model.errorMessage == nil { editing = nil }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(26)
            .frame(width: 420)
        }
    }
    
    private func subscriptionCard(_ sub: Subscription) -> some View {
        let nodeCount = model.state.nodes.filter { $0.subscriptionID == sub.id }.count
        let (used, total) = extractUsageBytes(sub.usage)
        
        return VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(sub.name)
                            .font(.headline)
                        
                        Text(sub.scope == .nodes ? "节点订阅" : "完整配置")
                            .font(.caption2.bold())
                            .foregroundStyle(Theme.accentBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accentBlue.opacity(0.12))
                            .clipShape(Capsule())
                        
                        Text("\(nodeCount) 个节点")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    
                    Text("最近更新：\(sub.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Toggle("自动更新", isOn: Binding(get: { sub.autoUpdate }, set: { model.updateSubscription(sub.id, auto: $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    
                    Button("重命名") {
                        name = sub.name
                        editing = sub
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button {
                        Task { await model.refresh(sub) }
                    } label: {
                        Label(sub.pendingReview ? "预览差异" : "更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(sub.pendingReview ? Theme.amberAccent : Theme.accentBlue)
                    .controlSize(.small)
                    
                    Button(role: .destructive) {
                        Task { await model.deleteSubscription(sub.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            Divider().opacity(0.5)
            
            // Usage Progress Bar & Expiration
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("流量用量配额：")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(formatUsageSummary(sub.usage))
                        .font(.caption)
                    Spacer()
                    if let expiry = extractExpiry(sub.usage) {
                        Text("到期时间：\(expiry)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if total != nil {
                    UsageProgressBar(usedBytes: used, totalBytes: total)
                }
            }
            
            if let error = sub.lastError {
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
                .stroke(sub.pendingReview ? Theme.amberAccent.opacity(0.5) : Theme.subtleBorder, lineWidth: 1)
        )
    }
    
    private func extractUsageBytes(_ info: UsageInfo?) -> (Int64?, Int64?) {
        guard let info else { return (nil, nil) }
        let used: Int64?
        if let u = info.upload, let d = info.download {
            let sum = u.addingReportingOverflow(d)
            used = sum.overflow ? nil : Int64(clamping: sum.partialValue)
        } else {
            used = nil
        }
        let total = info.total.map { Int64(clamping: $0) }
        return (used, total)
    }
    
    private func formatUsageSummary(_ info: UsageInfo?) -> String {
        guard let info else { return "服务端未提供用量信息" }
        let (used, total) = extractUsageBytes(info)
        let usedStr = used != nil ? bytes(used!) : "未知"
        let totalStr = total != nil ? bytes(total!) : "未知"
        if let u = used, let t = total, t > 0 {
            let pct = String(format: "%.1f%%", (Double(u) / Double(t)) * 100)
            return "\(usedStr) / \(totalStr) (\(pct))"
        }
        return "\(usedStr) / \(totalStr)"
    }
    
    private func extractExpiry(_ info: UsageInfo?) -> String? {
        guard let info, let exp = info.expire, exp.isFinite, exp > 0 else { return nil }
        return Date(timeIntervalSince1970: exp).formatted(date: .abbreviated, time: .omitted)
    }
}
