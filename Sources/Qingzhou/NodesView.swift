import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

struct NodesView: View {
    @ObservedObject var model: AppModel
    var onEdit: (Node) -> Void
    var onAdd: () -> Void
    var onImport: () -> Void

    @State private var noteNode: Node?
    @State private var note = ""
    @State private var sharing: ShareRequest?
    @State private var deleting = false

    @StateObject private var page=NodeListViewModel()
    private var filteredNodes:[Node] {page.nodes(state:model.state,invalidatedAt:model.latencyInvalidatedAt,now:max(model.latencyClock,Date()),profile:model.currentProfileID)}

    var body: some View {
        let filteredNodes=filteredNodes
        VStack(alignment: .leading, spacing: 16) {
            // 标题和主要操作
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("代理节点")
                        .font(.title2.bold())
                    Text("\(model.state.nodes.count) 个")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accentBlue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Theme.accentBlue.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                HStack(spacing: 10) {
                    // 全部节点延迟检测
                    Button {
                        if model.measuring { model.cancelMeasurement() }
                        else { model.measure() }
                    } label: {
                        Label(model.measuring ? "取消测速" : "一键测速", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.busy || model.state.nodes.isEmpty)

                    // 新增和导入菜单
                    Menu {
                        Button { onAdd() } label: {
                            Label("手动添加节点", systemImage: "plus")
                        }
                        Button { chooseFile() } label: {
                            Label("从本地文件导入", systemImage: "doc")
                        }
                        Button { onImport() } label: {
                            Label("从链接 / 订阅导入", systemImage: "link")
                        }
                    } label: {
                        Label("添加节点", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    // 排序选择
                    Picker("排序", selection: $page.sort) {
                        ForEach(["HTTPS 延迟", "节点名称", "协议", "最近使用"], id: \.self) { Text($0) }
                    }
                    .frame(width: 140)

                    // 保留用户视图偏好，同时明确按钮的当前状态与操作结果。
                    Toggle(isOn: Binding(get: { model.state.compactNodes }, set: { model.setCompact($0) })) {
                        Label(model.state.compactNodes ? "列表" : "卡片",systemImage:model.state.compactNodes ? "list.bullet" : "square.grid.2x2")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel("节点视图")
                    .accessibilityValue(model.state.compactNodes ? "紧凑列表":"卡片")
                    .help(model.state.compactNodes ? "切换到卡片视图":"切换到紧凑列表")
                    .controlSize(.regular)
                }
            }

            // 搜索和协议筛选
            HStack(spacing: 14) {
                // 搜索输入
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索节点名称、服务器或备注...", text: $page.query)
                        .textFieldStyle(.plain)
                    if !page.query.isEmpty {
                        Button { page.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(width: 260)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // 协议筛选标签保持单行
                HStack(spacing: 8) {
                    filterChip("全部", active: page.selectedKind == nil && !page.favoriteOnly) {
                        page.selectedKind = nil; page.favoriteOnly = false
                    }
                    filterChip("★ 收藏", active: page.favoriteOnly) {
                        page.favoriteOnly.toggle()
                    }
                    filterChip("HY2", active: page.selectedKind == .hysteria2) {
                        toggleKind(.hysteria2)
                    }
                    filterChip("VLESS", active: page.selectedKind == .vless) {
                        toggleKind(.vless)
                    }
                    filterChip("SS", active: page.selectedKind == .shadowsocks) {
                        toggleKind(.shadowsocks)
                    }
                    filterChip("Trojan", active: page.selectedKind == .trojan) {
                        toggleKind(.trojan)
                    }
                }

                Spacer()
            }

            // 已选节点的批量操作
            if !page.selection.isEmpty {
                HStack(spacing: 12) {
                    Text("已选择 \(page.selection.count) 个节点")
                        .font(.caption.bold())
                    Button("设为收藏") { model.batchFavorite(page.selection, value: true) }
                    Button("取消收藏") { model.batchFavorite(page.selection, value: false) }
                    Button("批量测速") { model.measure(Array(page.selection)) }
                    Button("删除所选", role: .destructive) { deleting = true }
                    Spacer()
                    Button("取消多选") { page.selection.removeAll() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.accentBlue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(model.locked)
            }

            if model.measuring {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.measurementProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 节点网格或列表
            if filteredNodes.isEmpty {
                ContentUnavailableView {
                    Label(model.state.nodes.isEmpty ? "还没有任何节点":"没有找到符合条件的节点",systemImage:"network.slash")
                } description: {
                    Text(model.state.nodes.isEmpty ? "点击右上角添加节点或订阅。":"试试其他关键词、协议，或关闭收藏筛选。")
                } actions: {
                    if !model.state.nodes.isEmpty {Button("清除筛选") {page.clearFilters()}}
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.state.compactNodes {
                // 节点卡片网格
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 16)], spacing: 16) {
                        ForEach(filteredNodes) { node in
                            nodeCard(node)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                // 紧凑列表
                List(filteredNodes, selection: $page.selection) { node in
                    nodeRow(node)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            }
        }
        .sheet(item: $sharing) { request in ShareView(model: model, node: request.node) }
        .sheet(item: $noteNode) { node in
            VStack(spacing: 18) {
                Text("个人备注").font(.headline)
                TextEditor(text: $note).frame(height: 120)
                if let message=model.issueTitle {Text(message).font(.caption).foregroundStyle(.red)}
                HStack {
                    Button("取消") { noteNode = nil }
                    Spacer()
                    Button("保存备注") {
                        if model.saveNote(node.id, note: note) { noteNode = nil }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
        .confirmationDialog("确认删除所选节点？", isPresented: $deleting) {
            Button("确认批量删除", role: .destructive) {
                let ids = page.selection
                page.selection = []
                Task { await model.batchDelete(ids) }
            }
        } message: {
            Text("所选节点将从当前配置中彻底移除。")
        }
    }

    private func toggleKind(_ kind: ProxyKind) {
        if page.selectedKind == kind { page.selectedKind = nil } else { page.selectedKind = kind }
    }

    private func filterChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(active ? Theme.accentBlue.opacity(0.18) : Color.secondary.opacity(0.08))
                .foregroundStyle(active ? Theme.accentBlue : Color.primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(active ? Theme.accentBlue.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "选择节点列表或 Clash/Mihomo YAML"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { await model.importFile(url) }
            }
        }
    }

    // 节点卡片
    private func nodeCard(_ node: Node) -> some View {
        let isSelected = model.state.activePolicy == .node(node.id)
        let isFav = model.state.favorites.contains(node.id)

        return VStack(alignment: .leading, spacing: 12) {
            // 协议、证书警告、收藏和选中状态
            HStack(spacing: 8) {
                ProtocolBadge(kind: node.kind)

                if node.insecure {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.amberAccent)
                        .help("此节点跳过 TLS 证书验证")
                }

                Spacer()

                Button {
                    model.toggleFavorite(node.id)
                } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(isFav ? Theme.amberAccent : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.connectedGreen)
                        .font(.system(size: 16))
                }
            }

            // 节点名称和服务器地址
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text(NodeSubscriptionSupport.source(node,state:model.state)).font(.caption2).foregroundStyle(.secondary)
                if let guidance=NodeSubscriptionSupport.guidance(node,state:model.state){Text(guidance).font(.caption2).foregroundStyle(Theme.amberAccent)}
                Text("\(node.server):\(node.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let note = model.state.notes[node.id.uuidString], !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.accentBlue)
                        .lineLimit(1)
                }
            }

            Divider().opacity(0.5)

            // 延迟及快捷操作
            HStack {
                LatencyBadge(delayText: latency(node, model))

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        model.measure([node.id])
                    } label: {
                        Image(systemName: "bolt")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Menu {
                        Button("分享节点") { sharing = ShareRequest(node: node) }
                        Button("修改备注") {
                            note = model.state.notes[node.id.uuidString] ?? ""
                            noteNode = node
                        }
                        if node.subscriptionID == nil {
                            Button("编辑节点") { onEdit(node) }
                        }
                        Divider()
                        Button("删除节点", role: .destructive) {
                            Task { await model.deleteNode(node.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .background(isSelected ? Theme.connectedGreen.opacity(0.06) : Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(isSelected ? Theme.connectedGreen.opacity(0.6) : Theme.subtleBorder, lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.select(node.id) }
        }
    }

    // 列表行
    private func nodeRow(_ node: Node) -> some View {
        let isSelected = model.state.activePolicy == .node(node.id)
        let isFav = model.state.favorites.contains(node.id)

        return HStack(spacing: 12) {
            Button {
                Task { await model.select(node.id) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.connectedGreen : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                model.toggleFavorite(node.id)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .foregroundStyle(isFav ? Theme.amberAccent : .secondary)
            }
            .buttonStyle(.plain)

            ProtocolBadge(kind: node.kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).font(.headline)
                Text("\(node.server):\(node.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if node.insecure {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(Theme.amberAccent)
            }

            Spacer()

            LatencyBadge(delayText: latency(node, model))
                .help(NodeSubscriptionSupport.source(node,state:model.state)+(NodeSubscriptionSupport.guidance(node,state:model.state).map{" · "+$0} ?? ""))

            Button("测速") { model.measure([node.id]) }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("分享") { sharing = ShareRequest(node: node) }
                .buttonStyle(.bordered)
                .controlSize(.small)

            if node.subscriptionID == nil {
                Button("编辑") { onEdit(node) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button(role: .destructive) {
                Task { await model.deleteNode(node.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .tag(node.id)
    }
}

// MARK: - 连接视图
