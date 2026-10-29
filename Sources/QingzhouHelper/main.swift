import Foundation
import Darwin
import Security
import CryptoKit
import SystemConfiguration
import QingzhouKit

final class Service {
    let root:URL
    let manifest:Manifest
    let queue=DispatchQueue(label:"cn.qingzhou.helper.capture")
    var quitRoutesRead:(() throws -> [ProtectedRoute])?
    var quitDNSRead:((String) -> NSDictionary?)?
    var routeTransaction=UUID()
    lazy var routeAudit=RouteAuditLog(directory:root)
    var routeMetrics:RouteOperationMetrics?
    var progressReply:((String)->Void)?
    var connectionTiming:ConnectionTiming?
    var failurePhase:String?
    var failureKind:ConnectionFailureKind?
    var phase="idle" {didSet {if phase != oldValue {connectionTiming?.begin(phase);progressReply?(phase)}}}
    var captureGeneration=UUID()
    var domainRouteSummary:[String]=[]
    var firewallCommand:([String]) throws -> String = {try NetworkInspection.command("/sbin/pfctl",$0)}
    var bypassServicesRead:()->[BypassNetworkService] = BypassNetworkService.read
    var pinnedMonitor:DispatchSourceTimer?
    var pinnedPaths:[ProtectedRoute]=[]
    var helperIsRunning:Bool {process?.isRunning==true || (journal?.proxyOnly==true && owner != nil) || (journal?.pinnedOnly==true && activeRequest != nil)}
    var capturePlan:CapturePlan?
    var dynamicRules:DynamicCaptureRules?
    var changeWindow=CaptureChangeWindow()
    var protectedQueriesSuspended=false
    var captureNodeAddresses:[String:[String]]=[:]
    var captureNodeInterfaces:[String:String]=[:]
    var knownProtectedDomains:Set<String>=[]
    var dynamicAnswerRoutes:[String:ProtectedRoute]=[:]
    var dnsForwarder:ScopedDNSForwarder?
    var activeRequest:TunRequest?
    var networkMonitorObservation: ((NetworkMonitorEvent) -> Void)?
    var networkChecks: NetworkCheckScheduler?
    let routeBackend:RouteBackend
    lazy var routeSample: () throws -> NetworkRouteSample = { [unowned self] in try self.routeAudit.operation(transaction:self.routeTransaction,stage:self.phase,kind:"snapshot",identity:"table") {try self.measured("routeTableSample") {try self.routeBackend.snapshot()}} }
    var corporateDNSVerify:(([String],Int) throws -> Void)?
    var dnsServiceWrite:((String,NSDictionary?) throws -> Void)?
    var networkDNSRead: ((String) -> NSDictionary?)?
    var networkSnapshotRead: ((NetworkRouteSample) throws -> NetworkSnapshot)?
    var networkClock: () -> Date = { Date() }
    var networkUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var networkTimer:DispatchSourceTimer?
    var networkStore:SCDynamicStore?
    var routeEvents:DispatchSourceRead?
    var pendingNetworkChange:Date?
    var snapshotRetry=NetworkSnapshotRetry()
    var networkResumeSession: NetworkResumeSession?
    var networkResumeWork: DispatchWorkItem?
    var performingNetworkResume = false
    var networkResumeSchedule: ((TimeInterval, @escaping () -> Void) -> Void)?
    var networkStatus:String {lastFailure ?? (phase=="networkRetry" ? "网络变化，正在重新检查":HelperPaths.version)}
    var networkSummary:[String] {(protectedQueriesSuspended ? ["企业网络更新中，普通代理继续运行，企业解析暂不可用"]:[])+domainRouteSummary+(capturePlan?.summary ?? [])+(dnsForwarder.map{[$0.diagnostics]} ?? [])}
    var lastFailure:String?
    var proxyMismatchSince:TimeInterval?
    var proxyVerificationClock:()->TimeInterval={ProcessInfo.processInfo.systemUptime}
    var proxyVerificationWait:(TimeInterval)->Void={usleep(useconds_t($0*1_000_000))}
    var coreDiagnostics=CoreDiagnosticBuffer(secrets:[])
    var coreOutput:Pipe?
    var process:Process?
    var activatePrepared:(() throws -> Void)?
    var owner:Int32?
    var journal:Journal?
    let dynamic:SCDynamicStore
    init(recoveryOnly:Bool=false,routeBackend:RouteBackend=NativeRouteBackend()) throws {
        self.routeBackend=routeBackend;root=URL(fileURLWithPath:HelperPaths.directory)
        guard geteuid()==0 else{throw ProxyError("辅助服务必须由管理员安装并由 launchd 运行")}
        dynamic=SCDynamicStoreCreate(nil,"QingzhouHelper" as CFString,nil,nil)!
        let directoryAttributes=try FileManager.default.attributesOfItem(atPath:root.path);guard (directoryAttributes[.ownerAccountID] as? NSNumber)?.uint32Value==0,((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)&0o022==0,directoryAttributes[.type] as? FileAttributeType == .typeDirectory else{throw ProxyError("辅助服务目录权限无效")}
        let url=root.appendingPathComponent("manifest.json");try Self.protected(url)
        manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:url));guard recoveryOnly || manifest.version==HelperPaths.version else{throw ProxyError("辅助服务版本不匹配，请重新批准安装")}
        for (name,expected) in [("sing-box",manifest.coreHash),("QingzhouHelper",manifest.helperHash)]{let file=root.appendingPathComponent(name);try Self.protected(file);guard Self.hash(try Data(contentsOf:file))==expected else{throw ProxyError("固定组件校验失败，请重新批准安装")}}
    }
    #if QZ_HELPER_FIXTURE
    // 仅供单独链接的离线检查程序；正式构建不包含此初始化入口。
    init(fixtureRoot:URL,backend:RouteBackend) {
        root=fixtureRoot;routeBackend=backend
        dynamic=SCDynamicStoreCreate(nil,"轻舟恢复隔离夹具" as CFString,nil,nil)!
        manifest=Manifest(version:HelperPaths.version,uid:getuid(),clientHash:"fixture",coreHash:"fixture",helperHash:"fixture")
    }
    #endif
    static func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func protected(_ url:URL) throws {let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value==0,let mode=(attrs[.posixPermissions] as? NSNumber)?.intValue,mode&0o022==0,attrs[.type] as? FileAttributeType == .typeRegular else{throw ProxyError("权限组件必须是 root 所有且不可由普通用户写入的常规文件")}}
    func authorize(_ fd:Int32) throws {
        var token=[UInt32](repeating:0,count:8);var size=socklen_t(32);guard getsockopt(fd,0,0x006,&token,&size)==0,size==32,token[1]==manifest.uid else{throw ProxyError("客户端身份不允许")}
        let audit=token.withUnsafeBytes{Data($0)};var guest:SecCode?;let attrs=[kSecGuestAttributeAudit as String:audit] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil,attrs,SecCSFlags(),&guest)==errSecSuccess,let guest,SecCodeCheckValidity(guest,SecCSFlags(),nil)==errSecSuccess else{throw ProxyError("客户端代码签名无效")}
        // 仅信任管理员安装时固定的完整签名要求；临时签名仍按原始哈希逐包授权。
        if let text=manifest.clientRequirement {
            var requirement:SecRequirement?
            guard SecRequirementCreateWithString(text as CFString,SecCSFlags(),&requirement)==errSecSuccess,let requirement,
                  SecCodeCheckValidity(guest,SecCSFlags(),requirement)==errSecSuccess else{throw ProxyError("客户端不符合已批准的签名身份")}
            return
        }
        var staticCode:SecStaticCode?;guard SecCodeCopyStaticCode(guest,SecCSFlags(),&staticCode)==errSecSuccess,let staticCode else{throw ProxyError("客户端代码身份无法读取")};var information:CFDictionary?;guard SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&information)==errSecSuccess,let info=information as? [String:Any],let cdhash=info[kSecCodeInfoUnique as String] as? Data,cdhash.map({String(format:"%02x",$0)}).joined()==manifest.clientHash else{throw ProxyError("客户端代码身份已变化，请重新批准更新")}
    }
    func save() throws {guard let journal else{return};try measured("routeJournalSave") {try SecureFile.write(JSONEncoder().encode(journal),to:root.appendingPathComponent("recovery.json"),durable:true)}}
    func writeRoute(_ arguments:[String],deadline:Date?) throws -> String {try routeAudit.operation(transaction:routeTransaction,stage:phase,kind:"write",identity:arguments.joined(separator:"|"),result:{CaptureOwnership.routeWriteFailed($0) ? "rejected":"confirmed"}) {try measured("routeWrite") {try RouteBackendAdapter.write(arguments,backend:routeBackend,deadline:deadline,interfaceHint:routeInterfaceHint(arguments))}}}
    func routeInfo(_ destination:String,ipv6:Bool,scope:String?=nil,deadline:Date?=nil) throws -> String {networkMonitorObservation?(.routeQuery);return try routeAudit.operation(transaction:routeTransaction,stage:phase,kind:"query",identity:destination+"|"+(scope ?? "global")) {try measured("routeQuery") {try routeBackend.lookup(destination,ipv6:ipv6,scope:scope,deadline:deadline).queryText}}}
    func field(_ label:String,_ text:String)->String? {
        label=="gateway" ? NetworkInspection.routeGateway(text):NetworkInspection.routeField(label,text)
    }
    func prefix(_ info:String)->String? {NetworkInspection.routePrefix(destination:field("destination",info),mask:field("mask",info),host:info.contains("HOST"))}
    func stop(preserveExternal:Bool=false) throws {
        if journal?.proxyOnly==true {try stopManagedSystemProxy(preserveExternal:preserveExternal);return}
        let previousPhase=phase
        phase="recovery"
        defer{phase=previousPhase}
        // 恢复采样、日志或写入失败也必须停止核心；路由恢复意图仍由原记录保留。
        defer {
            if let process,process.isRunning {
                process.terminate()
                for _ in 0..<40 {if !process.isRunning {break};usleep(50000)}
                if process.isRunning {kill(process.processIdentifier,SIGKILL)}
                process.waitUntilExit()
            }
            process=nil;owner=nil
        }

        if let backend=routeBackend as? NativeRouteBackend {backend.cancelled={false}}
        if !performingNetworkResume {cancelNetworkResume()}
        pinnedMonitor?.cancel();pinnedMonitor=nil;pinnedPaths=[]
        coreOutput?.fileHandleForReading.readabilityHandler=nil;coreOutput=nil
        captureGeneration=UUID();dynamicAnswerRoutes=[:];domainRouteSummary=[];activatePrepared=nil;activeRequest=nil;networkChecks?.cancel();networkChecks=nil;networkTimer?.cancel();networkTimer=nil;if let networkStore {SCDynamicStoreSetDispatchQueue(networkStore,nil)};networkStore=nil;routeEvents?.cancel();routeEvents=nil;pendingNetworkChange=nil;snapshotRetry.reset();dnsForwarder?.stop();dnsForwarder=nil;capturePlan=nil;proxyMismatchSince=nil;dynamicRules=nil;changeWindow.reset();protectedQueriesSuspended=false;captureNodeAddresses=[:];captureNodeInterfaces=[:];knownProtectedDomains=[]
        guard let record=journal else{        if let process,process.isRunning {process.terminate();for _ in 0..<40 {if !process.isRunning{break};usleep(50000)};if process.isRunning{kill(process.processIdentifier,SIGKILL)};process.waitUntilExit()};process=nil;owner=nil;try? FileManager.default.removeItem(at:root.appendingPathComponent("runtime.json"))
return};var issues:[String]=[]
        // 用户显式恢复时也只清理仍属于轻舟的入口，不能覆盖后来接管的代理。
        do{issues += try restoreProxy(record.proxies ?? [],preserveExternal:preserveExternal)}catch{issues.append("系统代理读取或提交失败："+error.localizedDescription)}
        issues += DNSServiceTransaction.restore(record.allDNSServices,read:readDNSService,write:writeDNSService)
        let recoverySample=preserveExternal ? try routeSample():nil
        let recoveryTable=recoverySample?.table ?? ""
        for route in record.routes.reversed() {
            if preserveExternal {
                let expectedRoute=ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope)
                // 已消失或已被外部替换的路由不再认领，仍属于本次记录的路由继续核对后清理。
                let state=try routeSample().identityIndex.state(expectedRoute)
                if state == .ambiguous {issues.append("路由 "+route.destination+" 存在多个同前缀出口，拒绝自动处理");continue}
                if state != .owned {
                    guard state == .absent,CaptureOwnership.legacyHostRouteInTable(expectedRoute,table:recoveryTable) else {continue}
                }
            }
            let info:String
            do {info=try routeInfo(route.destination,ipv6:route.ipv6,scope:route.scope)}
            catch {issues.append("路由 "+route.destination+" 恢复查询失败："+error.localizedDescription);continue}
            do {
            let expectedRoute=ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope)
            // 旧版错误路由只能凭当前恢复记录认领，不能根据历史归档推断外部路由所有权。
            if route.ipv6 && route.destination.hasSuffix("/128"),CaptureOwnership.legacyHostRouteInTable(expectedRoute,table:try routeSample().table) {
                let output=try writeRoute(CaptureOwnership.legacyHostDeletionArguments(expectedRoute),deadline:nil)
                if CaptureOwnership.routeWriteFailed(output) {issues.append("旧版主机路由恢复失败："+route.destination);continue}
                else if CaptureOwnership.legacyHostRouteInTable(expectedRoute,table:try routeSample().table) {issues.append("旧版主机路由仍存在："+route.destination);continue}
                continue
            }
            // 查询可能命中接口缓存；全局路由仍须按完整表中的身份确认后删除。
            if try verifiedRoute(expectedRoute,info:info) {
                do{try deleteOwnedRoute(ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope))}
                catch{issues.append("路由 "+route.destination+" 移除失败："+error.localizedDescription);continue}
            } else if NetworkInspection.routeScopeMatches(route.scope,flags:field("flags",info),interface:field("interface",info)),let current=prefix(info),NetworkInspection.samePrefix(current,route.destination) {
                if !preserveExternal {issues.append("路由 "+route.destination+" 已有外部修改，保留当前出口 "+(field("interface",info) ?? "未知")+"/"+(field("gateway",info) ?? "未知"))}
            }
            } catch {issues.append("路由 "+route.destination+" 恢复核验失败："+error.localizedDescription);continue}
        }
        if let process,process.isRunning {process.terminate();for _ in 0..<40 {if !process.isRunning{break};usleep(50000)};if process.isRunning{kill(process.processIdentifier,SIGKILL)};process.waitUntilExit()};process=nil;owner=nil
        try? FileManager.default.removeItem(at:root.appendingPathComponent("runtime.json"))
        if issues.isEmpty {
            do {
                let remaining=try routeSample().identityIndex
                if record.routes.contains(where:{let state=remaining.state(ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface,scope:$0.scope));return state == .owned || state == .ambiguous}) {
                    issues.append("恢复后仍有自有或无法确认的路由，保留恢复记录")
                }
            } catch {issues.append("恢复后路由采样失败："+error.localizedDescription)}
        }
        if issues.isEmpty {do{try restoreBypassFirewall()}catch{issues.append(error.localizedDescription)}}
        if !issues.isEmpty {try save();throw ProxyError("网络恢复未完成，已停止核心并保留恢复记录："+issues.prefix(8).joined(separator:"；"))}
        if preserveExternal {
            try verifyNoOwnedProxyEndpoint(record.proxies ?? [])
            let remaining=try self.routeSample().identityIndex
            guard record.routes.allSatisfy({route in
                let state=remaining.state(ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope))
                return state != .owned && state != .ambiguous
            }) else {throw ProxyError("仍有轻舟拥有的路由，保留恢复记录并拒绝完成交接")}
            // 显式交接外部网络时保留完整审计快照，不能直接丢弃恢复证据。
            let archive=root.appendingPathComponent("recovery-preserved-"+UUID().uuidString+".json")
            try SecureFile.write(JSONEncoder().encode(record),to:archive)
            print("已保留外部网络并归档恢复证据："+archive.path)
        }
        try FileManager.default.removeItem(at:root.appendingPathComponent("recovery.json"));journal=nil
    }
    func recoverStartup(preserveExternal:Bool=false) throws {let file=root.appendingPathComponent("recovery.json");if FileManager.default.fileExists(atPath:file.path){try Self.protected(file);journal=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:file));routeTransaction=journal?.transactionID ?? UUID();if let pid=journal?.pid {var buffer=[CChar](repeating:0,count:4096);if proc_pidpath(pid,&buffer,UInt32(buffer.count))>0,String(cString:buffer)==root.appendingPathComponent("sing-box").path{kill(pid,SIGTERM);usleep(200000)}};try stop(preserveExternal:preserveExternal)}}
    func start(_ request:TunRequest,fd:Int32) throws {
        guard networkResumeSession == nil || performingNetworkResume else{throw ProxyError("正在恢复当前连接，请先断开或恢复网络")}
        guard process==nil,journal==nil,let state=request.state,let values=request.credentials,let control=request.control,state.captureMode.usesTunnel,values.count<=6000 else{throw ProxyError("重复启动或 TUN 模型无效，请先恢复")}
        guard control.secret.count==64,control.secret.allSatisfy({$0.isHexDigit}),(1024...65535).contains(control.port),control.port != state.listenPort else{throw ProxyError("控制通道模型无效")}
        guard request.protocolVersion==5 else{throw ProxyError("辅助服务协议不匹配，请更新应用及辅助服务")}
        if let port=request.httpCompatibilityPort {guard (1024...65535).contains(port),port != state.listenPort,port != control.port,state.shadowrocket?.requiresHTTPCompatibility==true else{throw ProxyError("兼容端口模型无效")}}
        routeTransaction=UUID()
        coreDiagnostics=CoreDiagnosticBuffer(secrets:Array(values.values)+[control.secret])
        if state.captureMode == .compatible {guard let port=request.systemProxyPort,(1024...65535).contains(port),port != control.port else{throw ProxyError("兼容代理端口无效")}} else {guard request.systemProxyPort==nil else{throw ProxyError("非兼容模式不能请求系统代理")}}
        configureRouteCancellation(fd)
        phase="preflight"
        try NetworkInspection.checkConflicts(routes:try routeSample().table);try PolicyValidator.validate(state)
        let memory=MemoryCredentials();for (key,value) in values{guard key.count<=200,value.utf8.count<=16384 else{throw ProxyError("凭据模型超过限制")};try memory.set(value,for:key)}
        guard let global=SCDynamicStoreCopyValue(dynamic,"State:/Network/Global/IPv4" as CFString) as? [String:Any],let service=global["PrimaryService"] as? String,let primary=global["PrimaryInterface"] as? String,primary.range(of:"^[a-z][a-z0-9]{0,15}$",options:.regularExpression) != nil else{throw NetworkEnvironmentNotReady("原网络服务无法可靠识别")}
        let dnsKey=NetworkInspection.tunDNSKey(UUID())
        phase="bootstrapDNS"
        var preparedSnapshot:NetworkSnapshot?
        // 引导解析与只读快照准备重叠执行，仍共用原有四槽工作池与总时间预算。
        let nodeAddresses=try NetworkPreparationPool.shared.addresses(state.nodes.map(\.server),cancelled:{[weak self] in
            guard let self,let backend=self.routeBackend as? NativeRouteBackend else{return false};return backend.cancelled()
        },prepare:{
            try self.measured("fixedResources") {try DomesticRouting.validate()}
            let sample=try self.routeSample()
            preparedSnapshot=try NetworkSnapshot.read(store:self.dynamic,primary:primary,routes:sample.table,structuredRoutes:sample.planningRoutes,lookup:{try self.routeInfo($0,ipv6:$1)})
        })
        guard let snapshot=preparedSnapshot else {throw NetworkEnvironmentNotReady("原网络快照准备未完成")}
        let plan=try CapturePlan.make(snapshot:snapshot,state:state,pinned:try PinnedBypassPolicy.routes(state.pinnedBypasses,services:BypassNetworkService.read()))
        let dns=snapshot.resolvers.flatMap(\.servers).map{$0.components(separatedBy:"%")[0]}
        capturePlan=plan
        let v4:String
        do {v4=try routeInfo("default",ipv6:false)}
        catch {throw NetworkEnvironmentNotReady("IPv4 默认路由暂不可读取："+error.localizedDescription)}
        guard let gw4=field("gateway",v4),field("interface",v4)==primary else{throw NetworkEnvironmentNotReady("IPv4 原路由不可用，未启用 TUN")}
        let candidate6=try? routeInfo("default",ipv6:true)
        let v6:String?
        if let candidate6,field("interface",candidate6)==primary {v6=candidate6}
        else if candidate6?.contains("IFSCOPE")==true {v6=nil}
        else if candidate6 != nil {throw NetworkEnvironmentNotReady("IPv6 默认路由属于其他接口，未启用 TUN")}
        else {v6=nil}
        let gw6=v6.flatMap{field("gateway",$0)}
        phase="bootstrapDNS"
        var bypass=Set(dns+["1.1.1.1"])
        for values in nodeAddresses.values {bypass.formUnion(values)}
        let routesBeforeSample=try routeSample();let routesBefore=routesBeforeSample.table
        phase="networkRecheck"
        let currentDefault=try routeInfo("default",ipv6:false)
        let vpn=try NetworkInspection.command("/usr/sbin/scutil",["--nc","list"])
        guard let currentGlobal=SCDynamicStoreCopyValue(dynamic,"State:/Network/Global/IPv4" as CFString) as? [String:Any],currentGlobal["PrimaryService"] as? String==service,let currentProxies=SCDynamicStoreCopyProxies(nil) as? [String:Any] else{throw NetworkEnvironmentNotReady("准备期间网络服务已变化，未接管网络")}
        try NetworkInspection.validatePreparation(interface:primary,gateway:gw4,currentInterface:field("interface",currentDefault),currentGateway:field("gateway",currentDefault),vpn:vpn,routes:routesBefore,proxies:currentProxies)
        phase="bypassSnapshot"
        let bypassPlan=try BypassRoutePlan.capture(destinations:plan.exclusions.filter{cidr in !state.pinnedBypasses.contains{NetworkInspection.samePrefix($0.value,cidr)}}+bypass.map{$0+($0.contains(":") ? "/128":"/32")},existingPrefixes:TunAddressPlan.routePrefixes(routesBefore),hasIPv6:gw6 != nil,existingRoutes:NetworkSnapshot.parseRoutes(routesBefore,includeTransient:true),lookup:{try self.routeInfo($0,ipv6:$1)})
        let captureRoutes=try measured("capturePlanning") {try CaptureRoutePlan.make(plan:plan,bypass:bypassPlan,baseline:routesBeforeSample)}
        print("捕获规划 backend=native captureCount=\(captureRoutes.prefixes.count) excludedCount=\(captureRoutes.exclusions.count) fallback=\(captureRoutes.fallbackReason ?? "无")")
        let retainedBypasses=captureRoutes.fallbackReason==nil ? bypassPlan.routes.filter{!captureRoutes.excludes($0.destination)}:bypassPlan.routes
        phase="addressPlan"
        let addresses=try TunAddressPlan.make(routes:routesBefore,bypassCIDRs:state.bypassCIDRs,physicalInterface:primary)
        let address4=addresses.address4,address6=addresses.address6
        phase="coreValidation"
        captureGeneration=UUID();let generation=captureGeneration
        let forwarder=try ScopedDNSForwarder(plan:plan,protectSnapshotAnswers:{[weak self] queryPlan,revision,name,addresses,resolver,deadline in
            guard let self else {throw ProxyError("保护会话已结束")}
            try self.queue.sync {
                guard self.captureGeneration==generation,self.dnsForwarder?.isCurrentRevision(revision)==true,Date()<deadline,!self.protectedQueriesSuspended,let plan=self.capturePlan,plan==queryPlan else {throw ProxyError("企业 DNS 保护会话过期")}
                // 准备阶段尚未接管，先确认原路径；激活后才补充拥有的主机路由。
                let existingProtection=self.activeRequest == nil ? [] : NetworkSnapshot.parseRoutes(try self.routeSample().table,includeTransient:true)
                for address in addresses {
                    let route=try plan.domainRoute(address:address,resolver:resolver,host:name)
                    guard Date()<deadline else {throw ProxyError("企业路由保护超过 DNS 总预算")}
                    if self.activeRequest != nil {
                        // 已有企业网段提供相同的最长匹配出口时，无需制造可被 VPN 回收的冗余主机项。
                        if !CaptureOwnership.hasEquivalentHostPath(route,actual:existingProtection) {
                            guard (self.journal?.routes.count ?? 0)<4096 else {throw ProxyError("动态保护路由超过上限")}
                            try self.addRoute(route.destination,route.gateway,route.interface,ipv6:route.ipv6,deadline:deadline)
                            self.dynamicAnswerRoutes[route.destination]=route
                        }
                        let info=try self.routeInfo(address,ipv6:route.ipv6,deadline:deadline)
                        guard self.field("interface",info)==route.interface else {throw ProxyError("企业动态路由接口核验失败")}
                    } else {
                        let info=try self.routeInfo(address,ipv6:route.ipv6,deadline:deadline)
                        guard self.field("interface",info)==route.interface else {throw ProxyError("准备阶段企业原路由无法确认")}
                    }
                    let summary=name+" → "+address+" → "+route.interface+"（共享该地址的流量也受保护）"
                    if !self.domainRouteSummary.contains(summary) {self.domainRouteSummary.append(summary)}
                    if self.domainRouteSummary.count>100 {self.domainRouteSummary.removeFirst()}
                }
            }
        });dnsForwarder=forwarder;forwarder.start()
        phase="dnsBaseline"
        // 企业解析器可能拒绝根域查询；可选能力不再成为普通代理的启动门槛。
        knownProtectedDomains=Set(plan.domains)
        captureNodeAddresses=nodeAddresses
        captureNodeInterfaces=try plan.nodeInterfaces(nodeAddresses,family:state.effectiveAddressFamilyPolicy)
        let dynamicRules=try DynamicCaptureRules(directory:root.appendingPathComponent("dynamic-rules"),plan:plan)
        self.dynamicRules=dynamicRules
        phase="coreValidation"
        var object=try measured("configGeneration") {try TunConfigBuilder.object(state:state,credentials:memory,control:control,address4:address4,address6:address6,originalDNS:dns,bypass:bypass.map{$0+($0.contains(":") ? "/128":"/32")},httpCompatibilityPort:request.httpCompatibilityPort,plan:plan,dnsForwardPort:forwarder.port,nodeInterfaces:captureNodeInterfaces)}
        dynamicRules.apply(to:&object,plan:plan)
        let config=try JSONSerialization.data(withJSONObject:object)
        let file=root.appendingPathComponent("runtime.json");try SecureFile.write(config,to:file)
        try measured("coreConfigCheck") {
        do {_=try NetworkInspection.command(root.appendingPathComponent("sing-box").path,["check","-c",file.path])}
        catch {try? FileManager.default.removeItem(at:file);throw ProxyError("固定核心校验 TUN 配置失败："+error.localizedDescription)}
        }
        let expected=CaptureDNSPolicy.settings(server:addresses.gateway4)
        journal=Journal(transactionID:routeTransaction,captureRoutes:captureRoutes.prefixes,preservedRoutes:bypassPlan.preservedRoutes,dnsKey:dnsKey,previousDNS:try readDNSService(dnsKey).map(DNSServiceTransaction.encode),expectedDNS:try PropertyListSerialization.data(fromPropertyList:expected,format:.binary,options:0),address4:address4,address6:address6);try save()
        do {
            try installBypassFirewall(state)
            phase="coreStartup"
            let readiness=try NativeInterfaceReadiness()
            let interfacesBefore=try NativeInterfaces.addresses()
            let output=Pipe(),diagnostics=coreDiagnostics
            coreOutput=output;coreDiagnostics=diagnostics
            output.fileHandleForReading.readabilityHandler={handle in let data=handle.availableData;diagnostics.receive(data,end:data.isEmpty);if data.isEmpty {handle.readabilityHandler=nil}}
            let core=Process();core.executableURL=root.appendingPathComponent("sing-box");core.arguments=["run","-c",file.path];core.standardOutput=output;core.standardError=output;core.terminationHandler={ [weak self,weak core] _ in self?.queue.async{guard let self,let core,self.process === core else{return};try? self.stop()}};process=core;owner=fd;try measured("coreProcessStart") {try core.run()};try? output.fileHandleForWriting.close();journal!.pid=core.processIdentifier;try save()
            phase="interfaceReady"
            let tunnel=try measured("interfaceReady") {try readiness.wait(previous:interfacesBefore,address:addresses.gateway4,timeout:5,alive:{core.isRunning},cancelled:{(try? self.checkRouteOwner()) == nil})}
            journal!.interface=tunnel;try save()
            guard CoreController.listening(state.listenPort),request.httpCompatibilityPort.map({CoreController.listening($0)}) ?? true else{throw ProxyError("TUN 核心监听尚未就绪")}
            phase="routeEncodingValidation"
            // 接口存在后预检全部待新增项，不能先写数百条再遇到一个本地编码错误。
            if let backend=routeBackend as? NativeRouteBackend {
                let captures=captureRoutes.prefixes.map{ProtectedRoute(destination:$0,gateway:$0.contains(":") ? String(address6.split(separator:"/")[0]):String(address4.split(separator:"/")[0]),interface:tunnel)}
                let scoped4=["0.0.0.0/1","128.0.0.0/1"].map{ProtectedRoute(destination:$0,gateway:gw4,interface:primary,scope:primary)}
                let scoped6=gw6.map{gateway in ["::/1","8000::/1"].map{ProtectedRoute(destination:$0,gateway:gateway,interface:primary,scope:primary)}} ?? []
                let protections=plan.protectedRoutes.filter{$0.scope != nil || $0.source=="用户网络绕过"}.map{ProtectedRoute(destination:$0.destination,gateway:$0.gateway,interface:$0.interface)}
                try measured("routeEncodingValidation") {try backend.validateWrites(protections+retainedBypasses+scoped4+scoped6+captures)}
            }
            activatePrepared={ [unowned self] in
            try NetworkInspection.checkConflicts(ownedTunnel:tunnel,routes:try routeSample().table)
            guard field("interface",try routeInfo("default",ipv6:false))==primary else{throw NetworkEnvironmentNotReady("准备期间物理网络已变化")}
            if let v6 {guard let current=try? routeInfo("default",ipv6:true),field("gateway",current)==field("gateway",v6),field("interface",current)==primary else{throw NetworkEnvironmentNotReady("准备期间 IPv6 默认路由已变化")}}
            phase="protection"
            let baseline=try sampledRoutes()
            try measured("protectionPlanValidation") {
                let current=RouteIdentityIndex(NetworkSnapshot.parseRoutes(baseline.table))
                guard plan.protectedRoutes.filter({$0.source != "用户网络绕过"}).allSatisfy({current.contains($0)}) else {throw NetworkEnvironmentNotReady("企业路由在准备期间变化")}
                try bypassPlan.validatePreservedRoutes(baseline.ownershipRoutes)
                try bypassPlan.validate(lookup:{try self.routeInfo($0,ipv6:$1)})
            }
            try measured("protectionBatch") {
                try RouteProtectionBatch.run(protected:plan.protectedRoutes,bypass:retainedBypasses,baseline:baseline,
                    read:{try self.sampledRoutes()},
                    check:{try self.checkRouteOwner()},
                    add:{route,bypass in try self.addRoute(route.destination,route.gateway,route.interface,ipv6:route.ipv6,scope:route.scope,preparationBypass:bypass)},
                    metrics:self.routeMetrics)
            }
            // 出站绑定物理网卡后需要限定路由；否则全局 /1 接管使 macOS 返回网络不可达。
            for destination in ["0.0.0.0/1","128.0.0.0/1"] {try addRoute(destination,gw4,primary,ipv6:false,scope:primary)}
            if let gw6 {for destination in ["::/1","8000::/1"] {try addRoute(destination,gw6,primary,ipv6:true,scope:primary)}}
            for destination in captureRoutes.prefixes {try addRoute(destination,destination.contains(":") ? String(address6.split(separator:"/")[0]):String(address4.split(separator:"/")[0]),tunnel,ipv6:destination.contains(":"))}
            try bypassPlan.validatePreservedRoutes(try routeSample().ownershipRoutes)
            try bypassPlan.validate(lookup:{try self.routeInfo($0,ipv6:$1)})
            phase="dnsActivation"
            try DNSServiceTransaction.apply([journal!.allDNSServices[0]],persist:save,read:readDNSService,write:writeDNSService)
            try publishCorporateDNS(plan)
            let dnsDeadline=Date().addingTimeInterval(3)
            var preferredDNS=false,lastDNS="",dnsCheckError=""
            repeat {
                do {
                    let output=try NetworkInspection.command("/usr/sbin/scutil",["--dns"],deadline:dnsDeadline)
                    lastDNS=output
                    if CaptureDNSPolicy.isPreferred(server:addresses.gateway4,in:output) {preferredDNS=true;break}
                } catch {dnsCheckError=String(describing:error);break}
                // 不在截止时间即将耗尽时再启动命令，保留最后一次有效解析器证据。
                guard dnsDeadline.timeIntervalSinceNow>0.25 else {break}
                usleep(200000)
            } while Date()<dnsDeadline
            guard preferredDNS else {
                let details=lastDNS.isEmpty ? "未取得有效 DNS 状态" : Redactor.redact(String(lastDNS.prefix(4096)))
                throw ProxyError("完整接管的默认 DNS 优先级未生效，未提交接管；检查："+dnsCheckError+"；解析器："+details)
            }
            let captureProbes=[false,true].compactMap {ipv6 -> String? in
                let preferred=ipv6 ? "2606:4700:4700::1111":"8.8.8.8"
                return captureRoutes.captures(preferred) ? preferred:captureRoutes.prefixes.first(where:{$0.contains(":")==ipv6}).map{String($0.split(separator:"/")[0])}
            }
            for destination in captureProbes {guard field("interface",try routeInfo(destination,ipv6:destination.contains(":")))==tunnel else{throw ProxyError("TUN 路由接管验证失败")}}
            guard let current=SCDynamicStoreCopyValue(dynamic,dnsKey as CFString) as? NSDictionary,current==expected as NSDictionary else{throw ProxyError("TUN DNS 生效验证失败")}
            guard verifyProtection() else{throw ProxyError("企业路由保护核对失败")}
            if let port=request.systemProxyPort {phase="proxyActivation";try applyProxy(port:port,plan:plan);try verifyProxyActivation()}
            activeRequest=request
            startNetworkMonitor()
            startPinnedMonitor(state)
            }
        }catch{let original=error;failurePhase=failurePhase ?? phase;failureKind=failureKind ?? ConnectionFailureKind.classify(error);do{try rollbackStartup()}catch{throw ConnectionFailure(.recovery,"启动失败："+original.localizedDescription+"；恢复失败："+error.localizedDescription)};throw original}
    }
    private func rollbackStartup() throws {
        connectionTiming?.finish(succeeded:false)
        connectionTiming?.begin("recovery")
        do {try stop();connectionTiming?.finish()}
        catch {connectionTiming?.finish(succeeded:false);throw error}
    }
    func handle(_ request:TunRequest,fd:Int32)->TunReply {
        failurePhase=nil;failureKind=nil
        let timing=ConnectionTiming()
        routeMetrics=RouteOperationMetrics()
        (routeBackend as? NativeRouteBackend)?.metrics=routeMetrics
        routeAudit.metrics=routeMetrics
        if request.progressUpdates==true,["prepare","activate"].contains(request.operation) {
            progressReply={phase in
                var progress=TunReply(ok:true,message:"连接阶段更新",phase:phase)
                progress.isProgress=true
                try? UnixChannel.send(JSONEncoder().encode(progress),fd:fd)
            }
        }
        if ["prepare","activate","stop","recover"].contains(request.operation) {
            connectionTiming=timing;timing.begin("helperOperation")
        }
        defer {connectionTiming=nil;routeMetrics=nil;progressReply=nil;(routeBackend as? NativeRouteBackend)?.metrics=nil;routeAudit.metrics=nil}
        do {
            var reply=try handleOperation(request,fd:fd)
            reply.tunnelInterface=journal?.interface
            reply.supportsManagedSystemProxy=true;reply.supportsTrustedCorporateDNS=true;reply.supportsWakeRecovery=true;reply.supportsExternalRecovery=true;reply.recoveryPending=journal != nil
            if request.operation=="status",request.verifyNetwork==true {reply.safeToQuit=verifyReleasedForQuit()}
            timing.finish()
            reply.corporateDNSDiagnostics=dnsForwarder?.diagnosticResults
            reply.stageTimings=timing.samples+(routeMetrics?.samples ?? [])
            return reply
        } catch {
            timing.finish(succeeded:false)
            var reply=TunReply(ok:false,message:"接管阶段 "+(failurePhase ?? phase)+"："+Redactor.redact(error.localizedDescription),coreDiagnostics:["prepare","activate"].contains(request.operation) ? coreDiagnostics.recent:nil,running:helperIsRunning,phase:phase,networkNotReady:error is NetworkEnvironmentNotReady,stageTimings:timing.samples+(routeMetrics?.samples ?? []))
            reply.failurePhase=failurePhase ?? phase;reply.failureKind=phase=="recovery" ? .recovery:(failureKind ?? ConnectionFailureKind.classify(error));reply.recoveryPhase=phase
            reply.tunnelInterface=journal?.interface
            reply.supportsManagedSystemProxy=true;reply.supportsTrustedCorporateDNS=true;reply.supportsWakeRecovery=true;reply.supportsExternalRecovery=true;reply.recoveryPending=journal != nil
            return reply
        }
    }
    private func handleOperation(_ request:TunRequest,fd:Int32) throws -> TunReply {
        guard request.preserveExternal != true || request.operation=="recover" else{throw ProxyError("保留外部网络仅用于用户恢复操作")}
        switch request.operation {case "status":
            if journal?.proxyOnly==true {
                return TunReply(ok:true,message:"系统代理授权服务已就绪",running:helperIsRunning,proxyVerified:verifyProxy(),phase:phase)
            }
            if request.verifyNetwork==true,let record=journal,process?.isRunning==true {
                return try wakeNetworkReply(record:record,sample:routeSample())
            }
            return TunReply(ok:true,message:networkStatus+(journal != nil && process==nil ? " · 存在待恢复记录":""),coreDiagnostics:process?.isRunning==true ? coreDiagnostics.recent:nil,running:helperIsRunning,protectionSummary:networkSummary,phase:phase)
        case "systemProxy":return try startManagedSystemProxy(request,fd:fd)
        case "pinBypasses":
            guard request.protocolVersion==5,let state=request.state,state.captureMode == .systemProxy else {throw ProxyError("指定出口辅助协议或模式无效，请更新辅助服务")}
            do {try startPinnedBypasses(request,fd:fd)}catch{let original=error;try stop();throw original}
            return TunReply(ok:true,message:"指定出口路由与拒绝保护已准备",running:true,protectionSummary:pinnedPaths.map{$0.destination+" → "+$0.interface},phase:phase)
        case "prepare":lastFailure=nil;do{try start(request,fd:fd)}catch{let original=error;failurePhase=failurePhase ?? phase;failureKind=failureKind ?? ConnectionFailureKind.classify(error);do{try rollbackStartup()}catch{throw ConnectionFailure(.recovery,"启动失败："+original.localizedDescription+"；恢复失败："+error.localizedDescription)};throw original};phase="prepared";return TunReply(ok:true,message:"核心已准备，网络尚未接管",running:true,dnsServer:journal.map{String($0.address4.split(separator:"/")[0])})
        case "activate":
            guard request.protocolVersion==5,owner==fd,process?.isRunning==true,let activate=activatePrepared else{throw ProxyError("TUN 准备状态无效")}
            phase="activation"
            do{try activate();activatePrepared=nil;phase="active";return TunReply(ok:true,message:"TUN 路由及 DNS 已接管；应用连接另行检测",running:true)}catch{let original=error;failurePhase=failurePhase ?? phase;failureKind=failureKind ?? ConnectionFailureKind.classify(error);do{try rollbackStartup()}catch{throw ConnectionFailure(.recovery,"启动失败："+original.localizedDescription+"；恢复失败："+error.localizedDescription)};throw original}
        case "stop","recover":
            // 与辅助服务的网络重建共用串行队列；检查和恢复之间不允许插入另一轮重建。
            if request.deferToNetworkResume==true,networkResumeSession != nil {
                return TunReply(ok:true,message:"辅助服务正在重建，客户端等待核验",running:helperIsRunning,phase:"networkReconnecting")
            }
            phase="recovery";try stop(preserveExternal:request.preserveExternal==true);phase="restored";lastFailure=nil
            return TunReply(ok:true,message:request.preserveExternal==true ? "轻舟接管已清理，外部网络已保留":"原网络已恢复")
        default:throw ProxyError("只允许状态、启动、停止、恢复操作")}
    }
}
func run() throws {
    let preserving=CommandLine.arguments.dropFirst()==["--recover-preserving-external"]
    let service=try Service(recoveryOnly:preserving)
    if preserving {try service.recoverStartup(preserveExternal:true);print("外部网络保留完成；轻舟仍拥有的残留已清理");return}
    if CommandLine.arguments.dropFirst()==["--recover"]{try service.recoverStartup();print("原网络恢复完成");return}
    guard CommandLine.arguments.count==1 else{throw ProxyError("辅助服务参数无效")}
    try service.recoverStartup();umask(0o077)
    let path=HelperPaths.socket;try? FileManager.default.removeItem(atPath:path);let server=socket(AF_UNIX,SOCK_STREAM,0);guard server>=0 else{throw ProxyError("辅助服务套接字失败")};var address=try UnixChannel.address(path);let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(server,$0,socklen_t(MemoryLayout<sockaddr_un>.size))==0}};guard bound,listen(server,8)==0 else{throw ProxyError("辅助服务监听失败")};chown(path,uid_t(service.manifest.uid),0);chmod(path,0o600)
    signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);let termination=DispatchSource.makeSignalSource(signal:SIGTERM,queue:service.queue);termination.setEventHandler{try? service.stop();exit(0)};termination.resume()
    DispatchQueue.global().async {while true {let fd=accept(server,nil,nil);if fd<0{continue};var option:Int32=1;_=setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&option,socklen_t(MemoryLayout<Int32>.size));DispatchQueue.global().async{defer{service.queue.sync{if service.owner==fd{try? service.stop()}};close(fd)};do{do{try service.authorize(fd)}catch{try? UnixChannel.send(JSONEncoder().encode(TunReply(ok:false,message:error.localizedDescription)),fd:fd,deadline:ProcessInfo.processInfo.systemUptime+1);return};while true{let data=try UnixChannel.receive(fd:fd);let request=try JSONDecoder().decode(TunRequest.self,from:data);let response=service.queue.sync{service.handle(request,fd:fd)};try UnixChannel.send(JSONEncoder().encode(response),fd:fd)}}catch{}}}}
    dispatchMain()
}
#if !QZ_HELPER_FIXTURE
do{try run()}catch{fputs("辅助服务操作失败："+Redactor.redact(error.localizedDescription)+"\n",stderr);exit(1)}

#endif
