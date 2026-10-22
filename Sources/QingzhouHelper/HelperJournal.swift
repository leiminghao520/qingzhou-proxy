import Foundation
import QingzhouKit

struct Manifest:Codable {var version:String;var uid:UInt32;var clientHash:String;var coreHash:String;var helperHash:String}
struct OwnedRoute:Codable {var destination:String;var gateway:String;var interface:String;var ipv6:Bool;var scope:String?=nil}
struct Journal:Codable {var transactionID:UUID?;var captureRoutes:[String]?;var pinnedOnly:Bool?;var firewall:BypassFirewallLease?;var version=2;var proxies:[HelperProxyRecord]?;var pid:Int32?;var interface:String?;var routes:[OwnedRoute]=[];var preservedRoutes:[ProtectedRoute]?;var dnsKey:String;var previousDNS:Data?;var expectedDNS:Data;var address4:String;var address6:String}
