import Foundation
import QingzhouKit

struct Manifest:Codable {var version:String;var uid:UInt32;var clientHash:String;var coreHash:String;var helperHash:String}
struct OwnedRoute:Codable {var destination:String;var gateway:String;var interface:String;var ipv6:Bool;var scope:String?=nil}
struct Journal:Codable {var transactionID:UUID?;var captureRoutes:[String]?;var pinnedOnly:Bool?;var firewall:BypassFirewallLease?;var version=2;var proxies:[HelperProxyRecord]?;var pid:Int32?;var interface:String?;var routes:[OwnedRoute]=[];var preservedRoutes:[ProtectedRoute]?;var dnsServices:[DNSServiceRecord]?;var dnsKey:String;var previousDNS:Data?;var expectedDNS:Data;var address4:String;var address6:String}

extension Journal {
    // 旧记录仅认领原单个服务，不能推断新增域名服务的所有权。
    var allDNSServices:[DNSServiceRecord] {[DNSServiceRecord(key:dnsKey,expected:expectedDNS,original:previousDNS)]+(dnsServices ?? [])}
}
