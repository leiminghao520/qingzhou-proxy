import Foundation
import QingzhouKit

private final class PreparationCounter {
    private let lock=NSLock()
    private var active=0
    private var peak=0
    private var calls=0
    private var cancelled=false
    func enter() {lock.lock();active+=1;calls+=1;peak=max(peak,active);lock.unlock()}
    func leave() {lock.lock();active-=1;lock.unlock()}
    func cancel() {lock.lock();cancelled=true;lock.unlock()}
    var isCancelled:Bool {lock.lock();defer{lock.unlock()};return cancelled}
    var snapshot:(Int,Int,Int) {lock.lock();defer{lock.unlock()};return (active,peak,calls)}
}

private final class StartupFixtureProtocol:URLProtocol {
    private static let lock=NSLock()
    private static var cancellations=0
    private var work:DispatchWorkItem?
    static var cancelledRequests:Int {lock.lock();defer{lock.unlock()};return cancellations}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let url=request.url!
        let target=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first{$0.name=="url"}?.value
        // 主目标保持挂起，次目标成功；另一个端口用于父任务取消场景。
        if url.path.hasSuffix("/delay"),((target==ConfigBuilder.testURL && url.port != 18409) || url.port==18408) {return}
        let body:String
        if url.path=="/proxies" {
            let tag="node-00000000-0000-0000-0000-000000000001"
            body="{\"proxies\":{\"proxy\":{\"type\":\"Selector\",\"name\":\"proxy\",\"now\":\"\(tag)\"},\"\(tag)\":{\"type\":\"Shadowsocks\",\"name\":\"\(tag)\"}}}"
        } else if url.path=="/connections" {body="{\"connections\":[],\"uploadTotal\":0,\"downloadTotal\":0}"}
        else {body="{\"delay\":21}"}
        let item=DispatchWorkItem { [weak self] in
            guard let self else{return}
            self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self,didLoad:Data(body.utf8));self.client?.urlProtocolDidFinishLoading(self)
        }
        work=item
        DispatchQueue.global().asyncAfter(deadline:.now()+(url.path=="/connections" ? 0.12:(url.port==18409 && target==ConfigBuilder.testURL ? 0.3:0.03)),execute:item)
    }
    override func stopLoading() {
        work?.cancel()
        Self.lock.lock();Self.cancellations+=1;Self.lock.unlock()
    }
}

func runStartupOptimizationChecks() async throws {
    let id=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    let client=CoreAPIClient(context:CoreControlContext(port:18407,secret:"synthetic"),protocolClasses:[StartupFixtureProtocol.self])
    let before=StartupFixtureProtocol.cancelledRequests
    let started=DispatchTime.now().uptimeNanoseconds
    async let unrelated=client.connections()
    let measured=await client.measureNode(id)
    if case .success(let delay)=measured {expectEqual(delay,21)} else {expectTrue(false,"任一目标成功应通过")}
    expectTrue(Double(DispatchTime.now().uptimeNanoseconds-started)/1e9<1,"不能等待挂起目标超时")
    expectTrue(StartupFixtureProtocol.cancelledRequests>before,"成功必须取消剩余请求")
    let connections=try await unrelated
    expectEqual(connections.connections.count,0,"取消不能影响并发控制请求")
    let node=await ConnectivityProbe.node(client:client,mode:.rule)
    expectEqual(node.status,.passed)
    let status=await client.probe(id)
    expectTrue({if case .available=status{return true};return false}())
    _=try await client.proxies()
    await client.shutdown()

    let cancelling=CoreAPIClient(context:CoreControlContext(port:18408,secret:"synthetic"),protocolClasses:[StartupFixtureProtocol.self])
    let task=Task {await cancelling.measureNode(id)}
    try await Task.sleep(nanoseconds:50_000_000);task.cancel()
    if case .failure(let categories)=await task.value {expectTrue(categories.contains("取消"))} else {expectTrue(false,"已取消任务不得返回成功")}
    _=try await cancelling.proxies();await cancelling.shutdown()

    let pool=NetworkPreparationPool(),counter=PreparationCounter()
    let hosts=(0..<12).map{"node\($0).test"}
    let addresses=try pool.addresses(hosts+hosts,resolver:{_ in
        counter.enter();defer{counter.leave()};Thread.sleep(forTimeInterval:0.02)
        return ["192.0.2.1","2001:db8::1"]
    })
    expectEqual(addresses.count,12);expectEqual(counter.snapshot.2,12)
    expectTrue(counter.snapshot.1<=4 && counter.snapshot.1>1,"DNS 必须并发且不能超过四个")
    expectEqual(addresses[hosts[0]], ["192.0.2.1","2001:db8::1"])
    let baseline=try pool.map(Array(0..<9),operation:{value in
        counter.enter();defer{counter.leave()};Thread.sleep(forTimeInterval:0.01);return value%2==0
    })
    expectEqual(baseline,[true,false,true,false,true,false,true,false,true])
    let itemStarted=DispatchTime.now().uptimeNanoseconds
    let lateRelease=DispatchSemaphore(value:0)
    do {_=try pool.addresses(["late"],itemTimeout:0.02,totalTimeout:1,resolver:{_ in _ = lateRelease.wait(timeout:.now()+0.7);return ["192.0.2.9"]});expectTrue(false)} catch {expectTrue(true)}
    expectTrue(Double(DispatchTime.now().uptimeNanoseconds-itemStarted)/1e9<0.5,"单项超时不能等待底层解析退出")
    lateRelease.signal()
    let fresh=try pool.addresses(["fresh"],resolver:{_ in ["192.0.2.2"]})
    expectEqual(fresh,["fresh":["192.0.2.2"]],"晚到的旧批次结果不能污染新批次")
    do {_=try pool.map(Array(0..<20),totalTimeout:0.025,operation:{value in Thread.sleep(forTimeInterval:0.02);return value});expectTrue(false)} catch {expectTrue(true)}
    let cancellation=PreparationCounter()
    DispatchQueue.global().asyncAfter(deadline:.now()+0.02){cancellation.cancel()}
    do {_=try pool.map([1],cancelled:{cancellation.isCancelled},operation:{_ in Thread.sleep(forTimeInterval:0.12);return 1});expectTrue(false)} catch {expectTrue(error is CancellationError)}

    let blocked=NetworkPreparationPool(),blockedCount=PreparationCounter(),release=DispatchSemaphore(value:0)
    for _ in 0..<5 {
        do {_=try blocked.map(Array(0..<8),totalTimeout:0.04,operation:{value in
            blockedCount.enter();defer{blockedCount.leave()};release.wait();return value
        });expectTrue(false)} catch {expectTrue(true)}
    }
    expectEqual(blockedCount.snapshot.2,4,"超时重试不能累积底层解析线程")
    for _ in 0..<4 {release.signal()}
    let resumed=try blocked.map([99],totalTimeout:1,operation:{$0})
    expectEqual(resumed,[99],"原解析退出后才能复用槽位")
    do {_=try pool.map([1],operation:{_ -> Int in throw ProxyError("合成失败")});expectTrue(false)} catch {expectTrue(true)}
    let empty:[Int]=try pool.map([Int](),operation:{$0});expectTrue(empty.isEmpty)
    do {_=try pool.map([1],itemTimeout:0,operation:{$0});expectTrue(false)} catch {expectTrue(true)}
    do {_=try pool.map([1],totalTimeout:.infinity,operation:{$0});expectTrue(false)} catch {expectTrue(true)}
    let alreadyCancelled=PreparationCounter();alreadyCancelled.cancel()
    do {_=try pool.map([1],cancelled:{alreadyCancelled.isCancelled},operation:{value in alreadyCancelled.enter();return value});expectTrue(false)} catch {expectTrue(error is CancellationError)}
    expectEqual(alreadyCancelled.snapshot.2,0)


    let timing=ConnectionTiming();timing.begin("bootstrapDNS")
    try await Task.sleep(nanoseconds:5_000_000);timing.finish(succeeded:false)
    expectEqual(timing.samples.count,1);expectFalse(timing.samples[0].succeeded)
    expectTrue(timing.samples[0].milliseconds>=1)
    let encoded=try JSONEncoder().encode(TunReply(ok:false,message:"synthetic",stageTimings:timing.samples))
    let decoded=try JSONDecoder().decode(TunReply.self,from:encoded)
    expectEqual(decoded.stageTimings,timing.samples);expectEqual(decoded.protocolVersion,4)
    let legacy=try JSONDecoder().decode(TunReply.self,from:Data("{\"ok\":true,\"message\":\"legacy\",\"running\":false,\"protocolVersion\":4}".utf8))
    expectNil(legacy.stageTimings)
    print("PASS Startup.firstSuccessCancellationBoundedDNSAndTiming")
}

// 对照旧等待方式与正式新实现；全部使用隔离传输夹具，不表示真实 TUN 连接耗时。
func runStartupBenchmark(output:URL) async throws {
    let client=CoreAPIClient(context:CoreControlContext(port:18409,secret:"synthetic"),protocolClasses:[StartupFixtureProtocol.self])
    let id=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    var oldProbe:[Double]=[],newProbe:[Double]=[],oldDNS:[Double]=[],newDNS:[Double]=[]
    func now()->Double {Double(DispatchTime.now().uptimeNanoseconds)/1e6}
    let pool=NetworkPreparationPool()
    for _ in 0..<10 {
        var start=now()
        async let first=client.delay(id,url:ConfigBuilder.testURL)
        async let second=client.delay(id,url:ConfigBuilder.secondaryTestURL)
        _=try await [first,second];oldProbe.append(now()-start)
        start=now()
        guard case .success=await client.measureNode(id) else {throw ProxyError("隔离测速基准失败")}
        newProbe.append(now()-start)
        start=now()
        for _ in 0..<12 {try await Task.sleep(nanoseconds:20_000_000)}
        oldDNS.append(now()-start)
        start=now()
        _=try pool.addresses((0..<12).map{"node\($0).test"},resolver:{_ in Thread.sleep(forTimeInterval:0.02);return ["192.0.2.1"]})
        newDNS.append(now()-start)
    }
    await client.shutdown()
    func summary(_ values:[Double])->[String:Any] {
        let sorted=values.sorted()
        return ["samplesMs":values,"medianMs":(sorted[4]+sorted[5])/2,"maxMs":sorted.last!]
    }
    let result:[String:Any]=["kind":"synthetic-only","iterations":10,"realTUNVerified":false,
        "probeBefore":summary(oldProbe),"probeAfter":summary(newProbe),
        "dnsBefore":summary(oldDNS),"dnsAfter":summary(newDNS)]
    try SecureFile.write(JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),to:output)
    print("STARTUP_BENCHMARK_OK synthetic-only iterations=10")
}
