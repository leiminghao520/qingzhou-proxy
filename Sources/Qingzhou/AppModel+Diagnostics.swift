import Foundation
import QingzhouKit

extension AppModel {
    func recordEvent(_ category:NetworkEventCategory,_ outcome:NetworkEventOutcome,_ reason:NetworkEventReason,diagnosticID:UUID?=nil,profileID:UUID?=nil,historyTransactionID:UUID?=nil,phase:NetworkEventPhase?=nil,recoveryID:UUID?=nil,originalSessionID:UUID?=nil) {
        timeline.record(NetworkEvent(sessionID:eventSessionID,profileID:profileID ?? currentProfileID,category:category,outcome:outcome,reason:reason,phase:phase,recoveryID:recoveryID ?? wakeIntent?.id,originalSessionID:originalSessionID ?? wakeIntent?.session,diagnosticID:diagnosticID,historyTransactionID:historyTransactionID ?? activeHistoryTransactionID,time:dependencies.now()))
    }
    func invalidateDiagnostic() {
        diagnosticGeneration=UUID();diagnosticTask?.cancel();diagnosticTask=nil;diagnosing=false
        if diagnosticSession != nil {diagnosticSession=nil;diagnosticRows=[]}
    }
    func cancelDiagnostic() {diagnosticTask?.cancel()}
    func diagnose() async {
        guard !locked else{return}
        invalidateDiagnostic()
        let generation=diagnosticGeneration,frozen=state,profile=currentProfileID,connectionID=epoch
        let connected=connection == .connected,client=api
        let tag=frozen.mode == .direct ? nil:connected ? CoreAPIClient.actualTag(proxyInfo):frozen.activePolicy?.tag
        let nodeID=tag.flatMap{$0.hasPrefix("node-") ? UUID(uuidString:String($0.dropFirst(5))):nil}
        let node=nodeID.flatMap{id in frozen.nodes.first{$0.id==id}}
        let session=DiagnosticSession(profileID:profile,connectionID:connectionID,nodeID:nodeID,startedAt:dependencies.now())
        let corePath=core.binary.path,dns=dependencies.diagnosticDNS,helper=dependencies.diagnosticHelper
        var jobs=[DiagnosticJob("本地配置与端口") {DiagnosticService.local(state:frozen,corePath:corePath,connected:connected)}]
        jobs.append(DiagnosticJob("节点 DNS") {
            guard let node else {return [DiagnosticResult("节点 DNS","未验证","无法确认实际出站节点，未使用列表首项代替",code:"nodeUnverified")]}
            return [await dns(node.server)]
        })
        jobs.append(DiagnosticJob("辅助服务") {
            guard frozen.captureMode.usesTunnel else {return [DiagnosticResult("辅助服务","不适用","系统代理模式不要求 TUN 服务",code:"notApplicable")]}
            do {
                let status=try await helper()
                return [DiagnosticResult("辅助服务",status.running ? "通过":"未验证","独立只读通道；当前代理通道保持不变",code:status.running ? "helperRunning":"helperStopped"),
                        DiagnosticResult("TUN 路由",status.routesVerified==true ? "通过":status.running ? "失败":"未验证","按当前接管记录核验",code:status.routesVerified==true ? "routeVerified":"routeUnverified"),
                        DiagnosticResult("TUN DNS",status.dnsVerified==true ? "通过":status.running ? "失败":"未验证","按当前 DNS 所有权核验",code:status.dnsVerified==true ? "dnsVerified":"dnsUnverified"),
                        DiagnosticResult("内网保护",status.protectionVerified==true ? "通过":status.running ? "失败":"未验证","内网保护状态核验",code:status.protectionVerified==true ? "protectionVerified":"protectionUnverified")]
            }catch {return [DiagnosticResult("辅助服务","未验证","无法完成本次辅助服务核验",code:error is CancellationError ? "cancelled":"helperUnavailable")]}
        })
        jobs.append(DiagnosticJob("HTTPS 与代理入口") {
            guard connected,let client else{return [DiagnosticResult("HTTPS 与代理入口","未验证","未连接；诊断不会自动接管网络",code:"notConnected")]}
            async let rule=ConnectivityProbe.https(port:frozen.captureMode.usesTunnel ? nil:frozen.listenPort,entry:false)
            async let entry=ConnectivityProbe.https(port:frozen.captureMode.usesTunnel ? nil:frozen.listenPort,entry:true)
            let rows=await [rule,entry]
            var result=rows.map{DiagnosticResult($0.title,$0.status.rawValue,$0.category,code:$0.status == .passed ? "httpsPassed":$0.status == .notApplicable ? "notApplicable":"httpsFailed",milliseconds:$0.milliseconds)}
            if let nodeID {
                switch await client.measureNode(nodeID) {
                case .success(let delay):result.append(DiagnosticResult("冻结节点通道","通过","当前诊断冻结的出站节点通过 HTTPS 探测",code:"nodePassed",milliseconds:delay))
                case .failure:result.append(DiagnosticResult("冻结节点通道","失败","节点探测未通过",code:"nodeProbeFailed"))
                }
            }else{result.append(DiagnosticResult("冻结节点通道","未验证","实际节点不可确认",code:"nodeUnverified"))}
            return result
        })
        diagnosing=true;diagnosticSession=session;diagnosticRows=[]
        let executor=dependencies.diagnosticExecutor
        let task=Task {await executor.run(session,jobs:jobs)};diagnosticTask=task
        let result=await withTaskCancellationHandler(operation:{await task.value},onCancel:{task.cancel()})
        guard diagnosticGeneration==generation,epoch==connectionID,currentProfileID==profile else{return}
        diagnosticTask=nil;diagnosing=false;diagnosticSession=result;diagnosticRows=result.results
        let cancelled=result.results.contains{$0.code=="cancelled"},timeout=result.results.contains{$0.code=="timeout"}
        recordEvent(.diagnostic,cancelled ? .cancelled:timeout || result.results.contains{$0.outcome == .failed} ? .failed:.succeeded,cancelled ? .diagnosisCancelled:timeout ? .diagnosisTimeout:.diagnosisComplete,diagnosticID:result.id)
    }
}
