// examples/03_log_rotation/RotatingLogger.swift
// 日志轮转：防止日志文件占满磁盘

import Foundation
import Compression

/// 日志轮转管理器
///
/// 功能：
/// - 单文件最大 5MB
/// - 保留最近 3 个归档
/// - 自动 gzip 压缩
/// - 异步写入，不阻塞主线程
/// - 线程安全（使用 actor）
actor RotatingLogger {

    // MARK: - 配置

    private let maxFileSize: Int = 5 * 1024 * 1024  // 5MB
    private let maxBackups: Int = 3
    private let logDirectory: URL
    private let compressionEnabled: Bool

    // MARK: - 状态

    private var currentFileHandle: FileHandle?
    private var currentFileSize: Int = 0

    // MARK: - 初始化

    init(logDirectory: URL, compressionEnabled: Bool = true) {
        self.logDirectory = logDirectory
        self.compressionEnabled = compressionEnabled

        // 确保日志目录存在
        try? FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // 计算当前日志文件大小
        let currentLog = logDirectory.appendingPathComponent("proxy.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: currentLog.path),
           let size = attrs[.size] as? Int {
            currentFileSize = size
        }
    }

    deinit {
        try? currentFileHandle?.close()
    }

    // MARK: - 公开方法

    /// 记录日志
    func log(_ message: String, level: LogLevel, file: String = #file, function: String = #function, line: Int = #line) async {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let entry = "[\(timestamp)] [\(level.rawValue)] [\(fileName):\(line)] \(function) - \(message)\n"

        await write(entry)
    }

    /// 强制轮转
    func rotate() async {
        try? currentFileHandle?.close()
        currentFileHandle = nil

        await performRotation()
    }

    /// 清理旧日志
    func cleanup() async {
        let fm = FileManager.default
        let pattern = "proxy.\\d+\\.log(\\.gz)?"

        guard let files = try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        let logFiles = files
            .filter { $0.lastPathComponent.range(of: pattern, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        // 删除超过最大备份数的文件
        for file in logFiles.dropFirst(maxBackups) {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - 私有方法

    /// 写入日志
    private func write(_ entry: String) async {
        let data = Data(entry.utf8)

        // 检查是否需要轮转
        if currentFileSize + data.count > maxFileSize {
            await rotate()
        }

        let currentLog = logDirectory.appendingPathComponent("proxy.log")

        // 打开或创建文件句柄
        if currentFileHandle == nil {
            if !FileManager.default.fileExists(atPath: currentLog.path) {
                FileManager.default.createFile(atPath: currentLog.path, contents: nil)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: currentLog.path
                )
            }

            currentFileHandle = try? FileHandle(forWritingTo: currentLog)
        }

        // 写入数据
        do {
            if #available(macOS 10.15.4, *) {
                try currentFileHandle?.seekToEnd()
                try currentFileHandle?.write(contentsOf: data)
            } else {
                currentFileHandle?.seekToEndOfFile()
                currentFileHandle?.write(data)
            }

            currentFileSize += data.count
        } catch {
            print("Failed to write log: \(error)")
        }
    }

    /// 执行轮转
    private func performRotation() async {
        let fm = FileManager.default
        let currentLog = logDirectory.appendingPathComponent("proxy.log")

        guard fm.fileExists(atPath: currentLog.path) else { return }

        // 轮转现有备份: proxy.2.log -> proxy.3.log.gz
        for i in stride(from: maxBackups - 1, through: 1, by: -1) {
            let source = logDirectory.appendingPathComponent("proxy.\(i).log")
            let dest = logDirectory.appendingPathComponent("proxy.\(i + 1).log\(compressionEnabled ? ".gz" : "")")

            if fm.fileExists(atPath: source.path) {
                // 如果启用压缩，压缩并移动
                if compressionEnabled {
                    await compressAndMove(from: source, to: dest)
                } else {
                    try? fm.moveItem(at: source, to: dest)
                }
            }
        }

        // 当前日志 -> proxy.1.log
        let firstBackup = logDirectory.appendingPathComponent("proxy.1.log")
        try? fm.moveItem(at: currentLog, to: firstBackup)

        // 重置文件大小
        currentFileSize = 0

        // 清理超出限制的备份
        await cleanup()
    }

    /// 压缩并移动文件
    private func compressAndMove(from source: URL, to destination: URL) async {
        do {
            let data = try Data(contentsOf: source)
            let compressed = try compress(data)
            try compressed.write(to: destination)
            try FileManager.default.removeItem(at: source)
        } catch {
            print("Failed to compress log: \(error)")
        }
    }

    /// 使用 zlib 压缩数据
    private func compress(_ data: Data) throws -> Data {
        var compressedData = Data()
        var stream = z_stream()

        stream.avail_in = UInt32(data.count)
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: (data as NSData).bytes.bindMemory(to: Bytef.self, capacity: data.count))

        var result = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,  // +16 for gzip
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard result == Z_OK else {
            throw CompressionError.initFailed
        }

        defer { deflateEnd(&stream) }

        repeat {
            var buffer = [UInt8](repeating: 0, count: 16384)
            stream.avail_out = UInt32(buffer.count)
            stream.next_out = &buffer

            result = deflate(&stream, Z_FINISH)

            if result == Z_STREAM_END || result == Z_OK {
                let written = buffer.count - Int(stream.avail_out)
                compressedData.append(buffer, count: written)
            }
        } while result != Z_STREAM_END

        return compressedData
    }
}

// MARK: - 辅助类型

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case critical = "CRIT"

    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .critical: return "🔥"
        }
    }
}

enum CompressionError: Error {
    case initFailed
    case compressionFailed
}

// MARK: - 便捷扩展

extension RotatingLogger {
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(message, level: .debug, file: file, function: function, line: line)
    }

    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(message, level: .info, file: file, function: function, line: line)
    }

    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(message, level: .warning, file: file, function: function, line: line)
    }

    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(message, level: .error, file: file, function: function, line: line)
    }

    func critical(_ message: String, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(message, level: .critical, file: file, function: function, line: line)
    }
}

// MARK: - 使用示例

/*
 在 ServiceContainer 中初始化:

 private lazy var logger: RotatingLogger = {
     let logsDir = FileManager.default.urls(
         for: .applicationSupportDirectory,
         in: .userDomainMask
     )[0].appendingPathComponent("Qingzhou/logs")

     return RotatingLogger(
         logDirectory: logsDir,
         compressionEnabled: true
     )
 }()

 使用示例:

 // 记录日志
 await logger.info("应用启动")
 await logger.debug("当前配置: \(config)")
 await logger.error("连接失败: \(error)")

 // 手动轮转（通常不需要）
 await logger.rotate()

 // 清理旧日志
 await logger.cleanup()

 日志格式:
 [2026-10-21T10:30:45Z] [INFO] [AppModel.swift:123] connect - 正在连接到节点: example.com
 [2026-10-21T10:30:46Z] [ERROR] [CoreController.swift:89] start - 核心启动失败: connection timeout

 文件结构:
 ~/Library/Application Support/Qingzhou/logs/
 ├── proxy.log           # 当前日志
 ├── proxy.1.log         # 第 1 次轮转
 ├── proxy.2.log.gz      # 第 2 次轮转（已压缩）
 └── proxy.3.log.gz      # 第 3 次轮转（已压缩）
 */
