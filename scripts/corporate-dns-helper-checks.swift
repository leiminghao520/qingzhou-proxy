import Foundation
import Darwin
import QingzhouKit

final class DNSFixtureBackend:RouteBackend {
    func snapshot() throws -> NetworkRouteSample {NetworkRouteSample(routes:[])}
    func lookup(_ destination:String,ipv6:Bool,scope:String?,deadline:Date?) throws -> RouteRecord {throw RouteBackendError(ESRCH)}
    func write(_ operation:NetworkInspection.RouteOperation,route:ProtectedRoute,legacy:Bool,deadline:Date?) throws -> RouteWriteResult {fatalError("DNS 夹具禁止写系统路由")}
}
@main struct CorporateDNSHelperChecks {
    static func main() throws {
        guard geteuid() != 0 else {throw ProxyError("禁止管理员运行隔离夹具")}
        var count=0
        func check(_ condition:Bool,_ text:String) {count+=1;if !condition {fatalError(text)}}
        for scenario in ["success","partialWrite","externalRewrite","restoreFailure","crash","scopeVerifyFailure"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("qz-dns-helper-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:root)}
            let service=Service(fixtureRoot:root,backend:DNSFixtureBackend())
            let defaultDNS=try DNSServiceTransaction.encode(["ServerAddresses":["192.0.2.1"]])
            service.journal=Journal(dnsKey:"fixture-default",previousDNS:nil,expectedDNS:defaultDNS,address4:"",address6:"")
            var values:[String:NSDictionary]=[:],failWrite=false,failRestore=false,writes=0
            service.corporateDNSVerify={domains,port in
                // 按苹果真实打印规则省略零优先级，避免夹具掩盖系统输出格式差异。
                let output=domains.enumerated().map {index,domain in "resolver #\(index+1)\n domain : \(domain)\n nameserver[0] : 127.0.0.1\n port : \(port)\n"}.joined()
                check(!domains.isEmpty && domains.allSatisfy{CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:output,domain:$0,port:port)},"按真实零优先级输出核验新 DNS 作用域")
            }
            service.networkDNSRead={values[$0]}
            service.dnsServiceWrite={key,value in
                // 每次写入前必须已能从磁盘恢复该服务意图。
                let journal=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:root.appendingPathComponent("recovery.json")))
                check(journal.allDNSServices.contains{$0.key==key},"写入前持久化意图")
                writes+=1
                if failWrite || (failRestore && value==nil) {throw ProxyError("注入失败")}
                values[key]=value
            }
            let resolver=DNSResolverScope(service:"corp",interface:"lo0",servers:["127.0.0.2"],domains:["corp.test"])
            let snapshot=NetworkSnapshot(primaryInterface:"lo0",routes:[],resolvers:[resolver])
            let plan=try CapturePlan.make(snapshot:snapshot,extraCIDRs:[],extraDomains:[])
            service.dnsForwarder=try ScopedDNSForwarder(plan:plan)
            try service.publishCorporateDNS(plan)
            let old=service.journal!.dnsServices![0]
            check(values[old.key] != nil,"域名服务已发布")
            check(try DNSServiceTransaction.decode(old.expected)["ServerPort"] as? Int==service.dnsForwarder!.port,"域名服务直达原转发器")
            if scenario=="partialWrite" {
                var next=plan;next.domains.append("new.test");failWrite=true
                do {try service.publishCorporateDNS(next);fatalError("必须拒绝失败写入")} catch {}
                check(service.journal!.dnsServices!.count==2 && values[old.key] != nil,"部分写失败保留旧服务和新意图")
                failWrite=false
            } else if scenario=="scopeVerifyFailure" {
                var next=plan;next.domains.append("new.test")
                service.corporateDNSVerify={_,_ in throw ProxyError("注入系统作用域不匹配")}
                do {try service.publishCorporateDNS(next);fatalError("作用域未生效不能通过")} catch {}
                check(service.journal!.dnsServices!.count==2 && values[old.key] != nil,"作用域核验失败保留旧服务及新意图供恢复")
            } else if scenario=="externalRewrite" {values[old.key]=["ServerAddresses":["203.0.113.53"]]}
            else if scenario=="restoreFailure" {failRestore=true}
            else if scenario=="crash" {
                service.journal=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:root.appendingPathComponent("recovery.json")))
            } else {
                var next=plan;next.domains.append("new.test")
                try service.publishCorporateDNS(next)
                check(values[old.key]==nil && service.journal!.dnsServices!.count==1,"新服务核验后才撤销旧代次")
            }
            do {
                try service.stop()
                check(!["externalRewrite","restoreFailure"].contains(scenario),"未完成恢复不能报告成功")
                check(service.journal==nil && values.isEmpty,"退出清理所有本次服务")
            } catch {
                check(["externalRewrite","restoreFailure"].contains(scenario),"只接受注入错误")
                check(service.journal != nil && FileManager.default.fileExists(atPath:root.appendingPathComponent("recovery.json").path),"恢复失败保留磁盘证据")
            }
            check(writes>0,"执行正式事务写入")
        }
        let legacy=Journal(dnsKey:"legacy",previousDNS:nil,expectedDNS:try DNSServiceTransaction.encode([:]),address4:"",address6:"")
        let decoded=try JSONDecoder().decode(Journal.self,from:JSONEncoder().encode(legacy))
        check(decoded.dnsServices==nil && decoded.allDNSServices.count==1,"旧记录仅认领旧单服务")
        print("CORPORATE_DNS_HELPER_OK assertions=\(count)")
    }
}
