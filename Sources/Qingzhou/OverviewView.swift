import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // 首页连接控制区域
                FirstConnectionGuide(model:model,onImport:{model.office.importRequested=true})
                connectionHeroCard
                if model.wakeRecoveryStatus.phase != .idle && model.wakeRecoveryStatus.phase != .cancelled {
                    Text(model.wakeRecoveryStatus.label).font(.callout).foregroundStyle(model.wakeRecoveryStatus.phase == .manual ? .orange:.secondary)
                }
                if model.connection == .connecting,let stage=model.startupStage {
                    ConnectionProgressView(stage:stage,startedAt:model.startupStartedAt)
                }

                OfficeLiveRateCards(display:model.trafficDisplay,available:model.monitor.traffic == .available && !model.monitorPaused)
                // 速率与会话统计卡片
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ModernStatCard(
                        title: "本次会话流量",
                        value: bytes(model.downloadTotal + model.uploadTotal),
                        icon: "chart.pie.fill",
                        iconColor: Theme.purpleAccent,
                        subtitle: "↑ \(bytes(model.uploadTotal))  ↓ \(bytes(model.downloadTotal))"
                    )
                    ModernStatCard(
                        title: "活动连接数",
                        value: String(model.connections.count),
                        icon: "network",
                        iconColor: Theme.amberAccent,
                        subtitle: model.monitorStatus
                    )
                }

                // 最近速率曲线
                OfficeRateChart(display:model.trafficDisplay)

                // 快捷操作
                VStack(alignment: .leading, spacing: 12) {
                    Text("快捷操作")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Button {
                            Task { await model.selectPolicy(.automatic) }
                        } label: {
                            Label("自动选择最低延迟", systemImage: "bolt.badge.automatic")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.state.nodes.isEmpty || model.locked)

                        Button {
                            model.measure()
                        } label: {
                            Label("检测全部节点延迟", systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.locked || model.state.nodes.isEmpty)

                        Button {
                            Task { await model.refreshAll() }
                        } label: {
                            Label("一键更新订阅与规则", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.locked)

                        Button {
                            model.office.developerRequested=true
                        } label: {
                            Label("终端代理助手", systemImage: "terminal")
                        }
                        .buttonStyle(.bordered)
                    }

                    if model.measuring {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.measurementProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("取消测速") { model.cancelMeasurement() }
                                .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .stroke(Theme.subtleBorder, lineWidth: 1)
                )

                // 按节点和目标聚合的流量排行
                HStack(alignment: .top, spacing: 14) {
                    trafficRankingCard(
                        title: "按节点观测流量 (Top 5)",
                        icon: "server.rack",
                        items: model.trafficByNode.sorted { $0.value > $1.value }.prefix(5).map { (model.label($0.key), $0.value) }
                    )

                    trafficRankingCard(
                        title: "按目标观测流量 (Top 5)",
                        icon: "globe",
                        items: model.trafficByTarget.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
                    )
                }

                if model.state.subscriptions.contains(where: { $0.pendingReview }) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .foregroundStyle(Theme.amberAccent)
                        Text("部分订阅更新涉及敏感差异需要人工确认，请前往订阅页进行预览。")
                            .font(.caption)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amberAccent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: - 首页连接控制
    private var heroInformation:some View {
        HStack(spacing:16) {
            // 连接状态图标
            ZStack {
                Circle()
                    .fill(statusGlowColor.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: statusSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(statusGlowColor)
            }

            // 连接信息
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.connectionTitle)
                        .font(.title3.bold())
                        .lineLimit(1)
                        .fixedSize(horizontal:true,vertical:false)

                    // 接管方式标签
                    Text(model.effectiveState.captureMode.label)
                        .font(.caption2.bold())
                        .foregroundStyle(Theme.accentBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accentBlue.opacity(0.12))
                        .clipShape(Capsule())
                        .fixedSize(horizontal:true,vertical:false)
                        .help(model.effectiveState.captureMode.label)
                }

                HStack(spacing: 8) {
                    Text(model.selectedName)
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth:220,alignment:.leading)
                        .help(model.selectedName)
                    if model.connection == .connected {
                        let allPassed = model.connectivityHealth == .healthy
                        let anyFailed = model.connectivityResults.contains { $0.status == .failed }

                        HStack(spacing: 4) {
                            Circle()
                                .fill(allPassed ? Theme.connectedGreen : (anyFailed ? Theme.amberAccent : Color.secondary))
                                .frame(width: 6, height: 6)
                            Text(model.linkStatusLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(allPassed ? Theme.connectedGreen : (anyFailed ? Theme.amberAccent : Color.secondary))
                                .lineLimit(1)
                                .frame(width: 72, alignment: .leading)

                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background((allPassed ? Theme.connectedGreen : (anyFailed ? Theme.amberAccent : Color.secondary)).opacity(0.1))
                        .clipShape(Capsule())
                        .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }


        }
        .fixedSize(horizontal:true,vertical:true)
    }
    @ViewBuilder private var heroControls:some View {
        UsageGuideButton(model:model)
            // 代理模式分段选择
            Picker("", selection: Binding(get: { model.state.mode }, set: { mode in Task { await model.setMode(mode) } })) {
                ForEach(ProxyMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(model.locked)

            // 恢复入口
            if model.recoveryPending && model.connection != .connected {
                Button("恢复网络") { Task { await model.recover() } }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(model.loadingFailed || model.recovering)
            }

            // 连接与断开按钮
            Button {
                Task {
                    if model.hasConnectionActivity { await model.disconnect() }
                    else { await model.connect() }
                }
            } label: {
                HStack(spacing: 6) {
                    if model.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.connection == .connected ? "stop.fill" : "play.fill")
                    }
                    Text(model.hasConnectionActivity ? "断开" : "连接")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(minWidth: 70)
            }
            .liquidAction(prominent: true, tint: model.connection == .connected ? Theme.dangerRed : Theme.accentBlue)
            .controlSize(.large)
            .disabled(model.stopDisabled || (model.state.activePolicy == nil && model.state.mode != .direct && model.connection != .connected) || (model.recoveryPending && !model.hasConnectionActivity))
    }

    private var connectionHeroCard:some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:16) {heroInformation;Spacer(minLength:16);heroControls}
            VStack(alignment:.leading,spacing:14) {
                heroInformation
                HStack(spacing:12) {Spacer(minLength:0);heroControls}
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .liquidContentSurface(cornerRadius: Theme.cardCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(model.connection == .connected ? Theme.connectedGreen.opacity(0.3) : Theme.subtleBorder, lineWidth: 1)
        )
    }

    private var statusGlowColor: Color {
        switch model.connection {
        case .connected: return model.connectionAvailable ? Theme.connectedGreen:Theme.amberAccent
        case .connecting, .disconnecting: return Theme.connectingYellow
        case .error: return Theme.dangerRed
        case .disconnected: return Theme.disconnectedGray
        }
    }

    private var statusSymbol: String {
        switch model.connection {
        case .connected: return model.connectionAvailable ? "checkmark.shield.fill":"exclamationmark.triangle.fill"
        case .connecting, .disconnecting: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .disconnected: return "power.circle.fill"
        }
    }

    private func trafficRankingCard(title: String, icon: String, items: [(String, Int64)]) -> some View {
        let maxVal = items.map(\.1).max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)

            if items.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无流量数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(index + 1). " + item.0)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(bytes(item.1))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.1))
                                        .frame(height: 5)
                                    Capsule()
                                        .fill(Theme.accentBlue)
                                        .frame(width: max(5, geo.size.width * CGFloat(Double(item.1) / Double(max(1, maxVal)))), height: 5)
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Theme.subtleBorder, lineWidth: 1)
        )
    }
}

// MARK: - 节点视图
