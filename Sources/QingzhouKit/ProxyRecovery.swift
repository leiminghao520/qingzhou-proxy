import Foundation

public enum ProxyRecovery {
    public static let keys = ["HTTPEnable","HTTPProxy","HTTPPort","HTTPSEnable","HTTPSProxy","HTTPSPort","SOCKSEnable","SOCKSProxy","SOCKSPort","ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable"]
    public static func applied(to original: [String:Any], port: Int) -> [String:Any] {
        var value = original
        for prefix in ["HTTP","HTTPS","SOCKS"] { value[prefix + "Enable"] = 1; value[prefix + "Proxy"] = "127.0.0.1"; value[prefix + "Port"] = port }
        value["ProxyAutoConfigEnable"] = 0; value["ProxyAutoDiscoveryEnable"] = 0
        return value
    }
    public static func changedOwnedKeys(expected:[String:Any],current:[String:Any],protectsExceptions:Bool=false)->[String] {
        (keys+(protectsExceptions ? ["ExceptionsList","ExcludeSimpleHostnames"]:[])).filter {key in
            if expected[key]==nil && current[key]==nil{return false}
            guard let expected=expected[key] as? NSObject,let actual=current[key] as? NSObject else{return true}
            return !expected.isEqual(actual)
        }
    }
    // 只恢复本应用仍拥有的设置，保留用户后来修改的其他字段。
    public static func restored(original: [String:Any], applied: [String:Any], current: [String:Any]) -> [String:Any]? {
        func equal(_ a: Any?, _ b: Any?) -> Bool {
            if a == nil && b == nil { return true }
            guard let a = a as? NSObject, let b = b as? NSObject else { return false }
            return a.isEqual(b)
        }
        let changed = (keys+["ExceptionsList","ExcludeSimpleHostnames"]).filter {!equal(original[$0], applied[$0])}
        guard changed.allSatisfy({equal(current[$0], applied[$0])}) else { return nil }
        var result = current
        for key in changed { if let value = original[key] { result[key] = value } else { result.removeValue(forKey: key) } }
        return result
    }
}
