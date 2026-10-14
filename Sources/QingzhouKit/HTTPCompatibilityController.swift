import Foundation
import Darwin

@MainActor public final class HTTPCompatibilityController {
    private var process:Process?
    public var isRunning:Bool {process?.isRunning == true}
    public var log:((String)->Void)?
    public var onUnexpectedExit:(() -> Void)?
    public func start(configuration:Data,port:Int) async throws {
        guard process==nil,CoreController.portAvailable(port) else {throw ProxyError("HTTP 兼容端口已被占用")}
        let binary=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/qzhttp")
        guard FileManager.default.isExecutableFile(atPath:binary.path) else {throw ProxyError("Shadowrocket HTTP 兼容组件缺失")}
        let child=Process(),input=Pipe(),events=Pipe();child.executableURL=binary;child.standardInput=input
        // 兼容层不输出请求地址或请求头，避免把生产流量写入日志。
        child.standardOutput=FileHandle.nullDevice;child.standardError=events
        let framer=LogFramer(secrets:[])
        events.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData
            let lines=framer.receive(data,end:data.isEmpty)
            if data.isEmpty{handle.readabilityHandler=nil}
            let messages=lines.compactMap(CompatibilityDiagnostic.message)
            Task{@MainActor in for message in messages{self?.log?(message)}}
        }
        process=child
        child.terminationHandler={ [weak self] finished in Task{@MainActor in guard let self,self.process === finished else{return};self.process=nil;self.onUnexpectedExit?()} }
        do {
            try child.run();try input.fileHandleForReading.close();try input.fileHandleForWriting.write(contentsOf:configuration);try input.fileHandleForWriting.close()
            for _ in 0..<50 {guard child.isRunning else {throw ProxyError("HTTP 兼容组件启动失败")};if CoreController.listening(port){return};try await Task.sleep(nanoseconds:100_000_000)}
            throw ProxyError("HTTP 兼容组件启动超时")
        }catch{await stop();throw error}
    }
    public func stop() async {
        guard let child=process else{return};process=nil
        if child.isRunning {child.terminate();for _ in 0..<20 where child.isRunning {try? await Task.sleep(nanoseconds:50_000_000)};if child.isRunning{_ = Darwin.kill(child.processIdentifier,SIGKILL)}}
        child.waitUntilExit()
    }
}

public enum CompatibilityDiagnostic {
    private struct Event:Decodable {let stage:String;let category:String;let elapsedMs:Int64;let count:UInt64;let entry:String?;let sentBytes:Int64?;let receivedBytes:Int64?}
    public static func message(_ line:String)->String? {
        guard let event=try? JSONDecoder().decode(Event.self,from:Data(line.utf8)),["identify","socks","control","resolve","http","connect","relay","startup"].contains(event.stage),["limit","timeout","cancelled","upstream","auth","dns","control","compatibility","tls","ok","ipv6Unavailable"].contains(event.category),event.elapsedMs>=0,event.elapsedMs<=86_400_000 else{return nil}
        if let entry=event.entry,!["http","connect","socks","upgrade"].contains(entry){return nil}
        guard (event.sentBytes ?? 0)>=0,(event.receivedBytes ?? 0)>=0 else{return nil}
        return "兼容层 entry=\(event.entry ?? "unknown") sent=\(event.sentBytes ?? 0) received=\(event.receivedBytes ?? 0) stage=\(event.stage) category=\(event.category) elapsedMs=\(event.elapsedMs) count=\(event.count)"
    }
}
