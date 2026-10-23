import Foundation
import SystemConfiguration
import CFNetwork

public struct BypassPathDiagnostic:Sendable {
    public var rows:[String]
    public var hasFailure:Bool
    public init(rows:[String],hasFailure:Bool) {self.rows=rows;self.hasFailure=hasFailure}
}
public enum BypassDiagnostics {
    public static func inspect(_ input:String,state:AppState,active:Bool,ownedTunnel:String?=nil,cancelled:@escaping ()->Bool={false},resolve:(String)throws->[String]=NetworkInspection.addresses) throws -> BypassPathDiagnostic {
        let host=input.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard !host.isEmpty,!host.contains("/"),!host.contains("://") else {throw ProxyError("请输入不含协议、端口和路径的域名或 IP")}
        let isIP=(try? ConfigBuilder.validate(RoutingRule(kind:.cidr,value:host,action:.direct))) != nil
        if !isIP {_=try ProtectedDomainPolicy.normalize([host])}
        var rows=["运行查询：只读，不修改路由、DNS 或代理设置"],failed=false
        guard !cancelled() else{throw CancellationError()}
        let addresses=isIP ? [host] : try resolve(host)
        guard !cancelled() else{throw CancellationError()}
        let backend=NativeRouteBackend();backend.cancelled=cancelled
        let matched=state.enabledBypasses.filter{$0.matches(host:host,ip:isIP ? host:nil)}
        rows.append("配置匹配："+(matched.isEmpty ? "未命中绕过项":matched.map{$0.kind.label+" "+$0.value}.joined(separator:"；")))
        rows.append(active ? "配置状态：本次连接已应用此配置":"配置状态：当前未应用此配置，以下查询反映系统当前路径")
        if !isIP {rows.append("当前系统解析结果："+addresses.joined(separator:"、"))}
        guard let settings=CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {throw ProxyError("无法读取当前系统代理设置")}
        let authority=host.contains(":") ? "["+host+"]":host
        for scheme in ["https","http"] {
            guard let url=URL(string:scheme+"://"+authority+"/"),let choices=CFNetworkCopyProxiesForURL(url as CFURL,settings).takeRetainedValue() as? [[String:Any]],let first=choices.first,let type=first[kCFProxyTypeKey as String] as? String else {throw ProxyError("系统代理选择结果无法读取")}
            let direct=type==(kCFProxyTypeNone as String)
            rows.append(scheme.uppercased()+" 系统代理选择："+(direct ? "DIRECT（系统 API）":type))
            if !direct,!matched.isEmpty,active {failed=true}
        }
        let services=BypassNetworkService.read()
        for address in addresses.prefix(16) {
            guard !cancelled() else{throw CancellationError()}
            let info=try backend.lookup(address,ipv6:address.contains(":")).queryText
            let interface=NetworkInspection.routeField("interface",info) ?? "未知"
            let gateway=NetworkInspection.routeGateway(info) ?? "接口直连或不可确认"
            rows.append(address+" → "+interface+" / "+gateway)
            let targets=state.enabledBypasses.filter{$0.matches(host:host,ip:address)}
            if let tunnel=ownedTunnel {rows.append("TUN 路径："+(interface==tunnel ? "仍进入轻舟隧道":"未进入轻舟隧道"));if !targets.isEmpty,active,interface==tunnel {failed=true}}
            else {rows.append("TUN 路径：未取得本次轻舟隧道身份，不能仅凭 utun 名称判定")}
            for item in targets where item.exit == .pinned {
                let service=services.first{$0.id==item.serviceID}
                let valid=service?.active==true && service?.interface==interface && item.gateway==gateway
                rows.append("指定出口核验："+(valid ? "路径一致":"失败或网口未就绪")+"；期望 "+(service?.name ?? "服务缺失")+" / "+(item.gateway ?? "未配置"))
                if !valid {failed=true}
            }
        }
        if !isIP,let store=SCDynamicStoreCreate(nil,"轻舟绕过 DNS 路径只读诊断" as CFString,nil,nil),let global=SCDynamicStoreCopyValue(store,"State:/Network/Global/IPv4" as CFString) as? [String:Any],let primary=global["PrimaryInterface"] as? String {
            guard !cancelled() else{throw CancellationError()}
            let sample=try backend.snapshot()
            let snapshot=try NetworkSnapshot.read(store:store,primary:primary,routes:sample.table,ownedTunnel:ownedTunnel,structuredRoutes:sample.planningRoutes,lookup:{try backend.lookup($0,ipv6:$1).queryText})
            let plan=try CapturePlan.make(snapshot:snapshot,extraCIDRs:[],extraDomains:[])
            let resolvers=plan.resolvers(for:host)
            rows.append("系统 DNS 作用域："+resolvers.map{$0.interface+" / "+$0.servers.joined(separator:",")}.joined(separator:"；"))
            rows.append("核心 DNS 配置："+(matched.isEmpty ? "由普通分流决定":"优先使用原系统解析；完整接管由作用域转发器处理"))
        }
        rows.append("系统代理选择不代表每个应用都会遵循例外；Horizon 登录和桌面隧道需独立验收。")
        return BypassPathDiagnostic(rows:rows,hasFailure:failed)
    }
}
