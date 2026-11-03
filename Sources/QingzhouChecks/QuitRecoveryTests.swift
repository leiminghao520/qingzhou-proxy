import Foundation
import QingzhouKit

@MainActor func runQuitRecoveryChecks() async throws {
    var events:[String]=[]
    try await QuitRecoveryTransaction.run(recover:{events.append("recover")},verifyReleased:{events.append("verify")},deferredRecovery:{_ in events.append("deferred")})
    expectEqual(events,["recover","verify"])
    events=[]
    try await QuitRecoveryTransaction.run(recover:{events.append("recover");throw ProxyError("记录归档失败")},verifyReleased:{events.append("verify")},deferredRecovery:{_ in events.append("deferred")})
    expectEqual(events,["recover","verify","deferred"],"仅有记录残留、已确认释放时应允许退出")
    for recoverFails in [false,true] {
        events=[]
        do {
            try await QuitRecoveryTransaction.run(recover:{if recoverFails {throw ProxyError("恢复失败")}},verifyReleased:{events.append("verify");throw ProxyError("仍有拥有的路由")},deferredRecovery:{_ in events.append("deferred")})
            expectTrue(false,"不能略过接管释放证明")
        } catch {expectEqual(events,["verify"])}
    }

    let original:[String:Any]=["HTTPEnable":0,"ProxyAutoConfigEnable":1,"ProxyAutoConfigURLString":"https://original.invalid/pac"]
    let applied=ProxyRecovery.applied(to:original,port:27890)
    var current=applied;current["HTTPProxy"]="127.0.0.1";current["HTTPPort"]=1082
    current["ExceptionsList"]=["external.invalid"]
    let recovered=ProxyRecovery.restoredPreservingExternal(original:original,applied:applied,current:current)
    expectEqual(recovered["HTTPPort"] as? Int,1082)
    expectEqual(recovered["HTTPEnable"] as? Int,1)
    expectEqual(recovered["ExceptionsList"] as? [String],["external.invalid"])
    expectEqual(recovered["ProxyAutoConfigEnable"] as? Int,0,"外部接管后不能重新启用原 PAC")
    expectFalse(ProxyRecovery.pointsToOwnedEndpoint(current:recovered,applied:applied))
    expectNil(recovered["HTTPSPort"]);expectNil(recovered["SOCKSPort"])
    expectTrue(NSDictionary(dictionary:ProxyRecovery.restoredPreservingExternal(original:original,applied:applied,current:applied)).isEqual(to:original))
    let empty=ProxyRecovery.restoredPreservingExternal(original:[:],applied:applied,current:[:])
    expectTrue(empty.isEmpty)
    for alias in ["localhost","::1"] {
        var loopback=applied;loopback["HTTPProxy"]=alias
        expectTrue(ProxyRecovery.pointsToOwnedEndpoint(current:loopback,applied:applied))
        let cleared=ProxyRecovery.restoredPreservingExternal(original:original,applied:applied,current:loopback)
        expectFalse(ProxyRecovery.pointsToOwnedEndpoint(current:cleared,applied:applied))
    }

    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("qingzhou-quit-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:folder)}
    let core=CoreController(directory:folder),proxy=SystemProxyController(journal:folder.appendingPathComponent("proxy.json"))
    var pending=false,running=false,safe=true,failRecovery=false,supports=true
    var operations:[TunRequest]=[]
    let capture=CaptureController(core:core,proxy:proxy,helperRequest:{request in
        operations.append(request)
        if request.operation=="prepare" {running=true;pending=true}
        if request.operation=="recover" {
            running=false
            if failRecovery {throw ProxyError("合成归档失败")}
            pending=false
        }
        var reply=TunReply(ok:true,message:"合成状态",running:running)
        reply.recoveryPending=pending;reply.safeToQuit=safe;reply.supportsExternalRecovery=supports
        return reply
    })
    var state=AppState();state.captureMode = .tun
    try await capture.start(state,credentials:MemoryCredentials(),control:CoreControlContext(port:19991,secret:String(repeating:"a",count:64)))
    expectTrue(capture.running)
    try await capture.emergencyRecover(preserveExternal:true)
    expectTrue(operations.contains{$0.operation=="recover" && $0.preserveExternal==true})
    expectFalse(capture.running);expectNil(capture.activeMode)
    try await capture.verifyReleasedForQuit()

    operations=[];failRecovery=true;safe=true
    try await capture.start(state,credentials:MemoryCredentials(),control:CoreControlContext(port:19991,secret:String(repeating:"a",count:64)))
    var deferred=false
    try await QuitRecoveryTransaction.run(recover:{try await capture.emergencyRecover(preserveExternal:true)},verifyReleased:{try await capture.verifyReleasedForQuit()},deferredRecovery:{_ in deferred=true})
    expectTrue(deferred);expectTrue(pending,"退出不能伪造恢复记录已清空")
    expectFalse(capture.running,"失败后必须用新状态清除旧的运行缓存")
    expectTrue(operations.contains{$0.operation=="status" && $0.verifyNetwork==true})

    safe=false;deferred=false
    try await capture.start(state,credentials:MemoryCredentials(),control:CoreControlContext(port:19991,secret:String(repeating:"a",count:64)))
    do {
        try await QuitRecoveryTransaction.run(recover:{try await capture.emergencyRecover(preserveExternal:true)},verifyReleased:{try await capture.verifyReleasedForQuit()},deferredRecovery:{_ in deferred=true})
        expectTrue(false,"仍有残留接管时不能退出")
    } catch {expectFalse(deferred)}
    supports=false;failRecovery=false;safe=true;operations=[]
    do {try await capture.emergencyRecover(preserveExternal:true);expectTrue(false)} catch {expectTrue(error.localizedDescription.contains("更新辅助服务"))}
    expectFalse(operations.contains{$0.operation=="recover"},"旧服务不能悄悄忽略保留外部网络标记")

    let legacy=try JSONDecoder().decode(TunReply.self,from:Data("{\"ok\":true,\"message\":\"legacy\",\"running\":false}".utf8))
    expectNil(legacy.safeToQuit);expectNil(legacy.supportsExternalRecovery)
    let request=TunRequest(operation:"recover",preserveExternal:true)
    expectTrue(try JSONDecoder().decode(TunRequest.self,from:JSONEncoder().encode(request)).preserveExternal==true)
    print("PASS Recovery.externalTakeoverAndVerifiedQuit")
}
