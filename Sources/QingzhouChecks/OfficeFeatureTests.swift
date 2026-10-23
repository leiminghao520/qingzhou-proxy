import Foundation
import Network
import QingzhouKit

func runOfficeFeatureChecks() async throws {
    let target=try SavedDiagnosticTarget(name:" 内部仓库 ",host:"Git.EXAMPLE.",port:8443,test:.tls,expectedPath:.direct).validated()
    expectEqual(target.host,"git.example");expectEqual(target.name,"内部仓库");expectEqual(target.effectivePort,8443)
    for host in ["host","example.com","127.0.0.1","::1","2001:db8::1"] {expectEqual(try SavedDiagnosticTarget(name:"目标",host:host).validated().host,host)}
    for host in ["","https://internal.example","internal.example/path","*.example.com","a..b","host:443","$(id)","a b","a\nb","-a.example"] {expectThrows(try SavedDiagnosticTarget(name:"目标",host:host).validated())}
    expectThrows(try SavedDiagnosticTarget(name:"",host:"example.com").validated())
    expectThrows(try SavedDiagnosticTarget(name:"目标",host:"example.com",port:65536).validated())
    expectThrows(try SavedDiagnosticTarget(name:"目标",host:"example.com",port:0).validated())
    expectThrows(try SavedDiagnosticTarget.validate([target,target]))
    expectThrows(try SavedDiagnosticTarget.validate((0..<101).map{SavedDiagnosticTarget(name:String($0),host:"example.com")}))

    expectEqual(try SavedDiagnosticTarget.revision([target]),try SavedDiagnosticTarget.revision([target]))
    let legacy=try JSONDecoder().decode(AppState.self,from:Data("{}".utf8));expectNil(legacy.savedDiagnosticTargets)
    var state=AppState();state.savedDiagnosticTargets=[target]
    expectEqual(try JSONDecoder().decode(AppState.self,from:JSONEncoder().encode(state)).savedDiagnosticTargets,[target])
    var catalog=ProfileCatalog(state:state)
    catalog=try ProfileStore.create(in:catalog,name:"副本",copyID:catalog.currentProfileID)
    expectEqual(catalog.profiles.last?.configuration.savedDiagnosticTargets,[target])
    let snapshot=try BackupService.snapshot(catalog,credentials:MemoryCredentials())
    let backup=try BackupService.encrypt(snapshot,password:"隔离检查口令")
    expectEqual(try BackupService.decrypt(backup,password:"隔离检查口令").catalog.active.savedDiagnosticTargets,[target])
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:directory)}
    let credentials=MemoryCredentials(),store=try NodeStore(file:directory.appendingPathComponent("state.json"),credentials:credentials)
    try store.commit(state)
    let sub=Subscription(name:"隔离订阅")
    try store.importNodes([try NodeParser.parse("hy2://test@node.example")],subscription:sub,source:"https://subscription.example/list")
    expectEqual(store.state.savedDiagnosticTargets,[target])
    try store.importNodes([try NodeParser.parse("hy2://updated@node.example")],subscription:store.state.subscriptions[0])
    expectEqual(store.state.savedDiagnosticTargets,[target])
    let restore=try store.prepareRestore(snapshot);try store.commit(restore)
    expectEqual(store.state.savedDiagnosticTargets,[target])

    let bank=try OfficeSceneTemplate.bank.configuration(domains:["internal.example"],cidrs:["10.20.0.0/16"],targets:[target])
    expectEqual(bank.protectedDomains,["internal.example"]);expectEqual(bank.dnsPreference,.system)
    expectEqual(bank.savedDiagnosticTargets,[target]);expectEqual(bank.captureMode,.systemProxy)
    expectFalse(bank.autoConnect);expectTrue(bank.nodes.isEmpty);expectEqual(bank.rules.count,2)
    expectThrows(try OfficeSceneTemplate.bank.configuration(cidrs:["0.0.0.0/0"]))
    for scene in [OfficeSceneTemplate.home,.temporary] {
        let clean=try scene.configuration(domains:["internal.example"],cidrs:["10.0.0.0/8"],targets:[target])
        expectTrue(clean.protectedDomains.isEmpty);expectTrue(clean.nodes.isEmpty);expectTrue(clean.tunExcludedCIDRs.isEmpty)
        expectFalse(clean.autoConnect);expectNil(clean.savedDiagnosticTargets);expectEqual(clean.captureMode,.systemProxy)
    }
    let commands=try DeveloperProxyCommands(port:7890,domains:["INTERNAL.EXAMPLE"])
    expectTrue(commands.enable.contains("NO_PROXY='localhost,127.0.0.1,::1,internal.example,.internal.example'"))
    expectTrue(commands.disable.hasPrefix("unset "));expectTrue(commands.gitRepository.contains("--local"))
    expectTrue(commands.maven.contains("localhost|127.0.0.1|[::1]|internal.example|*.internal.example"))
    expectThrows(try DeveloperProxyCommands(port:0,domains:[]))
    expectThrows(try DeveloperProxyCommands(port:7890,domains:["x';touch /tmp/invalid"]))
    let secret="credential-value-that-must-not-be-output"
    expectFalse(DeveloperToolInspector.environment(["HTTP_PROXY":secret]).joined().contains(secret))
    expectFalse(DeveloperToolInspector.configuration(Data(("[http]\nproxy = "+secret).utf8),kind:"git").joined().contains(secret))
    expectTrue(DeveloperToolInspector.configuration(Data("<proxies><proxy><nonProxyHosts>x</nonProxyHosts></proxy></proxies>".utf8),kind:"maven").joined().contains("检测到 Maven"))

    let now=Date(),context=OfficeHealthContext(profileID:UUID(),connectionID:UUID(),networkID:UUID())
    var health=OfficeHealthSnapshot(id:"external",title:"外网",status:.healthy,detail:"已核验",checkedAt:now,context:context)
    expectTrue(health.isCurrent(context,now:now));expectFalse(health.isCurrent(context,now:now.addingTimeInterval(121)))
    expectFalse(health.isCurrent(context,now:now.addingTimeInterval(-1)))
    expectFalse(health.isCurrent(OfficeHealthContext(profileID:context.profileID,connectionID:context.connectionID,networkID:UUID()),now:now))
    health.stale=true;expectFalse(health.isCurrent(context,now:now))
    expectEqual(OfficeTelemetryCadence.connections(hidden:false,pageVisible:true),1)
    expectEqual(OfficeTelemetryCadence.connections(hidden:false,pageVisible:false),5)
    expectEqual(OfficeTelemetryCadence.connections(hidden:true,pageVisible:true),10)
    expectEqual(OfficeTelemetryCadence.policies(hidden:false),5);expectEqual(OfficeTelemetryCadence.policies(hidden:true),10)
    expectEqual(OfficeTelemetryCadence.traffic(hidden:false),1);expectEqual(OfficeTelemetryCadence.traffic(hidden:true),5)
    var menu=AppState()
    menu.nodes=try (0..<25).map{try NodeParser.parse("hy2://test@n\($0).example").node}
    menu.selectedPolicy = .node(menu.nodes[20].id);menu.favorites=Set(menu.nodes.prefix(20).map(\.id))
    menu.recentUse[menu.nodes[24].id.uuidString]=now
    let items=OfficeTelemetryCadence.menuNodes(menu,actualTag:PolicyReference.node(menu.nodes[21].id).tag)
    expectEqual(items.count,15);expectEqual(Set(items.map(\.id)).count,15)
    expectTrue(items.prefix(2).contains{$0.id==menu.nodes[20].id});expectTrue(items.prefix(2).contains{$0.id==menu.nodes[21].id})
    menu.favorites=[]
    expectEqual(OfficeTelemetryCadence.menuNodes(menu,actualTag:nil).last?.id,menu.nodes[24].id)
    let evidence=TargetPathEvidence(rows:[],addresses:["127.0.0.1"],corporate:false)
    let loopback=SavedDiagnosticTarget(name:"隔离端口",host:"127.0.0.1",test:.tcp)
    let disconnected=await TargetConnectionProbe.run(loopback,evidence:evidence,state:AppState(),connected:false)
    expectEqual(disconnected.code,"notConnected")
    let refused=await TargetConnectionProbe.run(loopback,evidence:TargetPathEvidence(rows:[],addresses:[],corporate:true),state:AppState(),connected:true)
    expectEqual(refused.code,"pathUnverified")
    let listener=try await OfficeLoopbackListener.start();defer{listener.close()}
    let tcp=SavedDiagnosticTarget(name:"隔离端口",host:"127.0.0.1",port:listener.port,test:.tcp)
    let passed=await TargetConnectionProbe.run(tcp,evidence:evidence,state:AppState(),connected:true)
    expectEqual(passed.code,"targetConnectionPassed")
    var tls=tcp;tls.test = .tls
    let waiting=Task{await TargetConnectionProbe.run(tls,evidence:evidence,state:AppState(),connected:true)}
    let waiting2=Task{await TargetConnectionProbe.run(tls,evidence:evidence,state:AppState(),connected:true)}
    try await Task.sleep(nanoseconds:200_000_000)
    let overloaded=await TargetConnectionProbe.run(tls,evidence:evidence,state:AppState(),connected:true)
    expectEqual(overloaded.code,"overloaded")
    waiting.cancel();waiting2.cancel()
    let cancelled=await waiting.value,cancelled2=await waiting2.value
    expectEqual(cancelled.code,"cancelled");expectEqual(cancelled2.code,"cancelled")
    let resumed=await TargetConnectionProbe.run(tcp,evidence:evidence,state:AppState(),connected:true)
    expectEqual(resumed.code,"targetConnectionPassed")
    let proxy=try await OfficeLoopbackListener.start(socks:true);defer{proxy.close()}
    var proxyState=AppState();proxyState.listenPort=proxy.port
    let proxyTarget=SavedDiagnosticTarget(name:"隔离代理",host:"target.invalid",port:443,test:.tcp,expectedPath:.proxy)
    let proxied=await TargetConnectionProbe.run(proxyTarget,evidence:evidence,state:proxyState,connected:true)
    expectEqual(proxied.code,"targetConnectionPassed");expectEqual(proxy.destinations.last,"target.invalid")
    let rejectProxy=try await OfficeLoopbackListener.start(socks:true,reject:true);defer{rejectProxy.close()}
    proxyState.listenPort=rejectProxy.port
    let rejectedProxy=await TargetConnectionProbe.run(proxyTarget,evidence:evidence,state:proxyState,connected:true)
    expectEqual(rejectedProxy.code,"targetConnectionFailed");expectEqual(rejectProxy.destinations.last,"target.invalid")
    let countBefore=listener.acceptedCount
    var noFallback=tcp;noFallback.expectedPath = .proxy
    let rejected=await TargetConnectionProbe.run(noFallback,evidence:evidence,state:proxyState,connected:true)
    expectEqual(rejected.code,"targetConnectionFailed")
    expectEqual(listener.acceptedCount,countBefore,"本机保护与预期代理冲突时不能擅自直连")
    let exported=try DiagnosticSession(profileID:nil,connectionID:UUID(),nodeID:nil,results:[DiagnosticResult("目标路径","失败","internal.example "+secret,code:"pathMismatch")]).export(json:true)
    expectFalse(String(decoding:exported,as:UTF8.self).contains(secret));expectFalse(String(decoding:exported,as:UTF8.self).contains("internal.example"))
    for _ in 0..<20 {
        let control=CoreAPIClient(context:try CoreControlContext.make(),protocolClasses:[OfficeClosingProtocol.self])
        let inFlight=Task {try await control.connections()}
        try await Task.sleep(nanoseconds:1_000_000)
        await control.shutdown();_ = await inFlight.result
        do {_ = try await control.connections();CheckHarness.failure("关闭后不能创建新的控制请求",file:#filePath,line:#line)}
        catch {expectTrue(error is CoreAPIError)}
        do {_ = try await control.traffic();CheckHarness.failure("关闭后不能创建新的流量通道",file:#filePath,line:#line)}
        catch {expectTrue(error is CoreAPIError)}
    }
    print("PASS OfficeFeature.compatibilityTemplatesCommandsCadenceAndLoopbackCancellation")
}

private final class OfficeClosingProtocol:URLProtocol {
    private let lock=NSLock()
    private var stopped=false
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline:.now()+0.05) {[weak self] in
            guard let self else{return};self.lock.lock();let stopped=self.stopped;self.lock.unlock();guard !stopped else{return}
            let response=HTTPURLResponse(url:self.request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!
            self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self,didLoad:Data("{\"uploadTotal\":0,\"downloadTotal\":0,\"connections\":[]}".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {lock.lock();stopped=true;lock.unlock()}
}

// 仅接收回环连接，不发送 TLS 数据，用于验证取消与并发上限。
private final class OfficeLoopbackListener:@unchecked Sendable {
    private let listener:NWListener
    private let lock=NSLock()
    private var connections:[NWConnection]=[]
    private var hosts:[String]=[]
    private let socks:Bool
    private let reject:Bool
    private let queue=DispatchQueue(label:"cn.qingzhou.office-checks")
    var port:Int {Int(listener.port!.rawValue)}
    var destinations:[String] {lock.lock();defer{lock.unlock()};return hosts}
    var acceptedCount:Int {lock.lock();defer{lock.unlock()};return connections.count}
    init(socks:Bool,reject:Bool) throws {self.socks=socks;self.reject=reject;let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any);listener=try NWListener(using:parameters,on:.any)}
    static func start(socks:Bool=false,reject:Bool=false) async throws -> OfficeLoopbackListener {
        let value=try OfficeLoopbackListener(socks:socks,reject:reject)
        try await withCheckedThrowingContinuation {(continuation:CheckedContinuation<Void,Error>) in
            value.listener.stateUpdateHandler={state in
                if case .ready=state {value.listener.stateUpdateHandler=nil;continuation.resume()}
                if case .failed(let error)=state {value.listener.stateUpdateHandler=nil;continuation.resume(throwing:error)}
            }
            value.listener.newConnectionHandler={connection in
                value.lock.lock();value.connections.append(connection);value.lock.unlock();connection.start(queue:value.queue)
                if value.socks {value.greeting(connection)}
            }
            value.listener.start(queue:value.queue)
        }
        return value
    }
    private func read(_ connection:NWConnection,count:Int,buffer:Data=Data(),completion:@escaping (Data)->Void) {
        connection.receive(minimumIncompleteLength:1,maximumLength:count-buffer.count) {[weak self] data,_,done,error in
            guard let self else{return};var next=buffer;if let data {next.append(data)}
            if next.count==count {completion(next)}
            else if done || error != nil {connection.cancel()}
            else {self.read(connection,count:count,buffer:next,completion:completion)}
        }
    }
    private func greeting(_ connection:NWConnection) {
        read(connection,count:2) {[weak self] header in
            guard let self,header[0]==5,header[1]>0 else {connection.cancel();return}
            self.read(connection,count:Int(header[1])) {methods in
                guard methods.contains(0) else {connection.cancel();return}
                connection.send(content:Data([5,0]),completion:.contentProcessed{error in
                    if error != nil {connection.cancel();return}
                    self.read(connection,count:4) {header in
                        guard header[0]==5,header[1]==1 else {connection.cancel();return}
                        if header[3]==3 {
                            self.read(connection,count:1) {length in self.destination(connection,length:Int(length[0]),domain:true)}
                        }else if header[3]==1 {self.destination(connection,length:4,domain:false)}
                        else if header[3]==4 {self.destination(connection,length:16,domain:false)}
                        else {connection.cancel()}
                    }
                })
            }
        }
    }
    private func destination(_ connection:NWConnection,length:Int,domain:Bool) {
        read(connection,count:length+2) {[weak self] data in
            guard let self else{return}
            let host=domain ? String(decoding:data.prefix(length),as:UTF8.self):data.prefix(length).map{String($0)}.joined(separator:".")
            self.lock.lock();self.hosts.append(host);self.lock.unlock()
            connection.send(content:Data([5,self.reject ? 5:0,0,1,127,0,0,1,0,0]),completion:.contentProcessed{_ in if self.reject {connection.cancel()}})
        }
    }
    func close() {listener.cancel();lock.lock();let connections=self.connections;self.connections=[];lock.unlock();for connection in connections {connection.cancel()};listener.newConnectionHandler=nil}
}
