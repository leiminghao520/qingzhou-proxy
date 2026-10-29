import Foundation
import QingzhouKit

extension Service {
    func startManagedSystemProxy(_ request:TunRequest,fd:Int32) throws -> TunReply {
            guard request.protocolVersion==5,let port=request.systemProxyPort,(1024...65535).contains(port),
                  (request.proxyExceptions ?? []).count<=4096,(request.proxyProtectedDomains ?? []).count<=4096,
                  ((request.proxyExceptions ?? [])+(request.proxyProtectedDomains ?? [])).allSatisfy({$0.utf8.count<=512 && !$0.contains(where:{$0.isNewline})}) else{throw ProxyError("系统代理请求参数无效")}
            guard owner==nil || owner==fd else{throw ProxyError("其他连接持有系统代理接管")}
            guard journal==nil || (owner==fd && journal?.proxies?.isEmpty != false) else{throw ProxyError("请先恢复已有接管")}
            if journal==nil {
                journal=Journal(proxyOnly:true,dnsKey:"",previousDNS:nil,expectedDNS:Data(),address4:"",address6:"");try save()
            }
            owner=fd
            do {
                phase="proxyActivation"
                try applyProxy(port:port,exceptions:request.proxyExceptions ?? [],protectedDomains:request.proxyProtectedDomains ?? [])
                try verifyProxyActivation();phase="active"
                return TunReply(ok:true,message:"系统代理已由辅助服务接管",running:true,proxyVerified:true,phase:phase)
            }catch{let original=error;failurePhase=phase;failureKind=ConnectionFailureKind.classify(error);do{try stop(preserveExternal:true)}catch{throw ConnectionFailure(.recovery,"代理激活失败："+original.localizedDescription+"；恢复失败："+error.localizedDescription)};throw original}
    }
    func stopManagedSystemProxy(preserveExternal:Bool) throws {
            defer{owner=nil;activeRequest=nil}
            let records=journal?.proxies ?? []
            let issues=try restoreProxy(records,preserveExternal:preserveExternal)
            guard issues.isEmpty else{throw ProxyError("系统代理恢复未完成："+issues.joined(separator:"；"))}
            // 系统动态配置可能晚于提交收敛，核验期间保留持久恢复记录。
            let deadline=proxyVerificationClock()+3
            while true {
                do{try verifyNoOwnedProxyEndpoint(records);break}
                catch{if proxyVerificationClock()>=deadline{throw error};proxyVerificationWait(0.05)}
            }
            try FileManager.default.removeItem(at:root.appendingPathComponent("recovery.json"))
            journal=nil;phase="restored"
    }
}
