import Foundation
import Darwin
import QingzhouKit

final class Counter:@unchecked Sendable {
    private let lock=NSLock();private var count=0
    func increment(){lock.lock();count+=1;lock.unlock()}
    var value:Int {lock.lock();defer{lock.unlock()};return count}
}
@main struct HelperChannelChecks {
    static var checks=0
    static func check(_ condition:Bool,_ message:String){checks+=1;if !condition{fatalError(message)}}
    static func pair() throws -> (HelperRequestChannel,Int32) {
        var sockets:[Int32]=[-1,-1]
        guard socketpair(AF_UNIX,SOCK_STREAM,0,&sockets)==0 else{throw ProxyError("本地夹具套接字创建失败")}
        for fd in sockets {var one:Int32=1;_=setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(4))}
        return (HelperRequestChannel(descriptor:sockets[0]),sockets[1])
    }
    static func main() async throws {
        // 仅使用进程内 Unix socketpair，既不连接辅助服务，也不发送任何路由消息。
        let counter=Counter(),(channel,server)=try pair()
        let serverDone=Counter()
        DispatchQueue.global().async {
            defer{close(server);serverDone.increment()}
            do {
                _=try UnixChannel.receive(fd:server)
                var progress=TunReply(ok:true,message:"阶段",phase:"protection");progress.isProgress=true
                try UnixChannel.send(JSONEncoder().encode(progress),fd:server)
                _=try? UnixChannel.receive(fd:server)
            } catch {}
        }
        let task=Task {try await channel.exchange(Data("fixture".utf8),progress:{_ in counter.increment()},timeout:60)}
        for _ in 0..<100 {if counter.value>0 {break};try await Task.sleep(nanoseconds:1_000_000)}
        check(counter.value==1,"阻塞期间进度必须可见")
        let began=ProcessInfo.processInfo.systemUptime
        task.cancel()
        do {_=try await task.value;check(false,"取消不得返回成功")}catch{check(true,"取消返回失败")}
        check(ProcessInfo.processInfo.systemUptime-began<1,"取消不能等待六十秒接收超时")
        for _ in 0..<100 {if serverDone.value>0 {break};try await Task.sleep(nanoseconds:1_000_000)}
        check(serverDone.value==1,"取消向服务端传播断开")

        let (actorChannel,actorServer)=try pair(),actorProgress=Counter()
        let client=PrivilegedServiceClient(channel:actorChannel)
        await client.setProgressObserver{_ in actorProgress.increment()}
        DispatchQueue.global().async {
            defer{close(actorServer)}
            do {
                _=try UnixChannel.receive(fd:actorServer)
                var frame=TunReply(ok:true,message:"激活中",phase:"protection");frame.isProgress=true
                try UnixChannel.send(JSONEncoder().encode(frame),fd:actorServer)
                _=try? UnixChannel.receive(fd:actorServer)
            }catch{}
        }
        let actorRequest=Task {try await client.request(TunRequest(operation:"activate"))}
        for _ in 0..<100 {if actorProgress.value>0 {break};try await Task.sleep(nanoseconds:1_000_000)}
        check(actorProgress.value==1,"正式客户端 actor 等待中仍转发阶段")
        do {_=try await client.request(TunRequest(operation:"status"));check(false,"事务中不能重复提交")}
        catch {check(true,"事务中不能重复提交")}
        let actorCancelStart=ProcessInfo.processInfo.systemUptime
        await client.closeChannel()
        do {_=try await actorRequest.value;check(false,"关闭等待中的正式客户端不能成功")}
        catch {check(true,"关闭等待中的正式客户端不能成功")}
        check(ProcessInfo.processInfo.systemUptime-actorCancelStart<1,"正式 actor 取消不受阻塞接收占用")

        let (budgetChannel,budgetServer)=try pair(),frames=Counter()
        DispatchQueue.global().async {
            defer{close(budgetServer)}
            do {
                _=try UnixChannel.receive(fd:budgetServer)
                for _ in 0..<30 {
                    var p=TunReply(ok:true,message:"仍在保护",phase:"protection");p.isProgress=true
                    try UnixChannel.send(JSONEncoder().encode(p),fd:budgetServer)
                    usleep(5_000)
                }
            }catch{}
        }
        let start=ProcessInfo.processInfo.systemUptime
        do {_=try await budgetChannel.exchange(Data("fixture".utf8),progress:{_ in frames.increment()},timeout:0.04);check(false,"进度不能重置总预算")}
        catch{check(true,"预算耗尽明确失败")}
        budgetChannel.cancel()
        check(frames.value>1 && ProcessInfo.processInfo.systemUptime-start<0.5,"持续进度不延长等待")

        let (success,successServer)=try pair()
        DispatchQueue.global().async {
            defer{close(successServer)}
            do {_=try UnixChannel.receive(fd:successServer);try UnixChannel.send(JSONEncoder().encode(TunReply(ok:true,message:"confirmed")),fd:successServer)}catch{}
        }
        let reply=try await success.exchange(Data("fixture".utf8),progress:{_ in},timeout:1)
        check(reply.ok && reply.message=="confirmed","最终帧而非进度帧确认完成");success.cancel()
        let (early,earlyServer)=try pair();early.cancel();close(earlyServer)
        do {_=try await early.exchange(Data(),progress:{_ in});check(false,"提交前取消")}catch{check(true,"提交前取消")}

        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("qz-audit-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:temporary)}
        let recoveryFile=temporary.appendingPathComponent("recovery.json")
        try SecureFile.write(Data("intent-before-write".utf8),to:recoveryFile,durable:true)
        check(try Data(contentsOf:recoveryFile)==Data("intent-before-write".utf8),"恢复意图原子保存并同步")
        let mode=try FileManager.default.attributesOfItem(atPath:recoveryFile.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue==0o600,"恢复记录权限保持私有")
        let audit=RouteAuditLog(directory:temporary,maximum:1024),transaction=UUID()
        for _ in 0..<12 {_=try audit.operation(transaction:transaction,stage:"protection",kind:"add",identity:"secret-host-identity"){42}}
        let current=temporary.appendingPathComponent("route-operations.jsonl"),previous=temporary.appendingPathComponent("route-operations.previous.jsonl")
        check(FileManager.default.fileExists(atPath:previous.path),"审计按大小轮转")
        check(try Data(contentsOf:current).count<2048 && Data(contentsOf:previous).count<2048,"审计保留有界文件")
        let text=try String(contentsOf:current,encoding:.utf8)+String(contentsOf:previous,encoding:.utf8)
        check(!text.contains("secret-host-identity") && text.contains("identityHash"),"审计不记录原始身份")
        do {_=try audit.operation(transaction:transaction,stage:"protection",kind:"add",identity:"x"){throw RouteBackendError(ETIMEDOUT,outcomeUnknown:true)} as Int;check(false,"未知结果应抛出")}
        catch {check(true,"未知结果应抛出")}
        check(try String(contentsOf:current,encoding:.utf8).contains("unknown"),"未知提交结果持久化")
        let absent=RouteAuditLog(directory:temporary.appendingPathComponent("missing"));var executed=false
        do {_=try absent.operation(transaction:transaction,stage:"protection",kind:"add",identity:"x"){executed=true};check(false,"写前日志失败必须拒绝操作")}
        catch {check(!executed,"写前日志失败不运行内核调用")}
        let (malformed,malformedServer)=try pair()
        DispatchQueue.global().async {
            defer{close(malformedServer)}
            do {_=try UnixChannel.receive(fd:malformedServer);var size=UInt32(UnixChannel.maximum+1).bigEndian;_ = withUnsafeBytes(of:&size){Darwin.send(malformedServer,$0.baseAddress,$0.count,0)}}catch{}
        }
        do {_=try await malformed.exchange(Data("x".utf8),progress:{_ in},timeout:0.2);check(false,"非法消息长度拒绝")}
        catch{check(true,"非法消息长度拒绝")};malformed.cancel()
        let cancelledChannel=try pair();let preCancelled=Task {try await cancelledChannel.0.exchange(Data("x".utf8),progress:{_ in})};preCancelled.cancel()
        do {_=try await preCancelled.value;check(false,"已取消任务不能提交")}
        catch{check(true,"已取消任务不能提交")};cancelledChannel.0.cancel();close(cancelledChannel.1)
        _=try audit.operation(transaction:transaction,stage:"recovery",kind:"delete",identity:"x",result:{_ in "rejected"}){1}
        check(try String(contentsOf:current,encoding:.utf8).contains("rejected"),"内核拒绝与成功在日志中区分")
        _=try audit.operation(transaction:transaction,stage:"credential-secret",kind:"credential-secret",identity:"credential-secret",result:{_ in "credential-secret"}){42}
        check(try !String(contentsOf:current,encoding:.utf8).contains("credential-secret"),"未知阶段、操作和结果只能写入受限枚举")
        print("HELPER_CHANNEL_OFFLINE_OK assertions=\(checks) routeSockets=0 helperConnections=0")
    }
}
