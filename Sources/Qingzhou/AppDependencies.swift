import Foundation
import QingzhouKit

// 应用入口统一装配依赖；测试可以替换下载、时钟和存储而不触碰日常数据。
struct AppDependencies {
    var downloader: any DownloadClient = ExternalDownloadClient.shared
    var trafficStream:(CoreAPIClient) async throws -> AsyncThrowingStream<TransferRate,Error> = {try await $0.traffic()}
    var now: () -> Date = Date.init
    var makeStore: (URL, any CredentialStore) throws -> NodeStore = {try NodeStore(file:$0,credentials:$1)}
    var makeHistory: (URL) throws -> TrafficHistoryStore = {try TrafficHistoryStore(url:$0)}
}
