import Foundation

public enum HelperProgress {
    // 新客户端兼容只返回最终结果的旧辅助服务；进度帧不能被当成激活成功。
    public static func receive(read:() throws -> TunReply,progress:(String)->Void) throws -> TunReply {
        var reply=try read()
        while reply.isProgress==true {
            guard reply.ok,let phase=reply.phase else {throw ProxyError("辅助服务进度消息无效")}
            progress(phase)
            reply=try read()
        }
        return reply
    }
    public static func label(_ phase:String)->String {
        switch phase {
        case "preflight":return "核对当前网络与其他代理"
        case "bootstrapDNS":return "解析节点与引导 DNS"
        case "networkRecheck","bypassSnapshot","addressPlan","dnsBaseline":return "准备网络快照与绕过路径"
        case "coreValidation":return "校验代理核心配置"
        case "routeEncodingValidation":return "整批校验路由报文"
        case "interfaceReady":return "等待并核对 TUN 接口"
        case "coreStartup","prepared":return "启动代理核心"
        case "activation":return "准备启用网络接管"
        case "protection":return "核验企业网络与绕过路由"
        case "dnsActivation":return "应用并核验 DNS"
        case "proxyActivation":return "应用并核验系统代理"
        case "active":return "接管已应用，正在验证实际网络"
        case "recovery":return "恢复原网络"
        default:return "准备网络接管"
        }
    }
    public static func elapsed(start:TimeInterval?,now:TimeInterval)->Int {
        guard let start else{return 0}
        return Int(min(Double(Int.max),max(0,now-start)))
    }
}
