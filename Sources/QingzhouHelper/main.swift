import Foundation
import Darwin
import Security
import CryptoKit
import SystemConfiguration
import QingzhouKit

struct Manifest:Codable {var version:String;var uid:UInt32;var clientHash:String;var coreHash:String;var helperHash:String}
struct OwnedRoute:Codable {var destination:String;var gateway:String;var interface:String;var ipv6:Bool;var scope:String?=nil}
struct Journal:Codable {var version=2;var proxies:[HelperProxyRecord]?;var pid:Int32?;var interface:String?;var routes:[OwnedRoute]=[];var dnsKey:String;var previousDNS:Data?;var expectedDNS:Data;var address4:String;var address6:String}
final class Service {
    let root=URL(fileURLWithPath:HelperPaths.directory)
    let manifest:Manifest
    let queue=DispatchQueue(label:"cn.qingzhou.helper.capture")
    var phase="idle"
    var capturePlan:CapturePlan?
    var dnsForwarder:ScopedDNSForwarder?
    var activeRequest:TunRequest?
    var networkTimer:DispatchSourceTimer?
    var networkStore:SCDynamicStore?
    var routeEvents:DispatchSourceRead?
    var pendingNetworkChange:Date?
    var snapshotRetry=NetworkSnapshotRetry()
    var networkStatus:String {phase=="networkRetry" ? "网络变化，正在重新检查":lastFailure ?? HelperPaths.version}
    var networkSummary:[String] {(capturePlan?.summary ?? [])+(dnsForwarder.map{[$0.diagnostics]} ?? [])}
    var lastFailure:String?
    var process:Process?
    var activatePrepared:(() throws -> Void)?
    var owner:Int32?
    var journal:Journal?
    let dynamic:SCDynamicStore
    init() throws {
        guard geteuid()==0 else{throw ProxyError("辅助服务必须由管理员安装并由 launchd 运行")}
        dynamic=SCDynamicStoreCreate(nil,"QingzhouHelper" as CFString,nil,nil)!
        let directoryAttributes=try FileManager.default.attributesOfItem(atPath:root.path);guard (directoryAttributes[.ownerAccountID] as? NSNumber)?.uint32Value==0,((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)&0o022==0,directoryAttributes[.type] as? FileAttributeType == .typeDirectory else{throw ProxyError("辅助服务目录权限无效")}
        let url=root.appendingPathComponent("manifest.json");try Self.protected(url)
        manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:url));guard manifest.version==HelperPaths.version else{throw ProxyError("辅助服务版本不匹配，请重新批准安装")}
        for (name,expected) in [("sing-box",manifest.coreHash),("QingzhouHelper",manifest.helperHash)]{let file=root.appendingPathComponent(name);try Self.protected(file);guard Self.hash(try Data(contentsOf:file))==expected else{throw ProxyError("固定组件校验失败，请重新批准安装")}}
    }
    static func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func protected(_ url:URL) throws {let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value==0,let mode=(attrs[.posixPermissions] as? NSNumber)?.intValue,mode&0o022==0,attrs[.type] as? FileAttributeType == .typeRegular else{throw ProxyError("权限组件必须是 root 所有且不可由普通用户写入的常规文件")}}
    func authorize(_ fd:Int32) throws {
        var token=[UInt32](repeating:0,count:8);var size=socklen_t(32);guard getsockopt(fd,0,0x006,&token,&size)==0,size==32,token[1]==manifest.uid else{throw ProxyError("客户端身份不允许")}
        let audit=token.withUnsafeBytes{Data($0)};var guest:SecCode?;let attrs=[kSecGuestAttributeAudit as String:audit] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil,attrs,SecCSFlags(),&guest)==errSecSuccess,let guest,SecCodeCheckValidity(guest,SecCSFlags(),nil)==errSecSuccess else{throw ProxyError("客户端代码签名无效")}
        var staticCode:SecStaticCode?;guard SecCodeCopyStaticCode(guest,SecCSFlags(),&staticCode)==errSecSuccess,let staticCode else{throw ProxyError("客户端代码身份无法读取")};var information:CFDictionary?;guard SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&information)==errSecSuccess,let info=information as? [String:Any],let cdhash=info[kSecCodeInfoUnique as String] as? Data,cdhash.map({String(format:"%02x",$0)}).joined()==manifest.clientHash else{throw ProxyError("客户端代码身份已变化，请重新批准更新")}
    }
    func save() throws {guard let journal else{return};try SecureFile.write(JSONEncoder().encode(journal),to:root.appendingPathComponent("recovery.json"))}
    func routeInfo(_ destination:String,ipv6:Bool,scope:String?=nil) throws -> String {try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.get,destination:destination,ipv6:ipv6,scope:scope))}
    func field(_ label:String,_ text:String)->String?{text.components(separatedBy:.newlines).first{$0.trimmingCharacters(in:.whitespaces).hasPrefix(label+":")}.map{$0.components(separatedBy:":").dropFirst().joined(separator:":").trimmingCharacters(in:.whitespaces)}}
    func prefix(_ info:String)->String? {NetworkInspection.routePrefix(destination:field("destination",info),mask:field("mask",info),host:info.contains("HOST"))}
    func stop() throws {
        activatePrepared=nil;activeRequest=nil;networkTimer?.cancel();networkTimer=nil;if let networkStore {SCDynamicStoreSetDispatchQueue(networkStore,nil)};networkStore=nil;routeEvents?.cancel();routeEvents=nil;pendingNetworkChange=nil;snapshotRetry.reset();dnsForwarder?.stop();dnsForwarder=nil;capturePlan=nil
        guard let record=journal else{        if let process,process.isRunning {process.terminate();for _ in 0..<40 {if !process.isRunning{break};usleep(50000)};if process.isRunning{kill(process.processIdentifier,SIGKILL)};process.waitUntilExit()};process=nil;owner=nil;try? FileManager.default.removeItem(at:root.appendingPathComponent("runtime.json"))
return};var conflict=false
        do{conflict = !(try restoreProxy(record.proxies ?? []))}catch{conflict=true}
        let current=SCDynamicStoreCopyValue(dynamic,record.dnsKey as CFString)
        let expected=try PropertyListSerialization.propertyList(from:record.expectedDNS,format:nil) as! NSDictionary
        if let current=current as? NSDictionary,current==expected {if let original=record.previousDNS {let value=try PropertyListSerialization.propertyList(from:original,format:nil);if !SCDynamicStoreSetValue(dynamic,record.dnsKey as CFString,value as CFPropertyList){conflict=true}}else if !SCDynamicStoreRemoveValue(dynamic,record.dnsKey as CFString){conflict=true}}
        else if current==nil,record.previousDNS != nil{conflict=true}
        else if let current=current as? NSDictionary {let old=try record.previousDNS.map{try PropertyListSerialization.propertyList(from:$0,format:nil) as! NSDictionary};if current != old{conflict=true}}
        for route in record.routes.reversed() {
            guard let info=try? routeInfo(route.destination,ipv6:route.ipv6,scope:route.scope) else{conflict=true;continue}
            if !NetworkInspection.routeScopeMatches(route.scope,flags:field("flags",info),interface:field("interface",info)) {continue}
            // 只有网关和接口都仍属于本次记录的路由才删除；外部修改时保留恢复记录。
            if let current=prefix(info),NetworkInspection.samePrefix(current,route.destination),field("gateway",info)==route.gateway,field("interface",info)==route.interface {do{_ = try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.delete,destination:route.destination,gateway:route.gateway,ipv6:route.ipv6,scope:route.scope))}catch{conflict=true}}
            else if let current=prefix(info),NetworkInspection.samePrefix(current,route.destination){conflict=true}
        }
                if let process,process.isRunning {process.terminate();for _ in 0..<40 {if !process.isRunning{break};usleep(50000)};if process.isRunning{kill(process.processIdentifier,SIGKILL)};process.waitUntilExit()};process=nil;owner=nil

        try? FileManager.default.removeItem(at:root.appendingPathComponent("runtime.json"))
        if conflict {try save();throw ProxyError("检测到外部 DNS/路由修改冲突，已停止核心；保留恢复记录，请查看手动恢复说明")}
        try FileManager.default.removeItem(at:root.appendingPathComponent("recovery.json"));journal=nil
    }
    func recoverStartup() throws {let file=root.appendingPathComponent("recovery.json");if FileManager.default.fileExists(atPath:file.path){try Self.protected(file);journal=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:file));if let pid=journal?.pid {var buffer=[CChar](repeating:0,count:4096);if proc_pidpath(pid,&buffer,UInt32(buffer.count))>0,String(cString:buffer)==root.appendingPathComponent("sing-box").path{kill(pid,SIGTERM);usleep(200000)}};try stop()}}
    func addRoute(_ destination:String,_ gateway:String,_ interface:String,ipv6:Bool,scope:String?=nil) throws {
        if let info=try? routeInfo(destination,ipv6:ipv6,scope:scope),let current=prefix(info),NetworkInspection.samePrefix(current,destination),NetworkInspection.routeScopeMatches(scope,flags:field("flags",info),interface:field("interface",info)){
            guard interface==field("interface",info) else{throw ProxyError("路由前缀 \(destination) 已被 \(field("interface",info) ?? "未知接口") 占用，未替换现有路由")};return
        }
        let args=gateway.hasPrefix("link#") ? NetworkInspection.routeArguments(.add,destination:destination,ipv6:ipv6,scope:scope)+["-interface",interface]:NetworkInspection.routeArguments(.add,destination:destination,gateway:gateway,ipv6:ipv6,scope:scope)
        let route=OwnedRoute(destination:destination,gateway:gateway,interface:interface,ipv6:ipv6,scope:scope)
        // 先记录意图再写路由；崩溃恢复仍通过当前网关和接口确认所有权。
        journal!.routes.append(route);try save()
        do{_=try NetworkInspection.command("/sbin/route",args)}catch{journal!.routes.removeLast();try save();throw error}
        if let current=try? routeInfo(destination,ipv6:ipv6,scope:scope),let actual=field("gateway",current) {journal!.routes[journal!.routes.count-1].gateway=actual};try save()
    }
    func start(_ request:TunRequest,fd:Int32) throws {
        guard process==nil,journal==nil,let state=request.state,let values=request.credentials,let control=request.control,state.captureMode.usesTunnel,values.count<=6000 else{throw ProxyError("重复启动或 TUN 模型无效，请先恢复")}
        guard control.secret.count==64,control.secret.allSatisfy({$0.isHexDigit}),(1024...65535).contains(control.port),control.port != state.listenPort else{throw ProxyError("控制通道模型无效")}
        guard request.protocolVersion==3 else{throw ProxyError("辅助服务协议不匹配，请更新应用及辅助服务")}
        if let port=request.httpCompatibilityPort {guard (1024...65535).contains(port),port != state.listenPort,port != control.port,state.shadowrocket?.requiresHTTPCompatibility==true else{throw ProxyError("兼容端口模型无效")}}
        if state.captureMode == .compatible {guard let port=request.systemProxyPort,(1024...65535).contains(port),port != control.port else{throw ProxyError("兼容代理端口无效")}} else {guard request.systemProxyPort==nil else{throw ProxyError("非兼容模式不能请求系统代理")}}
        phase="preflight"
        try NetworkInspection.checkConflicts();try PolicyValidator.validate(state)
        let memory=MemoryCredentials();for (key,value) in values{guard key.count<=200,value.utf8.count<=16384 else{throw ProxyError("凭据模型超过限制")};try memory.set(value,for:key)}
        guard let global=SCDynamicStoreCopyValue(dynamic,"State:/Network/Global/IPv4" as CFString) as? [String:Any],let service=global["PrimaryService"] as? String,let primary=global["PrimaryInterface"] as? String,primary.range(of:"^[a-z][a-z0-9]{0,15}$",options:.regularExpression) != nil else{throw ProxyError("原网络服务无法可靠识别")}
        let dnsKey=NetworkInspection.tunDNSKey(UUID())
        let originalRoutes=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
        let snapshot=try NetworkSnapshot.read(store:dynamic,primary:primary,routes:originalRoutes)
        let plan=try CapturePlan.make(snapshot:snapshot,extraCIDRs:state.tunExcludedCIDRs,extraDomains:state.protectedDomains)
        let dns=snapshot.resolvers.flatMap(\.servers).map{$0.components(separatedBy:"%")[0]}
        capturePlan=plan
        let v4=try routeInfo("default",ipv6:false)
        guard let gw4=field("gateway",v4),field("interface",v4)==primary else{throw ProxyError("IPv4 原路由不可用，未启用 TUN")}
        let candidate6=try? routeInfo("default",ipv6:true)
        let v6:String?
        if let candidate6,field("interface",candidate6)==primary {v6=candidate6}
        else if candidate6?.contains("IFSCOPE")==true {v6=nil}
        else if candidate6 != nil {throw ProxyError("IPv6 默认路由属于其他接口，未启用 TUN")}
        else {v6=nil}
        let gw6=v6.flatMap{field("gateway",$0)}
        phase="bootstrapDNS"
        let deadline=Date().addingTimeInterval(6)
        var bypass=Set(dns+["1.1.1.1"]);var nodeAddresses:[String:[String]]=[:]
        for host in Set(state.nodes.map(\.server)) {
            let remaining=min(3,deadline.timeIntervalSinceNow)
            guard remaining>0 else{throw ProxyError("节点引导解析超过启动预算，未接管网络")}
            let values=try NetworkInspection.boundedAddresses(host,timeout:remaining);nodeAddresses[host]=values;for address in values {bypass.insert(address)}
        }
        let routesBefore=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
        phase="networkRecheck"
        let currentDefault=try routeInfo("default",ipv6:false)
        let vpn=try NetworkInspection.command("/usr/sbin/scutil",["--nc","list"])
        guard let currentGlobal=SCDynamicStoreCopyValue(dynamic,"State:/Network/Global/IPv4" as CFString) as? [String:Any],currentGlobal["PrimaryService"] as? String==service,let currentProxies=SCDynamicStoreCopyProxies(nil) as? [String:Any] else{throw ProxyError("准备期间网络服务已变化，未接管网络")}
        try NetworkInspection.validatePreparation(interface:primary,gateway:gw4,currentInterface:field("interface",currentDefault),currentGateway:field("gateway",currentDefault),vpn:vpn,routes:routesBefore,proxies:currentProxies)
        phase="addressPlan"
        let addresses=try TunAddressPlan.make(routes:routesBefore,bypassCIDRs:state.tunExcludedCIDRs,physicalInterface:primary)
        let address4=addresses.address4,address6=addresses.address6
        phase="coreValidation"
        let forwarder=try ScopedDNSForwarder(plan:plan);dnsForwarder=forwarder;forwarder.start()
        phase="dnsBaseline"
        let baseline=plan.snapshot.resolvers.filter{forwarder.probe($0)}
        phase="coreValidation"
        let config=try TunConfigBuilder.build(state:state,credentials:memory,control:control,address4:address4,address6:address6,originalDNS:dns,bypass:bypass.map{$0+($0.contains(":") ? "/128":"/32")},httpCompatibilityPort:request.httpCompatibilityPort,plan:plan,dnsForwardPort:forwarder.port,nodeInterfaces:try plan.nodeInterfaces(nodeAddresses,family:state.effectiveAddressFamilyPolicy))
        let file=root.appendingPathComponent("runtime.json");try SecureFile.write(config,to:file)
        let check=Process();check.executableURL=root.appendingPathComponent("sing-box");check.arguments=["check","-c",file.path];check.standardOutput=FileHandle.nullDevice;check.standardError=FileHandle.nullDevice;try check.run();check.waitUntilExit();guard check.terminationStatus==0 else{try? FileManager.default.removeItem(at:file);throw ProxyError("固定核心校验 TUN 配置失败")}
        let expected:[String:Any]=["ServerAddresses":[addresses.gateway4],"SupplementalMatchDomains":[""],"SupplementalMatchDomainsNoSearch":1]
        journal=Journal(dnsKey:dnsKey,previousDNS:nil,expectedDNS:try PropertyListSerialization.data(fromPropertyList:expected,format:.binary,options:0),address4:address4,address6:address6);try save()
        do {
            phase="coreStartup"
            let interfacesBefore=try NetworkInspection.command("/sbin/ifconfig",["-l"]).split(separator:" ").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
            let core=Process();core.executableURL=root.appendingPathComponent("sing-box");core.arguments=["run","-c",file.path];core.standardOutput=FileHandle.nullDevice;core.standardError=FileHandle.nullDevice;core.terminationHandler={ [weak self,weak core] _ in self?.queue.async{guard let self,let core,self.process === core else{return};try? self.stop()}};process=core;owner=fd;try core.run();journal!.pid=core.processIdentifier;try save()
            var tunnel:String?
            for _ in 0..<100 {guard core.isRunning else{throw ProxyError("TUN 核心启动失败")};let interfaces=try NetworkInspection.command("/sbin/ifconfig",["-l"]).split(separator:" ").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)};let added=interfaces.filter{!interfacesBefore.contains($0) && $0.hasPrefix("utun")};if added.count==1 {let output=try NetworkInspection.command("/sbin/ifconfig",[added[0]]);if output.contains(addresses.gateway4){tunnel=added[0];break}};usleep(50000)}
            guard let tunnel else{throw ProxyError("TUN 接口归属校验失败")};journal!.interface=tunnel;try save()
            guard CoreController.listening(state.listenPort),request.httpCompatibilityPort.map({CoreController.listening($0)}) ?? true else{throw ProxyError("TUN 核心监听尚未就绪")}
            activatePrepared={ [unowned self] in
            try NetworkInspection.checkConflicts(ownedTunnel:tunnel)
            guard field("interface",try routeInfo("default",ipv6:false))==primary else{throw ProxyError("准备期间物理网络已变化")}
            if let v6 {guard let current=try? routeInfo("default",ipv6:true),field("gateway",current)==field("gateway",v6),field("interface",current)==primary else{throw ProxyError("准备期间 IPv6 默认路由已变化")}}
            phase="protection"
            let currentRoutes=NetworkSnapshot.parseRoutes(try NetworkInspection.command("/usr/sbin/netstat",["-rn"]))
            guard plan.protectedRoutes.allSatisfy({expected in currentRoutes.contains{actual in NetworkInspection.samePrefix(actual.destination,expected.destination) && actual.interface==expected.interface && actual.gateway==expected.gateway && actual.scope==expected.scope}}) else{throw ProxyError("企业路由在准备期间变化")}
            for route in plan.protectedRoutes {try protect(route)}
            let existing=TunAddressPlan.routePrefixes(routesBefore)
            for destination in Set(plan.exclusions+bypass.map{$0+($0.contains(":") ? "/128":"/32")}).sorted() {
                if TunAddressPlan.containsRoute(destination,prefixes:existing) {continue}
                let ipv6=destination.contains(":");if ipv6,gw6==nil {continue}
                // 明确排除项沿接管前查询到的原路径转发，不能一律改走物理接口。
                let target=String(destination.split(separator:"/")[0])
                let previous=try routeInfo(target,ipv6:ipv6)
                guard let gateway=field("gateway",previous),let interface=field("interface",previous) else{throw ProxyError("绕过项原出口无法确认")}
                try addRoute(destination,gateway,interface,ipv6:ipv6)
            }
            // 出站绑定物理网卡后需要限定路由；否则全局 /1 接管使 macOS 返回网络不可达。
            for destination in ["0.0.0.0/1","128.0.0.0/1"] {try addRoute(destination,gw4,primary,ipv6:false,scope:primary)}
            if let gw6 {for destination in ["::/1","8000::/1"] {try addRoute(destination,gw6,primary,ipv6:true,scope:primary)}}
            for destination in ["0.0.0.0/1","128.0.0.0/1","::/1","8000::/1"]{try addRoute(destination,destination.contains(":") ? String(address6.split(separator:"/")[0]):String(address4.split(separator:"/")[0]),tunnel,ipv6:destination.contains(":"))}
            phase="dnsActivation"
            guard SCDynamicStoreSetValue(dynamic,dnsKey as CFString,expected as CFDictionary) else{throw ProxyError("TUN DNS 设置失败")}
            for destination in ["8.8.8.8","2606:4700:4700::1111"] {guard field("interface",try routeInfo(destination,ipv6:destination.contains(":")))==tunnel else{throw ProxyError("TUN 路由接管验证失败")}}
            guard let current=SCDynamicStoreCopyValue(dynamic,dnsKey as CFString) as? NSDictionary,current==expected as NSDictionary else{throw ProxyError("TUN DNS 生效验证失败")}
            guard verifyProtection() else{throw ProxyError("企业路由保护核对失败")};guard baseline.allSatisfy({forwarder.probe($0)}) else{throw ProxyError("启动前可用的原 DNS 在接管后不可达")}
            if let port=request.systemProxyPort {phase="proxyActivation";try applyProxy(port:port,plan:plan);guard verifyProxy() else{throw ProxyError("兼容代理入口核对失败")}}
            activeRequest=request
            startNetworkMonitor()
            }
        }catch{let original=error;try stop();throw original}
    }
    func handle(_ request:TunRequest,fd:Int32)->TunReply {
        do {switch request.operation {case "status":
            if request.verifyNetwork==true,let record=journal,process?.isRunning==true {
                let tunnels=record.routes.filter{$0.interface==record.interface};let verified=tunnels.count==4 && tunnels.allSatisfy{route in guard let info=try? routeInfo(route.destination,ipv6:route.ipv6,scope:route.scope),let current=prefix(info) else{return false};return NetworkInspection.samePrefix(current,route.destination) && field("interface",info)==route.interface && field("gateway",info)==route.gateway}
                let current=SCDynamicStoreCopyValue(dynamic,record.dnsKey as CFString) as? NSDictionary;let expected=try PropertyListSerialization.propertyList(from:record.expectedDNS,format:nil) as! NSDictionary
                return TunReply(ok:true,message:networkStatus,running:true,routesVerified:verified,dnsVerified:current==expected,proxyVerified:verifyProxy(),protectionVerified:verifyProtection(),protectionSummary:networkSummary,phase:phase)
            }
            return TunReply(ok:true,message:networkStatus+(journal != nil && process==nil ? " · 存在待恢复记录":""),running:process?.isRunning==true,protectionSummary:networkSummary,phase:phase)
        case "prepare":lastFailure=nil;do{try start(request,fd:fd)}catch{let original=error;try stop();throw original};phase="prepared";return TunReply(ok:true,message:"核心已准备，网络尚未接管",running:true,dnsServer:journal.map{String($0.address4.split(separator:"/")[0])})
        case "activate":
            guard request.protocolVersion==3,owner==fd,process?.isRunning==true,let activate=activatePrepared else{throw ProxyError("TUN 准备状态无效")}
            phase="activation"
            do{try activate();activatePrepared=nil;phase="active";return TunReply(ok:true,message:"TUN 路由及 DNS 已接管；应用连接另行检测",running:true)}catch{let original=error;try stop();throw original}
        case "stop","recover":try stop();phase="restored";return TunReply(ok:true,message:"原网络已恢复")
        default:throw ProxyError("只允许状态、启动、停止、恢复操作")}}catch{return TunReply(ok:false,message:"TUN 阶段 "+phase+"："+Redactor.redact(error.localizedDescription),running:process?.isRunning==true,phase:phase)}
    }
}
func run() throws {
    let service=try Service()
    if CommandLine.arguments.dropFirst()==["--recover"]{try service.recoverStartup();print("原网络恢复完成");return}
    guard CommandLine.arguments.count==1 else{throw ProxyError("辅助服务参数无效")}
    try service.recoverStartup();umask(0o077)
    let path=HelperPaths.socket;try? FileManager.default.removeItem(atPath:path);let server=socket(AF_UNIX,SOCK_STREAM,0);guard server>=0 else{throw ProxyError("辅助服务套接字失败")};var address=try UnixChannel.address(path);let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(server,$0,socklen_t(MemoryLayout<sockaddr_un>.size))==0}};guard bound,listen(server,8)==0 else{throw ProxyError("辅助服务监听失败")};chown(path,uid_t(service.manifest.uid),0);chmod(path,0o600)
    signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);let termination=DispatchSource.makeSignalSource(signal:SIGTERM,queue:service.queue);termination.setEventHandler{try? service.stop();exit(0)};termination.resume()
    DispatchQueue.global().async {while true {let fd=accept(server,nil,nil);if fd<0{continue};var option:Int32=1;_=setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&option,socklen_t(MemoryLayout<Int32>.size));DispatchQueue.global().async{defer{service.queue.sync{if service.owner==fd{try? service.stop()}};close(fd)};do{try service.authorize(fd);while true{let data=try UnixChannel.receive(fd:fd);let request=try JSONDecoder().decode(TunRequest.self,from:data);let response=service.queue.sync{service.handle(request,fd:fd)};try UnixChannel.send(JSONEncoder().encode(response),fd:fd)}}catch{}}}}
    dispatchMain()
}
do{try run()}catch{fputs("辅助服务操作失败："+Redactor.redact(error.localizedDescription)+"\n",stderr);exit(1)}
