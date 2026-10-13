import Foundation
import Darwin
import Security
import CryptoKit
import SystemConfiguration
import QingzhouKit

struct Manifest:Codable {var version:String;var uid:UInt32;var clientHash:String;var coreHash:String;var helperHash:String}
struct OwnedRoute:Codable {var destination:String;var gateway:String;var interface:String;var ipv6:Bool}
struct Journal:Codable {var version=1;var pid:Int32?;var interface:String?;var routes:[OwnedRoute]=[];var dnsKey:String;var previousDNS:Data?;var expectedDNS:Data;var address4:String;var address6:String}
final class Service {
    let root=URL(fileURLWithPath:HelperPaths.directory)
    let manifest:Manifest
    let queue=DispatchQueue(label:"cn.qingzhou.helper.capture")
    var process:Process?
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
    func routeInfo(_ destination:String,ipv6:Bool) throws -> String {try NetworkInspection.command("/sbin/route",["-n","get"]+(ipv6 ? ["-inet6"]:[])+[destination])}
    func field(_ label:String,_ text:String)->String?{text.components(separatedBy:.newlines).first{$0.trimmingCharacters(in:.whitespaces).hasPrefix(label+":")}.map{$0.components(separatedBy:":").dropFirst().joined(separator:":").trimmingCharacters(in:.whitespaces)}}
    func prefix(_ info:String)->String? {NetworkInspection.routePrefix(destination:field("destination",info),mask:field("mask",info),host:info.contains("HOST"))}
    func stop() throws {
        guard let record=journal else{        if let process,process.isRunning {process.terminate();for _ in 0..<40 {if !process.isRunning{break};usleep(50000)};if process.isRunning{kill(process.processIdentifier,SIGKILL)};process.waitUntilExit()};process=nil;owner=nil
return};var conflict=false
        let current=SCDynamicStoreCopyValue(dynamic,record.dnsKey as CFString)
        let expected=try PropertyListSerialization.propertyList(from:record.expectedDNS,format:nil) as! NSDictionary
        if let current=current as? NSDictionary,current==expected {if let original=record.previousDNS {let value=try PropertyListSerialization.propertyList(from:original,format:nil);if !SCDynamicStoreSetValue(dynamic,record.dnsKey as CFString,value as CFPropertyList){conflict=true}}else if !SCDynamicStoreRemoveValue(dynamic,record.dnsKey as CFString){conflict=true}}
        else if current==nil,record.previousDNS != nil{conflict=true}
        else if let current=current as? NSDictionary {let old=try record.previousDNS.map{try PropertyListSerialization.propertyList(from:$0,format:nil) as! NSDictionary};if current != old{conflict=true}}
        for route in record.routes.reversed() {
            guard let info=try? routeInfo(route.destination,ipv6:route.ipv6) else{conflict=true;continue}
            // 只有网关和接口都仍属于本次记录的路由才删除；外部修改时保留恢复记录。
            if let current=prefix(info),NetworkInspection.samePrefix(current,route.destination),field("gateway",info)==route.gateway,field("interface",info)==route.interface {do{_ = try NetworkInspection.command("/sbin/route",["-n","delete"]+(route.ipv6 ? ["-inet6"]:[])+["-net",route.destination,route.gateway])}catch{conflict=true}}
            else if let current=prefix(info),NetworkInspection.samePrefix(current,route.destination){conflict=true}
        }
                if let process,process.isRunning {process.terminate();for _ in 0..<40 {if !process.isRunning{break};usleep(50000)};if process.isRunning{kill(process.processIdentifier,SIGKILL)};process.waitUntilExit()};process=nil;owner=nil

        try? FileManager.default.removeItem(at:root.appendingPathComponent("runtime.json"))
        if conflict {try save();throw ProxyError("检测到外部 DNS/路由修改冲突，已停止核心；保留恢复记录，请查看手动恢复说明")}
        try FileManager.default.removeItem(at:root.appendingPathComponent("recovery.json"));journal=nil
    }
    func recoverStartup() throws {let file=root.appendingPathComponent("recovery.json");if FileManager.default.fileExists(atPath:file.path){try Self.protected(file);journal=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:file));if let pid=journal?.pid {var buffer=[CChar](repeating:0,count:4096);if proc_pidpath(pid,&buffer,UInt32(buffer.count))>0,String(cString:buffer)==root.appendingPathComponent("sing-box").path{kill(pid,SIGTERM);usleep(200000)}};try stop()}}
    func addRoute(_ destination:String,_ gateway:String,_ interface:String,ipv6:Bool) throws {
        if let info=try? routeInfo(destination,ipv6:ipv6),let current=prefix(info),NetworkInspection.samePrefix(current,destination){
            guard interface==field("interface",info),!interface.hasPrefix("utun") else{throw ProxyError("路由前缀已被占用，未替换现有路由")};return
        }
        let args=["-n","add"]+(ipv6 ? ["-inet6"]:[])+["-net",destination,gateway]
        let route=OwnedRoute(destination:destination,gateway:gateway,interface:interface,ipv6:ipv6)
        // 先记录意图再写路由；崩溃恢复仍通过当前网关和接口确认所有权。
        journal!.routes.append(route);try save()
        do{_=try NetworkInspection.command("/sbin/route",args)}catch{journal!.routes.removeLast();try save();throw error}
    }
    func start(_ request:TunRequest,fd:Int32) throws {
        guard process==nil,journal==nil,let state=request.state,let values=request.credentials,let control=request.control,state.captureMode == .tun,values.count<=6000 else{throw ProxyError("重复启动或 TUN 模型无效，请先恢复")}
        guard control.secret.count==64,control.secret.allSatisfy({$0.isHexDigit}),(1024...65535).contains(control.port),control.port != state.listenPort else{throw ProxyError("控制通道模型无效")}
        try NetworkInspection.checkConflicts();try PolicyValidator.validate(state)
        let memory=MemoryCredentials();for (key,value) in values{guard key.count<=200,value.utf8.count<=16384 else{throw ProxyError("凭据模型超过限制")};try memory.set(value,for:key)}
        guard let global=SCDynamicStoreCopyValue(dynamic,"State:/Network/Global/IPv4" as CFString) as? [String:Any],let service=global["PrimaryService"] as? String,let primary=global["PrimaryInterface"] as? String,primary.range(of:"^[a-z][a-z0-9]{0,15}$",options:.regularExpression) != nil else{throw ProxyError("原网络服务无法可靠识别")}
        let dnsKey="State:/Network/Service/"+service+"/DNS";let old=SCDynamicStoreCopyValue(dynamic,dnsKey as CFString) as? [String:Any];guard let dns=old?["ServerAddresses"] as? [String],!dns.isEmpty else{throw ProxyError("原系统 DNS 无法读取，未启用 TUN")}
        let v4=try routeInfo("default",ipv6:false),v6=try routeInfo("default",ipv6:true);guard let gw4=field("gateway",v4),let gw6=field("gateway",v6),field("interface",v4)==primary,field("interface",v6)==primary else{throw ProxyError("IPv4/IPv6 原路由不完整或不同接口，暂不支持启用 TUN")}
        var bypass=Set(dns+["1.1.1.1"]);for node in state.nodes{for address in try NetworkInspection.addresses(node.server){bypass.insert(address)}}
        let routesBefore=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
        let index=try (1...200).first{index in
            let v4="100.64.\(index).1",v6="fd71:717a:\(String(index,radix:16))::1"
            for address in [v4,v6]{let info=try routeInfo(address,ipv6:address.contains(":"));if let route=prefix(info),!route.hasSuffix("/0"),RuleEvaluator.matches(RoutingRule(kind:.cidr,value:route,action:.direct),host:address,ip:address)==true{return false}}
            return true
        };guard let index else{throw ProxyError("找不到无冲突虚拟网段")}
        let address4="100.64.\(index).1/30",address6="fd71:717a:\(String(index,radix:16))::1/126"
        let config=try TunConfigBuilder.build(state:state,credentials:memory,control:control,address4:address4,address6:address6,originalDNS:dns,bypass:bypass.map{$0+($0.contains(":") ? "/128":"/32")})
        let file=root.appendingPathComponent("runtime.json");try SecureFile.write(config,to:file)
        let check=Process();check.executableURL=root.appendingPathComponent("sing-box");check.arguments=["check","-c",file.path];check.standardOutput=FileHandle.nullDevice;check.standardError=FileHandle.nullDevice;try check.run();check.waitUntilExit();guard check.terminationStatus==0 else{try? FileManager.default.removeItem(at:file);throw ProxyError("固定核心校验 TUN 配置失败")}
        let expected:[String:Any]=["ServerAddresses":["100.64.\(index).1"],"SupplementalMatchDomains":[""],"SupplementalMatchDomainsNoSearch":1]
        journal=Journal(dnsKey:dnsKey,previousDNS:try old.map{try PropertyListSerialization.data(fromPropertyList:$0,format:.binary,options:0)},expectedDNS:try PropertyListSerialization.data(fromPropertyList:expected,format:.binary,options:0),address4:address4,address6:address6);try save()
        do {
            let interfacesBefore=try NetworkInspection.command("/sbin/ifconfig",["-l"]).split(separator:" ").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
            let core=Process();core.executableURL=root.appendingPathComponent("sing-box");core.arguments=["run","-c",file.path];core.standardOutput=FileHandle.nullDevice;core.standardError=FileHandle.nullDevice;core.terminationHandler={ [weak self,weak core] _ in self?.queue.async{guard let self,let core,self.process === core else{return};try? self.stop()}};process=core;owner=fd;try core.run();journal!.pid=core.processIdentifier;try save()
            var tunnel:String?
            for _ in 0..<100 {guard core.isRunning else{throw ProxyError("TUN 核心启动失败")};let interfaces=try NetworkInspection.command("/sbin/ifconfig",["-l"]).split(separator:" ").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)};let added=interfaces.filter{!interfacesBefore.contains($0) && $0.hasPrefix("utun")};if added.count==1 {let output=try NetworkInspection.command("/sbin/ifconfig",[added[0]]);if output.contains("100.64.\(index).1"){tunnel=added[0];break}};usleep(50000)}
            guard let tunnel else{throw ProxyError("TUN 接口归属校验失败")};journal!.interface=tunnel;try save()
            let directRules=state.rules.filter{($0.target == .direct || ($0.target==nil && $0.action == .direct)) && $0.kind == .cidr}.map(\.value)+state.remoteRules.filter{$0.target == .direct}.flatMap{$0.rules.filter{$0.kind == .cidr}.map(\.value)}
            let exclusions=["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","fc00::/7","fe80::/10"]+(state.mode == .rule ? directRules:[])+state.tunExcludedCIDRs+bypass.map{$0+($0.contains(":") ? "/128":"/32")}
            let existing=routesBefore.components(separatedBy:.newlines).compactMap{$0.split(whereSeparator:{$0.isWhitespace}).first.map(String.init)}
            for destination in Set(exclusions).sorted() {if existing.contains(destination) || existing.contains(String(destination.split(separator:"/")[0])){continue};let ipv6=destination.contains(":");try addRoute(destination,ipv6 ? gw6:gw4,primary,ipv6:ipv6)}
            for destination in ["0.0.0.0/1","128.0.0.0/1","::/1","8000::/1"]{try addRoute(destination,destination.contains(":") ? String(address6.split(separator:"/")[0]):String(address4.split(separator:"/")[0]),tunnel,ipv6:destination.contains(":"))}
            guard SCDynamicStoreSetValue(dynamic,dnsKey as CFString,expected as CFDictionary) else{throw ProxyError("TUN DNS 设置失败")}
            for destination in ["8.8.8.8","2606:4700:4700::1111"] {guard field("interface",try routeInfo(destination,ipv6:destination.contains(":")))==tunnel else{throw ProxyError("TUN 路由接管验证失败")}}
            guard let current=SCDynamicStoreCopyValue(dynamic,dnsKey as CFString) as? NSDictionary,current==expected as NSDictionary else{throw ProxyError("TUN DNS 生效验证失败")}
        }catch{let original=error;try stop();throw original}
    }
    func handle(_ request:TunRequest,fd:Int32)->TunReply {
        do {switch request.operation {case "status":
            if request.verifyNetwork==true,let record=journal,process?.isRunning==true {
                let tunnels=record.routes.filter{$0.interface==record.interface};let verified=tunnels.count==4 && tunnels.allSatisfy{route in guard let info=try? routeInfo(route.destination,ipv6:route.ipv6),let current=prefix(info) else{return false};return NetworkInspection.samePrefix(current,route.destination) && field("interface",info)==route.interface && field("gateway",info)==route.gateway}
                let current=SCDynamicStoreCopyValue(dynamic,record.dnsKey as CFString) as? NSDictionary;let expected=try PropertyListSerialization.propertyList(from:record.expectedDNS,format:nil) as! NSDictionary
                return TunReply(ok:true,message:HelperPaths.version,running:true,routesVerified:verified,dnsVerified:current==expected)
            }
            return TunReply(ok:true,message:HelperPaths.version+(journal != nil && process==nil ? " · 存在待恢复记录":""),running:process?.isRunning==true)
        case "start":try start(request,fd:fd);return TunReply(ok:true,message:"TUN 接口、路由及 DNS 已接管；HTTPS 另行检测",running:true)
        case "stop","recover":try stop();return TunReply(ok:true,message:"原网络已恢复")
        default:throw ProxyError("只允许状态、启动、停止、恢复操作")}}catch{return TunReply(ok:false,message:Redactor.redact(error.localizedDescription),running:process?.isRunning==true)}
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
