import Foundation

@MainActor public enum CaptureRecoveryTransaction {
    // 各恢复路径独立执行，不能因系统代理冲突跳过辅助服务的路由和 DNS 恢复。
    public static func run(proxy:() throws -> Void,helper:() async throws -> Void,local:() async -> Void,verify:() async throws -> Void) async throws {
        var failures:[String]=[]
        do{try proxy()}catch{failures.append("系统代理："+error.localizedDescription)}
        do{try await helper()}catch{failures.append("辅助服务："+error.localizedDescription)}
        await local()
        do{try await verify()}catch{failures.append("恢复核对："+error.localizedDescription)}
        guard failures.isEmpty else{throw ProxyError("恢复未完成；"+failures.joined(separator:"；"))}
    }
}
