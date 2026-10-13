import Foundation

@MainActor public final class CaptureController {
    public private(set) var activeMode:CaptureMode?
    public private(set) var helperRunning=false
    public let helper=PrivilegedServiceClient()
    private let core:CoreController
    private let proxy:SystemProxyController
    public init(core:CoreController,proxy:SystemProxyController){self.core=core;self.proxy=proxy}
    public var running:Bool{helperRunning || core.isRunning}
    public func start(_ state:AppState,credentials:CredentialStore,control:CoreControlContext) async throws {
        guard activeMode==nil else{throw ProxyError("必须先恢复上一种接管方式")}
        if state.captureMode == .tun {
            guard !proxy.hasRecovery else{throw ProxyError("请先恢复系统代理后启用 TUN")}
            var values:[String:String]=[:];for ref in CredentialReferences.all(state) where !state.subscriptions.contains(where:{$0.sourceRef==ref}) && !state.remoteRules.contains(where:{$0.sourceRef==ref}){values[ref]=try credentials.get(ref)}
            let reply=try await helper.request(TunRequest(operation:"start",state:state,credentials:values,control:control));helperRunning=reply.running;activeMode = .tun
        }else{try await core.start(config:ConfigBuilder.build(state:state,credentials:credentials,control:control),port:state.listenPort);activeMode = .systemProxy}
    }
    public func activateSystemProxy(port:Int) throws{guard activeMode == .systemProxy else{return};try proxy.apply(port:port)}
    public func stop() async throws {
        if activeMode == .tun || helperRunning {_ = try await helper.request(TunRequest(operation:"stop"));helperRunning=false;activeMode=nil;await helper.closeChannel()}
        else{try proxy.restore();await core.stop();activeMode=nil}
    }
    public func helperStatus() async throws -> TunReply {let status=try await helper.request(TunRequest(operation:"status"));helperRunning=status.running;return status}
    public func recoverHelper() async throws {_ = try await helper.request(TunRequest(operation:"recover"));helperRunning=false;activeMode=nil;await helper.closeChannel()}
}
