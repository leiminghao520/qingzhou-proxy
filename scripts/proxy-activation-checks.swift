import Foundation
import QingzhouKit

// 直接链接正式代理激活和持续核验实现；只注入系统配置与动态汇总状态读取。
final class Service {
    var proxyMismatchSince:TimeInterval?
    var proxyVerificationClock:()->TimeInterval={0}
    var proxyVerificationWait:(TimeInterval)->Void={_ in fatalError("夹具必须使用合成时钟")}
    var configured:[String]=[]
    var live:ProxyLiveSample?
    var configuredReads=0,liveReads=0
    func proxyConfigurationIssues()->[String] {configuredReads += 1;return configured}
    func proxyLiveSample()->ProxyLiveSample? {liveReads += 1;return live}
}
@main struct ProxyActivationChecks {
    static func main() throws {
        var count=0
        func check(_ condition:Bool,_ message:String) {count += 1;if !condition {fatalError(message)}}
        let expected=ProxyRecovery.applied(to:[:],port:17890)
        var old=ProxyRecovery.applied(to:[:],port:1082);old["SOCKSEnable"]=0
        let delayed=Service();var clock=0.0,waits=0
        delayed.proxyVerificationClock={clock};delayed.live=ProxyLiveSample(expected:expected,current:old)
        delayed.proxyVerificationWait={seconds in
            clock += seconds;waits += 1
            if clock>=0.15 {delayed.live=ProxyLiveSample(expected:expected,current:expected)}
        }
        check(!delayed.verifyProxy(),"提交后旧汇总状态不能报告已经核验通过")
        try delayed.verifyProxyActivation()
        check(delayed.verifyProxy() && waits==3 && clock<2,"复现七毫秒即失败的路径，等待异步发布后正常激活")
        check(delayed.configuredReads>=4 && delayed.liveReads>=4,"每轮读取当前配置和汇总，不使用旧缓存")
        var alias=expected;alias["HTTPProxy"]="localhost";alias["HTTPSProxy"]="::1"
        check(ProxyLiveSample(expected:expected,current:alias).issues.isEmpty,"等价回环地址可通过")
        var missing=expected;missing.removeValue(forKey:"SOCKSPort")
        check(ProxyLiveSample(expected:expected,current:missing).issues.contains{$0.hasPrefix("SOCKSPort")},"端口缺失须给出实际字段差异")
        var disabled=expected;disabled["SOCKSEnable"]=0
        check(ProxyLiveSample(expected:expected,current:disabled).issues.contains{$0.hasPrefix("SOCKSEnable")},"协议禁用不能当作正确状态")
        let unavailable=Service();clock=0;unavailable.proxyVerificationClock={clock};unavailable.proxyVerificationWait={clock += $0};unavailable.live=nil
        do {try unavailable.verifyProxyActivation();check(false,"汇总一直不发布必须超时")}
        catch {check(clock>=2 && clock<2.01 && error.localizedDescription.contains("两秒"),"缺失状态有总等待上限")}
        let foreign=Service();clock=0;foreign.proxyVerificationClock={clock};foreign.proxyVerificationWait={clock += $0};foreign.live=ProxyLiveSample(expected:expected,current:old)
        do {try foreign.verifyProxyActivation();check(false,"持续外部代理必须拒绝")}
        catch {check(error.localizedDescription.contains("HTTPPort") && error.localizedDescription.contains("SOCKSEnable"),"失败报告具体差异，不屏蔽外部代理")}
        let changed=Service();changed.configured=["服务配置已被修改"]
        do {try changed.verifyProxyActivation();check(false,"已提交配置改写必须立即拒绝")}
        catch {check(changed.liveReads==0 && error.localizedDescription.contains("服务配置已被修改"),"真实配置冲突不等待汇总")}
        let monitor=Service();clock=100;monitor.proxyVerificationClock={clock};monitor.live=ProxyLiveSample(expected:expected,current:old)
        check(monitor.proxyOwnershipIssues().isEmpty,"运行中汇总短暂滞后先等待")
        clock += 1;check(monitor.proxyOwnershipIssues().isEmpty,"发布窗口内不能误停")
        clock += 1;check(!monitor.proxyOwnershipIssues().isEmpty,"持续不一致仍需报告冲突")
        monitor.live=ProxyLiveSample(expected:expected,current:expected)
        check(monitor.proxyOwnershipIssues().isEmpty && monitor.proxyMismatchSince==nil,"汇总恢复后清除计时")
        monitor.live=ProxyLiveSample(expected:expected,current:nil)
        check(monitor.proxyOwnershipIssues().isEmpty && !monitor.verifyProxy(),"容忍发布延迟不等于状态验证成功")
        monitor.configured=["外部修改"]
        check(monitor.proxyOwnershipIssues()==["外部修改"],"等待期间外部改写服务配置立即拒绝")
        var automatic=expected;automatic["ProxyAutoConfigEnable"]=1
        check(!ProxyLiveSample(expected:expected,current:automatic).issues.isEmpty,"外部自动代理不能被忽略")
        print("RESULT proxy_activation_assertions=\(count) failures=0")
    }
}
