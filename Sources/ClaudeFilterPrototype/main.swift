import Foundation
import NetworkExtension
import Network
import Security
import Darwin
import QingzhouKit

// 仅供签名原型验证；默认打包流程不会嵌入或激活此扩展。
@objc(ClaudeFilterDataProvider)
final class ClaudeFilterDataProvider: NEFilterDataProvider {
    private var policy: ClaudeApplicationPolicy?

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do {
            let configuration = filterConfiguration
            guard configuration.vendorConfiguration?["prototypeOnly"] as? Bool == true,
                  let data = configuration.vendorConfiguration?["policy"] as? Data,
                  data.count <= 65_536 else {
                throw ProxyError("过滤原型缺少显式测试配置；未启动过滤")
            }
            let candidate = try JSONDecoder().decode(ClaudeApplicationPolicy.self, from: data)
            try candidate.validate()
            for application in candidate.applications {
                var requirement: SecRequirement?
                guard SecRequirementCreateWithString(application.designatedRequirement as CFString, [], &requirement) == errSecSuccess else {
                    throw ProxyError("应用签名要求无法编译")
                }
            }
            policy = candidate
            // 系统默认放行回环流量，必须单独加入回环规则才能约束其他本地代理。
            let rules = [("127.0.0.1", 8), ("::1", 128)].map { address, prefix in
                NEFilterRule(networkRule: NENetworkRule(remoteNetwork: NWHostEndpoint(hostname: address, port: "0"),
                    remotePrefix: prefix, localNetwork: nil, localPrefix: 0, protocol: .any, direction: .outbound), action: .filterData)
            }
            let settings = NEFilterSettings(rules: rules, defaultAction: .filterData)
            apply(settings) { [weak self] error in
                if error != nil { self?.policy = nil }
                completionHandler(error)
            }
        } catch {
            policy = nil
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // 这里只清理内存；系统在扩展停止后如何处理连接必须实测，不能在此声明持续阻断。
        policy = nil
        completionHandler()
    }

    private func identity(_ token: Data?, policy: ClaudeApplicationPolicy) -> ClaudeFlowOwner {
        guard let token, token.count == MemoryLayout<audit_token_t>.size else { return .unresolved }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return .unresolved }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String else { return .unresolved }
        var matches: [ClaudeFlowOwner] = []
        for application in policy.applications {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(application.designatedRequirement as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { return .unresolved }
            if identifier == application.identifier && SecCodeCheckValidity(code, [], requirement) == errSecSuccess {
                matches.append(application.owner)
            }
        }
        guard matches.count <= 1 else { return .unresolved }
        return matches.first ?? .unrelatedApplication
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let policy else { return .drop() }
        let application = identity(flow.sourceAppAuditToken, policy: policy)
        let process = identity(flow.sourceProcessAuditToken, policy: policy)
        let owner: ClaudeFlowOwner
        if application == .protectedApplication || process == .protectedApplication {
            owner = .protectedApplication
        } else if application == .unresolved || process == .unresolved {
            owner = .unresolved
        } else if application == .dedicatedProxy || process == .dedicatedProxy {
            owner = application == .dedicatedProxy && process == .dedicatedProxy ? .dedicatedProxy : .unresolved
        } else {
            // 这里尚无同步子进程继承证据，因此此原型不能通过正式发布门槛。
            owner = .unrelatedApplication
        }
        var endpoint: ClaudeNetworkEndpoint?
        if let socket = flow as? NEFilterSocketFlow, let remote = socket.remoteEndpoint as? NWHostEndpoint,
           let port = UInt16(remote.port), socket.socketFamily == AF_INET || socket.socketFamily == AF_INET6 {
            let transport: ClaudeFlowTransport
            if socket.socketProtocol == IPPROTO_TCP && socket.socketType == SOCK_STREAM { transport = .tcp }
            else if socket.socketProtocol == IPPROTO_UDP && socket.socketType == SOCK_DGRAM { transport = .udp }
            else { transport = .unsupported }
            endpoint = ClaudeNetworkEndpoint(address: remote.hostname, port: port, transport: transport)
        }
        return policy.permits(owner: owner, destination: endpoint) ? .allow() : .drop()
    }
}

if CommandLine.arguments.contains("--preflight") {
    let bundlePath: String
    if let index = CommandLine.arguments.firstIndex(of: "--bundle"), index + 1 < CommandLine.arguments.count {
        bundlePath = CommandLine.arguments[index + 1]
    } else {
        bundlePath = "/Applications/汐航.app"
    }
    let result = ClaudeNetworkFilterClient.inspect(bundleURL: URL(fileURLWithPath: bundlePath))
    let data = try JSONEncoder().encode(result)
    print(String(decoding: data, as: UTF8.self))
    for issue in result.deploymentBlockers + ClaudeNetworkFilterClient.runtimeBlockers { print("BLOCKED: " + issue) }
    exit(2)
} else {
    autoreleasepool {
        NEProvider.startSystemExtensionMode()
    }
    dispatchMain()
}
