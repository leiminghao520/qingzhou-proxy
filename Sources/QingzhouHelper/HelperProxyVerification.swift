import Foundation
import QingzhouKit

extension Service {
    func verifyProxy()->Bool {proxyConfigurationIssues().isEmpty && proxyLiveSample()?.issues.isEmpty==true}
    func verifyProxyActivation() throws {
        let deadline=proxyVerificationClock()+2
        var last:[String]=[]
        repeat {
            let configured=proxyConfigurationIssues()
            guard configured.isEmpty else {throw ProxyError("兼容代理配置核对失败："+configured.joined(separator:"；"))}
            last=proxyLiveSample()?.issues ?? ["系统汇总代理状态无法读取"]
            if last.isEmpty {proxyMismatchSince=nil;return}
            let remaining=deadline-proxyVerificationClock()
            if remaining<=0 {break}
            proxyVerificationWait(min(0.05,remaining))
        } while proxyVerificationClock()<=deadline
        throw ProxyError("兼容代理汇总状态在两秒内未生效："+last.joined(separator:"；"))
    }
    func proxyOwnershipIssues()->[String] {
        let configured=proxyConfigurationIssues()
        guard configured.isEmpty else {proxyMismatchSince=nil;return configured}
        let live=proxyLiveSample()?.issues ?? ["系统汇总代理状态无法读取"]
        guard !live.isEmpty else {proxyMismatchSince=nil;return []}
        let now=proxyVerificationClock()
        guard let since=proxyMismatchSince else {proxyMismatchSince=now;return []}
        // 运行中也容忍有限的发布延迟；服务配置被修改仍立即拒绝，持续不符必须退出竞争。
        guard now-since>=2 else{return []}
        return live
    }
}
