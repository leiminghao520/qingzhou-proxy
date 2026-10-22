import Foundation
import Darwin
import CQingzhouRoute
import QingzhouKit

final class Transport:RouteTransport {
    var data=Data()
    var error:Int32=0
    var failure:Error?
    var sent:[Data]=[]
    var transform:((Data)->Data)?
    func dump() throws -> Data {if let failure {throw failure};return data}
    func exchange(_ request:Data,timeout:TimeInterval,cancelled:()->Bool) throws -> RouteExchangeResult {
        if cancelled(){throw CancellationError()}
        if let failure {throw failure}
        sent.append(request)
        var reply=Data(count:MemoryLayout<rt_msghdr>.size)
        let identity=request.withUnsafeBytes{$0.loadUnaligned(as:rt_msghdr.self)}
        reply.withUnsafeMutableBytes {p in
            var response=rt_msghdr();response.rtm_msglen=UInt16(MemoryLayout<rt_msghdr>.size);response.rtm_version=UInt8(RTM_VERSION);response.rtm_type=identity.rtm_type
            response.rtm_pid=identity.rtm_pid;response.rtm_seq=identity.rtm_seq;response.rtm_errno=error
            p.baseAddress!.storeBytes(of:response,as:rt_msghdr.self)
        }
        reply=transform?(reply) ?? reply
        return RouteExchangeResult(reply:reply,kernelError:error)
    }
}
@main struct Checks {
    static var assertions=0
    static func check(_ value:Bool,_ message:String) {assertions+=1;if !value{fatalError(message)}}
    static func fails(_ message:String,_ body:() throws -> Void) {do{try body();check(false,message)}catch{check(true,message)}}
    static func packet(_ destination:String="192.0.2.7",bits:Int=32,ipv6:Bool=false,scope:Bool=false,link:Bool=false,operation:Int32=RTM_ADD,legacy:Bool=false) throws -> Data {
        var bytes=Data(count:2048),length=0
        let gateway=link ? "link#\(if_nametoindex("lo0"))":ipv6 ? "::1":"127.0.0.1"
        let error=bytes.withUnsafeMutableBytes{qz_route_encode(operation,destination,ipv6 ? AF_INET6:AF_INET,Int32(bits),gateway,"lo0",scope ? 1:0,legacy ? 1:0,123,456,$0.baseAddress,$0.count,&length)}
        guard error==0 else{throw RouteBackendError(error)};bytes.count=length
        // 此夹具表示内核返回的表项，接口索引由内核填入；不能再直接把请求当作响应。
        bytes.withUnsafeMutableBytes{$0.baseAddress!.assumingMemoryBound(to:rt_msghdr.self).pointee.rtm_index=UInt16(if_nametoindex("lo0"))}
        return bytes
    }
    static func main() throws {
        if CommandLine.arguments.contains("--offline-benchmark") {
            let transport=Transport()
            for n in 0..<600 {transport.data.append(try packet("10.\(n/256).\(n%256).0",bits:24))}
            let backend=NativeRouteBackend(transport:transport)
            var samples:[Double]=[],text:[Double]=[]
            for _ in 0..<30 {
                let began=ProcessInfo.processInfo.systemUptime
                let snapshot=try backend.snapshot()
                samples.append((ProcessInfo.processInfo.systemUptime-began)*1000)
                let renderStart=ProcessInfo.processInfo.systemUptime
                check(snapshot.ownershipRoutes.count==600 && !snapshot.table.isEmpty,"独立采样保留六百项")
                text.append((ProcessInfo.processInfo.systemUptime-renderStart)*1000)
            }
            samples.sort();text.sort()
            print("OFFLINE_SNAPSHOT_BENCHMARK routes=600 n=30 structuredMedianMs=\((samples[14]+samples[15])/2) structuredP95Ms=\(samples[28]) textMedianMs=\((text[14]+text[15])/2) kernelCalls=0 externalCommands=0")
            return
        }
        if CommandLine.arguments.contains("--export-plans") {
            var rows:[[String:Any]]=[]
            let inputs:[([String],Int)]=[([],4096),(["10.0.0.0/8","10.1.0.0/16","192.168.0.0/16"],4096),(["fc00::/7","fe80::/64","2001:db8::/32"],4096),(["198.51.100.7/32","2606:4700::1111/128"],4096),(["192.0.2.0/25","192.0.2.128/25"],4096),(["198.51.100.7/32"],4)]
            for (exclusions,limit) in inputs {
                let plan=try CaptureRoutePlan(exclusions:exclusions,limit:limit)
                rows.append(["prefixes":plan.prefixes,"exclusions":plan.exclusions,"fallback":plan.fallbackReason != nil])
            }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]));return
        }
        if CommandLine.arguments.contains("--read-only") {
            let backend=NativeRouteBackend()
            let start=ProcessInfo.processInfo.systemUptime
            let sample=try backend.snapshot()
            let elapsed=(ProcessInfo.processInfo.systemUptime-start)*1000
            let route=try backend.lookup("default",ipv6:false)
            check(!sample.ownershipRoutes.isEmpty && route.route.destination=="0.0.0.0/0","原生只读采样和默认路由")
            let legacy=NetworkSnapshot.parseRoutes(try NetworkInspection.command("/usr/sbin/netstat",["-rn"]),includeTransient:true)
            let index=RouteIdentityIndex(sample.ownershipRoutes)
            let stable=legacy.filter{!$0.destination.hasSuffix("/32") && !$0.destination.hasSuffix("/128")}
            let missing=stable.filter{!index.contains($0)}
            print("NATIVE_READ_ONLY routes=\(sample.ownershipRoutes.count) dumpMs=\(elapsed) stableCompared=\(stable.count) missing=\(missing.count)")
            if !missing.isEmpty {print("MISMATCH_COUNT=\(missing.count)")}
            check(missing.isEmpty,"原生与命令整表稳定路由一致")
            let command=LegacyRouteBackend()
            for (target,ipv6,scope) in [("8.8.8.8",false,Optional<String>.none),("127.0.0.1",false,nil),("8.8.8.8",false,route.route.interface),("::1",true,nil),("fe80::",true,nil),("fe80::",true,route.route.interface)] {
                let old=try command.lookup(target,ipv6:ipv6,scope:scope,deadline:nil)
                let current=try backend.lookup(target,ipv6:ipv6,scope:scope)
                check(old.route.destination==current.route.destination && old.route.interface==current.route.interface && old.route.gateway==current.route.gateway && old.route.scope==current.route.scope,"原生最长匹配、作用域与链路路由对照")
            }
            print("NATIVE_LOOKUP_PARITY_OK queries=6")
            let scoped=try BypassRoutePlan.capture(destinations:["fe80::/10"],existingPrefixes:sample.planningRoutes.map(\.destination),hasIPv6:true,existingRoutes:sample.planningRoutes,lookup:{_,_ in throw ProxyError("链路本地不得选择单一默认出口")})
            check(scoped.routes.isEmpty && !scoped.preservedRoutes.isEmpty,"当前多接口链路本地快照复现截图路径")
            try scoped.validatePreservedRoutes(backend.snapshot().ownershipRoutes)
            print("LINKLOCAL_BYPASS_READONLY_OK globalWrites=0 preserved=\(scoped.preservedRoutes.count)")
            return
        }
        for (dest,bits,ipv6) in [("192.0.2.7",32,false),("10.0.0.0",8,false),("::1",128,true),("2001:db8::",64,true),("0.0.0.0",0,false),("::",0,true)] {
            let rows=try NativeRouteBackend.decode(packet(dest,bits:bits,ipv6:ipv6,scope:true))
            check(rows.count==1 && rows[0].route.destination==dest+"/\(bits)" && rows[0].route.scope=="lo0","报文前缀和作用域")
            check(CaptureOwnership.matchesQuery(rows[0].route,info:rows[0].queryText),"结构化查询兼容旧身份核验")
        }
        let direct=try NativeRouteBackend.decode(packet(link:true))[0]
        check(direct.route.gateway=="link#\(if_nametoindex("lo0"))","接口直连网关")
        let legacy=try NativeRouteBackend.decode(packet("2001:db8::7",bits:128,ipv6:true,operation:RTM_DELETE,legacy:true))[0]
        check(legacy.route.destination=="2001:db8::7/0","异常零掩码身份保留")
        let legacySample=NetworkRouteSample(records:[legacy])
        check(legacySample.ownershipRoutes.isEmpty && legacySample.table.contains("2001:db8::7/0"),"旧异常只保留原始身份")
        let valid=try packet()
        for size in [0,1,10,valid.count-1] {
            if size==0 {check(try NativeRouteBackend.decode(Data()).isEmpty,"空整表")}
            else {fails("截断报文拒绝") {_=try NativeRouteBackend.decode(valid.prefix(size))}}
        }
        var malformed=valid
        malformed.withUnsafeMutableBytes{$0.baseAddress!.assumingMemoryBound(to:rt_msghdr.self).pointee.rtm_version=99}
        fails("错误版本拒绝") {_=try NativeRouteBackend.decode(malformed)}
        var kernel:Int32=0
        let unrelated=valid.withUnsafeBytes{qz_route_match($0.baseAddress,$0.count,RTM_ADD,999,456,&kernel)}
        check(unrelated==0,"其他进程消息不作为确认")
        let wrongSeq=valid.withUnsafeBytes{qz_route_match($0.baseAddress,$0.count,RTM_ADD,123,999,&kernel)}
        check(wrongSeq==0,"其他请求消息不作为确认")
        let same=valid.withUnsafeBytes{qz_route_match($0.baseAddress,$0.count,RTM_ADD,123,456,&kernel)}
        check(same==1 && kernel==0,"确认匹配 PID 与序列")
        let t=Transport(),backend=NativeRouteBackend(transport:t)
        let r=ProtectedRoute(destination:"192.0.2.7/32",gateway:"127.0.0.1",interface:"lo0",scope:"lo0")
        check(try backend.write(.add,route:r) == .applied,"注入后端确认成功")
        t.error=EEXIST
        check(try backend.write(.add,route:r) == .rejected(EEXIST),"内核拒绝可区分")
        t.failure=RouteBackendError(ETIMEDOUT,outcomeUnknown:true)
        fails("写入超时不冒充拒绝或成功") {_=try backend.write(.add,route:r)}
        t.failure=nil;backend.cancelled={true}
        fails("取消不发起写入") {_=try backend.write(.add,route:r)}
        check(t.sent.count==2,"取消发生在提交前")
        backend.cancelled={false};t.error=0
        let output=try RouteBackendAdapter.write(NetworkInspection.routeArguments(.add,destination:r.destination,gateway:r.gateway,scope:r.scope,interface:r.interface),backend:backend,deadline:nil)
        check(output.isEmpty,"旧调用边界转结构化写入")
        fails("拒绝未知命令选项") {_=try RouteBackendAdapter.write(["-n","add","-shell"],backend:backend,deadline:nil)}
        let cidrs=try CaptureRoutePlan(exclusions:["10.0.0.0/8","10.1.2.0/24","192.168.0.0/16","2001:db8::/32"])
        check(!cidrs.captures("10.2.3.4") && !cidrs.captures("2001:db8::7") && cidrs.captures("8.8.8.8") && cidrs.captures("2606:4700::1111"),"捕获差集覆盖内外网")
        let prefixes=cidrs.prefixes.compactMap(IPPrefix.init)
        for (i,p) in prefixes.enumerated() {check(!prefixes.dropFirst(i+1).contains{p.overlaps($0)},"捕获前缀互不重叠")}
        check(try CaptureRoutePlan(exclusions:[],limit:1).fallbackReason != nil,"超过预算回退原计划")
        fails("拒绝全局排除") {_=try CaptureRoutePlan(exclusions:["0.0.0.0/0"])}
        let empty=try CaptureRoutePlan(exclusions:[])
        check(empty.prefixes==CaptureRoutePlan.legacyPrefixes,"空排除保留四个半网段")
        try extended()
        print("NATIVE_ROUTE_CHECKS_OK assertions=\(assertions)")
    }
}
