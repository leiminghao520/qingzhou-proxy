import Foundation

@MainActor public enum QuitRecoveryTransaction {
    // 恢复记录可留待下次处理，但退出前必须独立确认没有汐航仍在接管的路径。
    public static func run(recover:() async throws -> Void,verifyReleased:() async throws -> Void,
                           deferredRecovery:(Error)->Void) async throws {
        do {try await recover()}
        catch {
            let recoveryError=error
            try await verifyReleased()
            deferredRecovery(recoveryError)
            return
        }
        try await verifyReleased()
    }
}
