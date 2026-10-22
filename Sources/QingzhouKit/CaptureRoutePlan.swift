import Foundation
import Darwin

// 地址和掩码使用数值表示，避免依赖显示缩写或字符串排序。
public struct IPPrefix:Hashable,Sendable {
    public let bytes:[UInt8]
    public let bits:Int
    public var ipv6:Bool {bytes.count==16}
    public init?(_ text:String) {
        let parts=text.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count==2,let bits=Int(parts[1]) else{return nil}
        let family=parts[0].contains(":") ? AF_INET6:AF_INET,size=family==AF_INET6 ? 16:4
        guard (0...size*8).contains(bits) else{return nil}
        var bytes=[UInt8](repeating:0,count:16)
        guard String(parts[0]).withCString({inet_pton(family,$0,&bytes)})==1 else{return nil}
        self.init(bytes:Array(bytes.prefix(size)),bits:bits)
    }
    private init(bytes:[UInt8],bits:Int) {
        var result=bytes
        for index in result.indices {let kept=max(0,min(8,bits-index*8));result[index] &= kept==0 ? 0:UInt8((255 << (8-kept)) & 255)}
        self.bytes=result;self.bits=bits
    }
    public var address:String {
        var bytes=bytes,buffer=[CChar](repeating:0,count:Int(INET6_ADDRSTRLEN))
        _=inet_ntop(ipv6 ? AF_INET6:AF_INET,&bytes,&buffer,socklen_t(buffer.count));return String(cString:buffer)
    }
    public var text:String {address+"/\(bits)"}
    public var maskAddress:String {
        var mask=[UInt8](repeating:0,count:bytes.count)
        for index in mask.indices {let kept=max(0,min(8,bits-index*8));mask[index]=kept==0 ? 0:UInt8((255 << (8-kept)) & 255)}
        var buffer=[CChar](repeating:0,count:Int(INET6_ADDRSTRLEN));_=inet_ntop(ipv6 ? AF_INET6:AF_INET,&mask,&buffer,socklen_t(buffer.count));return String(cString:buffer)
    }
    public func contains(_ other:Self)->Bool {bytes.count==other.bytes.count && bits<=other.bits && Self(bytes:other.bytes,bits:bits).bytes==bytes}
    public func overlaps(_ other:Self)->Bool {contains(other) || other.contains(self)}
    fileprivate func child(_ right:Bool)->Self {
        var value=bytes;if right {value[bits/8] |= UInt8(1 << (7-bits%8))};return Self(bytes:value,bits:bits+1)
    }
    fileprivate func bit(_ index:Int)->Bool {bytes[index/8] & UInt8(1 << (7-index%8)) != 0}
}
private final class ExclusionTree {
    var terminal=false
    var left:ExclusionTree?,right:ExclusionTree?
    func insert(_ prefix:IPPrefix,depth:Int=0) {
        guard !terminal else{return}
        if depth==prefix.bits {terminal=true;left=nil;right=nil;return}
        if prefix.bit(depth) {if right==nil{right=ExclusionTree()};right!.insert(prefix,depth:depth+1)}
        else {if left==nil{left=ExclusionTree()};left!.insert(prefix,depth:depth+1)}
        if left?.terminal==true && right?.terminal==true {terminal=true;left=nil;right=nil}
    }
    func complement(_ prefix:IPPrefix,limit:Int,result:inout [IPPrefix]) throws {
        if terminal{return}
        if left==nil && right==nil {
            if prefix.bits==0 {result.append(prefix.child(false));result.append(prefix.child(true))}else{result.append(prefix)}
            guard result.count<=limit else {throw ProxyError("捕获路由超过预算")};return
        }
        for (child,right) in [(left,false),(self.right,true)] {
            let next=prefix.child(right)
            if let child {try child.complement(next,limit:limit,result:&result)}
            else {result.append(next);guard result.count<=limit else{throw ProxyError("捕获路由超过预算")}}
        }
    }
}
public struct CaptureRoutePlan:Equatable,Sendable {
    public static let legacyPrefixes=["0.0.0.0/1","128.0.0.0/1","::/1","8000::/1"]
    public let prefixes:[String]
    public let exclusions:[String]
    public let fallbackReason:String?
    public init(exclusions:[String],limit:Int=4096) throws {
        let v4=ExclusionTree(),v6=ExclusionTree()
        var normalized=Set<IPPrefix>()
        for value in exclusions {
            guard let prefix=IPPrefix(value),prefix.bits>1 else {throw ProxyError("捕获排除网段无效")}
            normalized.insert(prefix);(prefix.ipv6 ? v6:v4).insert(prefix)
        }
        var result:[IPPrefix]=[]
        do {
            try v4.complement(IPPrefix("0.0.0.0/0")!,limit:limit,result:&result)
            try v6.complement(IPPrefix("::/0")!,limit:limit,result:&result)
            prefixes=result.map(\.text);self.exclusions=normalized.map(\.text).sorted();fallbackReason=nil
        } catch {
            prefixes=Self.legacyPrefixes;self.exclusions=[];fallbackReason="捕获差集超过 \(limit) 条预算，使用原捕获方案与完整绕过保护"
        }
    }
    public static func make(plan:CapturePlan,bypass:BypassRoutePlan,baseline:NetworkRouteSample) throws -> Self {
        try bypass.validatePreservedRoutes(baseline.ownershipRoutes)
        let index=RouteIdentityIndex(baseline.ownershipRoutes)
        var excluded:[String]=[]
        // 必须证明未限定接口的原系统路径与快照查询一致；仅作用域出口继续保留保护路由。
        for route in bypass.routes {
            if let path=try? Self.systemPath(route.destination,routes:baseline.planningRoutes),path.interface==route.interface,path.gateway==route.gateway {excluded.append(route.destination)}
        }
        // 原接口的链路本地和组播路径按作用域保留，不能把它们的差集变成无作用域全局碎片。
        // 只依赖已核验的实际前缀；不把某个接口的路径扩大为整个链路本地地址空间。
        let protected=(plan.protectedRoutes.filter{index.state($0) == .owned}+bypass.preservedRoutes).compactMap{IPPrefix($0.destination)}
        // 已核验的更具体企业路由本来就优先于捕获路由，不必把每个公网主机拆成大量补集。
        // 其他排除项可能产生与企业路由同长或更长的碎片，必须继续做差集，直到不再覆盖企业出口。
        for _ in 0...protected.count {
            let capture=try Self(exclusions:excluded)
            if capture.fallbackReason != nil {return capture}
            let prefixes=capture.prefixes.compactMap(IPPrefix.init)
            let required=protected.filter {route in
                !capture.excludes(route.text) && prefixes.contains{route.contains($0) && $0.bits>=route.bits}
            }
            if required.isEmpty {
                // 某些显式绕过组合仍可能产生无法表达的全局链路本地碎片，必须在任何写入前拒绝。
                guard !prefixes.contains(where:{$0.ipv6 && (IPPrefix("fe80::/10")!.contains(IPPrefix($0.address+"/128")!) || $0.address.hasPrefix("ff01:") || $0.address.hasPrefix("ff02:"))}) else {
                    throw ProxyError("捕获差集包含无作用域链路本地或本地组播前缀，未修改网络；请核对原接口作用域与显式绕过范围")
                }
                return capture
            }
            excluded += required.map(\.text)
        }
        throw ProxyError("捕获规划未能收敛，保留原保护路径")
    }
    public static func systemPath(_ target:String,routes:[ProtectedRoute]) throws -> ProtectedRoute {
        let text=target.contains("/") ? target:target+(target.contains(":") ? "/128":"/32")
        guard let prefix=IPPrefix(text) else {throw ProxyError("原系统路径目标无效")}
        let candidates=routes.filter{$0.scope==nil && IPPrefix($0.destination)?.contains(prefix)==true}
        guard let bits=candidates.compactMap({IPPrefix($0.destination)?.bits}).max() else {throw NetworkEnvironmentNotReady("原系统出口缺失："+text)}
        let longest=candidates.filter{IPPrefix($0.destination)?.bits==bits}
        guard longest.count==1,let route=longest.first else {throw NetworkEnvironmentNotReady("原系统出口存在歧义："+text)}
        return route
    }
    public func captures(_ address:String)->Bool {
        let bits=address.contains(":") ? 128:32
        guard let host=IPPrefix(address+"/\(bits)") else{return false}
        return prefixes.contains{IPPrefix($0)?.contains(host)==true}
    }
    public func excludes(_ prefix:String)->Bool {
        guard let value=IPPrefix(prefix) else{return false}
        return exclusions.contains{IPPrefix($0)?.contains(value)==true}
    }
}
