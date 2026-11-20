import Foundation
import QingzhouKit

extension Service {
    // 由串行队列在原路由核验后调用；防火墙同步失败时不能返回成功 DNS 答案。
    func publishClaudeBypassAnswers(state: AppState, plan: CapturePlan, name: String,
                                   addresses: [String], resolver: DNSResolverScope, deadline: Date, queryType: UInt16 = 1, nameExists: Bool = true) throws {
        guard Date() < deadline, state.usesClaudeBypasses,
              state.enabledBypasses.contains(where: { $0.kind != .cidr && $0.matches(host: name) }) else {
            throw ProxyError("网络绕过答案不属于当前授权范围或已超时")
        }
        let current = try addresses.flatMap { address -> [ClaudeBypassException] in
            let route = try plan.domainRoute(address: address, resolver: resolver, host: name)
            if !(plan.yunshuControlDomains ?? []).isEmpty && YunshuConnectionPolicy.matches(name) {
                return try YunshuConnectionPolicy.controlEndpoints(host: name, address: address).map { endpoint in
                    var item = try YunshuConnectionPolicy.exception(endpoint, interface: route.interface)
                    item.controlGateway = route.gateway
                    return item
                }
            }
            return [ClaudeBypassException(destination: route.destination, interface: route.interface)]
        }
        var learned = claudeAnswerExceptions
        // A、AAAA 及其他问题类型分别持有答案，空 AAAA 不能撤销刚返回的 A 地址。
        if !nameExists { learned = learned.filter { !$0.key.hasPrefix(name + "|") } }
        else { learned[name + "|" + String(queryType)] = current }
        let initial = try ClaudeBypassPolicy.initialExceptions(state: state, plan: plan)
        try disconnectFirewall.updateBypassExceptions(initial + yunshuControlExceptions + learned.values.flatMap { $0 })
        guard Date() < deadline,
              case .node(let nodeID) = state.activePolicy,
              let node = state.nodes.first(where: { $0.id == nodeID }),
              try disconnectFirewall.verifyStrict(endpoint: ClaudePFPolicy.endpoint(node), allowsBypasses: true) else {
            throw ProxyError("网络绕过防火墙核验失败")
        }
        if !(plan.yunshuControlDomains ?? []).isEmpty {
            let controls = yunshuControlExceptions + learned.values.flatMap { $0 }.filter { $0.vpnControl == true }
            try writeYunshuControlRules(controls)
            yunshuControlExceptions = try ClaudeBypassPolicy.normalized(controls)
        }
        claudeAnswerExceptions = learned
    }
}
