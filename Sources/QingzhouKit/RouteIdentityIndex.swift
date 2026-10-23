import Foundation
import Darwin

// 将网络前缀规范为掩码后的地址；接口、网关和作用域仍分别核验，不能只按目标去重。
public struct RouteIdentityIndex {
    private var records:[RouteRecord]?
    private var routes:[String:[ProtectedRoute]]=[:]
    public init(_ values:[ProtectedRoute]) {
        for route in values {if let key=Self.key(route.destination) {routes[key,default:[]].append(route)}}
    }
    public init(records:[RouteRecord]) {
        self.init(records.map(\.route));self.records=records
    }
    // 仅处理现场组播父项与同接口派生邻居缓存；缺失原始标志时保持保守判断。
    private func ownershipCandidates(_ expected:ProtectedRoute)->[ProtectedRoute] {
        let matches=candidates(expected.destination).filter{$0.scope==expected.scope}
        guard matches.count==2,expected.destination=="239.255.255.250/32",let records else{return matches}
        let entries=records.filter{Self.key($0.route.destination)==Self.key(expected.destination) && $0.route.scope==expected.scope}
        let parents=entries.filter{$0.route==expected || ($0.route.gateway==expected.gateway && $0.route.interface==expected.interface)}
            .filter{$0.flags & UInt32(RTF_MULTICAST|RTF_CLONING)==UInt32(RTF_MULTICAST|RTF_CLONING) && $0.flags & UInt32(RTF_LLINFO|RTF_WASCLONED)==0 && $0.route.gateway.hasPrefix("link#")}
        guard parents.count==1,entries.count==2 else{return matches}
        let caches=entries.filter{$0.route.interface==expected.interface && $0.flags & UInt32(RTF_HOST|RTF_LLINFO|RTF_MULTICAST)==UInt32(RTF_HOST|RTF_LLINFO|RTF_MULTICAST) && $0.flags & UInt32(RTF_GATEWAY)==0 && ($0.linkLayerAddress ?? $0.route.gateway).lowercased()=="1:0:5e:7f:ff:fa"}
        guard caches.count==1 else{return matches}
        return [parents[0].route]
    }
    private static func key(_ prefix:String)->String? {
        let parts=prefix.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count==2,let bits=Int(parts[1]) else{return nil}
        let address=String(parts[0]),family=address.contains(":") ? AF_INET6:AF_INET
        let size=family==AF_INET6 ? 16:4
        guard (0...size*8).contains(bits) else{return nil}
        var bytes=[UInt8](repeating:0,count:16)
        guard address.withCString({inet_pton(family,$0,&bytes)})==1 else{return nil}
        for index in 0..<size {
            let kept=max(0,min(8,bits-index*8))
            bytes[index] &= kept==0 ? 0:UInt8(255 << (8-kept) & 255)
        }
        return String(family)+":"+String(bits)+":"+Data(bytes.prefix(size)).base64EncodedString()
    }
    public func candidates(_ destination:String)->[ProtectedRoute] {guard let key=Self.key(destination) else{return []};return routes[key] ?? []}
    public func state(_ expected:ProtectedRoute)->CaptureOwnership.RecoveryRouteState {
        let matches=ownershipCandidates(expected)
        guard !matches.isEmpty else{return .absent}
        // 满长父项删除后，内核可能保留同 link# 的邻居缓存；必须由当前整表中的组播父网段证明来源。
        if let records,expected.destination=="239.255.255.250/32",candidates(expected.destination).filter({$0.scope==expected.scope}).count==1,
           let cache=records.first(where:{$0.route.destination==expected.destination && $0.route.scope==expected.scope && $0.route.interface==expected.interface && $0.route.gateway==expected.gateway && $0.flags & UInt32(RTF_LLINFO) != 0}) {
            let parents=records.filter{$0.route.destination=="224.0.0.0/4" && $0.route.scope==expected.scope}
            let cacheFlags=UInt32(RTF_UP|RTF_HOST|RTF_LLINFO|RTF_MULTICAST)
            let parentFlags=UInt32(RTF_UP|RTF_MULTICAST|RTF_CLONING)
            if cache.flags & cacheFlags==cacheFlags,cache.flags & UInt32(RTF_GATEWAY)==0,
               cache.linkLayerAddress?.lowercased()=="1:0:5e:7f:ff:fa",expected.gateway.hasPrefix("link#"),
               parents.count==1,let parent=parents.first,parent.route.interface==expected.interface,parent.route.gateway==expected.gateway,
               parent.flags & parentFlags==parentFlags,parent.flags & UInt32(RTF_HOST|RTF_LLINFO|RTF_WASCLONED|RTF_GATEWAY)==0 {
                return .replaced
            }
            return .ambiguous
        }
        guard matches.contains(where:{$0.gateway==expected.gateway && $0.interface==expected.interface}) else{return .replaced}
        return matches.count==1 ? .owned:.ambiguous
    }
    // 只向已通过所有权核验的删除提供原始身份；缺少标志的旧快照仍使用兼容入口。
    public func ownedRecord(_ expected:ProtectedRoute)->RouteRecord? {
        guard state(expected) == .owned else{return nil}
        return records?.first {Self.key($0.route.destination)==Self.key(expected.destination) && $0.route.gateway==expected.gateway && $0.route.interface==expected.interface && $0.route.scope==expected.scope && !$0.isTransient}
    }
    public func contains(_ expected:ProtectedRoute)->Bool {
        candidates(expected.destination).contains{$0.gateway==expected.gateway && $0.interface==expected.interface && $0.scope==expected.scope}
    }
}

// 批次只复用只读基线；新增路由仍走原有逐条写前、写后核验，提交前重新读取整表。
public enum RouteProtectionBatch {
    public static func run(protected:[ProtectedRoute],bypass:[ProtectedRoute],baseline:NetworkRouteSample,
                           read:() throws -> NetworkRouteSample,check:() throws -> Void,
                           add:(ProtectedRoute,Bool) throws -> Void,
                           metrics:RouteOperationMetrics?=nil) throws {
        let index=RouteIdentityIndex(baseline.ownershipRoutes)
        for route in protected where route.scope != nil || route.source=="用户网络绕过" {
            try check()
            var global=route;global.scope=nil
            if index.state(global) != .owned {try add(global,false)}
        }
        for route in bypass {
            try check()
            if index.state(route) != .owned {try add(route,true)}
        }
        try check()
        func verifyFinal() throws {
            let final=RouteIdentityIndex(try read().ownershipRoutes)
            for route in protected+bypass {
                try check()
                guard final.state(route) == .owned else {throw ProxyError("接管前保护路径核验失败："+route.destination)}
                if route.scope != nil {
                    var global=route;global.scope=nil
                    guard final.state(global) == .owned else {throw ProxyError("全局保护路径核验失败："+route.destination)}
                }
            }
        }
        if let metrics {try metrics.measure("protectionFinalVerification",verifyFinal)} else {try verifyFinal()}
        try check()
    }
}
