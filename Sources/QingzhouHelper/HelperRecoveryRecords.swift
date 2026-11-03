import Foundation

struct HelperProxyRecord:Codable {
    var service:String
    var original:Data
    var applied:Data
    var enabled:Bool
    var hadProtocol:Bool
}
struct BypassFirewallLease:Codable {
    var anchor:String
    var expectedRules:String?
    var token:String?
}
