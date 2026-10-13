import Foundation
import Darwin
import CFNetwork

@MainActor public final class CoreController {
    private var process: Process?
    private var configURL: URL?
    private var intentionalStop = false
    public var onUnexpectedExit: (() -> Void)?
    public var log: ((String) -> Void)?
    public var secrets: [String] = []
    public let directory: URL
    public let binary: URL
    public let supervisor: URL?
    public var isRunning: Bool { process?.isRunning == true }
    public var processID: Int32? {process?.processIdentifier}
    public init(directory: URL, binary: URL? = nil, supervisor: URL? = nil) {
        self.directory = directory
        self.binary = binary ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sing-box")
        self.supervisor = binary == nil ? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/QingzhouRunner") : supervisor
    }
    public static func portAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET,SOCK_STREAM,0); guard fd >= 0 else { return false }; defer {close(fd)}
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) == 0}}
    }
    public static func listening(_ port: Int) -> Bool {
        let fd = socket(AF_INET,SOCK_STREAM,0); guard fd >= 0 else { return false }; defer {close(fd)}
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) == 0}}
    }
    public func validate(config:Data) async throws {
        guard FileManager.default.isExecutableFile(atPath:binary.path) else {throw ProxyError("代理核心缺失")}
        let url=directory.appendingPathComponent("check-"+UUID().uuidString+".json");try SecureFile.write(config,to:url);defer{try? FileManager.default.removeItem(at:url)}
        let binary=self.binary
        let valid=try await Task.detached{let p=Process();p.executableURL=binary;p.arguments=["check","-c",url.path];p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit();return p.terminationStatus==0}.value
        guard valid else {throw ProxyError("核心配置校验失败，请检查节点、策略和规则")}
    }
    public func start(config: Data, port: Int) async throws {
        guard process == nil else { throw ProxyError("代理核心已经运行") }
        guard FileManager.default.isExecutableFile(atPath:binary.path) else { throw ProxyError("应用内的 sing-box 核心缺失，请重新安装完整应用") }
        if let supervisor, !FileManager.default.isExecutableFile(atPath:supervisor.path) {throw ProxyError("核心监护程序缺失，请重新安装完整应用")}
        guard Self.portAvailable(port) else { throw ProxyError("监听端口已被占用，请修改端口或关闭占用程序") }
        let url = directory.appendingPathComponent("runtime-" + UUID().uuidString + ".json")
        try SecureFile.write(config,to:url); configURL = url
        do {
            let binary = self.binary
            let valid = try await Task.detached { () -> Bool in
                let p = Process(); p.executableURL = binary; p.arguments = ["check","-c",url.path]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try p.run(); p.waitUntilExit(); return p.terminationStatus == 0
            }.value
            guard valid else { throw ProxyError("核心配置校验失败，请检查节点和规则参数") }
            let p = Process();p.executableURL = supervisor ?? binary
            p.arguments = (supervisor == nil ? [] : [binary.path]) + ["run","-c",url.path]
            intentionalStop = false
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            let framer = LogFramer(secrets:secrets)
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                let lines = framer.receive(data,end:data.isEmpty)
                if data.isEmpty {handle.readabilityHandler = nil}
                Task { @MainActor in for line in lines {self?.log?(line)} }
            }
            p.terminationHandler = { [weak self] terminated in
                Task { @MainActor in
                    guard let self, self.process === terminated else { return }
                    let unexpected = !self.intentionalStop
                    self.process = nil
                    self.cleanup()
                    if unexpected { self.log?("代理核心异常退出"); self.onUnexpectedExit?() }
                }
            }
            process = p
            try p.run()
            for _ in 0..<50 {
                guard p.isRunning else { throw ProxyError("代理核心启动失败") }
                if Self.listening(port) { log?("本地代理已就绪，端口 \(port)"); return }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            throw ProxyError("代理核心启动超时")
        } catch { await stop(); throw error }
    }
    public func stop() async {
        intentionalStop = true
        if let p = process, p.isRunning {
            p.terminate()
            for _ in 0..<30 { if !p.isRunning { break }; try? await Task.sleep(nanoseconds:100_000_000) }
            if p.isRunning { kill(p.processIdentifier,SIGKILL); for _ in 0..<20 { if !p.isRunning { break }; try? await Task.sleep(nanoseconds:50_000_000) } }
        }
        process = nil; cleanup()
    }
    private func cleanup() { if let url = configURL { try? FileManager.default.removeItem(at:url) }; configURL = nil }
    public func probe(port: Int) async -> String {
        await ConnectivityProbe.detailed(port:port)
    }
}
