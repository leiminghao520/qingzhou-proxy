import Foundation
import Security
import LocalAuthentication

public enum KeychainFailure {
    public static func message(_ status:OSStatus,operation:String)->String {
        switch status {
        case errSecItemNotFound:return "节点或订阅凭据不存在，请重新导入对应节点或订阅；输入 Mac 密码不能找回缺失凭据"
        case errSecUserCanceled:return "已取消 macOS 钥匙串授权；重新连接可再次授权"
        case errSecAuthFailed:return "macOS 钥匙串授权未通过，请在系统授权窗口允许汐航访问"
        case errSecInteractionNotAllowed:return "当前无法显示 macOS 钥匙串授权窗口，请解锁 Mac 并将汐航切到前台后重试"
        case errSecNotAvailable:return "macOS 钥匙串暂不可用，请解锁登录钥匙串后重试"
        default:return "钥匙串"+operation+"失败（状态码 \(status)），请查看诊断；无需重复输入节点密码"
        }
    }
}
public final class KeychainStore:CredentialStore {
    public typealias Read=([String:Any])->(OSStatus,Data?)
    private let service:String
    private final class Session {
        let lock=NSRecursiveLock()
        let context=LAContext()
        var cache:[String:[String:String]]=[:]
        init(){context.localizedReason="汐航需要读取已保存的连接凭据；授权后本次运行自动复用"}
    }
    // 原生存储共用进程内授权会话；注入的测试或替代实现保持隔离。
    private static let nativeSession=Session()
    private let session:Session
    private let read:Read
    private let update:([String:Any],[String:Any])->OSStatus
    private let add:([String:Any])->OSStatus
    private let delete:([String:Any])->OSStatus
    public init(service:String="cn.qingzhou.proxy.credentials",read:Read?=nil,update:(([String:Any],[String:Any])->OSStatus)?=nil,add:(([String:Any])->OSStatus)?=nil,delete:(([String:Any])->OSStatus)?=nil) {
        self.service=service
        self.session = read==nil && update==nil && add==nil && delete==nil ? Self.nativeSession : Session()
        self.read=read ?? {query in var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result);return (status,result as? Data)}
        self.update=update ?? {SecItemUpdate($0 as CFDictionary,$1 as CFDictionary)}
        self.add=add ?? {SecItemAdd($0 as CFDictionary,nil)}
        self.delete=delete ?? {SecItemDelete($0 as CFDictionary)}
    }
    private func recordAuthorizationFailure(_ status:OSStatus) {
        if status==errSecUserCanceled || status==errSecAuthFailed {CredentialAuthorization.attempt?.cancel()}
    }
    private func query(_ ref:String)->[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:ref]}
    public func get(_ ref:String) throws -> String {
        session.lock.lock();defer{session.lock.unlock()}
        // 只缓存成功读取的凭据；取消或失败不会阻止用户下次重新触发系统授权。
        if let value=session.cache[service]?[ref] {return value}
        if CredentialAuthorization.attempt?.cancelled == true {throw ProxyError(KeychainFailure.message(errSecUserCanceled,operation:"读取"))}
        var q=query(ref);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String]=CredentialAuthorization.allowsInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        q[kSecUseAuthenticationContext as String]=session.context
        let (status,data)=read(q)
        recordAuthorizationFailure(status)
        if status==errSecItemNotFound {throw MissingCredential()}
        guard status==errSecSuccess else{throw ProxyError(KeychainFailure.message(status,operation:"读取"))}
        guard let data,let value=String(data:data,encoding:.utf8) else{throw ProxyError("保存的凭据格式损坏，请重新导入对应节点或订阅")}
        session.cache[service,default:[:]][ref]=value;return value
    }
    public func set(_ value:String,for ref:String) throws {
        session.lock.lock();defer{session.lock.unlock()}
        if CredentialAuthorization.attempt?.cancelled == true {throw ProxyError(KeychainFailure.message(errSecUserCanceled,operation:"保存"))}
        var q=query(ref);q[kSecUseAuthenticationUI as String]=CredentialAuthorization.allowsInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail;q[kSecUseAuthenticationContext as String]=session.context
        let data=Data(value.utf8);let status=update(q,[kSecValueData as String:data])
        recordAuthorizationFailure(status)
        if status==errSecItemNotFound {
            var item=query(ref);item[kSecValueData as String]=data;item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecUseAuthenticationUI as String]=CredentialAuthorization.allowsInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
            item[kSecUseAuthenticationContext as String]=session.context
            let added=add(item);recordAuthorizationFailure(added);guard added==errSecSuccess else{throw ProxyError(KeychainFailure.message(added,operation:"保存"))}
        }else if status != errSecSuccess {throw ProxyError(KeychainFailure.message(status,operation:"更新"))}
        session.cache[service,default:[:]][ref]=value
    }
    public func remove(_ ref:String) throws {
        session.lock.lock();defer{session.lock.unlock()}
        if CredentialAuthorization.attempt?.cancelled == true {throw ProxyError(KeychainFailure.message(errSecUserCanceled,operation:"删除"))}
        var q=query(ref);q[kSecUseAuthenticationUI as String]=CredentialAuthorization.allowsInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        q[kSecUseAuthenticationContext as String]=session.context
        let status=delete(q);recordAuthorizationFailure(status);guard status==errSecSuccess || status==errSecItemNotFound else{throw ProxyError(KeychainFailure.message(status,operation:"删除"))};session.cache[service]?.removeValue(forKey:ref)
    }
}
