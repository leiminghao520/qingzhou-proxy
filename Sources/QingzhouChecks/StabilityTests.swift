import Foundation
import QingzhouKit

// 手动推进探测和队列时钟，不访问用户网络或配置。
@MainActor private final class ManualHealthClock {
    var waits:[CheckedContinuation<Void,Error>]=[]
    func sleep(_ nanos:UInt64) async throws {try await withCheckedThrowingContinuation{waits.append($0)}}
    func advance() {let values=waits;waits=[];for value in values {value.resume()}}
}
@MainActor func runStabilityAsyncChecks() async {
    let clock=ManualHealthClock();let scheduler=HealthRefreshScheduler(sleep:{try await clock.sleep($0)})
    var executions=0
    scheduler.schedule {executions+=1}
    for _ in 0..<50 {await Task.yield()}
    expectEqual(clock.waits.count,1)
    scheduler.schedule {executions+=10};scheduler.schedule {executions+=100}
    clock.advance()
    for _ in 0..<100 {await Task.yield()}
    expectEqual(executions,0);expectEqual(clock.waits.count,1)
    clock.advance();await scheduler.wait();expectEqual(executions,100)
    scheduler.schedule {executions+=1000}
    for _ in 0..<50 {await Task.yield()}
    scheduler.cancel();clock.advance();await scheduler.wait();expectEqual(executions,100)
    let immediate=HealthRefreshScheduler(sleep:{_ in})
    var gate:CheckedContinuation<Void,Never>?
    var active=0,maximum=0,staleWrites=0
    immediate.schedule {
        active+=1;maximum=max(maximum,active)
        await withCheckedContinuation{gate=$0}
        if !Task.isCancelled {staleWrites+=1};active-=1
    }
    for _ in 0..<50 {await Task.yield()};expectEqual(active,1)
    immediate.schedule {active+=1;maximum=max(maximum,active);active-=1}
    gate?.resume();await immediate.wait()
    expectEqual(maximum,1);expectEqual(staleWrites,0);expectEqual(active,0)
    var failures=HealthFailureCounter()
    expectFalse(failures.update([.unavailable]));expectFalse(failures.update([.unknown]));expectFalse(failures.update([.unavailable]));expectTrue(failures.update([.unavailable]))
    print("PASS Stability.healthDebounceCancelAndSerialCompletion")
}
final class StabilityTests:CheckCase {
    func testSnapshotRetryAndLatency() {
        var retry=NetworkSnapshotRetry()
        expectTrue(retry.ready(now:0));expectTrue(retry.failed(now:0));expectFalse(retry.ready(now:0.9));expectTrue(retry.ready(now:1))
        expectTrue(retry.failed(now:1));expectEqual(retry.retryAt,3)
        expectTrue(retry.failed(now:3));expectEqual(retry.retryAt,7);expectFalse(retry.failed(now:7));retry.reset();expectEqual(retry.attempts,0);expectTrue(retry.ready(now:0))
        let now=Date(timeIntervalSince1970:1000),start=Date(timeIntervalSince1970:900)
        let good=LatencyResult(milliseconds:50,testedAt:now)
        expectTrue(LatencyPresentation.current(good,invalidatedAt:start,now:now))
        expectEqual(LatencyPresentation.sortValue(good,invalidatedAt:start,now:now),50)
        expectTrue(LatencyPresentation.current(good,invalidatedAt:start,now:now.addingTimeInterval(300)))
        expectFalse(LatencyPresentation.current(good,invalidatedAt:start,now:now.addingTimeInterval(301)))
        expectEqual(LatencyPresentation.sortValue(good,invalidatedAt:now.addingTimeInterval(1),now:now),Int.max)
        expectFalse(LatencyPresentation.current(good,invalidatedAt:start,now:now.addingTimeInterval(-1)))
        expectFalse(LatencyPresentation.current(nil,invalidatedAt:start,now:now));expectEqual(LatencyPresentation.label(nil,invalidatedAt:start,now:now),"未检测")
        expectTrue(LatencyPresentation.label(good,invalidatedAt:start,now:now).contains("测试于"))
        expectTrue(LatencyPresentation.label(good,invalidatedAt:now.addingTimeInterval(1),now:now).contains("历史结果"))
        let failed=LatencyResult(milliseconds:nil,testedAt:now)
        expectTrue(LatencyPresentation.label(failed,invalidatedAt:start,now:now).contains("检测失败"));expectEqual(LatencyPresentation.sortValue(failed,invalidatedAt:start,now:now),Int.max)
    }
    func testDNSQueueBoundsBudgetAndStop() {
        var now=0.0,jobs:[()->Void]=[]
        var runs=0,rejected=0
        let queue=DNSWorkQueue(clock:{now},execute:{jobs.append($0)})
        for _ in 0..<97 {queue.submit(run:{_ in runs+=1},reject:{rejected+=1})}
        expectEqual(queue.snapshot.active,32);expectEqual(queue.snapshot.waiting,64);expectEqual(queue.snapshot.queued,64);expectEqual(queue.snapshot.overloaded,1);expectEqual(rejected,1)
        now=0.249;queue.expire();expectEqual(queue.snapshot.waiting,64)
        now=0.25;queue.expire();expectEqual(queue.snapshot.timeouts,64);expectEqual(rejected,65)
        while !jobs.isEmpty {jobs.removeFirst()()};expectEqual(runs,32);expectEqual(queue.snapshot.active,0)
        var budget=0.0
        let serial=DNSWorkQueue(activeLimit:1,waitingLimit:1,clock:{now},execute:{jobs.append($0)})
        serial.submit(run:{_ in runs+=1},reject:{rejected+=1});serial.submit(run:{budget=$0},reject:{rejected+=1})
        now+=0.1;jobs.removeFirst()();expectEqual(serial.snapshot.active,1);jobs.removeFirst()();expectTrue(abs(budget-4.9)<0.001)
        serial.submit(run:{_ in runs+=1},reject:{rejected+=1});serial.submit(run:{_ in runs+=1000},reject:{rejected+=1000})
        serial.stop();let before=runs;jobs.removeFirst()();expectEqual(runs,before);expectEqual(serial.snapshot.waiting,0)
        serial.submit(run:{_ in runs+=1000},reject:{rejected+=1000});expectTrue(jobs.isEmpty)
        serial.expire();expectTrue(serial.snapshot.summary.contains("DNS 队列"))
        let expired=DNSWorkQueue(clock:{now},execute:{jobs.append($0)})
        expired.submit(run:{_ in runs+=1000},reject:{rejected+=1});now+=5;jobs.removeFirst()();expectEqual(expired.snapshot.timeouts,1)
    }
    func testSubscriptionClassificationAndRetry() {
        let cases:[(URLError.Code,SubscriptionFailure)]=[(.cannotFindHost,.dns),(.dnsLookupFailed,.dns),(.timedOut,.timeout),(.secureConnectionFailed,.tls),(.serverCertificateHasBadDate,.tls),(.serverCertificateUntrusted,.tls),(.serverCertificateHasUnknownRoot,.tls),(.serverCertificateNotYetValid,.tls),(.clientCertificateRejected,.tls),(.clientCertificateRequired,.tls),(.cancelled,.cancelled),(.notConnectedToInternet,.network)]
        for (code,expected) in cases {expectEqual(SubscriptionFailure.classify(URLError(code)),expected)}
        expectEqual(SubscriptionFailure.classify(CancellationError()),.cancelled);expectEqual(SubscriptionFailure.classify(ProxyError("https://secret.invalid/token")),.format)
        for code in [401,403] {expectEqual(SubscriptionFailure.status(code),.unauthorized)}
        for code in [404,410] {expectEqual(SubscriptionFailure.status(code),.gone)}
        expectEqual(SubscriptionFailure.status(429),.rateLimited);expectEqual(SubscriptionFailure.status(500),.server);expectEqual(SubscriptionFailure.status(599),.server);expectEqual(SubscriptionFailure.status(400),.http)
        let now=Date(timeIntervalSince1970:0)
        for failure in SubscriptionFailure.allCases {
            expectEqual(SubscriptionFailure.classify(failure),failure);expectFalse(failure.localizedDescription.contains("secret.invalid"))
            let retry=SubscriptionFailure.retryState(failure,previousCount:0,now:now);expectEqual(retry.after != nil,failure.retryable)
            if failure.retryable {expectEqual(retry.after,now.addingTimeInterval(60))}else{expectEqual(retry.count,4)}
        }
        expectEqual(SubscriptionFailure.retryState(SubscriptionFailure.network,previousCount:1,now:now).after,now.addingTimeInterval(300))
        expectEqual(SubscriptionFailure.retryState(SubscriptionFailure.network,previousCount:2,now:now).after,now.addingTimeInterval(1800))
        expectEqual(SubscriptionFailure.retryState(SubscriptionFailure.network,previousCount:3,now:now).after,nil)
        expectFalse(UpdateSchedule.due(updatedAt:nil,enabled:true,retryCount:4,retryAfter:nil,now:now))
    }
}
