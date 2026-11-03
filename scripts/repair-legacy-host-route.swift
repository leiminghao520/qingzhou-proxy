import Foundation
import Darwin
import QingzhouKit

// 默认仅预览；显式应用只删除操作者指定且完整身份仍匹配的异常项，不启动代理。
@main struct RepairLegacyHostRoute {
    static func main() {
        do {try run()} catch {fputs("残留修复："+error.localizedDescription+"\n",stderr);exit(1)}
    }
    static func run() throws {
        let args=Array(CommandLine.arguments.dropFirst())
        guard args.count==5,["--preview","--apply"].contains(args[0]) else {
            throw ProxyError("用法：repair-legacy-host-route --preview|--apply IPv6/128 网关 接口 global|接口作用域")
        }
        let expected=ProtectedRoute(destination:args[1],gateway:args[2],interface:args[3],scope:args[4]=="global" ? nil:args[4])
        try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:expected.destination,action:.direct))
        let before=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
        guard CaptureOwnership.legacyHostRouteInTable(expected,table:before) else {throw ProxyError("未找到唯一且完整身份匹配的旧版异常项，未修改任何路由")}
        print("匹配异常项："+expected.destination+"，接口="+expected.interface+"，网关="+expected.gateway+"，作用域="+(expected.scope ?? "global"))
        guard args[0]=="--apply" else {print("仅预览：没有修改路由、DNS 或代理；应用前必须由操作者确认此项归属。" );return}
        guard geteuid()==0 else {throw ProxyError("应用修复需要管理员权限")}
        // 执行前重新读取，不能用预览时的旧状态删除后来变更的路由。
        let current=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
        guard CaptureOwnership.legacyHostRouteInTable(expected,table:current) else {throw ProxyError("执行前路由身份变化，已取消")}
        let output=try NetworkInspection.command("/sbin/route",CaptureOwnership.legacyHostDeletionArguments(expected))
        guard !CaptureOwnership.routeWriteFailed(output) else {throw ProxyError("异常项删除失败："+output)}
        let after=try NetworkInspection.command("/usr/sbin/netstat",["-rn"])
        guard !CaptureOwnership.legacyHostRouteInTable(expected,table:after) else {throw ProxyError("异常项仍存在，未完成修复")}
        print("异常项已移除；没有启动核心或修改 DNS、系统代理。")
    }
}
