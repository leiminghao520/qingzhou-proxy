import Foundation
import AppKit
import QingzhouKit

@main struct RecoveryUIChecks {
    @MainActor static func main() async throws {
        var count=0
        func check(_ condition:Bool,_ message:String){count+=1;if !condition{fatalError(message)}}
        var now=Date(timeIntervalSince1970:100000)
        var dependencies=AppDependencies()
        dependencies.makeCredentials={_ in MemoryCredentials()}
        dependencies.now={now}
        dependencies.recoveryRuntimeHealthyOverride={true}
        dependencies.recoveryEnvironmentOverride={"isolated-network-A"}
        dependencies.recoveryReleasedOverride={}
        dependencies.recoverySafetyOverride={}
        dependencies.recoveryWait={_ in await Task.yield()}
        let model=AppModel(dependencies:dependencies)
        check(!model.loadingFailed,"隔离配置加载成功")
        var desired=model.state;desired.captureMode = .compatible
        let healthy=[ConnectivityResult("路径",.passed,"已验证")]
        var calls:[CaptureMode]=[]
        let generation=model.startupGeneration
        try await model.startWithRecovery(desired,generation:generation,profileID:nil){runtime in
            calls.append(runtime.captureMode)
            if runtime.captureMode == .compatible {throw ConnectionFailure(.tunnel,"模拟汇总状态未发布")}
            model.connectivityResults=healthy;model.connection = .connected
        }
        check(calls == [.compatible,.compatible,.systemProxy],"原方案只重试一次，备用只尝试一次")
        check(model.activeRecovery?.verified==true && model.effectiveState.captureMode == .systemProxy,"只在备用路径验证通过后发布状态")
        check(model.state.captureMode == .systemProxy,"运行期没有覆盖用户配置")
        check(model.connectionTitle == "已连接 · 使用备用方案","回退展示实际连接状态")
        let key=ConnectionRecoveryStore.key(state:desired,environment:"isolated-network-A")
        for _ in 0..<3 {
            calls=[]
            try await model.startWithRecovery(desired,generation:generation,profileID:nil){runtime in
                calls.append(runtime.captureMode);model.connectivityResults=healthy;model.connection = .connected
            }
            check(calls == [.systemProxy],"冷却内再次连接不重走失败流程")
            check(model.recoveryStore.records[key]?.failures==1,"再次连接不增长失败次数")
        }
        now=now.addingTimeInterval(61)
        calls=[]
        try await model.startWithRecovery(desired,generation:generation,profileID:nil){runtime in
            calls.append(runtime.captureMode);model.connectivityResults=healthy;model.connection = .connected
        }
        check(calls == [.compatible],"冷却结束只尝试一次原方案")
        check(model.recoveryStore.records[key]?.failures==2,"观察期间先保留新增冷却，崩溃重启可直接备用")
        await model.stableRecoveryTask?.value
        check(model.recoveryStore.records[key]==nil,"连续健康 60 个观察周期后解除持久回退")
        var strict=desired;strict.strictDNS=true
        check(model.fallbackPlan(for:.dns,state:strict)==nil,"严格 DNS 禁止回退系统解析")
        strict.strictDNS=false
        check(model.fallbackPlan(for:.dns,state:strict)?.dns == .system,"非严格 DNS 允许系统解析备用")
        check(model.fallbackPlan(for:.ownership,state:strict)==nil,"外部接管不得触发备用")
        calls=[]
        do {
            try await model.startWithRecovery(desired,generation:generation,profileID:nil){runtime in
                calls.append(runtime.captureMode);throw ConnectionFailure(.permission,"模拟权限缺失")
            }
            check(false,"权限错误必须停止")
        }catch{check(calls.count==1,"权限错误不重试、不回退")}
        calls=[]
        do {
            try await model.startWithRecovery(desired,generation:generation,profileID:nil){runtime in
                calls.append(runtime.captureMode);model.startupGeneration=UUID();throw ConnectionFailure(.tunnel,"模拟断开")
            }
            check(false,"取消必须停止")
        }catch is CancellationError{check(calls.count==1,"旧代次不得恢复接管")}
        model.startupGeneration=UUID()
        model.recoveryPending=true;calls=[]
        do {
            try await model.startWithRecovery(desired,generation:model.startupGeneration,profileID:nil){runtime in
                calls.append(runtime.captureMode);throw ConnectionFailure(.tunnel,"模拟恢复未完成")
            }
            check(false,"恢复未完成必须停止")
        }catch{check(calls.count==1,"恢复未完成不重试、不回退")}
        model.recoveryPending=false
        var dnsState=desired;dnsState.captureMode = .systemProxy
        calls=[]
        do {
            try await model.startWithRecovery(dnsState,generation:model.startupGeneration,profileID:nil){runtime in
                calls.append(runtime.captureMode)
                if runtime.dnsPreference == .httpsProxy {throw ConnectionFailure(.dns,"模拟 DNS 失败")}
                model.connectivityResults=[ConnectivityResult("路径",.failed,"DNS")]
            }
            check(false,"失败的备用方案不能报告成功")
        }catch{
            let dnsKey=ConnectionRecoveryStore.key(state:dnsState,environment:"isolated-network-A")
            check(model.recoveryStore.records[dnsKey]?.verified==false,"备用未通过时不保存为可复用方案")
            check(model.activeRecovery==nil,"备用未通过时不显示已连接备用")
        }
        calls=[]
        do {
            try await model.startWithRecovery(dnsState,generation:model.startupGeneration,profileID:nil){runtime in calls.append(runtime.captureMode)}
            check(false,"已知不可用方案应进入冷却")
        }catch{check(calls.isEmpty,"备用也失败后，重开不重复整条失败链路")}
        model.report(ConnectionFailure(.dns,"DNS 详细字段"))
        check(model.issueTitle == "当前 DNS 不可用" && model.errorMessage == "DNS 详细字段","面向用户的说明与技术详情分开")
        let group=PolicyGroup(name:"测试组",kind:.select,members:[])
        let saved=await model.saveGroup(group)
        check(!saved,"无效表单明确返回失败，保留编辑输入")
        check(model.errorMessage != nil,"失败详情保留，不要求模态确认")
        model.stableRecoveryTask?.cancel()
        print("PASS connection recovery UI: \(count) checks")
    }
}
