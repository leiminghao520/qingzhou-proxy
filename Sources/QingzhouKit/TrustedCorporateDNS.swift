import Foundation
import SystemConfiguration

public struct TrustedCorporateDNS:Codable,Equatable,Identifiable,Sendable {
    public var id:UUID
    public var name:String
    public var serviceID:String
    public var servers:[String]
    public var domains:[String]
    public init(id:UUID=UUID(),name:String,serviceID:String,servers:[String],domains:[String]) {
        self.id=id;self.name=name;self.serviceID=serviceID;self.servers=servers;self.domains=domains
    }
    public static func normalize(_ values:[Self]) throws -> [Self] {
        guard values.count<=32,Set(values.map(\.id)).count==values.count else {throw ProxyError("公司网络 DNS 配置过多或标识重复")}
        return try values.map {raw in
            var value=raw
            value.name=value.name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !value.name.isEmpty,value.name.utf8.count<=200,!value.serviceID.isEmpty,value.serviceID.utf8.count<=200,!value.servers.isEmpty,value.servers.count<=16 else {throw ProxyError("公司网络名称、服务或 DNS 地址无效")}
            value.servers=try Array(Set(value.servers.map {server in
                let canonical=try NetworkBypassPolicy.canonicalCIDR(server)
                guard !server.contains("/"),canonical.hasSuffix(server.contains(":") ? "/128":"/32") else {throw ProxyError("公司 DNS 必须是单个 IP 地址")}
                return String(canonical.split(separator:"/")[0])
            })).sorted()
            value.domains=try ProtectedDomainPolicy.normalize(value.domains)
            guard !value.domains.isEmpty,value.domains.count<=100 else {throw ProxyError("请指定公司 DNS 适用的企业域名")}
            return value
        }
    }
    public func matches(_ resolver:DNSResolverScope,primary:String,domain:String)->Bool {
        resolver.interface==primary && !CapturePlan.isVPN(primary) && primary != "lo0" && resolver.service==serviceID && !resolver.servers.isEmpty && Set(resolver.servers).isSubset(of:Set(servers)) && domains.contains{domain==$0 || domain.hasSuffix("."+$0)}
    }
    // 只读取当前主物理服务公布的原始 DNS，不采纳汐航或其他隧道的补充解析器。
    public static func current(domains:[String]) throws -> Self {
        guard let store=SCDynamicStoreCreate(nil,"汐航公司 DNS 识别" as CFString,nil,nil),
              let global=SCDynamicStoreCopyValue(store,"State:/Network/Global/IPv4" as CFString) as? [String:Any],
              let service=global["PrimaryService"] as? String,let interface=global["PrimaryInterface"] as? String,
              let network=BypassNetworkService.read().first(where:{$0.id==service && $0.active && $0.interface==interface}),
              !CapturePlan.isVPN(interface),interface != "lo0",
              let dns=SCDynamicStoreCopyValue(store,("State:/Network/Service/"+service+"/DNS") as CFString) as? [String:Any],let servers=dns["ServerAddresses"] as? [String] else {throw ProxyError("当前主物理网络 DNS 无法识别，请连接公司网络后重试")}
        return try normalize([Self(name:"公司网络（"+network.name+"）",serviceID:service,servers:servers,domains:domains)])[0]
    }
}

public enum CorporateDNSRouteError:Error,LocalizedError,Equatable {
    case unavailable,conflict,notProtected
    public var errorDescription:String? {
        switch self {
        case .unavailable:return "答案地址的原访问出口无法确认"
        case .conflict:return "答案地址存在同优先级出口冲突"
        case .notProtected:return "答案地址不在已批准的绕过或公司内网范围"
        }
    }
}
