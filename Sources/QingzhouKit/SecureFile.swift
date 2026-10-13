import Foundation
import Darwin

public enum SecureFile {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let temporary = directory.appendingPathComponent(".qingzhou-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw ProxyError("无法原子保存配置") }
    }
}
