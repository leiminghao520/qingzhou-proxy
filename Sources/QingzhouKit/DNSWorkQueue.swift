import Foundation

// 队列与计数均受同一把锁保护，执行和失败回调始终在锁外调用。
public final class DNSWorkQueue: @unchecked Sendable {
    public struct Metrics {
        public var active=0,waiting=0,queued=0,overloaded=0,timeouts=0
        public var summary:String {"DNS 队列：执行 \(active)，等待 \(waiting)，累计排队 \(queued)，超载 \(overloaded)，超时 \(timeouts)"}
    }
    private struct Job {let id=UUID();let received:TimeInterval;let run:(TimeInterval)->Void;let reject:()->Void}
    private let lock=NSLock()
    private let clock:()->TimeInterval
    private let execute:(@escaping ()->Void)->Void
    private let activeLimit:Int,waitingLimit:Int
    private var metrics=Metrics()
    private var pending:[Job]=[]
    private var stopped=false
    public init(activeLimit:Int=32,waitingLimit:Int=64,clock:@escaping ()->TimeInterval={ProcessInfo.processInfo.systemUptime},execute:@escaping (@escaping ()->Void)->Void={DispatchQueue.global(qos:.userInitiated).async(execute:$0)}) {
        self.activeLimit=activeLimit;self.waitingLimit=waitingLimit;self.clock=clock;self.execute=execute
    }
    public var snapshot:Metrics {lock.lock();defer{lock.unlock()};return metrics}
    public func recordTimeout() {lock.lock();metrics.timeouts+=1;lock.unlock()}
    public func submit(run:@escaping (TimeInterval)->Void,reject:@escaping ()->Void) {
        let job=Job(received:clock(),run:run,reject:reject)
        lock.lock()
        if stopped {lock.unlock();return}
        if metrics.active<activeLimit {metrics.active+=1;lock.unlock();launch(job);return}
        guard pending.count<waitingLimit else{metrics.overloaded+=1;lock.unlock();reject();return}
        pending.append(job);metrics.waiting=pending.count;metrics.queued+=1;lock.unlock()
        DispatchQueue.global().asyncAfter(deadline:.now()+0.25){[weak self] in self?.expire()}
    }
    public func expire() {
        lock.lock();let now=clock();let expired=pending.filter{now-$0.received>=0.25}
        pending.removeAll{now-$0.received>=0.25};metrics.waiting=pending.count;metrics.timeouts+=expired.count
        let notify = !stopped;lock.unlock()
        if notify {for job in expired {job.reject()}}
    }
    public func stop() {lock.lock();stopped=true;pending=[];metrics.waiting=0;lock.unlock()}
    private func launch(_ job:Job) {
        execute { [self] in
            lock.lock();let allowed = !stopped;let remaining=5-(clock()-job.received);lock.unlock()
            if allowed {if remaining>0 {job.run(remaining)}else{recordTimeout();job.reject()}}
            finish()
        }
    }
    private func finish() {
        expire()
        lock.lock();metrics.active-=1
        let next:Job?
        if !stopped,!pending.isEmpty {next=pending.removeFirst();metrics.active+=1}else{next=nil}
        metrics.waiting=pending.count;lock.unlock()
        if let next {launch(next)}
    }
}
