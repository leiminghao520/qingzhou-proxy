import Foundation
import Darwin
import QingzhouKit

// 仅在回环接口作用域验证内核语义，绝不创建全局默认路由或修改当前代理。
@main struct RouteKernelChecks {
    static func main() throws {
        guard geteuid()==0 else {throw ProxyError("内核路由验证需要管理员权限")}
        let old=try NetworkInspection.command("/sbin/route",["-d","-n","-v","add","-inet6","-net","2001:db8:71::1/128","::1"])
        print("OLD_DEBUG\n"+old)
        guard !old.contains("HOST"),!old.contains("NETMASK") else {throw ProxyError("旧命令没有复现缺失主机标志和掩码")}
        let cases=[("192.0.2.217/32","127.0.0.1"),("2001:db8:71::1/128","::1"),("2001:db8:72::/64","::1"),("::/1","::1"),("8000::/1","::1")]
        let original=NetworkSnapshot.parseRoutes(try NetworkInspection.command("/usr/sbin/netstat",["-rn"]),includeTransient:true)
        guard cases.allSatisfy({item in !original.contains{NetworkInspection.samePrefix($0.destination,item.0) && ($0.scope=="lo0" || (item.0.contains("db8") || item.0.contains("192.0.2")))}}) else {throw ProxyError("回环验证前缀已存在，未修改网络")}
        // 复现旧版异常路由残留，再尝试新版主机写法；所有写操作均限定在回环接口。
        let legacyHost="2001:db8:73::1"
        let legacyAdd=["-n","add","-inet6","-ifscope","lo0","-net",legacyHost+"/128","::1"]
        let legacyDelete=["-n","delete","-inet6","-ifscope","lo0","-net",legacyHost+"/128","::1"]
        let baseline=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
        guard !baseline.contains(legacyHost) else {throw ProxyError("旧版复现地址已存在，未运行")}
        do {
            _=try NetworkInspection.command("/sbin/route",legacyAdd)
            defer {_=try? NetworkInspection.command("/sbin/route",legacyDelete)}
            let table=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
            guard table.contains(legacyHost+"/0") else {throw ProxyError("旧版异常前缀没有复现")}
            let attempt=try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.add,destination:legacyHost+"/128",gateway:"::1",ipv6:true,scope:"lo0"))
            print("LEGACY_RETRY_OUTPUT\n"+attempt)
            guard CaptureOwnership.routeWriteFailed(attempt) else {throw ProxyError("未识别零退出码的内核写入错误")}
            let info=try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.get,destination:legacyHost+"/128",ipv6:true,scope:"lo0"))
            let desired=ProtectedRoute(destination:legacyHost+"/128",gateway:"::1",interface:"lo0",scope:"lo0")
            guard CaptureOwnership.legacyHostRouteMatches(desired,info:info) else {throw ProxyError("旧版恢复身份没有匹配")}
            guard !CaptureOwnership.matchesQuery(desired,info:info) else {throw ProxyError("遗留异常路由未阻挡新主机路由")}
            print("PASS legacy_residue_blocks_new_host_route")
            let repair=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("repair-legacy-host-route").path
            let preview=try NetworkInspection.command(repair,["--preview",desired.destination,desired.gateway,desired.interface,desired.scope!])
            guard preview.contains("仅预览"),CaptureOwnership.legacyHostRouteInTable(desired,table:try NetworkInspection.command("/usr/sbin/netstat",["-rn"])) else {throw ProxyError("修复预览改变了路由")}
            _=try NetworkInspection.command(repair,["--apply",desired.destination,desired.gateway,desired.interface,desired.scope!])
            _=try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.add,destination:desired.destination,gateway:desired.gateway,ipv6:true,scope:desired.scope))
            let repaired=try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.get,destination:desired.destination,ipv6:true,scope:desired.scope))
            guard CaptureOwnership.matchesQuery(desired,info:repaired) else {throw ProxyError("旧记录恢复后新版主机路由仍不正确")}
            _=try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.delete,destination:desired.destination,gateway:desired.gateway,ipv6:true,scope:desired.scope))
            print("PASS legacy_cleanup_then_new_host_route")
        }
        guard !(try NetworkInspection.command("/usr/sbin/netstat",["-rn"])).contains(legacyHost) else {throw ProxyError("旧版复现路由未清理")}
        let variants=cases.map{($0.0,$0.1,Optional("lo0"))}+cases.prefix(3).map{($0.0,$0.1,Optional<String>.none)}
        for (destination,gateway,scope) in variants {
            let expected=ProtectedRoute(destination:destination,gateway:gateway,interface:"lo0",scope:scope)
            let add=NetworkInspection.routeArguments(.add,destination:destination,gateway:gateway,ipv6:expected.ipv6,scope:scope,interface:"lo0")
            let remove=NetworkInspection.routeArguments(.delete,destination:destination,gateway:gateway,ipv6:expected.ipv6,scope:scope,interface:"lo0")
            _=try NetworkInspection.command("/sbin/route",add)
            var deleted=false
            defer {
                // 清理前再次确认完整身份，避免覆盖外部修改。
                if !deleted,let info=try? NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.get,destination:destination,ipv6:expected.ipv6,scope:scope)),CaptureOwnership.matchesQuery(expected,info:info) {_=try? NetworkInspection.command("/sbin/route",remove)}
            }
            let info=try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.get,destination:destination,ipv6:expected.ipv6,scope:scope))
            print("READ "+destination+"\n"+info)
            guard CaptureOwnership.matchesQuery(expected,info:info) else {throw ProxyError("内核实际路由身份不匹配："+destination)}
            let actual=NetworkSnapshot.parseRoutes(try NetworkInspection.command("/usr/sbin/netstat",["-rn"]),includeTransient:true)
            guard CaptureOwnership.routeIssues(expected:[expected],actual:actual).isEmpty else {throw ProxyError("路由表解析不匹配："+destination)}
            _=try NetworkInspection.command("/sbin/route",remove);deleted=true
            let remaining=NetworkSnapshot.parseRoutes(try NetworkInspection.command("/usr/sbin/netstat",["-rn"]),includeTransient:true)
            guard CaptureOwnership.recoveryState(expected:expected,actual:remaining)==CaptureOwnership.RecoveryRouteState.absent else {throw ProxyError("验证路由未清理："+destination)}
            print("PASS kernel_add_get_delete "+destination)
        }
        print("RESULT kernel_cases=8 failures=0")
    }
}
