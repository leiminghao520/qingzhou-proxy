import SwiftUI
import QingzhouKit

// 首页与独立线路页共享列表，偏好只影响展示，不修改代理配置。
struct DailyLinesView: View {
    @ObservedObject var model: AppModel
    var onImport: () -> Void
    var onEdit: (Node) -> Void
    var onProfessional: () -> Void
    @AppStorage("dailyLineSort") private var sort = "最近使用"
    @StateObject private var page = NodeListViewModel()
    @State private var detail: Node?
    @State private var pendingEdit: Node?
    @State private var frozenOrder: [UUID] = []
    @FocusState private var searchFocused: Bool

    private var nodes: [Node] {
        let result = page.nodes(state: model.state, invalidatedAt: model.latencyInvalidatedAt,
                                now: Date(), profile: model.currentProfileID, simple: true)
        guard model.measuring, !frozenOrder.isEmpty else { return result }
        let ranks = Dictionary(uniqueKeysWithValues: frozenOrder.enumerated().map { ($0.element, $0.offset) })
        return result.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("线路").font(.headline)
                Text("\(nodes.count) / \(model.state.nodes.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("添加", action: onImport).disabled(model.locked)
            }
            HStack(spacing: 8) {
                TextField("搜索线路或备注", text: $page.query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityIdentifier("dailyLineSearch")
                Toggle("收藏", isOn: $page.favoriteOnly).toggleStyle(.button)
                Picker("排序", selection: $sort) {
                    ForEach(["最近使用", "HTTPS 延迟", "节点名称"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 120).disabled(model.measuring)
            }
            HStack {
                Button {
                    if model.measuring { model.cancelMeasurement() }
                    else { frozenOrder = nodes.map(\.id); model.measure(nodes.map(\.id)) }
                } label: {
                    Label(model.measurementCancelling ? "正在取消…" : model.measuring ? "取消检测" : "检测当前列表", systemImage: "bolt")
                }
                .disabled(model.measurementCancelling || (!model.measuring && (model.locked || nodes.isEmpty)))
                .accessibilityIdentifier("dailyMeasureButton")
                if model.measuring {
                    Text(model.measurementProgress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("HTTPS 延迟 · 非下载速度").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            SelectionFeedbackView(model: model)
            Button { Task { await model.selectPolicy(.automatic) } } label: {
                HStack {
                    Image(systemName: "bolt.badge.automatic")
                    Text("自动选择")
                    if model.state.activePolicy == .automatic, model.connection == .connected {
                        Text("→ " + model.actualName).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if model.currentSelectionStatus?.active == true, model.currentSelectionStatus?.target == .automatic {
                        ProgressView().controlSize(.small)
                    } else if model.state.activePolicy == .automatic { Image(systemName: "checkmark.circle.fill") }
                }.padding(10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .liquidControl(in: RoundedRectangle(cornerRadius: 10), tint: Theme.accentBlue.opacity(0.08))
            .disabled(model.locked || model.state.nodes.isEmpty)
            if case .group = model.state.activePolicy {
                HStack {
                    Text("策略组：" + model.selectedName).font(.caption).lineLimit(1)
                    Spacer()
                    Button("管理策略组", action: onProfessional)
                }
            }
            if model.state.nodes.isEmpty {
                ContentUnavailableView {
                    Label("还没有线路", systemImage: "network")
                } description: { Text("添加订阅或节点后即可连接。") }
                actions: { Button("添加订阅或节点", action: onImport).disabled(model.locked) }
            } else if nodes.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的线路", systemImage: "magnifyingglass")
                } description: { Text("试试其他关键词，或关闭收藏筛选。") }
                actions: { Button("清除筛选") { page.clearFilters() } }
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(nodes) { node in line(node) }
                    }.padding(.vertical, 2)
                }.accessibilityIdentifier("dailyLineList")
            }
        }
        .onAppear { page.sort = sort }
        .onChange(of: sort) { _, value in page.sort = value }
        .onChange(of: model.measuring) { _, measuring in
            if measuring { frozenOrder = page.nodes(state: model.state, invalidatedAt: model.latencyInvalidatedAt, now: Date(), profile: model.currentProfileID, simple: true).map(\.id) }
            else { frozenOrder = [] }
        }
        .background {
            Button("搜索线路") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .sheet(item: $detail, onDismiss: {
            if let node = pendingEdit { pendingEdit = nil; onEdit(node) }
        }) { node in
            VStack(alignment: .leading, spacing: 16) {
                Text(node.name).font(.title2.bold()).textSelection(.enabled)
                LabeledContent("协议", value: node.kind.rawValue.uppercased())
                LabeledContent("服务器", value: node.server)
                LabeledContent("端口", value: String(node.port))
                LabeledContent("来源",value:NodeSubscriptionSupport.source(node,state:model.state))
                if let guidance=NodeSubscriptionSupport.guidance(node,state:model.state){Text(guidance).font(.caption).foregroundStyle(Theme.amberAccent)}
                Text(LatencyPresentation.label(model.state.latency[node.id.uuidString], invalidatedAt: model.latencyInvalidatedAt))
                    .font(.caption).foregroundStyle(.secondary)
                if let note = model.state.notes[node.id.uuidString], !note.isEmpty { Text(note) }
                HStack {
                    Button("编辑线路") { pendingEdit = node; detail = nil }.disabled(model.locked)
                    Spacer()
                    Button("完成") { detail = nil }.keyboardShortcut(.cancelAction)
                }
            }.padding(24).frame(width: 480)
        }
    }

    private func line(_ node: Node) -> some View {
        let selected = model.state.activePolicy == .node(node.id)
        let switching = model.currentSelectionStatus?.active == true && model.currentSelectionStatus?.target == .node(node.id)
        return HStack(spacing: 10) {
            Button { Task { await model.select(node.id) } } label: {
                HStack(spacing: 10) {
                    if switching { ProgressView().controlSize(.small).frame(width: 18) }
                    else { Image(systemName: selected ? "checkmark.circle.fill" : "circle").frame(width: 18) }
                    VStack(alignment:.leading,spacing:3) {
                        Text(node.name).font(.body.weight(selected ? .semibold : .regular)).lineLimit(2).help(node.name)
                        Text(NodeSubscriptionSupport.source(node,state:model.state)).font(.caption2).foregroundStyle(.secondary)
                        if let guidance=NodeSubscriptionSupport.guidance(node,state:model.state){Text(guidance).font(.caption2).foregroundStyle(Theme.amberAccent).lineLimit(2)}
                    }
                    Spacer(minLength: 8)
                    Text(delayLabel(node)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.locked)
            .foregroundStyle(selected ? Theme.accentBlue : Color.primary)
            .accessibilityLabel("选择线路：" + node.name)
            .accessibilityValue(switching ? "切换中" : selected ? "已选中" : "未选中")
            Button { model.toggleFavorite(node.id) } label: {
                Image(systemName: model.state.favorites.contains(node.id) ? "star.fill" : "star")
                    .foregroundStyle(model.state.favorites.contains(node.id) ? Theme.amberAccent : Color.secondary)
            }.buttonStyle(.borderless).disabled(model.locked)
                .accessibilityLabel((model.state.favorites.contains(node.id) ? "取消收藏：" : "收藏：") + node.name)
            Menu {
                Button("检测此节点延迟") { frozenOrder = nodes.map(\.id); model.measure([node.id]) }.disabled(model.locked)
                Button("线路详情") { detail = node }
                Button("编辑线路") { onEdit(node) }.disabled(model.locked)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("线路操作：" + node.name)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? Theme.accentBlue.opacity(0.07) : Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func delayLabel(_ node: Node) -> String {
        guard let result = model.state.latency[node.id.uuidString] else { return "未检测" }
        let value = result.milliseconds.map { "\($0) ms" } ?? "检测失败"
        return LatencyPresentation.current(result, invalidatedAt: model.latencyInvalidatedAt) ? value : "历史 · " + value
    }
}
