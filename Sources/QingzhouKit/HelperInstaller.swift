import Foundation
import Darwin

public enum HelperInstaller {
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
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            DispatchQueue.global().async {
                // 密码由 macOS 原生管理员授权窗口接收，应用不读取或保存。
                let process=Process(),output=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/osascript");process.arguments=["-e",script];process.standardOutput=output;process.standardError=output
                do {try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                    guard process.terminationStatus==0 else{throw ProxyError("辅助服务安装未完成："+Redactor.redact(String(decoding:data,as:UTF8.self)))}
                    continuation.resume(returning:())
                }catch{continuation.resume(throwing:error)}
            }
        }
    }
}
