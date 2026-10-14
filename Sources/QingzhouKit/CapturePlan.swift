import Foundation
import SystemConfiguration
import Darwin

public struct ProtectedRoute:Codable,Equatable,Sendable {
    public var destination:String
    public var gateway:String
    public var interface:String
    public var scope:String?
    public var source:String
    public var ipv6:Bool {destination.contains(":")}
    public init(destination:String,gateway:String,interface:String,scope:String?=nil,source:String="企业路由") {
        self.destination=destination;self.gateway=gateway;self.interface=interface;self.scope=scope;self.source=source
    }
}
public struct DNSResolverScope:Codable,Equatable,Sendable {
    public var service:String
    public var interface:String
    public var servers:[String]
    public var domains:[String]
    public var searchDomains:[String]
    public var defaultResolver:Bool
    public var order:Int
    public init(service:String,interface:String,servers:[String],domains:[String]=[],searchDomains:[String]=[],order:Int=200000,defaultResolver:Bool=false) {
        self.service=service;self.interface=interface;self.servers=servers;self.domains=domains;self.searchDomains=searchDomains;self.order=order;self.defaultResolver=defaultResolver
    }
    public var protectedDomains:[String] {Array(Set(domains+searchDomains)).filter{!$0.isEmpty}.sorted()}
}
public struct NetworkSnapshot:Codable,Equatable,Sendable {
    public var primaryInterface:String
    public var routes:[ProtectedRoute]
    public var resolvers:[DNSResolverScope]
    public var proxies:Data
    public init(primaryInterface:String,routes:[ProtectedRoute],resolvers:[DNSResolverScope],proxies:Data=Data()) {
        self.primaryInterface=primaryInterface;self.routes=routes;self.resolvers=resolvers;self.proxies=proxies
    }
    public static func parseRoutes(_ table:String)->[ProtectedRoute] {
        var ipv6=false
        return table.components(separatedBy:.newlines).compactMap {line in
            if line=="Internet6:" {ipv6=true};if line=="Internet:" {ipv6=false}
            let fields=line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            guard fields.count>=4,let interface=fields.dropFirst(3).first(where:{$0.range(of:"^[a-z][a-z0-9]{0,15}$",options:.regularExpression) != nil}),let prefix=(fields[0]=="default" ? (ipv6 ? "::/0":"0.0.0.0/0"):TunAddressPlan.routePrefixes(line).first) else{return nil}
            // 缓存主机路由不参与持久规划，避免普通公网连接缓存改变保护集合。
            guard !fields[2].contains("W"),!fields[2].contains("L") else{return nil}
            return ProtectedRoute(destination:prefix,gateway:fields[1],interface:interface,scope:fields[2].contains("I") ? interface:nil)
        }
    }
    public static func read(store:SCDynamicStore,primary:String,routes:String,ownedDNSKey:String?=nil,ownedTunnel:String?=nil) throws -> NetworkSnapshot {
        let keys=(SCDynamicStoreCopyKeyList(store,"State:/Network/Service/.*/DNS" as CFString) as? [String] ?? []).sorted()
        var resolvers:[DNSResolverScope]=[]
        for key in keys where key != ownedDNSKey {
            let parts=key.components(separatedBy:"/");guard parts.count>=5 else{continue};let service=parts[3]
            guard let dns=SCDynamicStoreCopyValue(store,key as CFString) as? [String:Any],let servers=dns["ServerAddresses"] as? [String],!servers.isEmpty else{continue}
            let base="State:/Network/Service/"+service
            let ipv4=SCDynamicStoreCopyValue(store,(base+"/IPv4") as CFString) as? [String:Any]
            let ipv6=SCDynamicStoreCopyValue(store,(base+"/IPv6") as CFString) as? [String:Any]
            let index=(dns["InterfaceIndex"] as? NSNumber)?.uint32Value
            let indexed=index.flatMap {value -> String? in var buffer=[CChar](repeating:0,count:Int(IF_NAMESIZE));return if_indextoname(value,&buffer).map{String(cString:$0)}}
            for server in servers {try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:server.components(separatedBy:"%")[0],action:.direct))}
            var inferred:String?
            if ipv4?["InterfaceName"] == nil && ipv6?["InterfaceName"] == nil && indexed == nil {
                // 部分企业 VPN 只公布 DNS 服务；通过解析器实际路由确认接口，不猜测物理出口。
                var interfaces=Set<String>()
                for server in servers {
                    let info=try NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.get,destination:server,ipv6:server.contains(":")))
                    if let row=info.components(separatedBy:.newlines).first(where:{$0.trimmingCharacters(in:.whitespaces).hasPrefix("interface:")}) {interfaces.insert(row.components(separatedBy:":").dropFirst().joined(separator:":").trimmingCharacters(in:.whitespaces))}
                }
                guard interfaces.count==1 else{throw ProxyError("DNS 服务接口无法确认，未接管网络")};inferred=interfaces.first
            }
            guard let interface=(ipv4?["InterfaceName"] as? String) ?? (ipv6?["InterfaceName"] as? String) ?? indexed ?? inferred else{throw ProxyError("DNS 服务接口无法确认，未接管网络")}
            if interface==ownedTunnel {continue}
            let domains=(dns["SupplementalMatchDomains"] as? [String] ?? []).filter{!$0.isEmpty}.map{$0.lowercased()}
            var search=(dns["SearchDomains"] as? [String] ?? []).map{$0.lowercased()}
            if let domain=dns["DomainName"] as? String,!domain.isEmpty {search.append(domain.lowercased())}
            for domain in domains+search {try ConfigBuilder.validate(RoutingRule(kind:.suffix,value:domain,action:.direct))}
            resolvers.append(DNSResolverScope(service:service,interface:interface,servers:servers,domains:domains,searchDomains:search,order:(dns["SearchOrder"] as? Int) ?? 200000,defaultResolver:(dns["SupplementalMatchDomains"] as? [String])?.contains("")==true || interface==primary))
        }
        guard resolvers.contains(where:{$0.interface==primary}) else{throw ProxyError("原系统 DNS 无法完整读取，未接管网络")}
        let proxies=SCDynamicStoreCopyProxies(nil) as? [String:Any] ?? [:]
        return NetworkSnapshot(primaryInterface:primary,routes:parseRoutes(routes).filter{$0.interface != ownedTunnel},resolvers:resolvers.sorted{$0.order == $1.order ? $0.service<$1.service:$0.order<$1.order},proxies:try PropertyListSerialization.data(fromPropertyList:proxies,format:.binary,options:0))
    }
}
public struct CapturePlan:Codable,Equatable,Sendable {
    public static let localCIDRs=["127.0.0.0/8","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","fc00::/7","fe80::/10"]
    public var snapshot:NetworkSnapshot
    public var protectedRoutes:[ProtectedRoute]
    public var domains:[String]
    public var exclusions:[String]
    public var summary:[String] {protectedRoutes.map{$0.destination+" → "+$0.interface}+domains.map{$0+" → 原作用域 DNS"}}
    public static func isVPN(_ interface:String)->Bool {interface.hasPrefix("utun") || interface.hasPrefix("ppp") || interface.hasPrefix("ipsec")}
    public static func make(snapshot:NetworkSnapshot,extraCIDRs:[String],extraDomains:[String]) throws -> CapturePlan {
        guard !snapshot.primaryInterface.isEmpty,!snapshot.resolvers.isEmpty else{throw ProxyError("原网络快照不完整")}
        for cidr in extraCIDRs {try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:cidr,action:.direct));guard Int(cidr.split(separator:"/").last ?? "0").map({$0>1})==true else{throw ProxyError("保护网段不能覆盖公网默认路由")}}
        for domain in extraDomains {try ConfigBuilder.validate(RoutingRule(kind:.suffix,value:domain,action:.direct))}
        let routes=snapshot.routes.filter {route in
            !route.destination.hasPrefix("fe80:") && !route.destination.hasPrefix("ff") && !(route.destination=="::/0" && route.scope != nil && route.gateway.hasPrefix("fe80:")) && (Self.isVPN(route.interface) || Self.localCIDRs.contains{cidr in RuleEvaluator.matches(RoutingRule(kind:.cidr,value:cidr,action:.direct),host:route.destination.components(separatedBy:"/")[0],ip:route.destination.components(separatedBy:"/")[0])==true})
        }
        for route in routes where Self.isVPN(route.interface) {
            let bits=Int(route.destination.split(separator:"/").last ?? "0") ?? 0
            guard bits>(route.ipv6 ? 3:8) || (!route.ipv6 && route.destination.hasPrefix("10.")) else{throw ProxyError("企业隧道正在接管公网大范围路由，无法安全兼容")}
        }
        let autoDomains=snapshot.resolvers.flatMap(\.protectedDomains)
        guard extraDomains.isEmpty || snapshot.resolvers.contains(where:{Self.isVPN($0.interface)}) else{throw ProxyError("补充内网域名需要可识别的企业 DNS 接口")}
        return CapturePlan(snapshot:snapshot,protectedRoutes:routes.sorted{(Int($0.destination.split(separator:"/").last ?? "0") ?? 0)>(Int($1.destination.split(separator:"/").last ?? "0") ?? 0)},domains:Array(Set(autoDomains+extraDomains)).map{$0.lowercased()}.sorted(),exclusions:Array(Set(Self.localCIDRs+extraCIDRs)).sorted())
    }
    public func originalInterface(for address:String)->String {
        let matches=snapshot.routes.filter{$0.scope==nil && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:$0.destination,action:.direct),host:address,ip:address)==true}
        return matches.max{(Int($0.destination.split(separator:"/").last ?? "0") ?? 0)<(Int($1.destination.split(separator:"/").last ?? "0") ?? 0)}?.interface ?? snapshot.primaryInterface
    }
    public func nodeInterfaces(_ addresses:[String:[String]],family:AddressFamilyPolicy) throws -> [String:String] {
        var result:[String:String]=[:]
        for (host,values) in addresses {
            let selected=values.filter{family != .ipv4Only || !$0.contains(":")}
            let interfaces=Set(selected.map{originalInterface(for:$0)})
            guard interfaces.count==1 else{throw ProxyError("节点原出口不唯一或没有可用地址，未接管网络")};result[host]=interfaces.first
        }
        return result
    }
    public func resolvers(for domain:String)->[DNSResolverScope] {
        let name=domain.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
        func suffixes(_ resolver:DNSResolverScope)->[String] {(resolver.domains+resolver.searchDomains).map{$0.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))}.filter{!$0.isEmpty}}
        let matches=snapshot.resolvers.filter{suffixes($0).contains{name==$0 || name.hasSuffix("."+$0)}}
        if !matches.isEmpty {
            let length=matches.flatMap{suffixes($0)}.filter{name==$0 || name.hasSuffix("."+$0)}.map(\.count).max() ?? 0
            return matches.filter{suffixes($0).contains{$0.count==length && (name==$0 || name.hasSuffix("."+$0))}}.sorted{$0.order<$1.order}
        }
        if domains.contains(where:{name==$0 || name.hasSuffix("."+$0)}) || !name.contains(".") {
            // 未匹配到明确作用域时只选择最高优先级企业解析器，不向所有 VPN 广播。
            let corporate=snapshot.resolvers.filter{Self.isVPN($0.interface)}.sorted{$0.order<$1.order}
            if let first=corporate.first {return [first]}
        }
        let defaults=snapshot.resolvers.filter{$0.defaultResolver};return defaults.isEmpty ? snapshot.resolvers.filter{$0.interface==snapshot.primaryInterface}:defaults
    }
}
