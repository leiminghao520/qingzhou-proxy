import Foundation
import SystemConfiguration
import QingzhouKit

// 链接正式退出核验，只注入快照和代理核验；夹具禁止写入真实网络。
struct HelperProxyRecord {}
struct Journal {
    var expectedDNS:Data
    var dnsKey="fixture"
    var proxies:[HelperProxyRecord]?=[]
    var routes:[ProtectedRoute]
}
final class Service {
    var process:Process?
    var activeRequest:TunRequest?
    var networkResumeSession:NSObject?
    var networkResumeWork:DispatchWorkItem?
    var journal:Journal?
    var quitRoutesRead:(() throws -> [ProtectedRoute])?
    var quitDNSRead:((String) -> NSDictionary?)?
    let dynamic=SCDynamicStoreCreate(nil,"轻舟退出只读夹具" as CFString,nil,nil)!
    var proxyBlocked=false
    func verifyNoOwnedProxyEndpoint(_ records:[HelperProxyRecord]) throws {
        if proxyBlocked {throw ProxyError("合成代理残留")}
    }
}
@main struct QuitReleaseChecks {
    static func main() throws {
        var count=0
        func check(_ condition:Bool,_ message:String) {count+=1;if !condition {fatalError(message)}}
        let service=Service()
        check(service.verifyReleasedForQuit(),"无会话无记录允许退出")
        let own=ProtectedRoute(destination:"128.0.0.0/1",gateway:"192.0.2.1",interface:"utun10")
        let foreign=ProtectedRoute(destination:"128.0.0.0/1",gateway:"link#26",interface:"utun7")
        let dns:NSDictionary=["ServerAddresses":["100.64.1.1"]]
        service.journal=Journal(expectedDNS:try PropertyListSerialization.data(fromPropertyList:dns,format:.binary,options:0),routes:[own])
        service.quitDNSRead={_ in nil}
        service.quitRoutesRead={[foreign]}
        check(service.verifyReleasedForQuit(),"外部已接管且无轻舟残留允许保留记录退出")
        service.quitRoutesRead={[]}
        check(service.verifyReleasedForQuit(),"原路由消失允许退出")
        service.quitRoutesRead={[own]}
        check(!service.verifyReleasedForQuit(),"仍拥有路由不得退出")
        service.quitRoutesRead={[own,foreign]}
        check(!service.verifyReleasedForQuit(),"竞争出口中仍有轻舟项不得退出")
        service.quitRoutesRead={[foreign]};service.quitDNSRead={_ in dns}
        check(!service.verifyReleasedForQuit(),"DNS 仍指向本次隧道不得退出")
        service.quitDNSRead={_ in ["ServerAddresses":["192.0.2.53"]]}
        check(service.verifyReleasedForQuit(),"外部 DNS 保留")
        service.proxyBlocked=true
        check(!service.verifyReleasedForQuit(),"代理仍指向轻舟不得退出")
        service.proxyBlocked=false;service.activeRequest=TunRequest(operation:"prepare")
        check(!service.verifyReleasedForQuit(),"仍有活动接管会话不得退出")
        service.activeRequest=nil;service.networkResumeWork=DispatchWorkItem{}
        check(!service.verifyReleasedForQuit(),"待重连任务不得越过退出核验")
        service.networkResumeWork=nil;service.networkResumeSession=NSObject()
        check(!service.verifyReleasedForQuit(),"待恢复会话不得越过退出核验")
        service.networkResumeSession=nil;service.quitRoutesRead={throw ProxyError("合成读取失败")}
        check(!service.verifyReleasedForQuit(),"核验失败不能当作已释放")
        service.quitRoutesRead={[foreign]};service.journal?.expectedDNS=Data("invalid".utf8)
        check(!service.verifyReleasedForQuit(),"损坏记录不能当作已释放")
        let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/sleep");process.arguments=["10"];try process.run()
        defer{if process.isRunning {process.terminate();process.waitUntilExit()}}
        service.process=process;service.journal=nil
        check(!service.verifyReleasedForQuit(),"没有记录也不能越过仍运行核心")
        print("RESULT quit_release_assertions=\(count) failures=0")
    }
}
