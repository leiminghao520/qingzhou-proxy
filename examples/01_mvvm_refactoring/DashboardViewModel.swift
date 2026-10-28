// examples/01_mvvm_refactoring/DashboardViewModel.swift
// MVVM 架构示例：Dashboard 视图模型

import SwiftUI
import Combine
import QingzhouKit

/// Dashboard 页面的视图模型
///
/// 职责：
/// - 管理连接状态
/// - 处理用户交互
/// - 暴露 UI 需要的数据和操作
@MainActor
final class DashboardViewModel: ObservableObject {

    // MARK: - 可观察属性

    @Published var connectionState: ConnectionState = .disconnected
    @Published var currentNode: ProxyNode?
    @Published var trafficStats: TrafficStats?
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false

    // MARK: - 依赖

    private let connectionService: ConnectionServiceProtocol
    private let statsService: StatsServiceProtocol
    private let nodeStore: NodeStoreProtocol

    // MARK: - 私有属性

    private var cancellables = Set<AnyCancellable>()
    private var statsUpdateTask: Task<Void, Never>?

    // MARK: - 初始化

    init(
        connectionService: ConnectionServiceProtocol,
        statsService: StatsServiceProtocol,
        nodeStore: NodeStoreProtocol
    ) {
        self.connectionService = connectionService
        self.statsService = statsService
        self.nodeStore = nodeStore

        setupObservers()
    }

    deinit {
        statsUpdateTask?.cancel()
    }

    // MARK: - 公开方法

    /// 切换连接状态
    func toggleConnection() async {
        isLoading = true
        defer { isLoading = false }

        do {
            switch connectionState {
            case .disconnected:
                try await connect()
            case .connected:
                try await disconnect()
            case .connecting:
                break // 正在连接时忽略
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 连接到代理
    func connect() async throws {
        guard let node = currentNode else {
            throw DashboardError.noNodeSelected
        }

        connectionState = .connecting

        do {
            try await connectionService.connect(with: node)
            startStatsMonitoring()
        } catch {
            connectionState = .disconnected
            throw error
        }
    }

    /// 断开代理连接
    func disconnect() async throws {
        try await connectionService.disconnect()
        stopStatsMonitoring()
        trafficStats = nil
    }

    /// 选择节点
    func selectNode(_ node: ProxyNode) async {
        // 如果已连接，先断开
        if case .connected = connectionState {
            try? await disconnect()
        }

        currentNode = node

        // 保存最近使用
        try? await nodeStore.markAsRecentlyUsed(node)
    }

    /// 刷新流量统计
    func refreshStats() async {
        guard case .connected = connectionState else { return }

        do {
            trafficStats = try await statsService.getCurrentStats()
        } catch {
            // 静默失败，不影响主流程
            print("Failed to refresh stats: \(error)")
        }
    }

    // MARK: - 私有方法

    /// 设置观察者
    private func setupObservers() {
        // 监听连接状态变化
        connectionService.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)

        // 监听当前节点变化
        nodeStore.currentNodePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] node in
                self?.currentNode = node
            }
            .store(in: &cancellables)
    }

    /// 开始流量监控
    private func startStatsMonitoring() {
        statsUpdateTask?.cancel()

        statsUpdateTask = Task {
            while !Task.isCancelled {
                await refreshStats()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 停止流量监控
    private func stopStatsMonitoring() {
        statsUpdateTask?.cancel()
        statsUpdateTask = nil
    }
}

// MARK: - 辅助类型

enum ConnectionState: String {
    case disconnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
}

enum DashboardError: LocalizedError {
    case noNodeSelected

    var errorDescription: String? {
        switch self {
        case .noNodeSelected:
            return "请先选择一个节点"
        }
    }
}

// MARK: - 协议定义

/// 连接服务协议
protocol ConnectionServiceProtocol {
    var statePublisher: AnyPublisher<ConnectionState, Never> { get }
    func connect(with node: ProxyNode) async throws
    func disconnect() async throws
}

/// 流量统计服务协议
protocol StatsServiceProtocol {
    func getCurrentStats() async throws -> TrafficStats
}

/// 节点存储协议
protocol NodeStoreProtocol {
    var currentNodePublisher: AnyPublisher<ProxyNode?, Never> { get }
    func markAsRecentlyUsed(_ node: ProxyNode) async throws
}

// MARK: - 使用示例

/*
 在 ContentView 中使用:

 struct ContentView: View {
     @StateObject private var viewModel = DashboardViewModel(
         connectionService: ServiceContainer.shared.connectionService,
         statsService: ServiceContainer.shared.statsService,
         nodeStore: ServiceContainer.shared.nodeStore
     )

     var body: some View {
         DashboardView(viewModel: viewModel)
     }
 }

 struct DashboardView: View {
     @ObservedObject var viewModel: DashboardViewModel

     var body: some View {
         VStack {
             // 连接状态
             Text(viewModel.connectionState.rawValue)

             // 当前节点
             if let node = viewModel.currentNode {
                 Text(node.name)
             }

             // 流量统计
             if let stats = viewModel.trafficStats {
                 Text("↑ \(stats.uploadSpeed)")
                 Text("↓ \(stats.downloadSpeed)")
             }

             // 连接按钮
             Button(action: {
                 Task {
                     await viewModel.toggleConnection()
                 }
             }) {
                 if viewModel.isLoading {
                     ProgressView()
                 } else {
                     Text(viewModel.connectionState == .connected ? "断开" : "连接")
                 }
             }
             .disabled(viewModel.isLoading)
         }
         .alert("错误", isPresented: .constant(viewModel.errorMessage != nil)) {
             Button("确定") {
                 viewModel.errorMessage = nil
             }
         } message: {
             if let error = viewModel.errorMessage {
                 Text(error)
             }
         }
     }
 }
 */
