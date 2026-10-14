import Foundation
import Security
import LocalAuthentication

public enum KeychainFailure {
    public static func message(_ status:OSStatus,operation:String)->String {
        switch status {
        case errSecItemNotFound:return "节点或订阅凭据不存在，请重新导入对应节点或订阅；输入 Mac 密码不能找回缺失凭据"
        case errSecUserCanceled:return "已取消 macOS 钥匙串授权；重新连接可再次授权"
        case errSecAuthFailed:return "macOS 钥匙串授权未通过，请在系统授权窗口允许轻舟访问"
        case errSecInteractionNotAllowed:return "当前无法显示 macOS 钥匙串授权窗口，请解锁 Mac 并将轻舟切到前台后重试"
        case errSecNotAvailable:return "macOS 钥匙串暂不可用，请解锁登录钥匙串后重试"
        default:return "钥匙串"+operation+"失败（状态码 \(status)），请查看诊断；无需重复输入节点密码"
        }
    }
}
public final class KeychainStore:CredentialStore {
    public typealias Read=([String:Any])->(OSStatus,Data?)
    private let service:String
    private let context=LAContext()
    private var cache:[String:String]=[:]
    private let read:Read
    private let update:([String:Any],[String:Any])->OSStatus
    private let add:([String:Any])->OSStatus
    private let delete:([String:Any])->OSStatus
    public init(service:String="cn.qingzhou.proxy.credentials",read:Read?=nil,update:(([String:Any],[String:Any])->OSStatus)?=nil,add:(([String:Any])->OSStatus)?=nil,delete:(([String:Any])->OSStatus)?=nil) {
        self.service=service
        self.read=read ?? {query in var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result);return (status,result as? Data)}
        self.update=update ?? {SecItemUpdate($0 as CFDictionary,$1 as CFDictionary)}
        self.add=add ?? {SecItemAdd($0 as CFDictionary,nil)}
        self.delete=delete ?? {SecItemDelete($0 as CFDictionary)}
        context.localizedReason="轻舟需要读取已保存的节点密码以连接代理；授权后本次运行自动复用"
    }
    private func query(_ ref:String)->[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:ref]}
    public func get(_ ref:String) throws -> String {
        // 只缓存成功读取的凭据；取消或失败不会阻止用户下次重新触发系统授权。
        if let value=cache[ref] {return value}
        var q=query(ref);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIAllow
        q[kSecUseAuthenticationContext as String]=context
        let (status,data)=read(q)
        guard status==errSecSuccess else{throw ProxyError(KeychainFailure.message(status,operation:"读取"))}
        guard let data,let value=String(data:data,encoding:.utf8) else{throw ProxyError("保存的凭据格式损坏，请重新导入对应节点或订阅")}
        cache[ref]=value;return value
    }
    public func set(_ value:String,for ref:String) throws {
        var q=query(ref);q[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIAllow;q[kSecUseAuthenticationContext as String]=context
        let data=Data(value.utf8);let status=update(q,[kSecValueData as String:data])
        if status==errSecItemNotFound {
            var item=query(ref);item[kSecValueData as String]=data;item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added=add(item);guard added==errSecSuccess else{throw ProxyError(KeychainFailure.message(added,operation:"保存"))}
        }else if status != errSecSuccess {throw ProxyError(KeychainFailure.message(status,operation:"更新"))}
        cache[ref]=value
    }
    public func remove(_ ref:String) throws {
        let status=delete(query(ref));guard status==errSecSuccess || status==errSecItemNotFound else{throw ProxyError(KeychainFailure.message(status,operation:"删除"))};cache.removeValue(forKey:ref)
    }
}
