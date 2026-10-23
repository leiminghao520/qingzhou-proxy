import Foundation

public struct DiagnosticSession: Codable, Sendable, Identifiable {
    public let id: UUID
    public let profileID: UUID?
    public let connectionID: UUID
    public let nodeID: UUID?
    public let startedAt: Date
    public var finishedAt: Date?
    public var results: [DiagnosticResult]
    public init(id:UUID=UUID(),profileID:UUID?,connectionID:UUID,nodeID:UUID?,startedAt:Date=Date(),results:[DiagnosticResult]=[]) {
        self.id=id;self.profileID=profileID;self.connectionID=connectionID;self.nodeID=nodeID;self.startedAt=startedAt;self.results=results
    }
    // 导出使用白名单字段，不导出目标、节点名、路由、凭据及原始错误内容。
    public func export(json:Bool) throws -> Data {
        let formatter=ISO8601DateFormatter()
        let rows:[[String:Any]]=results.map {row in
            ["stage":row.stage,"status":row.status,"outcome":row.outcome.rawValue,"code":row.code,"category":row.errorCategory.rawValue,"description":row.exportExplanation,"milliseconds":row.milliseconds.map{$0 as Any} ?? NSNull(),"checkedAt":formatter.string(from:row.checkedAt)]
        }
        if json {return try JSONSerialization.data(withJSONObject:["id":id.uuidString,"startedAt":formatter.string(from:startedAt),"finishedAt":finishedAt.map{formatter.string(from:$0) as Any} ?? NSNull(),"results":rows],options:[.prettyPrinted,.sortedKeys])}
        return Data((["诊断编号："+id.uuidString,"检查时间："+startedAt.formatted()]+results.map{$0.stage+" · "+$0.status+" · "+$0.code+" · "+($0.milliseconds.map{String($0)+" ms"} ?? "耗时未取得")+" · "+$0.exportExplanation}).joined(separator:"\n").utf8)
    }
}

public struct DiagnosticJob {
    public let stage:String
    public let run:() async -> [DiagnosticResult]
    public init(_ stage:String,run:@escaping () async -> [DiagnosticResult]) {self.stage=stage;self.run=run}
}

// 取消和总超时只终止本次等待；不等待不合作的同步系统调用，也不关闭代理的控制通道。
public final class DiagnosticExecutor: @unchecked Sendable {
    public init() {}
    public func run(_ session:DiagnosticSession,jobs:[DiagnosticJob],timeout:TimeInterval=30) async -> DiagnosticSession {
        let pending=DiagnosticPending(session:session,stages:jobs.map(\.stage))
        return await withTaskCancellationHandler(operation:{
            await withCheckedContinuation {continuation in
                pending.install(continuation)
                for (index,job) in jobs.enumerated() {
                    let task=Task {
                        guard !Task.isCancelled else{return}
                        let began=DispatchTime.now().uptimeNanoseconds
                        var rows=await job.run()
                        let elapsed=Int((DispatchTime.now().uptimeNanoseconds-began)/1_000_000)
                        for i in rows.indices {rows[i].milliseconds=rows[i].milliseconds ?? elapsed}
                        pending.receive(rows,index:index)
                    }
                    pending.add(task)
                }
                DispatchQueue.global().asyncAfter(deadline:.now()+max(0,timeout)) {pending.finish(code:"timeout",status:"超时")}
                pending.finishIfEmpty()
            }
        },onCancel:{pending.finish(code:"cancelled",status:"已取消")})
    }
}

private final class DiagnosticPending: @unchecked Sendable {
    private let lock=NSLock()
    private var session:DiagnosticSession
    private let stages:[String]
    private var results:[Int:[DiagnosticResult]]=[:]
    private var continuation:CheckedContinuation<DiagnosticSession,Never>?
    private var completed:DiagnosticSession?
    private var tasks:[Task<Void,Never>]=[]
    init(session:DiagnosticSession,stages:[String]) {self.session=session;self.stages=stages}
    func install(_ continuation:CheckedContinuation<DiagnosticSession,Never>) {
        lock.lock();if let completed {lock.unlock();continuation.resume(returning:completed)}else{self.continuation=continuation;lock.unlock()}
    }
    func add(_ task:Task<Void,Never>) {lock.lock();let done=completed != nil;if !done {tasks.append(task)};lock.unlock();if done {task.cancel()}}
    func receive(_ rows:[DiagnosticResult],index:Int) {lock.lock();if completed==nil {results[index]=rows};let ready=results.count==stages.count;lock.unlock();if ready {finish()}}
    func finishIfEmpty() {if stages.isEmpty {finish()}}
    func finish(code:String="complete",status:String="未验证") {
        lock.lock();guard completed==nil else{lock.unlock();return}
        session.results += stages.indices.flatMap {results[$0] ?? [DiagnosticResult(stages[$0],status,"本次检查未完成",code:code)]}
        session.finishedAt=Date();completed=session
        let reply=continuation;continuation=nil;let tasks=self.tasks;self.tasks=[];let value=session
        lock.unlock();for task in tasks {task.cancel()};reply?.resume(returning:value)
    }
}

// 超时调用继续占用原槽位，直到 getaddrinfo 真正结束；反复取消不能绕过两个执行槽位。
public final class DiagnosticWorkPool: @unchecked Sendable {
    public static let dns=DiagnosticWorkPool(limit:2)
    private let lock=NSLock()
    private var active=0
    private let limit:Int
    public init(limit:Int=2) {self.limit=max(1,limit)}
    public var activeCount:Int {lock.lock();defer{lock.unlock()};return active}
    private func acquire() -> Bool {lock.lock();defer{lock.unlock()};guard active<limit else{return false};active+=1;return true}
    public func run(stage:String,timeout:TimeInterval=3,operation:@escaping () throws -> [DiagnosticResult]) async -> [DiagnosticResult] {
        guard !Task.isCancelled else{return [DiagnosticResult(stage,"已取消","本次检查已取消",code:"cancelled")]}
        guard acquire() else {return [DiagnosticResult(stage,"未验证","诊断执行槽位已满，请稍后重试",code:"overloaded")]}
        let box=DiagnosticPending(session:DiagnosticSession(profileID:nil,connectionID:UUID(),nodeID:nil),stages:[stage])
        let response=await withTaskCancellationHandler(operation:{
            await withCheckedContinuation {continuation in
                box.install(continuation)
                DispatchQueue.global(qos:.utility).async { [self] in
                    let result:[DiagnosticResult]
                    do {result=try operation()}catch {result=[DiagnosticResult(stage,"失败","系统查询失败",code:"systemQueryFailed")]}
                    lock.lock();active-=1;lock.unlock()
                    box.receive(result,index:0)
                }
                DispatchQueue.global().asyncAfter(deadline:.now()+max(0,timeout)) {box.finish(code:"timeout",status:"超时")}
            }
        },onCancel:{box.finish(code:"cancelled",status:"已取消")})
        return response.results
    }
}

public final class DiagnosticCancellation:@unchecked Sendable {
    private let lock=NSLock()
    private var value=false
    public init() {}
    public var cancelled:Bool {lock.lock();defer{lock.unlock()};return value}
    public func cancel() {lock.lock();value=true;lock.unlock()}
}
