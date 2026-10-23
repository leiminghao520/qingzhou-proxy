import Foundation
import Combine
import QingzhouKit

@MainActor final class NetworkTimelineModel:ObservableObject {
    @Published private(set) var rows:[NetworkEvent]=[]
    @Published private(set) var error:String?
    @Published private(set) var dropped=0
    private let worker:TimelineWorker
    private var pending:[NetworkEvent]=[]
    private var task:Task<Void,Never>?
    private var writing=false
    private var activated=false
    private var clearing=false
    private var generation=UUID()
    var pendingCount:Int {pending.count}
    init(url:URL,now:@escaping ()->Date,autoload:Bool=true,makeStore:((URL)throws->NetworkEventStore)?=nil) {
        worker=TimelineWorker(url:url,now:now,makeStore:makeStore)
        if autoload {activate()}
    }
    // 取得应用单实例锁后才读取和清理事件文件，避免第二个实例抢写。
    func activate() {
        guard !activated else{return};activated=true
        let token=generation
        worker.queue.async { [worker,weak self] in
            do {let rows=Array(try worker.store().records.suffix(1000));Task {@MainActor in if self?.generation==token {self?.rows=rows}}}
            catch {Task {@MainActor in self?.reportFailure()}}
        }
    }
    func record(_ event:NetworkEvent) {
        guard activated else{return}
        pending.append(event)
        if pending.count>1000 {dropped+=pending.count-1000;pending.removeFirst(pending.count-1000)}
        guard task==nil else{return}
        task=Task { [weak self] in
            do {try await Task.sleep(nanoseconds:500_000_000)}catch{return}
            self?.flush()
        }
    }
    private func flush() {
        task?.cancel();task=nil
        guard !writing else{return}
        let batch=pending;pending=[];let token=generation
        guard !batch.isEmpty else{return}
        writing=true
        worker.queue.async { [worker,weak self] in
            do {let store=try worker.store();try store.append(batch);let rows=Array(store.records.suffix(1000));Task {@MainActor in if self?.generation==token {self?.rows=rows};self?.finishedWriting()}}
            catch {Task {@MainActor in self?.reportFailure();self?.finishedWriting()}}
        }
    }
    private func finishedWriting() {writing=false;if !pending.isEmpty {flush()}}
    func reportFailure() {if error==nil {error="网络事件保存失败，请检查用户目录权限；代理继续运行"}}
    func clear() async {
        guard activated,!clearing else{return}
        clearing=true;defer{clearing=false}
        task?.cancel();task=nil;pending=[];generation=UUID()
        let token=generation
        await withCheckedContinuation {continuation in
            worker.queue.async { [worker,weak self] in
                do {try worker.store().clear();Task {@MainActor in if self?.generation==token {self?.rows=[];self?.error=nil};continuation.resume()}}
                catch {Task {@MainActor in self?.reportFailure();continuation.resume()}}
            }
        }
    }
    func maintain() {
        guard activated,!writing,!clearing else{return}
        writing=true;let token=generation
        worker.queue.async { [worker,weak self] in
            do {
                let store=try worker.store();try store.append([]);let rows=Array(store.records.suffix(1000))
                Task {@MainActor in if self?.generation==token,self?.rows != rows {self?.rows=rows};self?.finishedWriting()}
            }catch {Task {@MainActor in self?.reportFailure();self?.finishedWriting()}}
        }
    }
    func drain() async {
        flush()
        let deadline=ProcessInfo.processInfo.systemUptime+2
        while (writing || !pending.isEmpty) && ProcessInfo.processInfo.systemUptime<deadline && !Task.isCancelled {try? await Task.sleep(nanoseconds:10_000_000)}
    }
}
private final class TimelineWorker:@unchecked Sendable {
    let queue=DispatchQueue(label:"cn.qingzhou.network-events",qos:.utility)
    private let url:URL
    private let now:()->Date
    private var database:NetworkEventStore?
    private let makeStore:((URL)throws->NetworkEventStore)?
    init(url:URL,now:@escaping ()->Date,makeStore:((URL)throws->NetworkEventStore)?) {self.url=url;self.now=now;self.makeStore=makeStore}
    func store() throws -> NetworkEventStore {if let database{return database};let value=try makeStore?(url) ?? NetworkEventStore(url:url,now:now);database=value;return value}
}
