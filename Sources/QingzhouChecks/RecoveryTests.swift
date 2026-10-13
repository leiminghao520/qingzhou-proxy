import Foundation
import QingzhouKit

final class RecoveryTests: CheckCase {
    func testOriginalPACAndProxyRestored() {
        let original: [String:Any] = ["HTTPEnable":1,"HTTPProxy":"original.example","HTTPPort":8080,"ProxyAutoConfigEnable":1,"ProxyAutoConfigURLString":"https://example.com/proxy.pac","ExceptionsList":["local"]]
        let applied = ProxyRecovery.applied(to:original,port:7890)
        expectEqual(applied["HTTPProxy"] as? String,"127.0.0.1");expectEqual(applied["ProxyAutoConfigEnable"] as? Int,0)
        let restored = ProxyRecovery.restored(original:original,applied:applied,current:applied)!
        expectTrue(NSDictionary(dictionary:restored).isEqual(to:original))
    }
    func testUnrelatedExternalChangesPreserved() {
        let original: [String:Any] = [:];let applied = ProxyRecovery.applied(to:original,port:7890);var current = applied;current["ExceptionsList"] = ["new.example"]
        let restored = ProxyRecovery.restored(original:original,applied:applied,current:current)!
        expectEqual(restored["ExceptionsList"] as? [String],["new.example"]);expectNil(restored["HTTPEnable"])
    }
    func testOwnedFieldConflictDoesNotOverwrite() {
        let original: [String:Any] = [:];let applied = ProxyRecovery.applied(to:original,port:7890);var current = applied;current["HTTPSPort"] = 9999
        expectNil(ProxyRecovery.restored(original:original,applied:applied,current:current))
    }
}
