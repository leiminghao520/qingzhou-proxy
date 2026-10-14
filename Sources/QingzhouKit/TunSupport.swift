import Foundation
import Darwin
import SystemConfiguration

public struct TunRequest:Codable,Sendable {
    public var protocolVersion:Int? = 3
    public var systemProxyPort:Int?
    public var httpCompatibilityPort:Int?
    public var operation:String
    public var verifyNetwork:Bool?
    public var state:AppState?
    public var credentials:[String:String]?
    public var control:CoreControlContext?
    public init(operation:String,state:AppState?=nil,credentials:[String:String]?=nil,control:CoreControlContext?=nil,verifyNetwork:Bool=false,httpCompatibilityPort:Int?=nil,systemProxyPort:Int?=nil){self.systemProxyPort=systemProxyPort;self.httpCompatibilityPort=httpCompatibilityPort;self.verifyNetwork=verifyNetwork;self.operation=operation;self.state=state;self.credentials=credentials;self.control=control}
}
public struct TunReply:Codable,Sendable {public var proxyVerified:Bool?;public var protectionVerified:Bool?;public var protectionSummary:[String]?;public var phase:String?;public var dnsServer:String?;public var protocolVersion:Int? = 3;public var ok:Bool;public var message:String;public var running:Bool;public var routesVerified:Bool?;public var dnsVerified:Bool?;public init(ok:Bool,message:String,running:Bool=false,routesVerified:Bool?=nil,dnsVerified:Bool?=nil,dnsServer:String?=nil,proxyVerified:Bool?=nil,protectionVerified:Bool?=nil,protectionSummary:[String]?=nil,phase:String?=nil){self.proxyVerified=proxyVerified;self.protectionVerified=protectionVerified;self.protectionSummary=protectionSummary;self.phase=phase;self.dnsServer=dnsServer;self.routesVerified=routesVerified;self.dnsVerified=dnsVerified;self.ok=ok;self.message=message;self.running=running}}
public enum HelperPaths {
    public static let directory="/Library/PrivilegedHelperTools/cn.qingzhou.proxy"
    public static let socket=directory+"/control.sock"
    public static let version="0.6.0"
}
public enum UnixChannel {
    public static let maximum=4*1024*1024
    public static func send(_ data:Data,fd:Int32) throws {guard data.count<=maximum else{throw ProxyError("控制模型超过 4 MiB")};var length=UInt32(data.count).bigEndian;let prefix=Data(bytes:&length,count:4);for packet in [prefix,data]{try packet.withUnsafeBytes{buffer in var offset=0;while offset<packet.count{let count=Darwin.send(fd,buffer.baseAddress!.advanced(by:offset),packet.count-offset,0);guard count>0 else{throw ProxyError("辅助服务控制通道已中断")};offset+=count}}}}
    public static func receive(fd:Int32) throws -> Data {
        func read(_ size:Int) throws -> Data {var data=Data(count:size);try data.withUnsafeMutableBytes{buffer in var offset=0;while offset<size{let count=recv(fd,buffer.baseAddress!.advanced(by:offset),size-offset,0);guard count>0 else{throw ProxyError("辅助服务控制通道已中断")};offset+=count}};return data}
        let header=try read(4);let size=header.reduce(0){($0<<8)|Int($1)};guard size>0,size<=maximum else{throw ProxyError("控制消息大小无效")};return try read(size)
    }
    public static func address(_ path:String) throws -> sockaddr_un {var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size);let bytes=Array(path.utf8)+[0];guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw ProxyError("控制通道路径过长")};withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)};return address}
}
public actor PrivilegedServiceClient {
    private var fd:Int32 = -1
    public init(){}
    public func request(_ request:TunRequest) async throws -> TunReply {
        if fd<0 {let descriptor=socket(AF_UNIX,SOCK_STREAM,0);guard descriptor>=0 else{throw ProxyError("无法创建辅助服务控制通道")};var option:Int32=1;_ = setsockopt(descriptor,SOL_SOCKET,SO_NOSIGPIPE,&option,socklen_t(MemoryLayout<Int32>.size));var timeout=timeval(tv_sec:60,tv_usec:0);_ = setsockopt(descriptor,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));var address=try UnixChannel.address(HelperPaths.socket);let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(descriptor,$0,socklen_t(MemoryLayout<sockaddr_un>.size))==0}};guard connected else{close(descriptor);throw ProxyError("管理员辅助服务未安装或不可用，请先安装/修复")};fd=descriptor}
        do {try UnixChannel.send(JSONEncoder().encode(request),fd:fd);let reply=try JSONDecoder().decode(TunReply.self,from:UnixChannel.receive(fd:fd));if ["prepare","activate"].contains(request.operation),reply.protocolVersion != 3 {throw ProxyError("辅助服务协议过旧，请更新后再开启组合接管")}
        guard reply.ok else{throw ProxyError(reply.message)};return reply}catch{close(fd);fd = -1;throw error}
    }
    public func closeChannel(){if fd>=0{close(fd);fd = -1}}
}
public enum NetworkInspection {
    public static func command(_ path:String,_ arguments:[String]) throws -> String {let process=Process();let output=Pipe();process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments;process.standardOutput=output;process.standardError=FileHandle.nullDevice;try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();guard process.terminationStatus==0,let text=String(data:data,encoding:.utf8) else{throw ProxyError("网络状态无法可靠读取")};return text}
    public static func conflicts(vpn:String,routes:String,proxies:[String:Any])->String? {
        let activeVPN=vpn.components(separatedBy:.newlines).contains(where:{$0.contains("(Connected)") || $0.contains("(Connecting)")})
        let rows=routes.components(separatedBy:.newlines).map{$0.split(whereSeparator:{$0.isWhitespace}).map(String.init)}
        if activeVPN && rows.allSatisfy({$0.count<4}) {return "活动 VPN 的路由无法确认，未启用 TUN"}
        // 保留企业 VPN 的具体网段和系统链路本地隧道；只阻止公网接管重叠。
        for row in rows where row.count>=4 {
            guard row.dropFirst(2).contains(where:{$0.hasPrefix("utun") || $0.hasPrefix("ppp") || $0.hasPrefix("ipsec")}) else{continue}
            let destination=row[0],gateway=row[1],flags=row[2]
            if destination.hasPrefix("fe80") || destination.hasPrefix("ff") || destination=="::1" {continue}
            // macOS 为系统隧道保留的接口限定默认项不会接管普通公网连接。
            if destination=="default" {
                if flags.contains("I") && gateway.hasPrefix("fe80:"){continue}
                return "另一个隧道正在接管默认路由，未启用 TUN"
            }
            let parts=destination.split(separator:"/",omittingEmptySubsequences:false)
            if destination.contains(":") {
                if let last=parts.last,let bits=Int(last),bits<=3 {return "另一个隧道正在接管 IPv6 公网大网段，未启用 TUN"}
            } else {
                let octets=parts[0].split(separator:".")
                guard octets.allSatisfy({Int($0).map{(0...255).contains($0)} ?? false}) else{continue}
                let bits=parts.count==2 ? Int(parts[1]):flags.contains("H") ? 32:octets.count*8
                let first=Int(octets[0])
                if let bits,bits<=8,first != 10,first != 127 {return "另一个隧道正在接管 IPv4 公网大网段，未启用 TUN"}
            }
        }
        for key in ["HTTPEnable","HTTPSEnable","SOCKSEnable","ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable"] where (proxies[key] as? NSNumber)?.boolValue==true{return "检测到其他软件或已有系统代理，请先恢复后启用 TUN"};return nil
    }
    public static func routePrefix(destination:String?,mask:String?,host:Bool=false)->String? {
        guard let rawDestination=destination else{return nil};
        // 零起点分流路由也可能显示为 default，必须结合掩码区分 /1 和 /0。
        guard rawDestination != "default" || !host else{return nil}
        let destination=rawDestination == "default" ? (mask?.contains(":")==true ? "::":"0.0.0.0"):rawDestination
        var bytes=[UInt8](repeating:0,count:16);let family=destination.withCString{inet_pton(AF_INET,$0,&bytes)==1 ? AF_INET:inet_pton(AF_INET6,$0,&bytes)==1 ? AF_INET6:0};guard family != 0 else{return nil}
        if host{return destination+"/"+(family==AF_INET ? "32":"128")}
        guard let mask,mask.withCString({inet_pton(family,$0,&bytes)})==1 else{return nil};let count=family==AF_INET ? 4:16;var bits=0,zero=false
        for byte in bytes.prefix(count){for i in (0..<8).reversed(){if byte&(1<<i) != 0{if zero{return nil};bits+=1}else{zero=true}}};return destination+"/\(bits)"
    }
    // 全局路由和限定路由可以拥有同一前缀；查询返回另一作用域时不能视为本次所有权。
    public static func routeScopeMatches(_ scope:String?,flags:String?,interface:String?)->Bool {
        guard let flags else{return false}
        if let scope {return flags.contains("IFSCOPE") && interface==scope}
        return !flags.contains("IFSCOPE")
    }
    public enum RouteOperation:String {case get,add,delete}
    // 限定网卡的查询、添加和恢复必须使用相同作用域，避免误处理全局接管路由。
    public static func routeArguments(_ operation:RouteOperation,destination:String,gateway:String?=nil,ipv6:Bool=false,scope:String?=nil)->[String] {
        var args=["-n",operation.rawValue]+(ipv6 ? ["-inet6"]:[])
        if let scope {args += ["-ifscope",scope]}
        if operation != .get {args.append("-net")}
        args.append(destination)
        if let gateway {args.append(gateway)}
        return args
    }
    // 使用独立的补充 DNS 服务，避免修改 DHCP 持有的物理服务状态后被系统刷新覆盖。
    public static func tunDNSKey(_ session:UUID)->String {"State:/Network/Service/Qingzhou-TUN-"+session.uuidString+"/DNS"}
    public static func samePrefix(_ a:String,_ b:String)->Bool {let left=a.split(separator:"/"),right=b.split(separator:"/");guard left.count==2,right.count==2,left[1]==right[1] else{return false};return RuleEvaluator.matches(RoutingRule(kind:.cidr,value:a,action:.direct),host:String(right[0]),ip:String(right[0]))==true && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:b,action:.direct),host:String(left[0]),ip:String(left[0]))==true}
    public static func checkConflicts(ownedTunnel:String?=nil) throws {let vpn=try command("/usr/sbin/scutil",["--nc","list"]);let rawRoutes=try command("/usr/sbin/netstat",["-rn"])
        let routes=rawRoutes.components(separatedBy:.newlines).filter{row in guard let ownedTunnel else{return true};return !row.split(whereSeparator:{$0.isWhitespace}).contains(Substring(ownedTunnel))}.joined(separator:"\n");guard let proxies=SCDynamicStoreCopyProxies(nil) as? [String:Any] else{throw ProxyError("不能可靠判断系统代理状态，未启用 TUN")};if let reason=conflicts(vpn:vpn,routes:routes,proxies:proxies){throw ProxyError(reason)}}
    public static func validatePreparation(interface:String,gateway:String,currentInterface:String?,currentGateway:String?,vpn:String,routes:String,proxies:[String:Any]) throws {
        guard currentInterface==interface,currentGateway==gateway else{throw ProxyError("准备期间默认网络已变化，未接管网络")}
        if let reason=conflicts(vpn:vpn,routes:routes,proxies:proxies){throw ProxyError("准备期间网络接管状态已变化："+reason)}
    }
    public static func boundedAddresses(_ host:String,timeout:TimeInterval=3,resolver:@escaping @Sendable (String) throws -> [String]=NetworkInspection.addresses) throws -> [String] {
        guard timeout>0,timeout<=10 else{throw ProxyError("DNS 等待预算无效")}
        let result=AddressResolutionResult(),completed=DispatchSemaphore(value:0)
        // 解析只读取网络状态；超时后不能继续执行任何接管步骤。
        DispatchQueue.global().async {result.set(Result{try resolver(host)});completed.signal()}
        guard completed.wait(timeout:.now()+timeout) == .success else{throw ProxyError("节点引导 DNS 解析超时，未接管网络")}
        return try result.get().get()
    }
    public static func addresses(_ host:String) throws -> [String] {var head:UnsafeMutablePointer<addrinfo>?;var hints=addrinfo();hints.ai_socktype=SOCK_STREAM;guard getaddrinfo(host,nil,&hints,&head)==0,let first=head else{throw ProxyError("节点或引导 DNS 无法解析，未启用 TUN")};defer{freeaddrinfo(first)};var cursor:UnsafeMutablePointer<addrinfo>?=first;var values=Set<String>();while let item=cursor{var buffer=[CChar](repeating:0,count:Int(NI_MAXHOST));if getnameinfo(item.pointee.ai_addr,item.pointee.ai_addrlen,&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST)==0{values.insert(String(cString:buffer))};cursor=item.pointee.ai_next};guard !values.isEmpty,values.count<=32 else{throw ProxyError("节点 DNS 地址数量无效")};return values.sorted()}
}
public enum TunConfigBuilder {
    public static func build(state:AppState,credentials:CredentialStore,control:CoreControlContext,address4:String,address6:String,originalDNS:[String],bypass:[String],httpCompatibilityPort:Int?=nil,plan:CapturePlan?=nil,dnsForwardPort:Int?=nil,nodeInterfaces:[String:String]=[:]) throws -> Data {
        try PolicyValidator.validate(state);guard !state.nodes.isEmpty,!originalDNS.isEmpty,originalDNS.count<=16 else{throw ProxyError("TUN 需要节点和可读取的原系统 DNS")}
        for value in [address4,address6]+bypass{try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:value,action:.direct))}
        // 权限服务只接受受限节点模型；利用分享链接往返校验阻止未支持字段进入核心。
        for node in state.nodes{let parsed=try NodeParser.parse(NodeShare.link(node,credentials:credentials));guard parsed.node.fingerprint==node.fingerprint else{throw ProxyError("节点模型参数无效")}}
        let base=try ConfigBuilder.build(state:state,credentials:credentials,control:control,httpCompatibilityPort:httpCompatibilityPort);var object=try JSONSerialization.jsonObject(with:base) as! [String:Any]
        var inbounds=object["inbounds"] as! [[String:Any]]
        // 路由和 DNS 由辅助服务按所有权记录管理，核心不替换现有路由。
        inbounds.append(["type":"tun","tag":"tun-in","address":[address4,address6],"mtu":1500,"stack":"gvisor","auto_route":false,"dns_mode":"disabled"]);object["inbounds"]=inbounds
        var route=object["route"] as! [String:Any];route["auto_detect_interface"]=true;var rules=route["rules"] as! [[String:Any]];rules.insert(["protocol":"dns","action":"hijack-dns"],at:0);rules.insert(["inbound":"tun-in","action":"sniff"],at:0);route["rules"]=rules;object["route"]=route
        for resolver in originalDNS {try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:resolver,action:.direct))}
        NetworkPolicy.apply(&object,state:state,originalDNS:originalDNS)
        if let plan,let dnsForwardPort {CaptureConfiguration.apply(&object,state:state,plan:plan,dnsForwardPort:dnsForwardPort,nodeInterfaces:nodeInterfaces)}
        return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
    }
}

private final class AddressResolutionResult:@unchecked Sendable {
    private let lock=NSLock()
    private var value:Result<[String],Error>?
    func set(_ value:Result<[String],Error>){lock.lock();self.value=value;lock.unlock()}
    func get()->Result<[String],Error>{lock.lock();defer{lock.unlock()};return value ?? .failure(ProxyError("DNS 解析结果缺失"))}
}
