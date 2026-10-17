import Foundation
import Security
import Mobile

enum TunnelSecrets {
    static func validate(_ request:String?)throws {
        var error:NSError?
        guard QZMobileValidate(request,&error) else {throw error ?? NSError(domain:"Qingzhou",code:30)}
    }
    static let group = "group.cn.qingzhou.qingzhou"
    static let service = "cn.qingzhou.tunnel.request"
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
         kSecAttrAccount as String:account, kSecAttrAccessGroup as String:accessGroup]
    }
    static var accessGroup: String { Bundle.main.object(forInfoDictionaryKey:"QingzhouKeychainGroup") as! String }
    static func save(_ data: Data, account: String) throws {
        let q = query(account)
        var attributes = q
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary,nil)
        guard status == errSecSuccess else { throw NSError(domain:"Qingzhou",code:Int(status)) }
    }
    static func consume(_ account: String) throws -> Data {
        var q = query(account);q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        guard status == errSecSuccess, let data = result as? Data else {throw NSError(domain:"Qingzhou",code:Int(status))}
        SecItemDelete(query(account) as CFDictionary)
        return data
    }
    static func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
