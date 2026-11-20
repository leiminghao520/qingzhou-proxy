import Foundation
import Darwin

public enum HelperInstaller {
    public static func componentsMatch(app:URL,directory:URL=URL(fileURLWithPath:HelperPaths.directory))->Bool {
        // 此检查只用于跳过重复安装，调用方还必须通过现有辅助服务的身份与协议核验。
        for name in ["QingzhouHelper","sing-box"] {
            guard let bundled=try? Data(contentsOf:app.appendingPathComponent("Contents/Resources/"+name)),
                  let installed=try? Data(contentsOf:directory.appendingPathComponent(name)),
                  !bundled.isEmpty,bundled==installed else{return false}
        }
        return true
    }
    public static func authorizationScript(app:URL)->String {
        func shellQuote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let script=app.appendingPathComponent("Contents/Resources/install-helper.sh")
        let command="/usr/bin/env SUDO_UID=\(getuid()) "+shellQuote(script.path)+" "+shellQuote(app.path)
        let literal=command.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
        return "do shell script \""+literal+"\" with administrator privileges"
    }
    public static func install(app:URL) async throws {
        let file=app.appendingPathComponent("Contents/Resources/install-helper.sh")
        guard FileManager.default.isExecutableFile(atPath:file.path) else{throw ProxyError("随包辅助服务安装脚本缺失")}
        let script=authorizationScript(app:app)
        try await executeAuthorization(script, failure: "辅助服务安装未完成")
    }
    public static func recoveryAuthorizationScript(app: URL, acknowledge: Bool = false) -> String {
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let file = app.appendingPathComponent("Contents/Resources/recover-helper.sh")
        let command = "/bin/bash " + shellQuote(file.path) + " " + shellQuote(app.path) + (acknowledge ? " --acknowledge" : "")
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"" + literal + "\" with administrator privileges"
    }
    public static func recoverNormalNetwork(app: URL, acknowledge: Bool = false) async throws {
        let file = app.appendingPathComponent("Contents/Resources/recover-helper.sh")
        guard FileManager.default.fileExists(atPath: file.path) else { throw ProxyError("随包网络恢复工具缺失，请使用完整的汐航应用包") }
        try await executeAuthorization(recoveryAuthorizationScript(app: app, acknowledge: acknowledge), failure: "管理员网络恢复未完成")
    }
    private static func executeAuthorization(_ script: String, failure: String) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            DispatchQueue.global().async {
                // 密码由 macOS 原生管理员授权窗口接收，应用不读取或保存。
                let process=Process(),output=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/osascript");process.arguments=["-e",script];process.standardOutput=output;process.standardError=output
                do {try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                    guard process.terminationStatus==0 else{throw ProxyError(failure+"："+Redactor.redact(String(decoding:data,as:UTF8.self)))}
                    continuation.resume(returning:())
                }catch{continuation.resume(throwing:error)}
            }
        }
    }
}
