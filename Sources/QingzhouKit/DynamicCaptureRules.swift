import Foundation
import Darwin

// 核心的配置更新接口不执行重载，使用其实际支持的本地规则集监视能力。
public final class DynamicCaptureRules {
    public let directory:URL
    public let interfaces:[String]
    private var contents:[String:Data]=[:]
    public init(directory:URL,plan:CapturePlan) throws {
        self.directory=directory
        var reserved=(0..<64).map{"utun"+String($0)}
        reserved += (0..<8).map{"ppp"+String($0)}
        reserved += (0..<8).map{"ipsec"+String($0)}
        reserved += plan.protectedRoutes.map(\.interface)+plan.snapshot.resolvers.map(\.interface)
        interfaces=Array(Set(reserved+[plan.snapshot.primaryInterface,"lo0"])).sorted()
        try update(plan)
    }
    public func supports(_ plan:CapturePlan)->Bool {
        Set(plan.protectedRoutes.map(\.interface)+plan.snapshot.resolvers.map(\.interface)).isSubset(of:Set(interfaces))
    }
    private func write(_ name:String,rules:[[String:Any]]) throws {
        let data=try JSONSerialization.data(withJSONObject:["version":3,"rules":rules],options:[.sortedKeys])
        if contents[name]==data {return}
        try SecureFile.write(data,to:directory.appendingPathComponent(name+".json"));contents[name]=data
    }
    public func stageDomains(_ domains:[String],exact:[String]=[]) throws {
        var rules:[[String:Any]]=[]
        if !domains.isEmpty {rules.append(["domain_suffix":domains])}
        if !exact.isEmpty {rules.append(["domain":exact])}
        try write("domains",rules:rules)
    }
    public func update(_ plan:CapturePlan) throws {
        guard supports(plan) else {throw NetworkEnvironmentNotReady("新接口需要重新配置核心")}
        // 先准备出口规则，再公布域名；断开的历史域名由调用方保留为拒绝解析。
        let partition=try Self.partitionRoutes(plan.protectedRoutes)
        for interface in interfaces {
            let cidrs=partition[interface] ?? []
            try write("interface-"+interface,rules:cidrs.isEmpty ? []:[["ip_cidr":cidrs]])
        }
        try stageDomains(plan.domains,exact:plan.exactDomains ?? [])
    }
    // 按最长前缀将不同接口的网段切成互不重叠集合，规则集排列顺序不改变出口。
    public static func partitionRoutes(_ routes:[ProtectedRoute]) throws -> [String:[String]] {
        func bits(_ cidr:String)->[UInt8] {
            let parts=cidr.split(separator:"/");let family=cidr.contains(":") ? AF_INET6:AF_INET
            var bytes=[UInt8](repeating:0,count:16)
            _=String(parts[0]).withCString{inet_pton(family,$0,&bytes)}
            return (0..<(Int(parts[1]) ?? 0)).map{(bytes[$0/8] >> (7-$0%8)) & 1}
        }
        func cidr(_ prefix:[UInt8],ipv6:Bool)->String {
            var bytes=[UInt8](repeating:0,count:16)
            for (index,bit) in prefix.enumerated() {bytes[index/8] |= bit << (7-index%8)}
            var buffer=[CChar](repeating:0,count:Int(INET6_ADDRSTRLEN))
            _=inet_ntop(ipv6 ? AF_INET6:AF_INET,&bytes,&buffer,socklen_t(buffer.count))
            return String(cString:buffer)+"/"+String(prefix.count)
        }
        var result:[String:[String]]=[:]
        for route in routes {
            let original=bits(route.destination)
            var pieces=[original]
            for other in routes where other.interface != route.interface && other.ipv6==route.ipv6 {
                let excluded=bits(other.destination)
                if excluded==original {throw ProxyError("同一保护前缀有多个企业出口："+route.destination)}
                guard excluded.count>original.count,excluded.starts(with:original) else {continue}
                var next:[[UInt8]]=[]
                for piece in pieces {
                    if excluded.starts(with:piece) {
                        var common=piece
                        while common.count<excluded.count {
                            next.append(common+[1-excluded[common.count]])
                            common.append(excluded[common.count])
                        }
                    } else if !piece.starts(with:excluded) {next.append(piece)}
                }
                pieces=next
                guard pieces.count<=4096 else {throw ProxyError("企业网段拆分超过上限")}
            }
            result[route.interface,default:[]] += pieces.map{cidr($0,ipv6:route.ipv6)}
        }
        return result.mapValues{Array(Set($0)).sorted()}
    }
    public func apply(to object:inout [String:Any],plan:CapturePlan) {
        var route=object["route"] as! [String:Any]
        var sets=route["rule_set"] as? [[String:Any]] ?? []
        for name in ["domains"]+interfaces.map({"interface-"+$0}) {
            sets.append(["type":"local","tag":"qingzhou-"+name,"format":"source","path":directory.appendingPathComponent(name+".json").path])
        }
        route["rule_set"]=sets
        var rules=route["rules"] as! [[String:Any]]
        // 用动态规则集替换静态保护规则，普通分流和现有连接不重建。
        rules.removeAll {item in
            if (item["domain_suffix"] as? [String] == plan.domains || (plan.exactDomains != nil && item["domain"] as? [String] == plan.exactDomains)),let action=item["action"] as? String,["resolve","reject"].contains(action) {return true}
            if let outbound=item["outbound"] as? String,outbound.hasPrefix("protected-"),outbound != "protected-lo0",item["ip_cidr"] as? [String] != plan.exclusions {return true}
            return false
        }
        let leading=rules.prefix{["sniff","hijack-dns"].contains($0["action"] as? String ?? "")}.count
        var dynamic:[[String:Any]]=[["rule_set":["qingzhou-domains"],"action":"resolve","server":"local","strategy":"","disable_cache":true]]
        dynamic += interfaces.map{["rule_set":["qingzhou-interface-"+$0],"action":"route","outbound":"protected-"+$0]}
        for (key,values) in [("domain_suffix",plan.userDomainSuffixes ?? []),("domain",plan.exactDomains ?? [])] where !values.isEmpty {dynamic.append([key:values,"action":"route","outbound":"protected-"+plan.snapshot.primaryInterface])}
        dynamic.append(["rule_set":["qingzhou-domains"],"action":"reject"])
        rules.insert(contentsOf:dynamic,at:leading);route["rules"]=rules;object["route"]=route
        var outbounds=object["outbounds"] as! [[String:Any]]
        let existing=Set(outbounds.compactMap{$0["tag"] as? String})
        for interface in interfaces where !existing.contains("protected-"+interface) {
            outbounds.append(["type":"direct","tag":"protected-"+interface,"bind_interface":interface,"domain_resolver":["server":"local","strategy":""]])
        }
        object["outbounds"]=outbounds
        var dns=object["dns"] as! [String:Any];var dnsRules=dns["rules"] as! [[String:Any]]
        if let index=dnsRules.firstIndex(where:{$0["domain_suffix"] as? [String] == plan.domains && $0["server"] as? String == "local"}) {dnsRules.remove(at:index)}
        dnsRules.insert(["rule_set":["qingzhou-domains"],"action":"route","server":"local","strategy":"","disable_cache":true],at:0)
        dns["rules"]=dnsRules;object["dns"]=dns
    }
}

// 事件必须得到两次一致采样；持续抖动满十秒后保留公网连接并暂停企业解析。
public struct CaptureChangeWindow {
    private var candidate:CapturePlan?
    private var since:TimeInterval=0
    private var began:TimeInterval?
    public init(){}
    public mutating func reset(){candidate=nil;began=nil}
    public mutating func observe(_ plan:CapturePlan,now:TimeInterval)->Bool {
        if began==nil {began=now}
        let same=candidate.map{$0.snapshot.primaryInterface==plan.snapshot.primaryInterface && $0.snapshot.resolvers==plan.snapshot.resolvers && $0.protectedRoutes==plan.protectedRoutes && $0.domains==plan.domains && $0.snapshot.routes.filter{$0.destination.hasSuffix("/0")}==plan.snapshot.routes.filter{$0.destination.hasSuffix("/0")}} ?? false
        if !same {candidate=plan;since=now;return false}
        return now-since>=1
    }
    public func expired(now:TimeInterval)->Bool {began.map{now-$0>=10} ?? false}
}
