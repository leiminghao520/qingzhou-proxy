import Foundation
import SystemConfiguration

public struct BypassNetworkService:Identifiable,Equatable,Sendable {
    public let id:String
    public let name:String
    public let interface:String
    public let active:Bool
    public init(id:String,name:String,interface:String,active:Bool) {self.id=id;self.name=name;self.interface=interface;self.active=active}
    public static func read()->[Self] {
        guard let preferences=SCPreferencesCreate(nil,"汐航网络服务只读查询" as CFString,nil),let services=SCNetworkServiceCopyAll(preferences) as? [SCNetworkService],let store=SCDynamicStoreCreate(nil,"汐航网络状态只读查询" as CFString,nil,nil) else {return []}
        return services.compactMap {service in
            guard SCNetworkServiceGetEnabled(service),let identifier=SCNetworkServiceGetServiceID(service) as String?,let device=SCNetworkServiceGetInterface(service),let interface=SCNetworkInterfaceGetBSDName(device) as String? else{return nil}
            let ipv4=SCDynamicStoreCopyValue(store,("State:/Network/Service/"+identifier+"/IPv4") as CFString) as? [String:Any]
            let ipv6=SCDynamicStoreCopyValue(store,("State:/Network/Service/"+identifier+"/IPv6") as CFString) as? [String:Any]
            let link=SCDynamicStoreCopyValue(store,("State:/Network/Interface/"+interface+"/Link") as CFString) as? [String:Any]
            let hasAddress=(ipv4?["Addresses"] as? [String])?.isEmpty==false || (ipv6?["Addresses"] as? [String])?.isEmpty==false
            return Self(id:identifier,name:(SCNetworkServiceGetName(service) as String?) ?? interface,interface:interface,active:hasAddress && (link?["Active"] as? Bool ?? true))
        }.sorted{$0.name<$1.name}
    }
}
public enum PinnedBypassPolicy {
    public static func routes(_ items:[NetworkBypass],services:[BypassNetworkService]) throws -> [ProtectedRoute] {
        try items.map {raw in
            let item=try raw.normalized()
            guard item.exit == .pinned,let service=services.first(where:{$0.id==item.serviceID}),service.interface.range(of:"^[a-z][a-z0-9]{0,15}$",options:.regularExpression) != nil,!CapturePlan.isVPN(service.interface),service.interface != "lo0" else {throw ProxyError("指定网络服务不存在或不是物理网卡："+item.value)}
            return ProtectedRoute(destination:item.value,gateway:item.gateway!,interface:service.interface,source:"指定出口网络绕过")
        }
    }
    // 拒绝规则始终存在；只有实际选中指定接口的流量才能通过，网卡掉线不依赖轮询才阻断。
    public static func firewallRules(_ routes:[ProtectedRoute])->String {
        routes.map {route in
            let family=route.ipv6 ? "inet6":"inet"
            return "block drop out quick on ! "+route.interface+" "+family+" from any to "+route.destination+"\npass out quick on "+route.interface+" "+family+" from any to "+route.destination+" no state"
        }.joined(separator:"\n")+"\n"
    }
    public static func validateFirewallRoot(_ text:String) throws {
        let lines=text.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty && !$0.hasPrefix("#")}
        guard lines.first=="anchor \"com.apple/*\" all",lines.count==1 else {throw ProxyError("系统防火墙未提供可验证的独立保护锚点，无法保证指定出口掉线后拒绝流量；未修改企业 VPN 防火墙。请保留系统路由方式或由网络管理员提供兼容环境")}
    }
}
