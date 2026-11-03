import Foundation
import SystemConfiguration
import Darwin

public enum NetworkSafety {
    public static func conflict(proxies:[String:Any],dns:String)->String? {
        for key in ["HTTPEnable","HTTPSEnable","SOCKSEnable","ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable"] where (proxies[key] as? NSNumber)?.boolValue==true {return "已有系统代理正在接管网络，请先关闭 Shadowrocket 等代理并确认网络恢复，再连接汐航"}
        let fake=dns.components(separatedBy:.newlines).contains{line in
            let text=line.trimmingCharacters(in:.whitespaces)
            guard text.hasPrefix("nameserver["),let address=text.components(separatedBy:": ").last else{return false}
            return RuleEvaluator.matches(RoutingRule(kind:.cidr,value:"198.18.0.0/15",action:.direct),host:address,ip:address)==true
        }
        return fake ? "检测到其他代理的 Fake-IP DNS，请先关闭该代理并等待 DNS 恢复，汐航未接管网络":nil
    }
    public static func excludingOwnedDNS(_ dns:String,owned:String?)->String {
        guard let owned else{return dns}
        // 只排除辅助服务本次返回且已核验的 DNS，不能忽略其他代理的 Fake-IP。
        return dns.components(separatedBy:.newlines).filter {line in
            let value=line.trimmingCharacters(in:.whitespaces)
            return !(value.hasPrefix("nameserver[") && value.components(separatedBy:": ").last==owned)
        }.joined(separator:"\n")
    }
    public static func check(ownedDNS:String?=nil) throws {
        guard let proxies=SCDynamicStoreCopyProxies(nil) as? [String:Any] else{throw ProxyError("无法可靠读取系统代理，未接管网络")}
        let dns=try NetworkInspection.command("/usr/sbin/scutil",["--dns"])
        if let reason=conflict(proxies:proxies,dns:excludingOwnedDNS(dns,owned:ownedDNS)){throw ProxyError(reason)}
    }
    @MainActor public static func loopbackListening(_ host:String,_ port:Int) -> Bool {
        guard (1...65535).contains(port) else{return false}
        if host != "::1" {return CoreController.listening(port)}
        let fd=socket(AF_INET6,SOCK_STREAM,0);guard fd>=0 else{return false};defer{close(fd)}
        var address=sockaddr_in6();address.sin6_len=UInt8(MemoryLayout<sockaddr_in6>.size);address.sin6_family=sa_family_t(AF_INET6);address.sin6_port=UInt16(port).bigEndian
        _ = "::1".withCString{inet_pton(AF_INET6,$0,&address.sin6_addr)}
        return withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in6>.size))==0}}
    }
    public static func restoration(_ original:[String:Any],listening:(String,Int)->Bool) -> [String:Any] {
        var result=original
        // 仅处理恢复快照里的失效回环代理，不修改用户当前另行设置的网络配置。
        for prefix in ["HTTP","HTTPS","SOCKS"] where (original[prefix+"Enable"] as? NSNumber)?.boolValue==true {
            guard let host=original[prefix+"Proxy"] as? String,["127.0.0.1","localhost","::1"].contains(host),let port=original[prefix+"Port"] as? Int else{continue}
            if !(1...65535).contains(port) || !listening(host,port){result[prefix+"Enable"]=0}
        }
        return result
    }
}

public enum ProbeStatus:Sendable {case available,unavailable,unknown}
public struct HealthFailureCounter {
    public private(set) var failures=0
    public init(){}
    public mutating func update(_ statuses:[ProbeStatus])->Bool {
        guard !statuses.isEmpty else{failures=0;return false}
        // 控制接口、DNS 或取消等未知结果不能累计成全部节点失效。
        if statuses.allSatisfy({if case .unavailable=$0{return true};return false}){failures+=1}else{failures=0}
        return failures>=2
    }
}

// 串行追加和有界归档避免每批读取整份诊断日志。
public final class DiagnosticLog {
    private let url:URL
    private let lock=NSLock()
    public static let maximumFileBytes=512*1024
    public static let maximumLineBytes=8192
    public init(url:URL){self.url=url}
    public func append(_ line:String) throws {try appendBatch([line])}
    public func appendBatch(_ lines:[String]) throws {
        lock.lock();defer{lock.unlock()}
        let fm=FileManager.default
        try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var batch=Data()
        for line in lines {
            let safe=Redactor.redact(line).replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")
            var entry=String(safe.prefix(Self.maximumLineBytes))
            while entry.utf8.count>Self.maximumLineBytes {entry.removeLast()}
            if safe.utf8.count>Self.maximumLineBytes {entry+=" [日志已截断]"}
            let data=Data((entry+"\n").utf8)
            if batch.count+data.count>Self.maximumFileBytes {try write(batch);batch=Data()}
            batch.append(data)
        }
        if !batch.isEmpty {try write(batch)}
    }
    private func write(_ data:Data) throws {
        let fm=FileManager.default
        let size=(try? fm.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size+data.count>Self.maximumFileBytes {
            let last=url.appendingPathExtension("3")
            if fm.fileExists(atPath:last.path){try fm.removeItem(at:last)}
            for index in stride(from:2,through:1,by:-1) {
                let source=url.appendingPathExtension(String(index))
                if fm.fileExists(atPath:source.path){try fm.moveItem(at:source,to:url.appendingPathExtension(String(index+1)))}
            }
            if fm.fileExists(atPath:url.path){try fm.moveItem(at:url,to:url.appendingPathExtension("1"))}
        }
        let fd=open(url.path,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else {throw ProxyError("诊断日志无法打开")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer {try? handle.close()}
        guard fchmod(fd,0o600)==0 else {throw ProxyError("诊断日志权限无法设置")}
        try handle.write(contentsOf:data)
    }
}
