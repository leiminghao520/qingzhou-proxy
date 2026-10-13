import Foundation
import Darwin
import SystemConfiguration

public struct TunRequest:Codable,Sendable {
    public var operation:String
    public var verifyNetwork:Bool?
    public var state:AppState?
    public var credentials:[String:String]?
    public var control:CoreControlContext?
    public init(operation:String,state:AppState?=nil,credentials:[String:String]?=nil,control:CoreControlContext?=nil,verifyNetwork:Bool=false){self.verifyNetwork=verifyNetwork;self.operation=operation;self.state=state;self.credentials=credentials;self.control=control}
}
public struct TunReply:Codable,Sendable {public var ok:Bool;public var message:String;public var running:Bool;public var routesVerified:Bool?;public var dnsVerified:Bool?;public init(ok:Bool,message:String,running:Bool=false,routesVerified:Bool?=nil,dnsVerified:Bool?=nil){self.routesVerified=routesVerified;self.dnsVerified=dnsVerified;self.ok=ok;self.message=message;self.running=running}}
public enum HelperPaths {
    public static let directory="/Library/PrivilegedHelperTools/cn.qingzhou.proxy"
    public static let socket=directory+"/control.sock"
    public static let version="0.3.0"
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
        if fd<0 {let descriptor=socket(AF_UNIX,SOCK_STREAM,0);guard descriptor>=0 else{throw ProxyError("无法创建辅助服务控制通道")};var option:Int32=1;_ = setsockopt(descriptor,SOL_SOCKET,SO_NOSIGPIPE,&option,socklen_t(MemoryLayout<Int32>.size));var timeout=timeval(tv_sec:20,tv_usec:0);_ = setsockopt(descriptor,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));var address=try UnixChannel.address(HelperPaths.socket);let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(descriptor,$0,socklen_t(MemoryLayout<sockaddr_un>.size))==0}};guard connected else{close(descriptor);throw ProxyError("管理员辅助服务未安装或不可用，请先安装/修复")};fd=descriptor}
        do {try UnixChannel.send(JSONEncoder().encode(request),fd:fd);let reply=try JSONDecoder().decode(TunReply.self,from:UnixChannel.receive(fd:fd));guard reply.ok else{throw ProxyError(reply.message)};return reply}catch{close(fd);fd = -1;throw error}
    }
    public func closeChannel(){if fd>=0{close(fd);fd = -1}}
}
public enum NetworkInspection {
    public static func command(_ path:String,_ arguments:[String]) throws -> String {let process=Process();let output=Pipe();process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments;process.standardOutput=output;process.standardError=FileHandle.nullDevice;try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();guard process.terminationStatus==0,let text=String(data:data,encoding:.utf8) else{throw ProxyError("网络状态无法可靠读取")};return text}
    public static func conflicts(vpn:String,routes:String,proxies:[String:Any])->String? {
        if vpn.components(separatedBy:.newlines).contains(where:{$0.contains("(Connected)") || $0.contains("(Connecting)")}){return "检测到活动 VPN，未启用 TUN"}
        let rows=routes.components(separatedBy:.newlines).map{$0.split(whereSeparator:{$0.isWhitespace}).map(String.init)}
        if rows.contains(where:{$0.count>=4 && $0.dropFirst(2).contains(where:{$0.hasPrefix("utun") || $0.hasPrefix("ppp") || $0.hasPrefix("ipsec")}) && !($0[0].hasPrefix("fe80") || $0[0].hasPrefix("ff") || $0[0]=="::1")}){return "存在其他隧道路由，归属无法可靠判断，未启用 TUN"}
        for key in ["HTTPEnable","HTTPSEnable","SOCKSEnable","ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable"] where (proxies[key] as? NSNumber)?.boolValue==true{return "检测到其他软件或已有系统代理，请先恢复后启用 TUN"};return nil
    }
    public static func routePrefix(destination:String?,mask:String?,host:Bool=false)->String? {
        guard let destination,destination != "default" else{return nil};var bytes=[UInt8](repeating:0,count:16);let family=destination.withCString{inet_pton(AF_INET,$0,&bytes)==1 ? AF_INET:inet_pton(AF_INET6,$0,&bytes)==1 ? AF_INET6:0};guard family != 0 else{return nil}
        if host{return destination+"/"+(family==AF_INET ? "32":"128")}
        guard let mask,mask.withCString({inet_pton(family,$0,&bytes)})==1 else{return nil};let count=family==AF_INET ? 4:16;var bits=0,zero=false
        for byte in bytes.prefix(count){for i in (0..<8).reversed(){if byte&(1<<i) != 0{if zero{return nil};bits+=1}else{zero=true}}};return destination+"/\(bits)"
    }
    public static func samePrefix(_ a:String,_ b:String)->Bool {let left=a.split(separator:"/"),right=b.split(separator:"/");guard left.count==2,right.count==2,left[1]==right[1] else{return false};return RuleEvaluator.matches(RoutingRule(kind:.cidr,value:a,action:.direct),host:String(right[0]),ip:String(right[0]))==true && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:b,action:.direct),host:String(left[0]),ip:String(left[0]))==true}
    public static func checkConflicts() throws {let vpn=try command("/usr/sbin/scutil",["--nc","list"]);let routes=try command("/usr/sbin/netstat",["-rn"]);guard let proxies=SCDynamicStoreCopyProxies(nil) as? [String:Any] else{throw ProxyError("不能可靠判断系统代理状态，未启用 TUN")};if let reason=conflicts(vpn:vpn,routes:routes,proxies:proxies){throw ProxyError(reason)}}
    public static func addresses(_ host:String) throws -> [String] {var head:UnsafeMutablePointer<addrinfo>?;var hints=addrinfo();hints.ai_socktype=SOCK_STREAM;guard getaddrinfo(host,nil,&hints,&head)==0,let first=head else{throw ProxyError("节点或引导 DNS 无法解析，未启用 TUN")};defer{freeaddrinfo(first)};var cursor:UnsafeMutablePointer<addrinfo>?=first;var values=Set<String>();while let item=cursor{var buffer=[CChar](repeating:0,count:Int(NI_MAXHOST));if getnameinfo(item.pointee.ai_addr,item.pointee.ai_addrlen,&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST)==0{values.insert(String(cString:buffer))};cursor=item.pointee.ai_next};guard !values.isEmpty,values.count<=32 else{throw ProxyError("节点 DNS 地址数量无效")};return values.sorted()}
}
public enum TunConfigBuilder {
    public static func build(state:AppState,credentials:CredentialStore,control:CoreControlContext,address4:String,address6:String,originalDNS:[String],bypass:[String]) throws -> Data {
        try PolicyValidator.validate(state);guard !state.nodes.isEmpty,!originalDNS.isEmpty,originalDNS.count<=16 else{throw ProxyError("TUN 需要节点和可读取的原系统 DNS")}
        for value in [address4,address6]+bypass{try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:value,action:.direct))}
        // 权限服务只接受受限节点模型；利用分享链接往返校验阻止未支持字段进入核心。
        for node in state.nodes{let parsed=try NodeParser.parse(NodeShare.link(node,credentials:credentials));guard parsed.node.fingerprint==node.fingerprint else{throw ProxyError("节点模型参数无效")}}
        let base=try ConfigBuilder.build(state:state,credentials:credentials,control:control);var object=try JSONSerialization.jsonObject(with:base) as! [String:Any]
        var inbounds=object["inbounds"] as! [[String:Any]]
        // 路由和 DNS 由辅助服务按所有权记录管理，核心不替换现有路由。
        inbounds.append(["type":"tun","tag":"tun-in","address":[address4,address6],"mtu":1500,"stack":"gvisor","auto_route":false,"dns_mode":"disabled"]);object["inbounds"]=inbounds
        var route=object["route"] as! [String:Any];route["auto_detect_interface"]=true;var rules=route["rules"] as! [[String:Any]];rules.insert(["protocol":"dns","action":"hijack-dns"],at:0);rules.insert(["inbound":"tun-in","action":"sniff"],at:0);route["rules"]=rules;object["route"]=route
        let resolver=originalDNS[0];try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:resolver,action:.direct))
        var dns:[String:Any]=["servers":[["type":"udp","tag":"local","server":resolver,"detour":"direct"],["type":"https","tag":"remote","server":"1.1.1.1","path":"/dns-query","tls":["enabled":true,"server_name":"cloudflare-dns.com"],"detour":"proxy"]],"final":state.dnsPreference == .httpsProxy ? "remote":"local"]
        var dnsRules:[[String:Any]]=[]
        for node in state.nodes{dnsRules.append(["domain":[node.server],"action":"route","server":"local"])}
        dnsRules.append(["domain":["localhost"],"action":"route","server":"local"])
        if state.mode == .rule {
            let rows=state.rules.map{($0,nil as PolicyReference?)}+state.remoteRules.flatMap{source in source.rules.map{($0,source.target as PolicyReference?)}}
            for (rule,override) in rows where rule.kind != .cidr {let target=override ?? rule.target ?? (rule.action == .direct ? .direct:rule.action == .reject ? .reject:.selected);var condition=RuleEvaluator.condition(rule);condition["action"]="route";condition["server"]=target == .direct || state.dnsPreference == .system ? "local":"remote";dnsRules.append(condition)}
        }
        if state.mode == .direct{dns["final"]="local"}
        dns["rules"]=dnsRules;object["dns"]=dns
        return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
    }
}
