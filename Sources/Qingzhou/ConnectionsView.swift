import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

struct ConnectionsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var page=ConnectionListModel()
    @State private var detail: CoreConnection?
    @State private var ruleDraft: RoutingRule?
    var body: some View {
        let labels=Dictionary(Set(model.connections.flatMap(\.chains)).map{($0,model.label($0))},uniquingKeysWith:{$1})
        let rows=page.rows(model.connections,labels:labels)
        let visible=Array(rows.prefix(page.limit))
        VStack(alignment: .leading, spacing: 16) {
            // 页面标题
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时连接监控")
                        .font(.title2.bold())
                    Text("\(model.monitorPaused ? "刷新已暂停" : model.monitorStatus) · 当前 \(model.connections.count) 条活跃连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    Task { await model.closeConnection(nil) }
                } label: {
                    Label("关闭全部连接", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.locked || model.connection != .connected)
            }

            // 筛选栏
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索目标、应用路径或出站节点...", text: $page.query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 280)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Picker("协议", selection: $page.network) {
                    ForEach(["全部", "TCP", "UDP"], id: \.self) { Text($0) }
                }
                .frame(width: 120)

                Picker("排序", selection: $page.order) {
                    ForEach(["流量", "目标", "持续时间"], id: \.self) { Text($0) }
                }
                .frame(width: 130)

                Toggle("暂停刷新", isOn: $model.monitorPaused)
                    .toggleStyle(.checkbox)

                Spacer()
            }

            if rows.isEmpty {
                ContentUnavailableView {
                    Label(model.connections.isEmpty ? "暂无活动连接":"没有匹配的连接",systemImage:"network")
                } description: {
                    Text(model.connections.isEmpty ? "代理处理网络请求后，此处将展示连接与路由链路。":"试试其他关键词或协议。")
                } actions: {
                    if !page.query.isEmpty || page.network != "全部" {Button("清除筛选") {page.clearFilters()}}
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible) { row in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.target)
                                .font(.headline)
                                .lineLimit(1).help(row.target)

                            HStack(spacing: 6) {
                                Text(row.metadata.network?.uppercased() ?? "未知")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                Text(row.chains.map { model.label($0) }.joined(separator: " → "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text("↑ \(bytes(row.upload))  ↓ \(bytes(row.download))")
                                .font(.system(size: 11, design: .monospaced))
                            Text(row.duration)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button("详情") { detail = row }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                        Button("关闭", role: .destructive) {
                            Task { await model.closeConnection(row.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.locked)
                    }
                    .padding(.vertical, 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            }
            HStack {
                Text("已显示 \(visible.count) / 匹配 \(rows.count) / 全部 \(model.connections.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if visible.count<rows.count {Button("再显示 1,000 条") {page.loadMore()}}
            }
        }
        .sheet(item: $detail) { row in
            VStack(alignment: .leading, spacing: 14) {
                Text("连接详细信息").font(.title2.bold())

                VStack(alignment: .leading, spacing: 8) {
                    detailRow("目标地址", row.target)
                    detailRow("来源进程", row.metadata.processPath?.isEmpty == false ? row.metadata.processPath! : "核心未提供")
                    detailRow("匹配规则", row.rule?.isEmpty == false ? row.rule! : "默认策略")
                    detailRow("出站链路", row.chains.map { model.label($0) }.joined(separator: " → "))
                    detailRow("持续时间", row.duration)
                    detailRow("累计传输", "上传 \(bytes(row.upload)) · 下载 \(bytes(row.download))")
                }
                .padding(14)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    Button("以此目标生成分流规则") {
                        let host = row.metadata.host?.isEmpty == false ? row.metadata.host! : row.metadata.destinationIP ?? ""
                        ruleDraft = RoutingRule(kind: row.metadata.host?.isEmpty == false ? .domain : .cidr, value: host, action: .proxy, target: .selected)
                        detail = nil
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                    Button("关闭") { detail = nil }
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(width: 540)
        }
        .sheet(item: $ruleDraft) { draft in RuleDraftView(model: model, draft: draft) }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - 设置视图
