import Foundation
import Darwin
import CryptoKit

public enum BypassTargetKind:String,Codable,CaseIterable,Sendable {
    case domain,suffix,cidr
    public var label:String {switch self {case .domain:return "精确域名";case .suffix:return "域名及子域";case .cidr:return "IP / 网段"}}
}
public enum BypassExit:String,Codable,CaseIterable,Sendable {case system,pinned}
public struct NetworkBypass:Codable,Identifiable,Equatable,Sendable {
    public var legacyProtection:Bool?
    public var id:UUID
    public var kind:BypassTargetKind
    public var value:String
    public var note:String
    public var enabled:Bool
    public var exit:BypassExit
    public var serviceID:String?
    public var gateway:String?
    public init(id:UUID=UUID(),kind:BypassTargetKind,value:String,note:String="",enabled:Bool=true,exit:BypassExit = .system,serviceID:String?=nil,gateway:String?=nil) {
        self.id=id;self.kind=kind;self.value=value;self.note=note;self.enabled=enabled;self.exit=exit;self.serviceID=serviceID;self.gateway=gateway
    }
    public var rule:RoutingRule {RoutingRule(kind:kind == .cidr ? .cidr:kind == .domain ? .domain:.suffix,value:value,action:.direct)}
    public func normalized() throws -> Self {
        var item=self
        item.value=value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if kind == .cidr {item.value=try NetworkBypassPolicy.canonicalCIDR(item.value)}
        else {item.value=try ProtectedDomainPolicy.normalize([item.value])[0]}
        guard note.utf8.count<=2048 else {throw ProxyError("绕过备注不能超过 2048 字节")}
        if exit == .pinned {
            guard kind == .cidr,let serviceID,!serviceID.isEmpty,serviceID.utf8.count<=200,let gateway else {throw ProxyError("指定出口仅支持 IP/网段，且必须选择网络服务及网关")}
            let normalizedGateway=try NetworkBypassPolicy.canonicalCIDR(gateway)
            guard !gateway.contains("/"),gateway.contains(":")==item.value.contains(":"),normalizedGateway.hasSuffix(gateway.contains(":") ? "/128":"/32") else {throw ProxyError("网关必须是同地址族的 IP 地址")}
            item.gateway=String(normalizedGateway.split(separator:"/")[0])
        } else {item.serviceID=nil;item.gateway=nil}
        return item
    }
    public func matches(host:String,ip:String?=nil)->Bool {RuleEvaluator.matches(rule,host:host.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:".")),ip:ip)==true}
    public var proxyExceptions:[String] {
        switch kind {
        case .domain:return [value]
        case .suffix:return [value,"*."+value]
        case .cidr:
            let parts=value.split(separator:"/")
            return [parts.count==1 || parts.last==Substring(value.contains(":") ? "128":"32") ? String(parts[0]):value]
        }
    }
}
public struct BypassInputIssue:Identifiable,Sendable {public var id:Int {line};public let line:Int;public let message:String}
public struct BypassInputResult:Sendable {
    public var items:[NetworkBypass]=[]
    public var issues:[BypassInputIssue]=[]
    public var warnings:[String]=[]
}
public enum NetworkBypassPolicy {
    public static func canonicalCIDR(_ input:String) throws -> String {
        try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:input,action:.direct))
        let parts=input.split(separator:"/"),ipv6=input.contains(":")
        let prefix=parts.count==2 ? Int(parts[1])!:(ipv6 ? 128:32)
        guard prefix>1 else {throw ProxyError("绕过网段不能覆盖公网默认路由")}
        var bytes=[UInt8](repeating:0,count:16)
        let family=ipv6 ? AF_INET6:AF_INET
        _=String(parts[0]).withCString{inet_pton(family,$0,&bytes)}
        for bit in prefix..<(ipv6 ? 128:32) {bytes[bit/8] &= ~(1 << (7-bit%8))}
        var buffer=[CChar](repeating:0,count:Int(INET6_ADDRSTRLEN))
        _=inet_ntop(family,&bytes,&buffer,socklen_t(buffer.count))
        return String(cString:buffer)+"/"+String(prefix)
    }
    public static func normalize(_ items:[NetworkBypass]) throws -> [NetworkBypass] {
        guard items.count<=5000,Set(items.map(\.id)).count==items.count else {throw ProxyError("绕过项超过 5000 条或标识重复")}
        let normalized=try items.map{try $0.normalized()}
        var seen=Set<String>()
        for item in normalized {
            guard seen.insert(item.kind.rawValue+":"+item.value).inserted else {throw ProxyError("重复绕过项："+item.value)}
        }
        let pinned=normalized.filter{$0.enabled && $0.exit == .pinned}
        for (index,item) in pinned.enumerated() {
            for other in pinned.dropFirst(index+1) where item.value.contains(":")==other.value.contains(":") && (item.matches(host:String(other.value.split(separator:"/")[0]),ip:String(other.value.split(separator:"/")[0])) || other.matches(host:String(item.value.split(separator:"/")[0]),ip:String(item.value.split(separator:"/")[0]))) {
                guard item.serviceID==other.serviceID,item.gateway==other.gateway else {throw ProxyError("重叠网段指定了不同出口："+item.value+"、"+other.value)}
            }
        }
        return normalized
    }
    public static func migrate(domains:[String],cidrs:[String])->[NetworkBypass] {
        var seen=Set<String>()
        return (domains.map{NetworkBypass(kind:.suffix,value:$0)}+cidrs.map{NetworkBypass(kind:.cidr,value:$0)}).compactMap {raw in
            var item=(try? raw.normalized()) ?? raw
            item.legacyProtection=true
            let key=item.kind.rawValue+":"+item.value
            guard seen.insert(key).inserted else{return nil}
            // 使用内容生成稳定标识，旧配置反复读取和草稿比较不会发生漂移。
            let hex=SHA256.hash(data:Data(key.utf8)).prefix(16).map{String(format:"%02x",$0)}.joined()
            let chars=Array(hex);let uuid=[String(chars[0..<8]),String(chars[8..<12]),String(chars[12..<16]),String(chars[16..<20]),String(chars[20..<32])].joined(separator:"-")
            item.id=UUID(uuidString:uuid)!
            return item
        }
    }
    public static func parse(_ text:String,existing:[NetworkBypass]=[]) -> BypassInputResult {
        var result=BypassInputResult()
        guard text.utf8.count<=2*1024*1024 else {result.issues=[BypassInputIssue(line:1,message:"批量文本超过 2 MiB")];return result}
        var keys=Set(existing.map{$0.kind.rawValue+":"+$0.value})
        for (offset,line) in text.components(separatedBy:.newlines).enumerated() {
            for raw in line.components(separatedBy:",") {
                let input=raw.trimmingCharacters(in:.whitespacesAndNewlines)
                if input.isEmpty || input.hasPrefix("#") {continue}
                do {
                    guard result.items.count+existing.count<5000 else {throw ProxyError("绕过项超过 5000 条")}
                    let kind:BypassTargetKind=input.hasPrefix("*.") ? .suffix:((try? ConfigBuilder.validate(RoutingRule(kind:.cidr,value:input,action:.direct))) != nil ? .cidr:.domain)
                    let item=try NetworkBypass(kind:kind,value:input.hasPrefix("*.") ? String(input.dropFirst(2)):input).normalized()
                    guard keys.insert(item.kind.rawValue+":"+item.value).inserted else {result.warnings.append("第 \(offset+1) 行重复，已跳过："+item.value);continue}
                    result.items.append(item)
                } catch {result.issues.append(BypassInputIssue(line:offset+1,message:input+"："+error.localizedDescription));if result.issues.count>=100 {return result}}
            }
        }
        result.warnings += coverageWarnings(existing+result.items)
        return result
    }
    public static func coverageWarnings(_ items:[NetworkBypass])->[String] {
        let active=items.filter(\.enabled)
        var warnings:[String]=[]
        let covering=active.filter{$0.kind == .suffix || $0.kind == .cidr}
        for item in active {
            if let other=covering.first(where:{$0.id != item.id && $0.exit==item.exit && $0.serviceID==item.serviceID && $0.gateway==item.gateway && ($0.kind == .suffix && item.kind != .cidr || $0.kind == .cidr && item.kind == .cidr && (Int($0.value.split(separator:"/").last ?? "129") ?? 129)<=(Int(item.value.split(separator:"/").last ?? "0") ?? 0)) && $0.matches(host:String(item.value.split(separator:"/")[0]),ip:item.kind == .cidr ? String(item.value.split(separator:"/")[0]):nil)}) {
                warnings.append(item.value+" 已被 "+other.value+" 覆盖（保留原项）")
            }
            if warnings.count>=100 {break}
        }
        return warnings
    }
    public static func convert(_ rule:RoutingRule) throws -> NetworkBypass {
        guard (rule.target ?? (rule.action == .direct ? .direct:.selected)) == .direct,[RuleKind.domain,.suffix,.cidr].contains(rule.kind) else {throw ProxyError("仅精确域名、域名后缀和 IP 的普通直连规则可转为绕过")}
        return try NetworkBypass(id:rule.id,kind:rule.kind == .cidr ? .cidr:rule.kind == .suffix ? .suffix:.domain,value:rule.value).normalized()
    }
}
extension AppState {
    public var effectiveBypasses:[NetworkBypass] {networkBypasses ?? NetworkBypassPolicy.migrate(domains:protectedDomains,cidrs:tunExcludedCIDRs)}
    public var enabledBypasses:[NetworkBypass] {effectiveBypasses.filter(\.enabled)}
    public var bypassCIDRs:[String] {enabledBypasses.filter{$0.kind == .cidr}.map(\.value)}
    public var bypassDomains:[String] {enabledBypasses.filter{$0.kind == .suffix}.map(\.value)}
    public var bypassExactDomains:[String] {enabledBypasses.filter{$0.kind == .domain}.map(\.value)}
    public var pinnedBypasses:[NetworkBypass] {enabledBypasses.filter{$0.exit == .pinned}}
    public mutating func setBypasses(_ items:[NetworkBypass]) throws {
        networkBypasses=try NetworkBypassPolicy.normalize(items)
        // 旧字段只保留兼容镜像，新版本运行逻辑统一读取有效绕过项。
        protectedDomains=bypassDomains;tunExcludedCIDRs=bypassCIDRs
    }
    public var bypassProxyExceptions:[String] {Array(Set(enabledBypasses.flatMap(\.proxyExceptions))).sorted()}
}
