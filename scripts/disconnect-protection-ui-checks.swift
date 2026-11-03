import Foundation
import AppKit
import SwiftUI
import QingzhouKit

@main struct DisconnectProtectionUIChecks {
    @MainActor static func main() async throws {
        var assertions=0
        func check(_ value:Bool,_ message:String) {assertions+=1;if !value {fatalError(message)}}
        var dependencies=AppDependencies();dependencies.makeCredentials={_ in MemoryCredentials()}
        let model=AppModel(dependencies:dependencies)
        check(!model.loadingFailed,"隔离配置加载成功")
        var state=AppState()
        let node=Node(name:"固定测试节点",kind:.hysteria2,server:"43.163.70.144",port:443)
        state.nodes=[node];state.selectedPolicy = .node(node.id)
        try model.credentials.set("fixture",for:node.credentialRef)
        try model.persist(state)
        let draft=SettingsDraft(state)
        check(!draft.network.disconnectProtection && !draft.dirty,"旧配置默认关闭且没有草稿")
        draft.network.disconnectProtection=true
        check(draft.dirty,"选项进入草稿，不直接接管网络")
        draft.discard();check(!draft.network.disconnectProtection,"撤销草稿恢复关闭")
        var supports=false,armed=false,conflict=false
        var operations:[String]=[]
        model.capture=CaptureController(core:model.core,proxy:model.proxy,helperRequest:{request in
            operations.append(request.operation)
            if request.operation=="checkDisconnectProtection",conflict {throw ProxyError("模拟企业防火墙不兼容")}
            if request.operation=="releaseDisconnectProtection" {armed=false}
            var reply=TunReply(ok:true,message:"隔离状态")
            reply.supportsDisconnectProtection=supports;reply.disconnectProtectionArmed=armed;reply.safeToQuit=true;reply.supportsExternalRecovery=true
            return reply
        })
        let oldApply=await model.applyCaptureSettings(mode:.systemProxy,dns:.system,family:.dualStack,httpCompatibility:false,disconnectProtection:true)
        check(!oldApply && !model.state.protectsDisconnect,"旧辅助服务拒绝开启，不提交配置")
        check(model.errorMessage?.contains("更新辅助服务")==true,"明确提示更新辅助服务")
        supports=true;conflict=true
        let conflictApply=await model.applyCaptureSettings(mode:.systemProxy,dns:.system,family:.dualStack,httpCompatibility:false,disconnectProtection:true)
        check(!conflictApply && !model.state.protectsDisconnect,"企业防火墙冲突不提交配置")
        conflict=false
        let applied=await model.applyCaptureSettings(mode:.systemProxy,dns:.system,family:.dualStack,httpCompatibility:false,disconnectProtection:true)
        check(applied && model.state.protectsDisconnect,"兼容检查通过才能保存选项")
        check(model.state.captureMode == .compatible && model.state.mode == .global,"自动应用完整接管与全部代理")
        check(model.state.strictDNS==true && model.state.dnsPreference == .httpsProxy,"解析不能回退系统")
        check(model.fallbackPlan(for:.tunnel,state:model.state)==nil,"保护开启时禁止降级到系统代理")
        check(model.fallbackPlan(for:.dns,state:model.state)==nil,"保护开启时禁止 DNS 降级")
        await model.selectPolicy(.automatic)
        check(model.state.activePolicy == .node(node.id),"不能在保护配置中切换自动选择")
        armed=true;_=try await model.capture.helperStatus();model.connection = .error
        check(model.connectionTitle.contains("断线保护"),"异常断开显示保留保护，不能误报普通网络已恢复")
        try await model.verifyConnectionReleased()
        check(armed,"重连的路由恢复核验不解除保护")
        do {try await model.capture.verifyReleasedForQuit();check(false,"保护仍生效时不能误判可退出")}catch{check(armed,"退出核验拒绝但不解除保护")}
        let off=await model.applyCaptureSettings(mode:.systemProxy,dns:.system,family:.dualStack,httpCompatibility:false,strictDNS:false,disconnectProtection:false)
        check(off && !model.state.protectsDisconnect && !armed,"关闭选项解除异常会话的阻断并保存")
        check(operations.contains("releaseDisconnectProtection"),"显式解除通过授权辅助服务执行")
        // 仅渲染隔离视图，不连接真实节点或辅助服务。
        let view=NSHostingView(rootView:SettingsView(model:model));view.frame=NSRect(x:0,y:0,width:1000,height:1800);view.layoutSubtreeIfNeeded()
        check(view.fittingSize.width>0,"含可选保护设置的真实 SwiftUI 视图可构建")
        print("DISCONNECT_PROTECTION_UI_OK assertions=\(assertions) realNetworkWrites=0")
    }
}
