import Foundation
import QingzhouKit

@MainActor final class TrafficHistoryModel: ObservableObject {
    @Published private(set) var rows:[TrafficHistoryRow]=[]
    @Published private(set) var error:String?
    private let worker:TrafficHistoryWorker
    private var accumulator=TrafficHistoryAccumulator()
    private var pending:[String:TrafficHistoryRow]=[:]
    private var flushTask:Task<Void,Never>?
    private let now:()->Date
    private var revision=0
    init(url:URL,now:@escaping ()->Date,makeStore:@escaping (URL)throws->TrafficHistoryStore) {self.worker=TrafficHistoryWorker(url:url,makeStore:makeStore);self.now=now}
    func begin() {finish();accumulator=TrafficHistoryAccumulator()}
    func receive(_ snapshot:ConnectionSnapshot,profileID:UUID) {
        for row in accumulator.receive(snapshot,profileID:profileID,now:now()) {
            if var old=pending[row.id] {old.upload+=row.upload;old.download+=row.download;old.incomplete = old.incomplete || row.incomplete;pending[row.id]=old}
            else {pending[row.id]=row}
        }
        guard flushTask==nil else{return}
        flushTask=Task{[weak self] in
            do {try await Task.sleep(nanoseconds:30_000_000_000)}catch{return}
            self?.finish()
        }
    }
    func finish() {
        flushTask?.cancel();flushTask=nil
        let batch=Array(pending.values);pending=[:]
        guard !batch.isEmpty else{return}
        let date=now();revision+=1;let revision=revision
        worker.queue.async {[self,worker] in
            do {let store=try worker.database();try store.append(batch,now:date);let values=try store.rows();Task{@MainActor in if self.revision==revision {self.rows=values}}}
            catch {Task{@MainActor in self.error="流量历史保存失败，当前内存监控继续可用"}}
        }
    }
    func reload() {
        finish()
        let date=now();revision+=1;let revision=revision
        worker.queue.async {[self,worker] in
            do {let store=try worker.database();try store.append([],now:date);let values=try store.rows();Task{@MainActor in if self.revision==revision {self.rows=values}}}
            catch {Task{@MainActor in self.error="流量历史无法读取"}}
        }
    }
    func clear() {
        flushTask?.cancel();flushTask=nil;pending=[:];revision+=1;let revision=revision
        worker.queue.async {[self,worker] in
            do {try worker.database().clear();Task{@MainActor in if self.revision==revision {self.rows=[];self.error=nil}}}
            catch {Task{@MainActor in self.error="流量历史清除失败"}}
        }
    }
    func drain() async {finish();await withCheckedContinuation{continuation in worker.queue.async{continuation.resume()}}}
}

// 该对象仅在自己的串行队列访问，避免从后台队列读取主线程隔离状态。
private final class TrafficHistoryWorker: @unchecked Sendable {
    let queue=DispatchQueue(label:"cn.qingzhou.traffic-history",qos:.utility)
    private let url:URL
    private let makeStore:(URL)throws->TrafficHistoryStore
    private var store:TrafficHistoryStore?
    init(url:URL,makeStore:@escaping (URL)throws->TrafficHistoryStore){self.url=url;self.makeStore=makeStore}
    func database() throws -> TrafficHistoryStore {
        if let store {return store}
        let value=try makeStore(url);store=value;return value
    }
}
