import Foundation
import Darwin

public enum SecureFile {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let temporary = directory.appendingPathComponent(".qingzhou-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // 创建时即为 0600，不存在按 umask 放宽权限的窗口。
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProxyError("无法创建临时配置文件") }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ProxyError("无法写入配置文件") }
                    offset += count
                }
            }
            // 落盘后再改名，避免断电后留下空文件或半截文件。
            guard fsync(fd) == 0 else { throw ProxyError("无法同步配置文件") }
        } catch { close(fd); throw error }
        close(fd)
        guard rename(temporary.path, url.path) == 0 else { throw ProxyError("无法原子保存配置") }
        // 同步目录项，保证改名本身也已持久化。
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
    }
}
