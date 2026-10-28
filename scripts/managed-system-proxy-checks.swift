import Foundation
import QingzhouKit

// 隔离运行正式接管事务，所有网络写入和时钟均由内存夹具替代。
final class Service {
    let root:URL
    var owner:Int32?,activeRequest:TunRequest?,journal:Journal?
    var phase="idle",clock:TimeInterval=0
    var proxyVerificationClock:()->TimeInterval{{self.clock}}
    var proxyVerificationWait:(TimeInterval)->Void{{self.clock+=$0}}
    var applyFailure=false,verifyFailure=false,restoreFailure=false,saveFailure=false
    var transient=0,applied=0,restored=0
    init(_ root:URL){self.root=root}
    func save() throws {if saveFailure{throw ProxyError("模拟持久化失败")};try JSONEncoder().encode(journal).write(to:root.appendingPathComponent("recovery.json"))}
    func applyProxy(port:Int,exceptions:[String],protectedDomains:[String]) throws {
        applied+=1
        journal?.proxies=[HelperProxyRecord(service:"fixture",original:Data(),applied:Data(),enabled:false,hadProtocol:true)];try save()
        if applyFailure{throw ProxyError("模拟提交失败")}
    }
    func verifyProxyActivation() throws {if verifyFailure{throw ProxyError("模拟接管核验失败")}}
    func restoreProxy(_ records:[HelperProxyRecord],preserveExternal:Bool)throws->[String] {restored+=1;return restoreFailure ? ["模拟外部冲突"]:[]}
    func verifyNoOwnedProxyEndpoint(_ records:[HelperProxyRecord]) throws {if transient>0 {transient-=1;throw ProxyError("模拟动态设置收敛中")}}
    func stop(preserveExternal:Bool) throws {try stopManagedSystemProxy(preserveExternal:preserveExternal)}
}
@main struct ManagedProxyChecks {
    static var assertions=0
    static func check(_ value:Bool,_ reason:String)throws {assertions+=1;if !value{throw ProxyError(reason)}}
    static func rejects(_ work:()throws->Void)throws {do{try work()}catch{return};throw ProxyError("应拒绝请求")}
    static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        func fixture()->Service{try? FileManager.default.removeItem(at:root.appendingPathComponent("recovery.json"));return Service(root)}
        let request=TunRequest(operation:"systemProxy",systemProxyPort:27890)
        let service=fixture();let result=try service.startManagedSystemProxy(request,fd:10)
        try check(result.proxyVerified==true && result.running && service.owner==10,"服务接管成功")
        try check(service.journal?.proxyOnly==true && service.journal?.allDNSServices.isEmpty==true,"纯代理不认领 DNS")
        try check(FileManager.default.fileExists(atPath:root.appendingPathComponent("recovery.json").path),"写入前保留恢复记录")
        try rejects{_=try service.startManagedSystemProxy(request,fd:11)}
        try rejects{_=try service.startManagedSystemProxy(request,fd:10)}
        try check(service.applied==1,"不能重复覆盖已有快照")
        service.transient=2;try service.stopManagedSystemProxy(preserveExternal:true)
        try check(service.owner==nil && service.journal==nil && service.clock>0,"等待动态收敛再释放")
        try check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("recovery.json").path),"核验完成后删除日志")
        for port in [nil,0,1023,65536] as [Int?] {
            let s=fixture();try rejects{_=try s.startManagedSystemProxy(TunRequest(operation:"systemProxy",systemProxyPort:port),fd:10)};try check(s.applied==0,"非法端口不写入")
        }
        for index in 0..<6 {
            let s=fixture();var bad=request
            switch index {case 0:bad.protocolVersion=4;case 1:bad.proxyExceptions=Array(repeating:"x",count:4097);case 2:bad.proxyProtectedDomains=Array(repeating:"x",count:4097);case 3:bad.proxyExceptions=[String(repeating:"x",count:513)];case 4:bad.proxyExceptions=["bad\nvalue"];default:bad.proxyProtectedDomains=["bad\nvalue"]}
            try rejects{_=try s.startManagedSystemProxy(bad,fd:10)};try check(s.applied==0,"不接受不受限参数")
        }
        for failure in ["apply","verify","save"] {
            let s=fixture();s.applyFailure=failure=="apply";s.verifyFailure=failure=="verify";s.saveFailure=failure=="save"
            try rejects{_=try s.startManagedSystemProxy(request,fd:10)}
            try check(s.applied==(failure=="save" ? 0:1),"保存失败不得写入网络")
            if failure != "save"{try check(s.journal==nil && s.owner==nil && s.restored==1,"失败后回滚释放")}
        }
        let interrupted=fixture();interrupted.journal=Journal(proxyOnly:true,dnsKey:"",previousDNS:nil,expectedDNS:Data(),address4:"",address6:"");try interrupted.save()
        try interrupted.stopManagedSystemProxy(preserveExternal:true)
        try check(interrupted.journal==nil,"写入前崩溃的空事务也可安全恢复")
        let shared=fixture();shared.owner=10;shared.journal=Journal(pinnedOnly:true,dnsKey:"fixture",previousDNS:nil,expectedDNS:Data(),address4:"",address6:"")
        var detailed=request;detailed.proxyExceptions=["192.0.2.0/24"];detailed.proxyProtectedDomains=["corp.example"]
        _=try shared.startManagedSystemProxy(detailed,fd:10)
        try check(shared.journal?.pinnedOnly==true && shared.journal?.proxyOnly != true,"同会话已有路由事务不被覆盖")
        let conflict=fixture();_=try conflict.startManagedSystemProxy(request,fd:10);conflict.restoreFailure=true
        try rejects{try conflict.stopManagedSystemProxy(preserveExternal:true)}
        try check(conflict.journal != nil && conflict.owner==nil,"冲突时保留日志且释放死会话")
        conflict.restoreFailure=false;conflict.transient=1000
        try rejects{try conflict.stopManagedSystemProxy(preserveExternal:true)}
        try check(conflict.journal != nil && conflict.clock>=3,"超时不能假报恢复完成")
        conflict.transient=0;try conflict.stopManagedSystemProxy(preserveExternal:true)
        try check(conflict.journal==nil,"后续恢复可重试")
        print("MANAGED_SYSTEM_PROXY_CHECKS_OK assertions=\(assertions)")
    }
}
