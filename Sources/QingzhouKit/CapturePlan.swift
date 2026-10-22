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
    public var unavailableDomains:[String]=[]
    public init(primaryInterface:String,routes:[ProtectedRoute],resolvers:[DNSResolverScope],proxies:Data=Data()) {
        self.primaryInterface=primaryInterface;self.routes=routes;self.resolvers=resolvers;self.proxies=proxies
    }
    private enum CodingKeys:String,CodingKey {case primaryInterface,routes,resolvers,proxies,unavailableDomains}
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        primaryInterface=try values.decode(String.self,forKey:.primaryInterface)
        routes=try values.decode([ProtectedRoute].self,forKey:.routes)
        resolvers=try values.decode([DNSResolverScope].self,forKey:.resolvers)
        proxies=try values.decode(Data.self,forKey:.proxies)
        unavailableDomains=try values.decodeIfPresent([String].self,forKey:.unavailableDomains) ?? []
    }
    public static func parseRoutes(_ table:String,includeTransient:Bool=false)->[ProtectedRoute] {
        var ipv6=false
        return table.components(separatedBy:.newlines).compactMap {line in
            if line=="Internet6:" {ipv6=true};if line=="Internet:" {ipv6=false}
            let fields=line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            guard fields.count>=4,let interface=fields.dropFirst(3).first(where:{$0.range(of:"^[a-z][a-z0-9]{0,15}$",options:.regularExpression) != nil}),let prefix=(fields[0]=="default" ? (ipv6 ? "::/0":"0.0.0.0/0"):TunAddressPlan.routePrefixes(line).first) else{return nil}
            // 保留 VPN 主机路由用于确认企业虚拟地址；物理公网缓存不参与规划。
            guard includeTransient || (!fields[2].contains("W") && !fields[2].contains("L")) || CapturePlan.isVPN(interface) else{return nil}
            // 链路路由可能显示链路索引、ARP 地址或本机地址，统一为接口直连身份。
            let index=if_nametoindex(interface)
            let gateway=(!fields[2].contains("G") && index>0) ? "link#"+String(index):fields[1]
            return ProtectedRoute(destination:prefix,gateway:gateway,interface:interface,scope:fields[2].contains("I") ? interface:nil)
        }
    }
    public static func read(store:SCDynamicStore,primary:String,routes:String,ownedDNSKey:String?=nil,ownedTunnel:String?=nil,structuredRoutes:[ProtectedRoute]?=nil,lookup:((String,Bool) throws -> String)?=nil) throws -> NetworkSnapshot {
        let keys=(SCDynamicStoreCopyKeyList(store,"State:/Network/Service/.*/DNS" as CFString) as? [String] ?? []).sorted()
        var resolvers:[DNSResolverScope]=[]
        var unavailableDomains:[String]=[]
        for key in keys where key != ownedDNSKey {
            let parts=key.components(separatedBy:"/");guard parts.count>=5 else{continue};let service=parts[3]
            guard let dns=SCDynamicStoreCopyValue(store,key as CFString) as? [String:Any],let servers=dns["ServerAddresses"] as? [String],!servers.isEmpty else{continue}
            let base="State:/Network/Service/"+service
            let ipv4=SCDynamicStoreCopyValue(store,(base+"/IPv4") as CFString) as? [String:Any]
            let ipv6=SCDynamicStoreCopyValue(store,(base+"/IPv6") as CFString) as? [String:Any]
            let index=(dns["InterfaceIndex"] as? NSNumber)?.uint32Value
            let indexed=index.flatMap {value -> String? in var buffer=[CChar](repeating:0,count:Int(IF_NAMESIZE));return if_indextoname(value,&buffer).map{String(cString:$0)}}
            let rawDomains=(dns["SupplementalMatchDomains"] as? [String] ?? [])+(dns["SearchDomains"] as? [String] ?? [])+((dns["DomainName"] as? String).map{[$0]} ?? [])
            let scopeDomains=rawDomains.filter{!$0.isEmpty && (try? ConfigBuilder.validate(RoutingRule(kind:.suffix,value:$0,action:.direct))) != nil}
            guard servers.allSatisfy({(try? ConfigBuilder.validate(RoutingRule(kind:.cidr,value:$0.components(separatedBy:"%")[0],action:.direct))) != nil}) else {unavailableDomains += scopeDomains;continue}
            var inferred:String?
            if ipv4?["InterfaceName"] == nil && ipv6?["InterfaceName"] == nil && indexed == nil {
                // 部分企业 VPN 只公布 DNS 服务；通过解析器实际路由确认接口，不猜测物理出口。
                var interfaces=Set<String>()
                for server in servers {
                    guard let info=try? (lookup?(server,server.contains(":")) ?? NetworkInspection.command("/sbin/route",NetworkInspection.routeArguments(.get,destination:server,ipv6:server.contains(":")))) else {continue}
                    if let row=info.components(separatedBy:.newlines).first(where:{$0.trimmingCharacters(in:.whitespaces).hasPrefix("interface:")}) {interfaces.insert(row.components(separatedBy:":").dropFirst().joined(separator:":").trimmingCharacters(in:.whitespaces))}
                }
                if interfaces.count==1 {inferred=interfaces.first}
            }
            guard let interface=(ipv4?["InterfaceName"] as? String) ?? (ipv6?["InterfaceName"] as? String) ?? indexed ?? inferred else{unavailableDomains += scopeDomains;continue}
            if interface==ownedTunnel {continue}
            let domains=(dns["SupplementalMatchDomains"] as? [String] ?? []).filter{!$0.isEmpty}.map{$0.lowercased()}
            var search=(dns["SearchDomains"] as? [String] ?? []).map{$0.lowercased()}
            if let domain=dns["DomainName"] as? String,!domain.isEmpty {search.append(domain.lowercased())}
            let validScope=Set(scopeDomains.map{$0.lowercased()})
            resolvers.append(DNSResolverScope(service:service,interface:interface,servers:servers,domains:domains.filter{validScope.contains($0)},searchDomains:search.filter{validScope.contains($0)},order:(dns["SearchOrder"] as? Int) ?? 200000,defaultResolver:(dns["SupplementalMatchDomains"] as? [String])?.contains("")==true || interface==primary))
        }
        guard resolvers.contains(where:{$0.interface==primary}) else{throw NetworkEnvironmentNotReady("原系统 DNS 无法完整读取，未接管网络")}
        let proxies=SCDynamicStoreCopyProxies(nil) as? [String:Any] ?? [:]
        var snapshot=NetworkSnapshot(primaryInterface:primary,routes:(structuredRoutes ?? parseRoutes(routes)).filter{$0.interface != ownedTunnel},resolvers:resolvers.sorted{$0.order == $1.order ? $0.service<$1.service:$0.order<$1.order},proxies:try PropertyListSerialization.data(fromPropertyList:proxies,format:.binary,options:0))
        snapshot.unavailableDomains=Array(Set(unavailableDomains)).sorted()
        return snapshot
    }
}
public struct CapturePlan:Codable,Equatable,Sendable {
    public static let localCIDRs=["127.0.0.0/8","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","fc00::/7","fe80::/10"]
    public var snapshot:NetworkSnapshot
    public var protectedRoutes:[ProtectedRoute]
    public var domains:[String]
    public var exclusions:[String]
    public var exactDomains:[String]?
    public var userDomainSuffixes:[String]?
    public var summary:[String] {protectedRoutes.map{$0.destination+" → "+$0.interface}+domains.map{$0+" → 原作用域 DNS"}}
    public static func isVPN(_ interface:String)->Bool {interface.hasPrefix("utun") || interface.hasPrefix("ppp") || interface.hasPrefix("ipsec")}
    // 原始快照保留全部作用域；核心按目的地址分流，只能使用已确认的单一出口。
    public static func effectiveRoutes(_ routes:[ProtectedRoute],resolvers:[DNSResolverScope]) throws -> [ProtectedRoute] {
        var groups:[[ProtectedRoute]]=[]
        for route in routes {
            if let index=groups.firstIndex(where:{NetworkInspection.samePrefix($0[0].destination,route.destination)}) {groups[index].append(route)}
            else {groups.append([route])}
        }
        var selected:[ProtectedRoute]=[]
        for group in groups {
            let global=group.filter{$0.scope==nil}
            let candidates=global.isEmpty ? group.filter {route in
                route.scope==route.interface && resolvers.contains{$0.interface==route.interface && !$0.protectedDomains.isEmpty}
            }:global
            var unique:[ProtectedRoute]=[]
            for route in candidates where !unique.contains(where:{$0.interface==route.interface && $0.gateway==route.gateway && $0.scope==route.scope}) {unique.append(route)}
            if unique.count>1 {
                // 只有作用域明确且出口唯一时才能发布为核心规则；歧义查询稍后单独拒绝。
                if global.isEmpty {continue}
                let detail=unique.map{$0.interface+"/"+$0.gateway+"/scope="+($0.scope ?? "global")}.sorted().joined(separator:"；")
                throw NetworkCaptureConflict("同一保护前缀有多个全局出口："+group[0].destination+"；"+detail)
            }
            if let route=unique.first {selected.append(route)}
        }
        return selected.sorted {
            let left=Int($0.destination.split(separator:"/").last ?? "0") ?? 0,right=Int($1.destination.split(separator:"/").last ?? "0") ?? 0
            return left==right ? $0.destination<$1.destination:left>right
        }
    }
    public static func make(snapshot:NetworkSnapshot,extraCIDRs:[String],extraDomains:[String]) throws -> CapturePlan {
        guard !snapshot.primaryInterface.isEmpty,!snapshot.resolvers.isEmpty else{throw ProxyError("原网络快照不完整")}
        for cidr in extraCIDRs {try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:cidr,action:.direct));guard Int(cidr.split(separator:"/").last ?? "0").map({$0>1})==true else{throw ProxyError("保护网段不能覆盖公网默认路由")}}
        for domain in extraDomains {try ConfigBuilder.validate(RoutingRule(kind:.suffix,value:domain,action:.direct))}
        let routes=snapshot.routes.filter {route in
            !route.destination.hasPrefix("fe80:") && !route.destination.hasPrefix("ff") && !(route.destination=="::/0" && route.scope != nil && route.gateway.hasPrefix("fe80:")) && (Self.isVPN(route.interface) || Self.localCIDRs.contains{cidr in RuleEvaluator.matches(RoutingRule(kind:.cidr,value:cidr,action:.direct),host:route.destination.components(separatedBy:"/")[0],ip:route.destination.components(separatedBy:"/")[0])==true})
        }
        for route in routes where Self.isVPN(route.interface) {
            let bits=Int(route.destination.split(separator:"/").last ?? "0") ?? 0
            guard bits>(route.ipv6 ? 3:8) || (!route.ipv6 && route.destination.hasPrefix("10.")) else{throw NetworkCaptureConflict("企业隧道正在接管公网大范围路由，无法安全兼容")}
        }
        // 已被同接口企业网段覆盖的主机缓存不增加保护项，避免每次业务连接触发重连。
        let stableRoutes=routes.filter {route in
            let bits=Int(route.destination.split(separator:"/").last ?? "0") ?? 0
            guard bits==(route.ipv6 ? 128:32),Self.isVPN(route.interface) else {return true}
            let address=String(route.destination.split(separator:"/")[0])
            return !routes.contains {other in
                other.interface==route.interface && other.scope==route.scope && (Int(other.destination.split(separator:"/").last ?? "0") ?? 0)<bits && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:other.destination,action:.direct),host:address,ip:address)==true
            }
        }
        let autoDomains=snapshot.resolvers.flatMap(\.protectedDomains)+snapshot.unavailableDomains
        return CapturePlan(snapshot:snapshot,protectedRoutes:try effectiveRoutes(stableRoutes,resolvers:snapshot.resolvers),domains:Array(Set(autoDomains+extraDomains)).map{$0.lowercased()}.sorted(),exclusions:Array(Set(Self.localCIDRs+extraCIDRs)).sorted())
    }
    public static func make(snapshot:NetworkSnapshot,state:AppState,pinned:[ProtectedRoute]=[]) throws -> CapturePlan {
        var plan=try make(snapshot:snapshot,extraCIDRs:state.bypassCIDRs,extraDomains:state.bypassDomains)
        plan.exactDomains=state.bypassExactDomains;plan.userDomainSuffixes=state.enabledBypasses.filter{$0.kind == .suffix && $0.legacyProtection != true}.map(\.value)
        for item in state.enabledBypasses where item.kind == .cidr {
            if item.value.hasPrefix("ff") {continue}
            let address=String(item.value.split(separator:"/")[0])
            let path:ProtectedRoute?
            if item.exit == .pinned {path=pinned.first{NetworkInspection.samePrefix($0.destination,item.value)}}
            else {path=plan.originalRoute(for:address)}
            if item.exit == .system,item.value.contains(":"),path==nil {continue}
            guard let path else {throw NetworkEnvironmentNotReady("绕过目标的原出口无法确认："+item.value)}
            let route=ProtectedRoute(destination:item.value,gateway:path.gateway,interface:path.interface,source:"用户网络绕过")
            if let previous=plan.protectedRoutes.first(where:{NetworkInspection.samePrefix($0.destination,item.value)}) {
                guard previous.gateway==route.gateway,previous.interface==route.interface else {throw NetworkCaptureConflict("绕过项与原保护出口冲突："+item.value)}
            } else {plan.protectedRoutes.append(route)}
        }
        plan.protectedRoutes=try effectiveRoutes(plan.protectedRoutes,resolvers:snapshot.resolvers)
        return plan
    }
    public func protects(_ domain:String)->Bool {
        let name=domain.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
        return (exactDomains ?? []).contains(name) || !name.contains(".") || domains.contains{name==$0 || name.hasSuffix("."+$0)}
    }
    public func originalRoute(for address:String)->ProtectedRoute? {
        snapshot.routes.filter{$0.scope==nil && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:$0.destination,action:.direct),host:address,ip:address)==true}.max{(Int($0.destination.split(separator:"/").last ?? "0") ?? 0)<(Int($1.destination.split(separator:"/").last ?? "0") ?? 0)}
    }
    public func domainRoute(address:String,resolver:DNSResolverScope,host:String?=nil) throws -> ProtectedRoute {
        let loopback=["127.0.0.0/8","::1/128"].contains{RuleEvaluator.matches(RoutingRule(kind:.cidr,value:$0,action:.direct),host:address,ip:address)==true}
        let candidates=snapshot.routes.filter{($0.interface==resolver.interface || (loopback && $0.interface=="lo0")) && RuleEvaluator.matches(RoutingRule(kind:.cidr,value:$0.destination,action:.direct),host:address,ip:address)==true}
        let longest=candidates.compactMap{Int($0.destination.split(separator:"/").last ?? "0")}.max()
        let best=candidates.filter{Int($0.destination.split(separator:"/").last ?? "0")==longest}
        let preferred=best.contains(where:{$0.scope==nil}) ? best.filter{$0.scope==nil}:best
        guard let original=preferred.first,preferred.allSatisfy({$0.gateway==original.gateway && $0.scope==original.scope}) else {throw ProxyError("保护域名解析地址的原路径无法确认，拒绝返回未保护地址")}
        // 原物理网卡的局域网及回环同样需要保留，不能因为不是 VPN 而误拒绝本地设备。
        let local=Self.localCIDRs.contains{RuleEvaluator.matches(RoutingRule(kind:.cidr,value:$0,action:.direct),host:address,ip:address)==true}
        let effective=protectedRoutes.first{RuleEvaluator.matches(RoutingRule(kind:.cidr,value:$0.destination,action:.direct),host:address,ip:address)==true}
        let explicit=host.map {name in (exactDomains ?? []).contains(name) || (userDomainSuffixes ?? []).contains{name==$0 || name.hasSuffix("."+$0)}} ?? false
        let userPhysical=original.interface==snapshot.primaryInterface && original.scope==nil && explicit
        guard loopback || userPhysical || (effective.map{$0.interface==original.interface && $0.gateway==original.gateway} ?? (local && original.interface==snapshot.primaryInterface && original.scope==nil)) else {throw ProxyError("企业解析地址与已确认的核心出口不一致，拒绝返回未保护地址")}
        guard userPhysical || Self.isVPN(original.interface) || local || (loopback && original.interface=="lo0") else {throw ProxyError("企业解析地址的原 VPN 路径无法确认，拒绝返回未保护地址")}
        return ProtectedRoute(destination:address+(address.contains(":") ? "/128":"/32"),gateway:original.gateway,interface:original.interface,source:"企业域名动态保护")
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
            // 企业 VPN 离线时保留域名保护，只拒绝该域名的查询，不阻止普通代理连接。
            if domains.contains(where:{name==$0 || name.hasSuffix("."+$0)}) {return []}
        }
        let defaults=snapshot.resolvers.filter{$0.defaultResolver};return defaults.isEmpty ? snapshot.resolvers.filter{$0.interface==snapshot.primaryInterface}:defaults
    }
}
