import Foundation

@MainActor public final class CaptureController {
    public private(set) var activeMode:CaptureMode?
    public private(set) var helperRunning=false
    public let helper=PrivilegedServiceClient()
    private let core:CoreController
    private var ownedTunDNS:String?
    private var httpCompatibility:HTTPCompatibilityController?
    private let proxy:SystemProxyController
    public init(core:CoreController,proxy:SystemProxyController){self.core=core;self.proxy=proxy}
    public var running:Bool{(helperRunning || core.isRunning) && (httpCompatibility == nil || httpCompatibility!.isRunning)}
    public func start(_ state:AppState,credentials:CredentialStore,control:CoreControlContext) async throws {
        guard activeMode==nil else{throw ProxyError("必须先恢复上一种接管方式")}
        if state.captureMode.usesTunnel {
            guard !proxy.hasRecovery else{throw ProxyError("请先恢复系统代理后启用 TUN")}
            var values:[String:String]=[:];for ref in CredentialReferences.all(state) where !state.subscriptions.contains(where:{$0.sourceRef==ref}) && !state.remoteRules.contains(where:{$0.sourceRef==ref}){values[ref]=try credentials.get(ref)}
            var runtime=state
            var compatibilityPort:Int?
            if state.shadowrocket?.requiresHTTPCompatibility==true {
                var used:Set<Int>=[state.listenPort,control.port]
                func port() throws -> Int {for _ in 0..<20 {let value=try CoreControlContext.make().port;if used.insert(value).inserted{return value}};throw ProxyError("不能分配兼容端口")}
                runtime.listenPort=try port();compatibilityPort=try port()
            }
            try await CaptureActivationTransaction.run(prepare:{
                let status=try await self.helper.request(TunRequest(operation:"status"))
                guard status.protocolVersion==3 else{throw ProxyError("辅助服务协议过旧，请更新后再开启组合接管")}
                let reply=try await self.helper.request(TunRequest(operation:"prepare",state:runtime,credentials:values,control:control,httpCompatibilityPort:compatibilityPort,systemProxyPort:state.captureMode == .compatible ? state.listenPort:nil))
                self.ownedTunDNS=reply.dnsServer;self.helperRunning=reply.running;self.activeMode = state.captureMode
            },compatibility:{
                if let compatibilityPort,let shadow=state.shadowrocket {
                    let compatibility=HTTPCompatibilityController();compatibility.log=self.core.log;compatibility.onUnexpectedExit=self.core.onUnexpectedExit;self.httpCompatibility=compatibility
                    try await compatibility.start(configuration:shadow.gatewayData(listenPort:state.listenPort,corePort:runtime.listenPort,httpPort:compatibilityPort,control:control,state:state),port:state.listenPort)
                }
            },activate:{
                _=try await self.helper.request(TunRequest(operation:"activate"))
            },rollback:{
                try await self.emergencyRecover()
                await self.helper.closeChannel()
            })
        }else{
            if let shadow=state.shadowrocket,shadow.requiresHTTPCompatibility {
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
    public func activateSystemProxy(port:Int) throws{guard activeMode == .systemProxy || (activeMode == .tun && httpCompatibility != nil) else{return};try proxy.apply(port:port,ownedTunDNS:activeMode == .tun ? ownedTunDNS:nil)}
    public func stop() async throws {
        let needsHelper=activeMode?.usesTunnel == true || helperRunning
        try await restoreAll(includeHelper:needsHelper)
    }
    public func helperStatus() async throws -> TunReply {let status=try await helper.request(TunRequest(operation:"status"));helperRunning=status.running;return status}
    public func recoverHelper() async throws {try await restoreAll(includeHelper:true)}
    public func emergencyRecover() async throws {
        // 应急入口不依赖当前选择的模式；安装的辅助服务可能仍保留另一会话的恢复记录。
        try await restoreAll(includeHelper:FileManager.default.fileExists(atPath:HelperPaths.socket) || activeMode?.usesTunnel == true || helperRunning)
    }
    private func restoreAll(includeHelper:Bool) async throws {
        var helperRestored = !includeHelper
        do {
            try await CaptureRecoveryTransaction.run(proxy:{try self.proxy.restore()},helper:{
                if includeHelper {
                    _=try await self.helper.request(TunRequest(operation:"recover"))
                    helperRestored=true
                }
            },local:{
                await self.httpCompatibility?.stop();self.httpCompatibility=nil;await self.core.stop()
            },verify:{
                if includeHelper {
                    let status=try await self.helper.request(TunRequest(operation:"status"))
                    guard !status.running,!status.message.contains("待恢复") else{throw ProxyError("辅助服务仍在运行或保留恢复记录")}
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
