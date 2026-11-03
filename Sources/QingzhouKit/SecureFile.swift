import Foundation
import Darwin

public enum SecureFile {
    public static func write(_ data: Data, to url: URL, durable:Bool=false) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let temporary = directory.appendingPathComponent(".qingzhou-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // 直接以 0600 独占创建临时文件，不经过 umask 默认权限再 chmod 的窗口。
        let fd = open(temporary.path, O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProxyError("无法创建临时配置文件") }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0 { if errno == EINTR { continue }; throw ProxyError("写入临时配置文件失败") }
                    offset += written
                }
            }
            if durable { guard fsync(fd) == 0 else { throw ProxyError("临时配置文件同步失败") } }
        } catch { close(fd); throw error }
        guard close(fd) == 0 else { throw ProxyError("关闭临时配置文件失败") }
        guard rename(temporary.path, url.path) == 0 else { throw ProxyError("无法原子保存配置") }
        if durable {
            let fd=open(directory.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC)
            guard fd>=0 else {throw ProxyError("恢复目录无法打开并同步")}
            defer{close(fd)}
            guard fsync(fd)==0 else {throw ProxyError("恢复目录同步失败，拒绝后续路由写入")}
        }
    }
}
