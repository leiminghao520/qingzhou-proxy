import Foundation
import Darwin

public enum SecureFile {
    public static func write(_ data: Data, to url: URL, durable:Bool=false) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let temporary = directory.appendingPathComponent(".qingzhou-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: temporary.path)
        if durable {
            let handle=try FileHandle(forWritingTo:temporary);defer{try? handle.close()}
            try handle.synchronize()
        }
        guard rename(temporary.path, url.path) == 0 else { throw ProxyError("无法原子保存配置") }
        if durable {
            let fd=open(directory.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC)
            guard fd>=0 else {throw ProxyError("恢复目录无法打开并同步")}
            defer{close(fd)}
            guard fsync(fd)==0 else {throw ProxyError("恢复目录同步失败，拒绝后续路由写入")}
        }
    }
}
