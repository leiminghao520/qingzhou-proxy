import Foundation
import QingzhouKit

// 应用入口统一装配依赖；测试可以替换下载、时钟和存储而不触碰日常数据。
struct AppDependencies {
    var recoveryRuntimeHealthyOverride:(()->Bool)?
    var recoveryEnvironmentOverride:(()->String)?
    var recoveryReleasedOverride:(() async throws -> Void)?
    var recoverySafetyOverride:(() throws -> Void)?
    var recoveryWait:(TimeInterval) async throws -> Void = {try await Task.sleep(nanoseconds:UInt64($0*1_000_000_000))}

    var officeHiddenOverride:(()->Bool)?
    var officePathOverride:((SavedDiagnosticTarget,AppState,Bool,String?) throws -> TargetPathEvidence)?
    var officeProbeOverride:((SavedDiagnosticTarget,TargetPathEvidence,AppState,Bool) async -> DiagnosticResult)?
    var makeCredentials:(Bool)->any CredentialStore = {$0 ? MemoryCredentials():UnifiedCredentialStore.native}
    var makeThroughputProbe:(ThroughputContext)->ThroughputProbe = {ThroughputProbe(context:$0)}
    var throughputCoreVersion:(String) async -> String = {path in
        await Task.detached {
            guard let text=try? NetworkInspection.command(path,["version"],deadline:Date().addingTimeInterval(2)),
                  let line=text.components(separatedBy:"\n").first, line.hasPrefix("sing-box version ") else {return "未取得"}
            return String(line.dropFirst("sing-box version ".count).prefix(80))
        }.value
    }
    var diagnosticExecutor=DiagnosticExecutor()
    var diagnosticDNS:(String) async -> DiagnosticResult = {await DiagnosticService.dns($0)}
    var diagnosticHelper:() async throws -> TunReply = {
        let client=PrivilegedServiceClient()
        defer {Task {await client.closeChannel()}}
        return try await client.request(TunRequest(operation:"status",verifyNetwork:true))
    }
    var downloader: any DownloadClient = ExternalDownloadClient.shared
    var trafficStream:(CoreAPIClient) async throws -> AsyncThrowingStream<TransferRate,Error> = {try await $0.traffic()}
    var now: () -> Date = Date.init
    var makeStore: (URL, any CredentialStore) throws -> NodeStore = {try NodeStore(file:$0,credentials:$1)}
    var makeHistory: (URL) throws -> TrafficHistoryStore = {try TrafficHistoryStore(url:$0)}
}
