import Foundation
import Security

public final class KeychainStore: CredentialStore {
    private let service: String
    public init(service: String = "cn.qingzhou.proxy.credentials") {self.service = service}
    private func query(_ ref: String) -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:ref] }
    public func get(_ ref: String) throws -> String {
        var q = query(ref); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let value = String(data:data,encoding:.utf8) else { throw ProxyError("无法读取钥匙串凭据，请重新导入或允许钥匙串访问") }
        return value
    }
    public func set(_ value: String, for ref: String) throws {
        let q = query(ref); let data = Data(value.utf8)
        let updated = SecItemUpdate(q as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw ProxyError("无法保存钥匙串凭据") }
        } else if updated != errSecSuccess { throw ProxyError("无法更新钥匙串凭据") }
    }
    public func remove(_ ref: String) throws { let status = SecItemDelete(query(ref) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw ProxyError("无法删除钥匙串凭据") } }
}
