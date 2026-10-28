// examples/02_dependency_injection/ServiceContainer.swift
// 依赖注入容器：统一管理服务实例

import Foundation
import QingzhouKit

/// 服务容器
///
/// 采用单例模式 + 懒加载，集中管理所有服务依赖
/// 便于测试时替换 mock 实现
@MainActor
final class ServiceContainer {

    // MARK: - 单例

    static let shared = ServiceContainer()

    private init() {
        setupLogging()
    }

    // MARK: - 公开服务

    /// 连接服务
    lazy var connectionService: ConnectionServiceProtocol = {
        DefaultConnectionService(
            coreController: coreController,
            helperProxy: helperProxy,
            systemProxyController: systemProxyController,
            logger: logger
        )
    }()

    /// 订阅服务
    lazy var subscriptionService: SubscriptionServiceProtocol = {
        DefaultSubscriptionService(
            httpClient: httpClient,
            nodeStore: nodeStore,
            profileStore: profileStore,
            logger: logger
        )
    }()

    /// 流量统计服务
    lazy var statsService: StatsServiceProtocol = {
        DefaultStatsService(
            coreAPIClient: coreAPIClient,
            trafficDatabase: trafficDatabase
        )
    }()

    /// 节点存储
    lazy var nodeStore: NodeStoreProtocol = {
        NodeStore(
            storage: userDefaults,
            keychainStore: keychainStore
        )
    }()

    /// 配置存储
    lazy var profileStore: ProfileStoreProtocol = {
        ProfileStore(storage: userDefaults)
    }()

    /// 规则服务
    lazy var ruleService: RuleServiceProtocol = {
        DefaultRuleService(
            httpClient: httpClient,
            cache: ruleCache
        )
    }()

    /// 诊断服务
    lazy var diagnosticService: DiagnosticServiceProtocol = {
        DiagnosticService(
            coreController: coreController,
            systemProxyController: systemProxyController,
            tunSupport: tunSupport
        )
    }()

    // MARK: - 内部依赖

    private lazy var coreController: CoreControllerProtocol = {
        CoreController(
            apiClient: coreAPIClient,
            binaryPath: coreExecutablePath
        )
    }()

    private lazy var coreAPIClient: CoreAPIClient = {
        CoreAPIClient(
            baseURL: URL(string: "http://127.0.0.1:9090")!,
            httpClient: httpClient
        )
    }()

    private lazy var helperProxy: HelperProxyProtocol = {
        HelperProxy()
    }()

    private lazy var systemProxyController: SystemProxyControllerProtocol = {
        SystemProxyController()
    }()

    private lazy var tunSupport: TunSupportProtocol = {
        TunSupport(helperProxy: helperProxy)
    }()

    private lazy var httpClient: HTTPClient = {
        HTTPClient.shared
    }()

    private lazy var keychainStore: KeychainStoreProtocol = {
        KeychainStore(service: "cn.qingzhou.proxy")
    }()

    private lazy var trafficDatabase: TrafficDatabase = {
        TrafficDatabase()
    }()

    private lazy var ruleCache: RuleCache = {
        RuleCache(maxSize: 100_000)
    }()

    private lazy var userDefaults: UserDefaults = {
        UserDefaults(suiteName: "cn.qingzhou.proxy")!
    }()

    private lazy var logger: Logger = {
        Logger(label: "cn.qingzhou.proxy")
    }()

    // MARK: - 路径

    private var coreExecutablePath: URL {
        Bundle.main.url(
            forResource: "sing-box",
            withExtension: nil,
            subdirectory: "Vendor"
        )!
    }

    // MARK: - 初始化设置

    private func setupLogging() {
        // 配置日志系统
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .info
            return handler
        }
    }
}

// MARK: - 测试支持

#if DEBUG
extension ServiceContainer {
    /// 创建测试容器（带 mock 依赖）
    static func makeTestContainer(
        connectionService: ConnectionServiceProtocol? = nil,
        subscriptionService: SubscriptionServiceProtocol? = nil,
        statsService: StatsServiceProtocol? = nil,
        nodeStore: NodeStoreProtocol? = nil
    ) -> ServiceContainer {
        let container = ServiceContainer()

        // 替换为 mock 实现
        if let service = connectionService {
            container.connectionService = service
        }
        if let service = subscriptionService {
            container.subscriptionService = service
        }
        if let service = statsService {
            container.statsService = service
        }
        if let store = nodeStore {
            container.nodeStore = store
        }

        return container
    }
}
#endif

// MARK: - 环境键

/// SwiftUI Environment Key
struct ServiceContainerKey: EnvironmentKey {
    static let defaultValue: ServiceContainer = .shared
}

extension EnvironmentValues {
    var serviceContainer: ServiceContainer {
        get { self[ServiceContainerKey.self] }
        set { self[ServiceContainerKey.self] = newValue }
    }
}

// MARK: - 在 SwiftUI 中使用

/*
 在 App 入口注入容器:

 @main
 struct QingzhouApp: App {
     var body: some Scene {
         WindowGroup {
             ContentView()
                 .environment(\.serviceContainer, ServiceContainer.shared)
         }
     }
 }

 在 View 中使用:

 struct ContentView: View {
     @Environment(\.serviceContainer) private var container

     var body: some View {
         DashboardView(
             viewModel: DashboardViewModel(
                 connectionService: container.connectionService,
                 statsService: container.statsService,
                 nodeStore: container.nodeStore
             )
         )
     }
 }

 在测试中使用:

 func testConnectionFlow() async throws {
     let mockConnection = MockConnectionService()
     let container = ServiceContainer.makeTestContainer(
         connectionService: mockConnection
     )

     let viewModel = DashboardViewModel(
         connectionService: container.connectionService,
         statsService: container.statsService,
         nodeStore: container.nodeStore
     )

     await viewModel.connect()
     XCTAssertTrue(mockConnection.didConnect)
 }
 */

// MARK: - 测试替代实现

#if DEBUG
final class MockConnectionService: ConnectionServiceProtocol {
    var didConnect = false
    var didDisconnect = false

    private let stateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)

    var statePublisher: AnyPublisher<ConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    func connect(with node: ProxyNode) async throws {
        didConnect = true
        stateSubject.send(.connected)
    }

    func disconnect() async throws {
        didDisconnect = true
        stateSubject.send(.disconnected)
    }
}
#endif
