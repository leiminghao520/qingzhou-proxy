import Foundation

public struct TunAddressPlan:Sendable {
    public let address4:String
    public let address6:String
    public var gateway4:String {String(address4.split(separator:"/")[0])}
    public static func routePrefixes(_ table:String)->[String] {
        table.components(separatedBy:.newlines).compactMap {line in
            let fields=line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            guard fields.count>=4,fields[0] != "default" else{return nil}
            let parts=fields[0].split(separator:"/",omittingEmptySubsequences:false)
            var address=String(parts[0]);let bits:Int
            if address.contains(":") {
                address=address.components(separatedBy:"%")[0]
                bits=parts.count==2 ? Int(parts[1]) ?? -1:128
            }else{
                let octets=address.split(separator:".")
                guard (1...4).contains(octets.count),octets.allSatisfy({Int($0).map{(0...255).contains($0)} ?? false}) else{return nil}
                bits=parts.count==2 ? Int(parts[1]) ?? -1:fields[2].contains("H") ? 32:octets.count*8
                address=(octets.map(String.init)+Array(repeating:"0",count:4-octets.count)).joined(separator:".")
            }
            guard bits>0 else{return nil}
            let prefix=address+"/\(bits)"
            guard (try? ConfigBuilder.validate(RoutingRule(kind:.cidr,value:prefix,action:.direct))) != nil else{return nil}
            return prefix
        }
    }
    // macOS 会缩写网络地址，按前缀语义识别已有路由，不能直接比较显示字符串。
    public static func containsRoute(_ destination:String,prefixes:[String])->Bool {
        prefixes.contains {NetworkInspection.samePrefix($0,destination)}
    }
    // 一次读取路由表后在内存中选址，避免数百次子进程查询耗尽控制通道时限。
    public static func occupiedPrefixes(routes:String,bypassCIDRs:[String]=[],physicalInterface:String?=nil)->[String] {
        return routes.components(separatedBy:.newlines).flatMap {line -> [String] in
            let prefixes=routePrefixes(line)
            let fields=line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            guard let physicalInterface,fields.count>=4,!fields[1].hasPrefix("link#"),!fields[2].contains("H"),fields.dropFirst(3).contains(physicalInterface) else{return prefixes}
            // 显式排除范围的物理网关路由只表示转发，不代表整个范围都分配给接口。
            // 仍保留真实接口网段、具体主机路由以及其他隧道拥有的业务路由。
            return prefixes.filter {prefix in !bypassCIDRs.contains{NetworkInspection.samePrefix(prefix,$0)}}
        }
    }
    public static func conflicts(candidate:String,occupied:[String])->[String] {
            let address=String(candidate.split(separator:"/")[0])
            let rule=RoutingRule(kind:.cidr,value:candidate,action:.direct)
            return occupied.filter {prefix in
                let old=String(prefix.split(separator:"/")[0])
                return RuleEvaluator.matches(RoutingRule(kind:.cidr,value:prefix,action:.direct),host:address,ip:address)==true || RuleEvaluator.matches(rule,host:old,ip:old)==true
            }
    }
    public static func make(routes:String,bypassCIDRs:[String]=[],physicalInterface:String?=nil) throws -> TunAddressPlan {
        let existing=occupiedPrefixes(routes:routes,bypassCIDRs:bypassCIDRs,physicalInterface:physicalInterface)
        func overlaps(_ candidate:String)->Bool {
            let address=String(candidate.split(separator:"/")[0])
            let rule=RoutingRule(kind:.cidr,value:candidate,action:.direct)
            return existing.contains {prefix in
                let old=String(prefix.split(separator:"/")[0])
                return RuleEvaluator.matches(RoutingRule(kind:.cidr,value:prefix,action:.direct),host:address,ip:address)==true || RuleEvaluator.matches(rule,host:old,ip:old)==true
            }
        }
        // 企业 VPN 可能占满共享地址和基准测试地址；私有地址也必须逐个通过重叠检查。
        for (pool,base) in ["100.64","198.18","172.31","192.168","10.255"].enumerated() {
            for index in 1...200 {
                let v4="\(base).\(index).1/30"
                let v6="fd71:717a:\(String(pool*200+index,radix:16))::1/126"
                if !overlaps(v4) && !overlaps(v6) {return TunAddressPlan(address4:v4,address6:v6)}
            }
        }
        throw ProxyError("保留地址候选均与现有路由重叠，未创建 TUN；请查看网络诊断")
    }
}
