import Foundation
import Darwin

public enum DisconnectProtectionPolicy {
    public static func publicEndpoint(_ address:String)->Bool {
        var bytes=[UInt8](repeating:0,count:16)
        if address.withCString({inet_pton(AF_INET,$0,&bytes)})==1 {
            return bytes[0] != 0 && bytes[0] != 10 && bytes[0] != 127 && bytes[0]<224 && !(bytes[0]==169 && bytes[1]==254) && !(bytes[0]==172 && (16...31).contains(bytes[1])) && !(bytes[0]==192 && bytes[1]==168) && !(bytes[0]==100 && (64...127).contains(bytes[1]))
        }
        // 只接受全球单播 IPv6；拒绝 IPv4 映射、私网、组播及链路本地地址。
        return address.withCString({inet_pton(AF_INET6,$0,&bytes)})==1 && bytes[0]&0xe0==0x20
    }
    public static func validate(_ state:AppState) throws {
        guard state.protectsDisconnect else{return}
        guard state.captureMode.usesTunnel,state.mode == .global,state.dnsPreference == .httpsProxy,state.strictDNS==true,!state.httpCompatibilityEnabled else {
            throw ProxyError("断线保护要求 TUN / 完整接管、全部代理、严格代理 DNS，并关闭 HTTP 兼容模式")
        }
        guard case .node(let id)=state.activePolicy,let node=state.nodes.first(where:{$0.id==id}) else {
            throw ProxyError("断线保护需要手动选择单个固定 IP 节点，不能自动选择或使用策略组")
        }
        guard publicEndpoint(node.server) else {throw ProxyError("断线保护节点需要固定公网 IP；请选择 IP 节点，域名节点和私网转发节点不支持")}
        try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:node.server,action:.proxy))
        guard state.pinnedBypasses.isEmpty else {throw ProxyError("断线保护暂不能与指定网卡绕过同时开启")}
    }
    // 运行时仅保留固定节点，避免自动测速或控制接口切换到其他出口；用户原配置不变。
    public static func runtime(_ state:AppState) throws -> AppState {
        try validate(state)
        guard state.protectsDisconnect,case .node(let id)=state.activePolicy else{return state}
        var next=state
        next.nodes=state.nodes.filter{$0.id==id};next.groups=[];next.rules=[];next.remoteRules=[];next.ruleFinal = .selected
        return next
    }
    public static func allowedDestinations(state:AppState,plan:CapturePlan) throws -> [String] {
        try validate(state)
        guard case .node(let id)=state.activePolicy,let node=state.nodes.first(where:{$0.id==id}) else{throw ProxyError("固定节点不存在")}
        // 公网仅放行固定节点；公司已核验路由和链路基础流量作为显式例外保留。
        let infrastructure=["127.0.0.0/8","::1/128","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","fe80::/10","fc00::/7","224.0.0.0/4","ff00::/8","255.255.255.255/32"]
        let endpoint=node.server+(node.server.contains(":") ? "/128":"/32")
        let corporate=plan.protectedRoutes.map(\.destination)
        let allowed=Array(Set(infrastructure+[endpoint]+corporate)).sorted()
        for value in allowed {
            try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:value,action:.direct))
            guard let bits=value.split(separator:"/").last.flatMap({Int($0)}),bits>3 else {throw ProxyError("公司路由例外范围过大，不能安全启用断线保护")}
        }
        return allowed
    }
    public static func rules(allowed:[String],tunnel:String?) throws -> String {
        guard !allowed.isEmpty,allowed.count<=4096 else{throw ProxyError("断线保护例外为空或超过限制")}
        for value in allowed {try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:value,action:.direct));guard value.contains("/"),let bits=value.split(separator:"/").last.flatMap({Int($0)}),bits>3 else{throw ProxyError("断线保护例外必须限定目标网段")}}
        if let tunnel {guard tunnel.range(of:"^utun[0-9]{1,5}$",options:.regularExpression) != nil else{throw ProxyError("断线保护隧道接口无效")}}
        let scope=tunnel.map{" on ! "+$0} ?? ""
        // 只有拒绝规则，不添加放行规则，不绕过其他组件的安全检查；两种地址族都阻断。
        return "table <qz_disconnect_allowed> { "+allowed.joined(separator:", ")+" }\nblock drop out quick"+scope+" inet from any to ! <qz_disconnect_allowed>\nblock drop out quick"+scope+" inet6 from any to ! <qz_disconnect_allowed>\n"
    }
}
