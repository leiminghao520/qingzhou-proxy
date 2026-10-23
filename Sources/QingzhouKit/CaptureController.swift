import Foundation

@MainActor public final class CaptureController {
    public private(set) var activeMode:CaptureMode?
    public private(set) var helperRunning=false
    public let helper=PrivilegedServiceClient()
    private let core:CoreController
    private var ownedTunDNS:String?
    private var httpCompatibility:HTTPCompatibilityController?
    private let proxy:SystemProxyController
    private let helperRequestOverride:((TunRequest) async throws -> TunReply)?
    public init(core:CoreController,proxy:SystemProxyController,helperRequest:((TunRequest) async throws -> TunReply)?=nil){self.core=core;self.proxy=proxy;self.helperRequestOverride=helperRequest}
    private func requestHelper(_ request:TunRequest) async throws -> TunReply {
        if let helperRequestOverride {return try await helperRequestOverride(request)}
        return try await helper.request(request)
    }
    public var running:Bool{(activeMode == .systemProxy ? core.isRunning:(helperRunning || core.isRunning)) && (httpCompatibility == nil || httpCompatibility!.isRunning)}
    public func start(_ state:AppState,credentials:CredentialStore,control:CoreControlContext) async throws {
        guard activeMode==nil else{throw ProxyError("必须先恢复上一种接管方式")}
        if state.captureMode.usesTunnel {
            guard !proxy.hasRecovery else{throw ProxyError("请先恢复系统代理后启用 TUN")}
            var values:[String:String]=[:];for ref in CredentialReferences.all(state) where !state.subscriptions.contains(where:{$0.sourceRef==ref}) && !state.remoteRules.contains(where:{$0.sourceRef==ref}){values[ref]=try credentials.get(ref)}
            var runtime=state
            var compatibilityPort:Int?
            if state.usesHTTPCompatibility {
                var used:Set<Int>=[state.listenPort,control.port]
                func port() throws -> Int {for _ in 0..<20 {let value=try CoreControlContext.make().port;if used.insert(value).inserted{return value}};throw ProxyError("不能分配兼容端口")}
                runtime.listenPort=try port();compatibilityPort=try port()
            }
            try await CaptureActivationTransaction.run(prepare:{
                let status=try await self.requestHelper(TunRequest(operation:"status"))
                guard status.protocolVersion==5 else{throw ProxyError("辅助服务协议过旧，请更新后再开启组合接管")}
                let reply=try await self.requestHelper(TunRequest(operation:"prepare",state:runtime,credentials:values,control:control,httpCompatibilityPort:compatibilityPort,systemProxyPort:state.captureMode == .compatible ? state.listenPort:nil))
                self.ownedTunDNS=reply.dnsServer;self.helperRunning=reply.running;self.activeMode = state.captureMode
            },compatibility:{
                if let compatibilityPort,let shadow=state.shadowrocket {
                    let compatibility=HTTPCompatibilityController();compatibility.log=self.core.log;compatibility.onUnexpectedExit=self.core.onUnexpectedExit;self.httpCompatibility=compatibility
                    try await compatibility.start(configuration:shadow.gatewayData(listenPort:state.listenPort,corePort:runtime.listenPort,httpPort:compatibilityPort,control:control,state:state),port:state.listenPort)
                }
            },activate:{
                // 这里只准备组件；应用显式代理检测通过后才提交系统接管。
            },rollback:{
                try await self.emergencyRecover()
                await self.helper.closeChannel()
            })
        }else{
            if !state.pinnedBypasses.isEmpty {
                let status=try await requestHelper(TunRequest(operation:"status"))
                guard status.protocolVersion==5 else {throw ProxyError("指定出口需要更新辅助服务")}
                _=try await requestHelper(TunRequest(operation:"pinBypasses",state:state));helperRunning=true
            }
            if let shadow=state.shadowrocket,state.usesHTTPCompatibility {
                var used:Set<Int>=[state.listenPort,control.port]
                func port() throws -> Int {for _ in 0..<20 {let value=try CoreControlContext.make().port;if used.insert(value).inserted{return value}};throw ProxyError("不能分配兼容端口")}
                let corePort=try port(),httpPort=try port();var runtime=state;runtime.listenPort=corePort
                let config=try ConfigBuilder.build(state:runtime,credentials:credentials,control:control,httpCompatibilityPort:httpPort)
                try await core.start(config:config,port:corePort)
                let compatibility=HTTPCompatibilityController();compatibility.log=core.log;compatibility.onUnexpectedExit=core.onUnexpectedExit;httpCompatibility=compatibility
                do{try await compatibility.start(configuration:shadow.gatewayData(listenPort:state.listenPort,corePort:corePort,httpPort:httpPort,control:control,state:state),port:state.listenPort)}catch{httpCompatibility=nil;await core.stop();throw error}
            }else{try await core.start(config:ConfigBuilder.build(state:state,credentials:credentials,control:control),port:state.listenPort)}
            activeMode = .systemProxy
        }
    }
    public func activateTunnel() async throws {
        guard activeMode?.usesTunnel == true else {return}
        _=try await requestHelper(TunRequest(operation:"activate"))
    }
    public func activateSystemProxy(port:Int,protectedDomains:[String]=[],exceptions:[String]=[]) throws{guard activeMode == .systemProxy || (activeMode == .tun && httpCompatibility != nil) else{return};try proxy.apply(port:port,ownedTunDNS:activeMode == .tun ? ownedTunDNS:nil,protectedDomains:activeMode == .systemProxy ? protectedDomains:[],exceptions:activeMode == .systemProxy ? exceptions:[])}
    public func stop() async throws {
        let needsHelper=activeMode?.usesTunnel == true || helperRunning
        try await restoreAll(includeHelper:needsHelper)
    }
    public func helperStatus() async throws -> TunReply {let status=try await requestHelper(TunRequest(operation:"status"));helperRunning=status.running;return status}
    public func wakeStatus() async throws -> TunReply {try await requestHelper(TunRequest(operation:"status",verifyNetwork:true))}
    // 原子地让辅助服务优先完成已有重建；旧辅助服务不支持该语义时停止自动处理。
    public func recoverForWake() async throws -> Bool {
        if activeMode?.usesTunnel == true || helperRunning {
            let status:TunReply
            do {status=try await requestHelper(TunRequest(operation:"status"))} catch is HelperRequestBusy {return false}
            if status.networkReconnecting {return false}
            guard status.supportsWakeRecovery==true else {throw WakeRecoveryError(.configuration)}
            var request=TunRequest(operation:"recover",preserveExternal:true);request.deferToNetworkResume=true
            let reply:TunReply
            do {reply=try await requestHelper(request)} catch is HelperRequestBusy {return false}
            if reply.networkReconnecting {return false}
            guard !reply.running,reply.recoveryPending != true else {throw WakeRecoveryError(.configuration)}
            try await restoreAll(includeHelper:false,preserveExternal:true)
            return true
        }
        try await emergencyRecover(preserveExternal:true)
        return true
    }
    public func recoverHelper() async throws {try await restoreAll(includeHelper:true)}
    public func emergencyRecover(preserveExternal:Bool=false) async throws {
        // 应急入口不依赖当前选择的模式；安装的辅助服务可能仍保留另一会话的恢复记录。
        let evidence=HelperRecoveryPolicy.inspect()
        try await restoreAll(includeHelper:HelperRecoveryPolicy.requiresRecovery(activeTunnel:activeMode?.usesTunnel == true,running:helperRunning,journalPresent:evidence.journalPresent,inspectionAvailable:evidence.available),preserveExternal:preserveExternal)
    }
    public func verifyReleasedForQuit() async throws {
        guard !core.isRunning,httpCompatibility?.isRunning != true else{throw ProxyError("轻舟本地核心仍在运行，尚不能退出")}
        try proxy.verifyReleased()
        let evidence=HelperRecoveryPolicy.inspect()
        if HelperRecoveryPolicy.requiresRecovery(activeTunnel:activeMode?.usesTunnel == true,running:helperRunning,journalPresent:evidence.journalPresent,inspectionAvailable:evidence.available) {
            let status=try await requestHelper(TunRequest(operation:"status",verifyNetwork:true))
            helperRunning=status.running
            guard !status.running,status.safeToQuit==true else{throw ProxyError("尚不能确认轻舟的路由、DNS 和代理已释放；恢复记录已保留")}
        }
        ownedTunDNS=nil;activeMode=nil
        await helper.closeChannel()
    }
    private func restoreAll(includeHelper:Bool,preserveExternal:Bool=false) async throws {
        var helperRestored = !includeHelper
        do {
            try await CaptureRecoveryTransaction.run(proxy:{try self.proxy.restore(preserveExternal:preserveExternal)},helper:{
                if includeHelper {
                    if preserveExternal {
                        let status=try await self.requestHelper(TunRequest(operation:"status"))
                        guard status.supportsExternalRecovery==true else{throw ProxyError("辅助服务不支持保留外部网络恢复，请更新辅助服务")}
                    }
                    _=try await self.requestHelper(TunRequest(operation:"recover",preserveExternal:preserveExternal))
                    helperRestored=true
                }
            },local:{
                await self.httpCompatibility?.stop();self.httpCompatibility=nil;await self.core.stop()
            },verify:{
                if includeHelper {
                    let status=try await self.requestHelper(TunRequest(operation:"status"))
                    self.helperRunning=status.running
                    guard !status.running,!(status.recoveryPending ?? status.message.contains("待恢复")) else{throw ProxyError("辅助服务仍在运行或保留恢复记录")}
                }
                guard !self.proxy.hasRecovery else{throw ProxyError("系统代理恢复记录仍存在")}
            })
            ownedTunDNS=nil;helperRunning=false;activeMode=nil;await helper.closeChannel()
        }catch {
            if helperRestored {ownedTunDNS=nil;helperRunning=false;activeMode=nil}
            await helper.closeChannel();throw error
        }
    }
}

@MainActor public enum CaptureActivationTransaction {
    // 任何准备或激活失败都执行恢复；恢复失败必须保留可诊断的错误状态。
    public static func run(prepare:() async throws -> Void,compatibility:() async throws -> Void,activate:() async throws -> Void,rollback:() async throws -> Void) async throws {
        do {try await prepare();try await compatibility();try await activate()}
        catch {
            let original=error
            do {try await rollback()} catch {throw ProxyError("接管失败："+original.localizedDescription+"；恢复失败："+error.localizedDescription)}
            throw original
        }
    }
}
