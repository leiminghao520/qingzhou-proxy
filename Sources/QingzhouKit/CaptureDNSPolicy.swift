import Foundation

public enum CaptureDNSPolicy {
    public static func settings(server:String)->[String:Any] {
        // 完整接管的默认查询先进入核心，再由核心按企业域名转发原解析器。
        // 独立补充服务的 SearchOrder 会被 macOS 移除，必须按匹配域名指定顺序。
        ["ServerAddresses":[server],"SupplementalMatchDomains":[""],"SupplementalMatchOrders":[1],"SupplementalMatchDomainsNoSearch":1]
    }

    public static func matchOrder(_ settings:[String:Any],index:Int)->Int {
        let orders=settings["SupplementalMatchOrders"] as? [Int] ?? []
        return orders.indices.contains(index) ? orders[index]:((settings["SearchOrder"] as? Int) ?? 200000)
    }

    public static func corporateSettings(domains:[String],port:Int)->[String:Any] {
        // 域名匹配优先于全域服务，直接送到绑定原接口的现有回环转发器。
        ["ServerAddresses":["127.0.0.1"],"ServerPort":port,"SupplementalMatchDomains":Array(Set(domains)).sorted(),"SupplementalMatchOrders":Array(repeating:0,count:Set(domains).count),"SupplementalMatchDomainsNoSearch":1]
    }

    public static func isPreferred(server:String,in output:String,domain:String?=nil,port:Int?=nil)->Bool {
        struct Resolver {
            var servers:[String]=[]
            var domain=""
            var port=53
            // scutil 仅输出非零 search_order；缺省字段表示合法优先级 0。
            // 显式字段无法解析时仍置为无效值，不能据此认领解析器。
            var order=0
            var multicast=false
        }
        var resolvers:[Resolver]=[],current:Resolver?
        for raw in output.components(separatedBy:.newlines) {
            let line=raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("DNS configuration (for scoped queries)") {break}
            if line.hasPrefix("resolver #") {
                if let current {resolvers.append(current)}
                current=Resolver();continue
            }
            guard current != nil,let separator=line.firstIndex(of:":") else {continue}
            let key=line[..<separator].trimmingCharacters(in:.whitespaces)
            let value=line[line.index(after:separator)...].trimmingCharacters(in:.whitespaces)
            if key.hasPrefix("nameserver[") {current!.servers.append(value)}
            if key=="domain" {current!.domain=value}
            if key=="port" {current!.port=Int(value) ?? 53}
            if key=="order" {current!.order=Int(value) ?? Int.max}
            if key=="options",value.split(whereSeparator:{$0.isWhitespace}).contains("mdns") {current!.multicast=true}
        }
        if let current {resolvers.append(current)}
        let defaults=resolvers.filter{resolver in !resolver.multicast && (domain.map{resolver.domain==$0} ?? (resolver.domain.isEmpty || resolver.domain==".")) && !resolver.servers.isEmpty}
        guard let order=defaults.map(\.order).min(),order != Int.max else {return false}
        // 同优先级有其他全域解析器时不能认定已取得默认 DNS。
        return defaults.filter{$0.order==order}.allSatisfy{$0.servers==[server] && (port==nil || $0.port==port)}
    }
}
