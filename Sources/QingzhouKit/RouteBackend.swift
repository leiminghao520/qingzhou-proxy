import Foundation
import Darwin
import CQingzhouRoute

public struct RouteRecord:Equatable,Sendable {
    public var route:ProtectedRoute
    public var flags:UInt32
    public var linkLayerAddress:String?
    public init(route:ProtectedRoute,flags:UInt32,linkLayerAddress:String?=nil) {self.route=route;self.flags=flags;self.linkLayerAddress=linkLayerAddress}
    public var isTransient:Bool {flags & UInt32(RTF_WASCLONED|RTF_LLINFO) != 0}
    public var queryText:String {
        let parts=route.destination.split(separator:"/")
        let bits=Int(parts.last ?? "0") ?? 0
        let address=String(parts[0])
        let names:[(Int32,String)]=[(RTF_UP,"UP"),(RTF_GATEWAY,"GATEWAY"),(RTF_HOST,"HOST"),(RTF_STATIC,"STATIC"),(RTF_IFSCOPE,"IFSCOPE")]
        let mask=IPPrefix(route.destination)?.maskAddress ?? (route.ipv6 ? "::":"0.0.0.0")
        return "destination: \(bits==0 && (address=="0.0.0.0" || address=="::") ? "default":address)\nmask: \(mask)\ngateway: \(route.gateway)\ninterface: \(route.interface)\nflags: <\(names.filter{flags & UInt32($0.0) != 0}.map{$0.1}.joined(separator:","))>"
    }
    public var tableLine:String {
        let names:[(Int32,String)]=[(RTF_UP,"U"),(RTF_GATEWAY,"G"),(RTF_HOST,"H"),(RTF_STATIC,"S"),(RTF_IFSCOPE,"I"),(RTF_WASCLONED,"W"),(RTF_LLINFO,"L")]
        let destination=["0.0.0.0/0","::/0"].contains(route.destination) ? "default":route.destination
        return destination+" "+route.gateway+" "+names.filter{flags & UInt32($0.0) != 0}.map{$0.1}.joined()+" "+route.interface
    }
}
public enum RouteWriteResult:Equatable,Sendable {case applied,rejected(Int32)}
public struct RouteBackendError:Error,LocalizedError,Sendable {
    public let code:Int32
    public let outcomeUnknown:Bool
    public init(_ code:Int32,outcomeUnknown:Bool=false) {self.code=code;self.outcomeUnknown=outcomeUnknown}
    public var errorDescription:String? {"原生路由操作失败（\(code)：\(String(cString:strerror(code)))）；"+(outcomeUnknown ? "写入结果未知，保留恢复记录":"未确认提交")}
}
public protocol RouteBackend:AnyObject {
    func delete(_ record:RouteRecord,deadline:Date?) throws -> RouteWriteResult
    func snapshot() throws -> NetworkRouteSample
    func lookup(_ destination:String,ipv6:Bool,scope:String?,deadline:Date?) throws -> RouteRecord
    func write(_ operation:NetworkInspection.RouteOperation,route:ProtectedRoute,legacy:Bool,deadline:Date?) throws -> RouteWriteResult
}
public extension RouteBackend {
    func delete(_ record:RouteRecord,deadline:Date?) throws -> RouteWriteResult {try write(.delete,route:record.route,legacy:false,deadline:deadline)}
}
public struct RouteExchangeResult {
    public var reply:Data
    public var kernelError:Int32
    public init(reply:Data,kernelError:Int32=0){self.reply=reply;self.kernelError=kernelError}
}
// 注入报文交换与整表采样，隔离检查不会执行内核写入。
public protocol RouteTransport:AnyObject {
    func dump() throws -> Data
    func exchange(_ request:Data,timeout:TimeInterval,cancelled:()->Bool) throws -> RouteExchangeResult
}
private final class CancellationBox {let body:()->Bool;init(_ body:@escaping ()->Bool){self.body=body}}
public final class DarwinRouteTransport:RouteTransport {
    public init() {}
    public func dump() throws -> Data {
        var bytes:UnsafeMutableRawPointer?,size=0
        let error=qz_route_dump(&bytes,&size)
        guard error==0,let bytes else {throw RouteBackendError(error)}
        defer{qz_route_free(bytes)}
        return Data(bytes:bytes,count:size)
    }
    public func exchange(_ request:Data,timeout:TimeInterval,cancelled:()->Bool) throws -> RouteExchangeResult {
        try withoutActuallyEscaping(cancelled) {body in
            let box=CancellationBox(body)
            var output=Data(count:65536),length=0,submitted:Int32=0,kernel:Int32=0
            let error=request.withUnsafeBytes {input in output.withUnsafeMutableBytes {buffer in
                qz_route_exchange(input.baseAddress,input.count,timeout,{context in
                    guard let context else{return 1}
                    return Unmanaged<CancellationBox>.fromOpaque(context).takeUnretainedValue().body() ? 1:0
                },Unmanaged.passUnretained(box).toOpaque(),buffer.baseAddress,buffer.count,&length,&submitted,&kernel)
            }}
            guard error==0 else {throw RouteBackendError(error,outcomeUnknown:submitted != 0)}
            output.count=length;return RouteExchangeResult(reply:output,kernelError:kernel)
        }
    }
}
public final class NativeRouteBackend:RouteBackend {
    private let transport:RouteTransport
    private let lock=NSLock()
    private static let sequenceLock=NSLock()
    private static var sequence:Int32=0
    private static func nextSequence()->Int32 {
        sequenceLock.lock();defer{sequenceLock.unlock()}
        sequence = sequence == Int32.max ? 1:sequence+1
        return sequence
    }
    public var metrics:RouteOperationMetrics?
    public var cancelled:()->Bool={false}
    public init(transport:RouteTransport=DarwinRouteTransport()) {self.transport=transport}
    public static func decode(_ data:Data) throws -> [RouteRecord] {
        var count=0
        var error=data.withUnsafeBytes{qz_route_decode($0.baseAddress,$0.count,nil,0,&count)}
        guard error==0 else {throw RouteBackendError(error)}
        var rows=[QZRouteRow](repeating:QZRouteRow(),count:count)
        error=data.withUnsafeBytes{bytes in rows.withUnsafeMutableBufferPointer{qz_route_decode(bytes.baseAddress,bytes.count,$0.baseAddress,$0.count,&count)}}
        guard error==0 else {throw RouteBackendError(error)}
        return rows.prefix(count).map {value in
            var value=value
            let destination=withUnsafePointer(to:&value.destination){$0.withMemoryRebound(to:CChar.self,capacity:64){String(cString:$0)}}
            let gateway=withUnsafePointer(to:&value.gateway){$0.withMemoryRebound(to:CChar.self,capacity:64){String(cString:$0)}}
            let link=withUnsafePointer(to:&value.link_layer_address){$0.withMemoryRebound(to:CChar.self,capacity:64){String(cString:$0)}}
            let interface=withUnsafePointer(to:&value.interface_name){$0.withMemoryRebound(to:CChar.self,capacity:32){String(cString:$0)}}
            return RouteRecord(route:ProtectedRoute(destination:destination+"/\(value.prefix_length)",gateway:gateway,interface:interface,scope:value.flags & UInt32(RTF_IFSCOPE) != 0 ? interface:nil),flags:value.flags,linkLayerAddress:link.isEmpty ? nil:link)
        }
    }
    public func snapshot() throws -> NetworkRouteSample {
        lock.lock();defer{lock.unlock()}
        guard !cancelled() else {throw CancellationError()}
        let data:Data
        if let metrics {data=try metrics.measure("routeDump") {try transport.dump()}}
        else {data=try transport.dump()}
        let rows: [RouteRecord]
        if let metrics {rows=try metrics.measure("routeDecode") {try Self.decode(data)}}
        else {rows=try Self.decode(data)}
        guard !cancelled() else {throw CancellationError()}
        if let metrics {return metrics.measure("routeSampleBuild") {NetworkRouteSample(records:rows,metrics:metrics)}}
        return NetworkRouteSample(records:rows)
    }
    private func encoded(_ operation:Int32,destination:String,ipv6:Bool,bits:Int,gateway:String,interface:String,scoped:Bool,legacy:Bool,pid:Int32,sequence:Int32,hostOverride:Bool?=nil) throws -> Data {
        var packet=Data(count:2048),size=0
        let error=packet.withUnsafeMutableBytes {buffer in
            if let hostOverride,operation==RTM_DELETE {
                return qz_route_encode_delete(destination,ipv6 ? AF_INET6:AF_INET,Int32(bits),gateway,interface,scoped ? 1:0,hostOverride ? 1:0,pid,sequence,buffer.baseAddress,buffer.count,&size)
            }
            return qz_route_encode(operation,destination,ipv6 ? AF_INET6:AF_INET,Int32(bits),gateway,interface,scoped ? 1:0,legacy ? 1:0,pid,sequence,buffer.baseAddress,buffer.count,&size)
        }
        guard error==0 else {throw RouteBackendError(error)}
        packet.count=size;return packet
    }
    // 全批次只做编码和独立结构校验，不打开路由 socket，也不通过试写探测参数。
    public func validateWrites(_ routes:[ProtectedRoute]) throws {
        lock.lock();defer{lock.unlock()}
        for (ordinal,route) in routes.enumerated() {
            guard !cancelled() else {throw CancellationError()}
            guard route.scope==nil || route.scope==route.interface,let prefix=IPPrefix(route.destination) else {throw RouteBackendError(EINVAL)}
            do {_=try encoded(RTM_ADD,destination:prefix.address,ipv6:route.ipv6,bits:prefix.bits,gateway:route.gateway,interface:route.interface,scoped:route.scope != nil,legacy:false,pid:getpid(),sequence:1)}
            catch {throw ProxyError("路由整批编码预检第 \(ordinal+1) 项失败（\(route.ipv6 ? "IPv6":"IPv4") /\(prefix.bits)，\(route.scope==nil ? "全局":"作用域")）；未发送路由请求："+error.localizedDescription)}
        }
    }
    private func exchange(_ operation:Int32,destination:String,ipv6:Bool,bits:Int,gateway:String,interface:String,scoped:Bool,legacy:Bool,deadline:Date?,hostOverride:Bool?=nil) throws -> RouteExchangeResult {
        guard !cancelled() else {throw CancellationError()}
        let budget=NetworkCommandBudget(deadline:deadline,uptime:ProcessInfo.processInfo.systemUptime)
        let seq=Self.nextSequence(),pid=getpid()
        let packet=try encoded(operation,destination:destination,ipv6:ipv6,bits:bits,gateway:gateway,interface:interface,scoped:scoped,legacy:legacy,pid:pid,sequence:seq,hostOverride:hostOverride)
        let remaining=budget.remaining(wallTime:Date(),uptime:ProcessInfo.processInfo.systemUptime)
        guard remaining>0 else {throw RouteBackendError(ETIMEDOUT)}
        let result=try transport.exchange(packet,timeout:remaining,cancelled:cancelled)
        var kernel:Int32=0
        let matched=result.reply.withUnsafeBytes{qz_route_match($0.baseAddress,$0.count,operation,pid,seq,&kernel)}
        guard matched==1,kernel==result.kernelError else {throw RouteBackendError(EPROTO,outcomeUnknown:operation != RTM_GET)}
        return result
    }
    public func lookup(_ destination:String,ipv6:Bool,scope:String?=nil,deadline:Date?=nil) throws -> RouteRecord {
        lock.lock();defer{lock.unlock()}
        let address=destination=="default" ? (ipv6 ? "::":"0.0.0.0"):String(destination.split(separator:"/")[0])
        let result=try exchange(RTM_GET,destination:address,ipv6:ipv6,bits:destination=="default" ? 0:(ipv6 ? 128:32),gateway:"",interface:scope ?? "",scoped:scope != nil,legacy:false,deadline:deadline)
        guard result.kernelError==0 else {throw RouteBackendError(result.kernelError)}
        guard let route=try Self.decode(result.reply).first else {throw RouteBackendError(EPROTO)}
        return route
    }
    public func delete(_ record:RouteRecord,deadline:Date?=nil) throws -> RouteWriteResult {
        try write(.delete,route:record.route,legacy:false,deadline:deadline,hostOverride:record.flags & UInt32(RTF_HOST) != 0)
    }
    public func write(_ operation:NetworkInspection.RouteOperation,route:ProtectedRoute,legacy:Bool=false,deadline:Date?=nil) throws -> RouteWriteResult {
        try write(operation,route:route,legacy:legacy,deadline:deadline,hostOverride:nil)
    }
    private func write(_ operation:NetworkInspection.RouteOperation,route:ProtectedRoute,legacy:Bool,deadline:Date?,hostOverride:Bool?) throws -> RouteWriteResult {
        lock.lock();defer{lock.unlock()}
        guard operation != .get,route.scope==nil || route.scope==route.interface,let prefix=IPPrefix(route.destination) else {throw RouteBackendError(EINVAL)}
        let address=legacy ? String(route.destination.split(separator:"/")[0]):prefix.address
        do {
            let result=try exchange(operation == .add ? RTM_ADD:RTM_DELETE,destination:address,ipv6:route.ipv6,bits:prefix.bits,gateway:route.gateway,interface:route.interface,scoped:route.scope != nil,legacy:legacy,deadline:deadline,hostOverride:hostOverride)
            return result.kernelError==0 ? .applied:.rejected(result.kernelError)
        } catch let error as RouteBackendError where !error.outcomeUnknown && [EEXIST,ESRCH,EPERM,EACCES,ENETUNREACH,EHOSTUNREACH].contains(error.code) {
            return .rejected(error.code)
        }
    }
}
// 兼容原有辅助服务调用边界，内部仍通过结构化后端操作，不拼接或执行命令。
public enum RouteBackendAdapter {
    public static func write(_ arguments:[String],backend:RouteBackend,deadline:Date?,interfaceHint:String?=nil) throws -> String {
        guard let op=arguments.first(where:{["add","delete"].contains($0)}),let operation=NetworkInspection.RouteOperation(rawValue:op) else {throw RouteBackendError(EINVAL)}
        var scope:String?,interface:String?=interfaceHint,destination:String?,gateway:String?,bits:Int?,net=false
        var index=0
        while index<arguments.count {
            let value=arguments[index]
            if ["-ifscope","-interface","-prefixlen"].contains(value) {
                index+=1;guard index<arguments.count else {throw RouteBackendError(EINVAL)}
                if value=="-ifscope"{scope=arguments[index]}else if value=="-interface"{interface=arguments[index]}else{bits=Int(arguments[index])}
            } else if value=="-net" {net=true}
            else if !value.hasPrefix("-") && !["add","delete"].contains(value) {
                if destination==nil {destination=value}else if gateway==nil {gateway=value}else {throw RouteBackendError(EINVAL)}
            } else if !["-n","-inet6","-host","add","delete"].contains(value) {throw RouteBackendError(EINVAL)}
            index+=1
        }
        guard var destination else {throw RouteBackendError(EINVAL)}
        let ipv6=arguments.contains("-inet6")
        if !destination.contains("/"){destination += "/\(bits ?? (ipv6 ? 128:32))"}
        if let gateway,gateway.hasPrefix("link#"),let number=UInt32(gateway.dropFirst(5)) {
            var name=[CChar](repeating:0,count:Int(IF_NAMESIZE));guard if_indextoname(number,&name) != nil else {throw RouteBackendError(ENXIO)};interface=String(cString:name)
        }
        if let scope {interface=scope}
        // 数值网关的全局路由也需要记录对应接口，查询只用于补齐旧调用边界。
        if interface==nil,let gateway {interface=try backend.lookup(gateway,ipv6:ipv6,scope:nil,deadline:deadline).route.interface}
        guard let interface else {throw RouteBackendError(EINVAL)}
        let link="link#"+String(if_nametoindex(interface))
        let route=ProtectedRoute(destination:destination,gateway:gateway ?? link,interface:interface,scope:scope)
        let result=try backend.write(operation,route:route,legacy:net && ipv6 && destination.hasSuffix("/128"),deadline:deadline)
        switch result {case .applied:return "";case .rejected(let code):return "writing to routing socket: "+String(cString:strerror(code))}
    }
}
public enum NativeInterfaces {
    public static func addresses() throws -> [String:Set<String>] {
        var bytes:UnsafeMutablePointer<CChar>?,count=0
        let error=qz_interface_addresses(&bytes,&count)
        guard error==0,let bytes else {throw RouteBackendError(error)}
        defer {qz_route_free(bytes)}
        var result:[String:Set<String>]=[:]
        for line in String(decoding:UnsafeRawBufferPointer(start:bytes,count:count),as:UTF8.self).split(separator:"\n") {
            let parts=line.split(separator:" ");if parts.count==2 {result[String(parts[0]),default:[]].insert(String(parts[1]))}
        }
        return result
    }
}

// 仅用于隔离对照或整包回退；一次事务在创建服务时固定一个后端。
public final class LegacyRouteBackend:RouteBackend {
    public typealias Command=(String,[String],Date?) throws -> String
    private let command:Command
    public init(command:@escaping Command={try NetworkInspection.command($0,$1,deadline:$2)}) {self.command=command}
    public func snapshot() throws -> NetworkRouteSample {try NetworkRouteSample(read:{try command("/usr/sbin/netstat",["-rn"],nil)})}
    public func lookup(_ destination:String,ipv6:Bool,scope:String?,deadline:Date?) throws -> RouteRecord {
        let info=try command("/sbin/route",NetworkInspection.routeArguments(.get,destination:destination,ipv6:ipv6,scope:scope),deadline)
        guard let prefix=NetworkInspection.routePrefix(destination:NetworkInspection.routeField("destination",info),mask:NetworkInspection.routeField("mask",info)=="default" ? (ipv6 ? "::":"0.0.0.0"):NetworkInspection.routeField("mask",info),host:info.contains("HOST")),let gateway=NetworkInspection.routeGateway(info),let interface=NetworkInspection.routeField("interface",info) else {throw RouteBackendError(EPROTO)}
        let names=NetworkInspection.routeField("flags",info) ?? ""
        var flags=UInt32(RTF_UP)
        for (flag,name) in [(RTF_GATEWAY,"GATEWAY"),(RTF_HOST,"HOST"),(RTF_STATIC,"STATIC"),(RTF_IFSCOPE,"IFSCOPE")] where names.contains(name) {flags |= UInt32(flag)}
        return RouteRecord(route:ProtectedRoute(destination:prefix,gateway:gateway,interface:interface,scope:names.contains("IFSCOPE") ? interface:nil),flags:flags)
    }
    public func write(_ operation:NetworkInspection.RouteOperation,route:ProtectedRoute,legacy:Bool,deadline:Date?) throws -> RouteWriteResult {
        guard operation != .get else {throw RouteBackendError(EINVAL)}
        let args=legacy ? CaptureOwnership.legacyHostDeletionArguments(route):NetworkInspection.routeArguments(operation,destination:route.destination,gateway:route.gateway,ipv6:route.ipv6,scope:route.scope,interface:route.interface)
        let output=try command("/sbin/route",args,deadline)
        return CaptureOwnership.routeWriteFailed(output) ? .rejected(EIO):.applied
    }
}

// 在核心启动前订阅接口事件；每次唤醒都重新读取地址，不能仅凭接口名称认领 TUN。
public final class NativeInterfaceReadiness {
    private let descriptor:Int32
    private var readAddresses:()->[String:Set<String>] = {[:]}
    private var injectedWait:((Int32) throws -> Void)?
    public init(addresses:@escaping ()->[String:Set<String>],wait:@escaping (Int32) throws -> Void) {descriptor = -1;readAddresses=addresses;injectedWait=wait}
    public init() throws {
        descriptor=socket(PF_ROUTE,SOCK_RAW,0)
        guard descriptor>=0 else {throw RouteBackendError(errno)}
        guard fcntl(descriptor,F_SETFD,FD_CLOEXEC)>=0,fcntl(descriptor,F_SETFL,O_NONBLOCK)>=0 else {let error=errno;close(descriptor);throw RouteBackendError(error)}
    }
    deinit {if descriptor>=0 {close(descriptor)}}
    public func wait(previous:[String:Set<String>],address:String,timeout:TimeInterval,alive:()->Bool,cancelled:()->Bool) throws -> String {
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while true {
            guard alive() else {throw ProxyError("TUN 核心启动失败")}
            guard !cancelled() else {throw CancellationError()}
            let current=descriptor>=0 ? try NativeInterfaces.addresses():readAddresses()
            let matches=current.keys.filter{$0.hasPrefix("utun") && previous[$0]==nil && current[$0]?.contains(address)==true}
            if matches.count==1 {return matches[0]}
            guard matches.isEmpty else {throw ProxyError("多个 TUN 接口具有相同地址，拒绝认领")}
            let remaining=deadline-ProcessInfo.processInfo.systemUptime
            guard remaining>0 else {throw ProxyError("TUN 接口归属校验超时")}
            if let injectedWait {try injectedWait(Int32(min(50,max(1,remaining*1000))));continue}
            var item=pollfd(fd:descriptor,events:Int16(POLLIN),revents:0)
            let ready=poll(&item,1,Int32(min(50,max(1,remaining*1000))))
            if ready<0 && errno != EINTR {throw RouteBackendError(errno)}
            if item.revents & Int16(POLLERR|POLLHUP|POLLNVAL) != 0 {throw RouteBackendError(EIO)}
            if ready>0 {var data=[UInt8](repeating:0,count:8192);for _ in 0..<64 {if recv(descriptor,&data,data.count,0)<=0 {break}}}
        }
    }
}
