import Foundation
import Security

public struct ClaudeFilterPreflight: Codable, Sendable {
    public var developerIDSigned: Bool
    public var embeddedExtensionPresent: Bool
    public var extensionSignedBySameTeam: Bool
    public var provisioningProfilesPresent: Bool
    public var extensionEntitlementPresent: Bool
    public var hostInstallEntitlementPresent: Bool

    public var deploymentBlockers: [String] {
        var issues: [String] = []
        if !developerIDSigned { issues.append("缺少有效的 Developer ID 应用签名") }
        if !embeddedExtensionPresent { issues.append("未嵌入 Claude 网络过滤系统扩展") }
        if !extensionSignedBySameTeam { issues.append("系统扩展与主应用签名团队尚未核验一致") }
        if !provisioningProfilesPresent { issues.append("缺少主应用或扩展的配置描述文件") }
        if !extensionEntitlementPresent { issues.append("系统扩展缺少内容过滤权限") }
        if !hostInstallEntitlementPresent { issues.append("主应用缺少系统扩展安装权限") }
        return issues
    }
}

// 首阶段只检查部署条件；不会请求系统授权、启停过滤器或修改网络设置。
public enum ClaudeNetworkFilterClient {
    public static let extensionIdentifier = "cn.qingzhou.proxy.claude-filter"
    public static let runtimeBlockers = [
        "过滤组件崩溃和开机空窗的持续阻断尚未实机验证",
        "Claude Code 子进程、MCP 和系统代解析的完整覆盖尚未实现",
        "专用代理端口的监听进程身份及防替占机制尚未验证",
        "已有连接、IPv6、DNS 和云枢共存尚未完成实机验收"
    ]

    private static func signingInfo(_ url: URL) -> [String: Any]? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }

    private static func isDeveloperID(_ url: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    public static func inspect(bundleURL: URL) -> ClaudeFilterPreflight {
        let extensionURL = bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(extensionIdentifier).systemextension")
        let exists = FileManager.default.fileExists(atPath: extensionURL.path)
        let hostInfo = signingInfo(bundleURL)
        let extensionInfo = exists ? signingInfo(extensionURL) : nil
        let hostTeam = hostInfo?[kSecCodeInfoTeamIdentifier as String] as? String
        let extensionTeam = extensionInfo?[kSecCodeInfoTeamIdentifier as String] as? String
        let hostEntitlements = hostInfo?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let filterEntitlements = extensionInfo?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let network = filterEntitlements["com.apple.developer.networking.networkextension"] as? [String] ?? []
        return ClaudeFilterPreflight(
            developerIDSigned: isDeveloperID(bundleURL),
            embeddedExtensionPresent: exists,
            extensionSignedBySameTeam: hostTeam?.isEmpty == false && hostTeam == extensionTeam && isDeveloperID(extensionURL),
            provisioningProfilesPresent: [bundleURL, extensionURL].allSatisfy {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/embedded.provisionprofile").path)
            },
            extensionEntitlementPresent: network.contains("content-filter-provider-systemextension"),
            hostInstallEntitlementPresent: hostEntitlements["com.apple.developer.system-extension.install"] as? Bool == true)
    }

    public static func requireProductionReady(bundleURL: URL = Bundle.main.bundleURL) throws {
        let issues = inspect(bundleURL: bundleURL).deploymentBlockers + runtimeBlockers
        // 未完成的平台能力不提供配置开关绕过；不能用 PF 规则或模拟证据冒充应用级保护。
        throw ProxyError("Claude 应用级安全模式暂不可开启：" + issues.joined(separator: "；") + "。原网络未改变")
    }
}
