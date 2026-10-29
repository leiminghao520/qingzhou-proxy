import Foundation
import QingzhouKit

@main struct ConnectionRecoveryChecks {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ value:Bool,_ message:String){checks+=1;if !value{fatalError(message)}}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("qingzhou-recovery-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:folder)}
        let url=folder.appendingPathComponent("recovery.json"),now=Date(timeIntervalSince1970:10000)
        var state=AppState();state.captureMode = .compatible
        let key=ConnectionRecoveryStore.key(state:state,environment:"A"),plan=RecoveryPlan({var s=state;s.captureMode = .systemProxy;return s}())
        let store=ConnectionRecoveryStore(url:url)
        check(store.preferred(key:key,now:now)==nil,"旧安装没有记录时使用原配置")
        try store.failed(key:key,kind:.tunnel,plan:plan,now:now)
        check(store.preferred(key:key,now:now)==nil,"尚未验证的备用方案不得复用")
        try store.verified(key:key,now:now)
        for _ in 0..<3 {
            let reopened=ConnectionRecoveryStore(url:url)
            check(reopened.preferred(key:key,now:now)?.failures==1,"连续重开三次保持备用及失败次数")
            check(reopened.preferred(key:key,now:now)?.retryAfter==now.addingTimeInterval(60),"重开不重置冷却时间")
        }
        check(store.preferred(key:key,now:now.addingTimeInterval(60))==nil,"冷却到期允许一次原方案检查")
        check(store.preferred(key:key,now:now,force:true)==nil,"用户手动重试可越过冷却")
        for (index,delay) in [(2,300.0),(3,1800.0),(4,1800.0)] {
            try store.failed(key:key,kind:.tunnel,plan:plan,now:now)
            check(store.records[key]?.failures==index && store.records[key]?.retryAfter==now.addingTimeInterval(delay),"退避遵循 1/5/30 分钟并封顶")
        }
        check(key != ConnectionRecoveryStore.key(state:state,environment:"B"),"环境变化获得独立检查机会")
        var edited=state;edited.dnsPreference = .system
        check(key != ConnectionRecoveryStore.key(state:edited,environment:"A"),"相关配置变化获得检查机会")
        edited=state;edited.notes=["x":"备注"];edited.recentUse=["x":now]
        check(key == ConnectionRecoveryStore.key(state:edited,environment:"A"),"备注及使用时间不重置故障")
        var subscriptionState=state
        subscriptionState.subscriptions=[Subscription(name:"订阅")]
        let subscriptionKey=ConnectionRecoveryStore.key(state:subscriptionState,environment:"A")
        subscriptionState.subscriptions[0].updatedAt=now;subscriptionState.subscriptions[0].lastError="更新失败";subscriptionState.subscriptions[0].retryCount=3
        check(subscriptionKey==ConnectionRecoveryStore.key(state:subscriptionState,environment:"A"),"订阅更新时间及重试元数据不重置回退")
        try store.unavailable(key:key,now:now)
        check(store.preferred(key:key,now:now)==nil && store.records[key]?.verified==false,"已验证备用失效后不能继续当作可用缓存")
        try store.stableOriginal(key:key)
        check(ConnectionRecoveryStore(url:url).records.isEmpty,"稳定恢复后持久解除记录")
        try Data("broken".utf8).write(to:url)
        let damaged=ConnectionRecoveryStore(url:url)
        check(damaged.records.isEmpty && damaged.readError != nil,"损坏记录不覆盖原配置")
        check(state.captureMode == .compatible,"回退不改变期望配置")
        let legacy=try JSONDecoder().decode(TunReply.self,from:Data("{\"ok\":false,\"message\":\"旧服务失败\",\"running\":false}".utf8))
        check(legacy.failurePhase==nil,"兼容旧辅助服务缺失字段")
        var failure=TunReply(ok:false,message:"失败后已释放",phase:"restored")
        failure.failurePhase="proxyActivation";failure.failureKind = .tunnel;failure.recoveryPhase="restored"
        do{try failure.validateSuccess();check(false,"失败不能当作恢复成功")}catch let error as HelperOperationFailure{check(error.phase=="proxyActivation" && error.kind == .tunnel,"原失败阶段不被回滚阶段覆盖")}
        let expected=ProxyRecovery.applied(to:[:],port:17890)
        let disabled:[String:Any]=["HTTPEnable":0,"HTTPSEnable":0,"SOCKSEnable":0]
        check(!ProxyLiveSample(expected:expected,current:disabled).hasForeignEndpoint,"尚未发布不推断为外部竞争")
        let foreign=ProxyRecovery.applied(to:[:],port:1082)
        check(ProxyLiveSample(expected:expected,current:foreign).hasForeignEndpoint,"其他代理端口识别为真实竞争")
        check(ConnectionFailureKind.classify(ConnectionFailure(.ownership,"外部代理")) == .ownership,"所有权错误不能进入回退")
        let passed=ConnectivityResult("节点",.passed,"")
        let timeout=ConnectivityResult("节点",.failed,"超时")
        let dead=ConnectivityResult("节点",.failed,"节点通道")
        check(SelectionConnectivityPolicy.evaluate([dead,dead,dead],requiresNode:true) == .failed,"全部探测失败不得确认切换")
        check(SelectionConnectivityPolicy.evaluate([dead,passed,dead],requiresNode:true) == .verified,"实际目标可用不受测试网站局部异常误伤")
        check(SelectionConnectivityPolicy.evaluate([passed,timeout,passed],requiresNode:true) == .unconfirmed,"测试网站正常不能掩盖目标节点超时")
        check(SelectionConnectivityPolicy.evaluate([passed,.init("节点",.notApplicable,""),passed],requiresNode:false) == .verified,"直连选择按实际路径核验")
        check(SelectionConnectivityPolicy.evaluate([.init("入口",.failed,"鉴权"),passed,passed],requiresNode:true) == .failed,"鉴权失败不能由节点通过掩盖")
        let a=UUID(),b=UUID()
        var health=ExitHealthTracker()
        check(!health.update(a,status:.unavailable),"单轮实际出口失败不重建")
        check(!health.update(b,status:.available),"无关出口健康独立记录")
        check(health.update(a,status:.unavailable),"无关出口正常不能清零默认出口失败")
        check(!health.update(a,status:.unknown),"未知结果清除连续明确失败")
        var resume=NetworkResumeBackoff()
        let delays=(0..<40).map{_ in resume.nextRecoveryDelay()}
        check(delays.prefix(7).reduce(0,+)==90 && delays.last==30,"长断网超过十分钟仍保持低频恢复预算")
        let retry=SubscriptionFailure.retryState(SubscriptionFailure.network,previousCount:3,now:now)
        check(retry.after==now.addingTimeInterval(3600),"订阅快速重试耗尽后转一小时低频重试")
        check(SubscriptionFailure.retryState(SubscriptionFailure.unauthorized,previousCount:3,now:now).after==nil,"鉴权失败等待人工处理")
        print("PASS connection recovery policy: \(checks) checks")
    }
}
