import Foundation

// 仅允许本机已安装云枢所需的两个控制域名，不接受来自订阅或界面的任意域名。
public enum YunshuControlPolicy {
    public static let hosts = ["sp.eagleyun.cn", "idp.eagleyun.cn"]
    public static func resolve(installed: Bool, lookup: (String) throws -> [String]) throws -> [String] {
        guard installed else { return [] }
        var addresses = Set<String>()
        for host in hosts {
            let answers = try lookup(host)
            guard !answers.isEmpty, answers.count <= 16,
                  answers.allSatisfy(DisconnectProtectionPolicy.publicEndpoint) else {
                throw ProxyError("云枢控制服务解析结果无效，未扩大公网例外")
            }
            addresses.formUnion(answers)
        }
        return addresses.sorted()
    }
}
