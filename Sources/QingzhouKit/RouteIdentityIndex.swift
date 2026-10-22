import Foundation
import Darwin

// 将网络前缀规范为掩码后的地址；接口、网关和作用域仍分别核验，不能只按目标去重。
public struct RouteIdentityIndex {
    private var routes:[String:[ProtectedRoute]]=[:]
    public init(_ values:[ProtectedRoute]) {
        for route in values {if let key=Self.key(route.destination) {routes[key,default:[]].append(route)}}
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
        let matches=candidates(expected.destination).filter{$0.scope==expected.scope}
        guard !matches.isEmpty else{return .absent}
        guard matches.contains(where:{$0.gateway==expected.gateway && $0.interface==expected.interface}) else{return .replaced}
        return matches.count==1 ? .owned:.ambiguous
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
