import Foundation
import Darwin
import QingzhouKit

@MainActor func runRuntimeChecks() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qingzhou-runtime-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:dir)}
    let binary = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/sing-box")
    let fd = socket(AF_INET,SOCK_STREAM,0);defer {close(fd)}
    var address = sockaddr_in();address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family = sa_family_t(AF_INET);address.sin_addr.s_addr = inet_addr("127.0.0.1")
    guard withUnsafePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}) == 0 else {throw ProxyError("无法保留测试端口")}
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&length)}}
    let occupied = Int(UInt16(bigEndian:address.sin_port));_ = listen(fd,1)
    let controller = CoreController(directory:dir,binary:binary)
    do {try await controller.start(config:Data("{}".utf8),port:occupied);CheckHarness.failure("占用端口应拒绝启动",file:#filePath,line:#line)} catch {expectTrue(error.localizedDescription.contains("占用"))}
    print("PASS RuntimeTests.occupiedPort")
    let reserve = socket(AF_INET,SOCK_STREAM,0);address.sin_port = 0
    _ = withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(reserve,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
    _ = withUnsafeMutablePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(reserve,$0,&length)}}
    let port = Int(UInt16(bigEndian:address.sin_port));close(reserve)
    do {try await controller.start(config:Data("{bad}".utf8),port:port);CheckHarness.failure("无效配置应拒绝启动",file:#filePath,line:#line)} catch {expectTrue(error.localizedDescription.contains("校验"))}
    expectTrue(try FileManager.default.contentsOfDirectory(atPath:dir.path).isEmpty);print("PASS RuntimeTests.invalidConfigCleanup")
    let candidate = try NodeParser.parse("ss://aes-128-gcm:test-password@127.0.0.1:65530")
    let credentials = MemoryCredentials();try credentials.set(candidate.secret,for:candidate.node.credentialRef)
    var state = AppState();state.listenPort = port
    let config = try ConfigBuilder.build(node:candidate.node,state:state,credentials:credentials)
    var unexpected = false;controller.onUnexpectedExit = {unexpected = true}
    try await controller.start(config:config,port:port);expectTrue(controller.isRunning)
    await controller.stop();expectFalse(controller.isRunning);expectFalse(unexpected);expectTrue(try FileManager.default.contentsOfDirectory(atPath:dir.path).isEmpty);print("PASS RuntimeTests.normalStopCleanup")
    try await controller.start(config:config,port:port);guard let pid = controller.processID else {throw ProxyError("测试进程缺失")}
    kill(pid,SIGKILL)
    for _ in 0..<40 {if unexpected {break};try await Task.sleep(nanoseconds:50_000_000)}
    expectTrue(unexpected);expectFalse(controller.isRunning);expectTrue(try FileManager.default.contentsOfDirectory(atPath:dir.path).isEmpty);await controller.stop();print("PASS RuntimeTests.crashCallbackCleanup")
    let runner = binary.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/QingzhouRunner")
    let supervised = CoreController(directory:dir,binary:binary,supervisor:runner)
    var supervisedUnexpected = false;supervised.onUnexpectedExit = {supervisedUnexpected = true}
    try await supervised.start(config:config,port:port);await supervised.stop()
    expectFalse(supervised.isRunning);expectFalse(supervisedUnexpected);expectTrue(try FileManager.default.contentsOfDirectory(atPath:dir.path).isEmpty);print("PASS RuntimeTests.supervisedNormalStop")
    try await supervised.start(config:config,port:port)
    let listing = Process();listing.executableURL = URL(fileURLWithPath:"/usr/bin/pgrep");listing.arguments = ["-P",String(supervised.processID!)]
    let output = Pipe();listing.standardOutput = output;try listing.run();listing.waitUntilExit()
    guard let childID = Int32(String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) else {throw ProxyError("监护核心子进程缺失")}
    kill(childID,SIGKILL)
    for _ in 0..<40 {if supervisedUnexpected {break};try await Task.sleep(nanoseconds:50_000_000)}
    expectTrue(supervisedUnexpected);expectFalse(supervised.isRunning);expectTrue(try FileManager.default.contentsOfDirectory(atPath:dir.path).isEmpty);await supervised.stop();print("PASS RuntimeTests.supervisedCoreCrash")
    let unavailable = CoreController(directory:dir,binary:dir.appendingPathComponent("missing"))
    do {try await unavailable.start(config:config,port:port);CheckHarness.failure("缺失核心应拒绝启动",file:#filePath,line:#line)} catch {expectTrue(error.localizedDescription.contains("缺失"))};print("PASS RuntimeTests.missingCore")
    let keychainService="cn.qingzhou.test."+UUID().uuidString
    let keychain = KeychainStore(service:keychainService)
    let ref = UUID().uuidString
    defer {try? keychain.remove(ref)}
    try keychain.set("synthetic-test-secret",for:ref);expectEqual(try keychain.get(ref),"synthetic-test-secret")
    let peer=KeychainStore(service:keychainService)
    expectEqual(try peer.get(ref),"synthetic-test-secret")
    try peer.set("updated-synthetic-secret",for:ref);expectEqual(try keychain.get(ref),"updated-synthetic-secret")
    try keychain.remove(ref);expectThrows(try keychain.get(ref));try keychain.remove(ref);print("PASS RuntimeTests.keychainRoundTripAndRemoval")
    let managedJournal=dir.appendingPathComponent("managed-user-recovery.json")
    var operations:[String]=[],managedActive=false,managedCapability=true
    let observedProxy=SystemProxyController(journal:managedJournal,preferencesFactory:{throw ProxyError("不允许主程序申请网络写权限")})
    let managed=CaptureController(core:CoreController(directory:dir,binary:binary),proxy:observedProxy,helperRequest:{request in
        operations.append(request.operation)
        if request.operation=="systemProxy" {managedActive=true}
        if request.operation=="recover" || request.operation=="stop" {managedActive=false}
        var reply=TunReply(ok:true,message:"隔离服务",running:managedActive,proxyVerified:managedActive)
        reply.supportsManagedSystemProxy=managedCapability;reply.supportsExternalRecovery=true;reply.recoveryPending=false
        return reply
    })
    var direct=AppState();direct.mode = .direct;direct.listenPort=port
    for _ in 0..<2 {
        try await managed.start(direct,credentials:MemoryCredentials(),control:CoreControlContext.make())
        try await managed.activateSystemProxy(port:port)
        expectTrue(managed.helperRunning);expectFalse(FileManager.default.fileExists(atPath:managedJournal.path))
        try await managed.stop();expectFalse(managed.running)
    }
    expectEqual(operations.filter{$0=="systemProxy"}.count,2)
    managedCapability=false
    try await managed.start(direct,credentials:MemoryCredentials(),control:CoreControlContext.make())
    do{try await managed.activateSystemProxy(port:port);expectTrue(false,"旧辅助服务不能退回交互式授权")}catch{expectTrue(error.localizedDescription.contains("首次使用"))}
    try await managed.stop()
    print("PASS RuntimeTests.managedProxyReusesServiceWithoutUserWrites")

}
