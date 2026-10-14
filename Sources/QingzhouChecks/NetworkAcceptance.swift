import Foundation
import SystemConfiguration
import Darwin
import QingzhouKit

// 实网检查只使用临时回环入口，不修改用户配置、系统代理、路由或 DNS。
@MainActor func runNetworkAcceptance(_ args:[String]) async throws {
    guard args.count==6 || args.count==7 else{throw ProxyError("用法：network-acceptance state.json sing-box qzhttp result.json [观察秒数]")}
    let duration=args.count==7 ? Int(args[6]) ?? 0:0
    guard duration==0 || (60...14400).contains(duration) else{throw ProxyError("观察时长必须为 60–14400 秒")}
    let started=Date()
    var active:[(CoreController,CoreAPIClient,Process?,Int,String)]=[]
    var samples:[[String:Any]]=[]
    let data=try Data(contentsOf:URL(fileURLWithPath:args[2]))
    let catalog=try JSONDecoder().decode(ProfileCatalog.self,from:data);try catalog.validate()
    let state=catalog.active,credentials=KeychainStore()
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("qingzhou-network-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    defer{try? FileManager.default.removeItem(at:dir)}
    var reports:[[String:Any]]=[]
    func rows(_ results:[ConnectivityResult])->[[String:Any]] {results.map{["stage":$0.title,"status":$0.status.rawValue,"category":$0.category,"milliseconds":$0.milliseconds as Any? ?? NSNull()]}}
    if let settings=SCDynamicStoreCopyProxies(nil) as? [String:Any],settings["HTTPEnable"] as? Int==1,settings["HTTPProxy"] as? String=="127.0.0.1",let port=settings["HTTPPort"] as? Int {
        async let first=ConnectivityProbe.https(port:port,entry:false)
        async let second=ConnectivityProbe.https(port:port,entry:true)
        let results=await [first,second]
        reports.append(["path":"current-system-proxy","results":rows(results)])
    }
    for compatible in [false,true] {
        if compatible && state.shadowrocket==nil {continue}
        var test=state;test.captureMode = .systemProxy;test.autoConnect=false;test.httpCompatibilityEnabled=compatible
        let control=try CoreControlContext.make();var used:Set<Int>=[control.port]
        func port() throws -> Int {for _ in 0..<20 {let port=try CoreControlContext.make().port;if used.insert(port).inserted{return port}};throw ProxyError("无法分配验收入口")}
        test.listenPort=try port();let publicPort=test.listenPort
        let corePort=compatible ? try port():publicPort,httpPort=compatible ? try port():nil
        var runtime=test;runtime.listenPort=corePort
        let binary=URL(fileURLWithPath:args[3]),runner=binary.deletingLastPathComponent().appendingPathComponent("QingzhouRunner")
        let core=CoreController(directory:dir,binary:binary,supervisor:FileManager.default.isExecutableFile(atPath:runner.path) ? runner:nil)
        let client=CoreAPIClient(context:control);var gateway:Process?
        do {
            try await core.start(config:ConfigBuilder.build(state:runtime,credentials:credentials,control:control,httpCompatibilityPort:httpPort),port:corePort)
            if compatible,let shadow=test.shadowrocket,let httpPort {
                let process=Process(),input=Pipe();process.executableURL=URL(fileURLWithPath:args[4]);process.standardInput=input;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
                gateway=process;try process.run();try input.fileHandleForReading.close()
                try input.fileHandleForWriting.write(contentsOf:shadow.gatewayData(listenPort:publicPort,corePort:corePort,httpPort:httpPort,control:control,state:test));try input.fileHandleForWriting.close()
                for _ in 0..<50 {if CoreController.listening(publicPort){break};try await Task.sleep(nanoseconds:100_000_000)}
            }
            var results=await ConnectivityProbe.all(port:publicPort,client:client,mode:test.mode)
            results.append(await socksProbe(publicPort))
            reports.append(["path":compatible ? "qingzhou-compatibility":"qingzhou-native","mode":test.mode.rawValue,"dns":test.dnsPreference.rawValue,"results":rows(results)])
        }catch{reports.append(["path":compatible ? "qingzhou-compatibility":"qingzhou-native","startup":"failed","category":ConnectivityResult.category(error)])}
        if duration>0,core.isRunning {active.append((core,client,gateway,publicPort,compatible ? "compatibility":"native"))}
        else {await stop(core,client,gateway)}
    }
    func save() throws {
        try SecureFile.write(JSONSerialization.data(withJSONObject:["date":ISO8601DateFormatter().string(from:started),"elapsedSeconds":Int(Date().timeIntervalSince(started)),"requestedDuration":duration,"completed":duration==0 || Date().timeIntervalSince(started)>=Double(duration),"protocols":state.nodes.map{$0.kind.rawValue},"systemNetworkModified":false,"paths":reports,"samples":samples],options:[.prettyPrinted,.sortedKeys]),to:URL(fileURLWithPath:args[5]))
    }
    do {
        try save()
        if duration>0 {print("SOAK_STARTED paths=\(active.count) duration=\(duration)");fflush(stdout)}
        while !active.isEmpty,Date().timeIntervalSince(started)<Double(duration) {
            try await Task.sleep(nanoseconds:UInt64(min(60,max(1,Double(duration)-Date().timeIntervalSince(started))))*1_000_000_000)
            for (_,client,_,port,path) in active {
                var results=await ConnectivityProbe.all(port:port,client:client,mode:state.mode)
                results.append(await socksProbe(port))
                samples.append(["path":path,"elapsedSeconds":Int(Date().timeIntervalSince(started)),"results":rows(results)])
            }
            try save()
        }
        for (core,client,gateway,_,_) in active {await stop(core,client,gateway)}
        try save()
    }catch{for (core,client,gateway,_,_) in active {await stop(core,client,gateway)};throw error}
    for report in reports {print("NETWORK_ACCEPTANCE "+(report["path"] as! String)+" "+(report["startup"] as? String ?? "probed"))}
}

@MainActor private func stop(_ core:CoreController,_ client:CoreAPIClient,_ gateway:Process?) async {
    if let gateway,gateway.isRunning {
        gateway.terminate();for _ in 0..<30 where gateway.isRunning {try? await Task.sleep(nanoseconds:100_000_000)}
        if gateway.isRunning {Darwin.kill(gateway.processIdentifier,SIGKILL)};gateway.waitUntilExit()
    }
    await client.shutdown();await core.stop()
}

private func socksProbe(_ port:Int) async -> ConnectivityResult {
    await Task.detached {
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/curl")
        process.arguments=["--silent","--fail","--connect-timeout","3","--max-time","10","--noproxy","","--proxy","socks5h://127.0.0.1:\(port)",ConfigBuilder.testURL]
        let output=Pipe();process.standardOutput=output;process.standardError=FileHandle.nullDevice;let started=Date()
        do {
            try process.run();let body=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            return ConnectivityResult("终端 SOCKS HTTPS",process.terminationStatus==0 && String(decoding:body,as:UTF8.self).contains("Success") ? .passed:.failed,"回环 SOCKS 入口",milliseconds:Int(Date().timeIntervalSince(started)*1000))
        }catch{return ConnectivityResult("终端 SOCKS HTTPS",.failed,"启动")}
    }.value
}
