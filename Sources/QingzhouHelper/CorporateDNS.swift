import Foundation
import Darwin
import SystemConfiguration
import QingzhouKit

extension Service {
    func readDNSService(_ key:String) throws -> NSDictionary? {
        if let networkDNSRead {return networkDNSRead(key)}
        if let value=SCDynamicStoreCopyValue(dynamic,key as CFString) {
            guard let result=value as? NSDictionary else {throw ProxyError("DNS 服务类型无效")}
            return result
        }
        guard SCError()==kSCStatusNoKey else {throw ProxyError("DNS 服务读取失败")}
        return nil
    }
    func writeDNSService(_ key:String,_ value:NSDictionary?) throws {
        if let dnsServiceWrite {try dnsServiceWrite(key,value);return}
        let ok=value.map{SCDynamicStoreSetValue(dynamic,key as CFString,$0)} ?? SCDynamicStoreRemoveValue(dynamic,key as CFString)
        guard ok else {throw ProxyError("DNS 服务提交失败")}
    }
    func dnsServiceIssues()->[String] {
        guard let record=journal else {return ["DNS 恢复记录缺失"]}
        return DNSServiceTransaction.issues(record.allDNSServices,read:readDNSService)
    }
    func publishCorporateDNS(_ plan:CapturePlan) throws {
        guard let forwarder=dnsForwarder,journal != nil else {throw ProxyError("企业 DNS 转发器未就绪")}
        let domains=Array(Set(plan.domains+(plan.exactDomains ?? []))).sorted()
        let old=journal?.dnsServices ?? []
        let settings=CaptureDNSPolicy.corporateSettings(domains:domains,port:forwarder.port) as NSDictionary
        if old.count==1,try DNSServiceTransaction.decode(old[0].expected)==settings {return}
        var next:[DNSServiceRecord]=[]
        if !domains.isEmpty {
            let key="State:/Network/Service/Qingzhou-Corporate-"+UUID().uuidString+"/DNS"
            next=[DNSServiceRecord(key:key,expected:try DNSServiceTransaction.encode(settings),original:try readDNSService(key).map(DNSServiceTransaction.encode))]
        }
        // 新路径已由调用者核验；新增服务先写入并核验，再撤回旧代次服务。
        journal?.dnsServices=old+next
        try DNSServiceTransaction.apply(next,persist:save,read:readDNSService,write:writeDNSService)
        if !domains.isEmpty {
            if let verify=corporateDNSVerify {try verify(domains,forwarder.port)}
            else {
                let deadline=Date().addingTimeInterval(3)
                var confirmed=false
                repeat {
                    let output=try NetworkInspection.command("/usr/sbin/scutil",["--dns"],deadline:deadline)
                    confirmed=domains.allSatisfy{CaptureDNSPolicy.isPreferred(server:"127.0.0.1",in:output,domain:$0,port:forwarder.port)}
                    if confirmed {break}
                    if deadline.timeIntervalSinceNow<=0.25 {break}
                    usleep(200000)
                } while Date()<deadline
                guard confirmed else {throw ProxyError("企业 DNS 域名服务的系统匹配作用域核验失败")}
            }
        }
        let issues=DNSServiceTransaction.restore(old,read:readDNSService,write:writeDNSService)
        guard issues.isEmpty else {throw ProxyError(issues.joined(separator:"；"))}
        journal?.dnsServices=next
        try save()
    }
}
