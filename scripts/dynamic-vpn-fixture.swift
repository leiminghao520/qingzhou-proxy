import Foundation
import QingzhouKit

// 复用正式监控与计划应用，所有路由及 DNS 外部输入由本地夹具提供。
extension MonitorChecks {
    static func runDynamicFixture(_ directory:URL,ports:[String:Int]) throws {
        let service=Service()
        let dns:NSDictionary=["ServerAddresses":["100.64.1.1"]]
        let dnsData=try PropertyListSerialization.data(fromPropertyList:dns,format:.binary,options:0)
        let table="Internet:\ndefault 127.0.0.1 UGSc lo0\n127/8 link#1 UCS lo0\n0/1 link#42 USc utun42"
        let publicDNS=DNSResolverScope(service:"wifi",interface:"lo0",servers:["192.0.2.53"],defaultResolver:true)
        var corporateInterface="utun6"
        var corporateDNS=ports["initialCorporate"]==1,corporateRoute=ports["initialCorporate"]==1,tick=100.0
        var dnsUnavailable=false
        service.networkUptime={tick}
        service.journal=Journal(expectedDNS:dnsData,routes:[OwnedRoute(destination:"0.0.0.0/1",gateway:"link#42",interface:"utun42")])
        service.networkDNSRead={_ in dns}
        service.routeSample={try NetworkRouteSample(read:{table+"\n"+(corporateRoute ? "10.20/16 10.20.0.1 UGSc "+corporateInterface+"\n":"")})}
        service.networkSnapshotRead={sample in
            let routes=NetworkSnapshot.parseRoutes(sample.table)
            return NetworkSnapshot(primaryInterface:"lo0",routes:routes,resolvers:[publicDNS]+(corporateDNS ? [DNSResolverScope(service:"corp",interface:corporateInterface,servers:["10.20.0.53"],domains:["corp.test"])]:[]))
        }
        service.capturePlan=try CapturePlan.make(snapshot:service.currentSnapshot(),extraCIDRs:[],extraDomains:["private.test"])
        service.knownProtectedDomains=Set(service.capturePlan!.domains)
        let rules=try DynamicCaptureRules(directory:directory.appendingPathComponent("rules"),plan:service.capturePlan!)
        service.dynamicRules=rules
        var queryCount=0
        let queryLock=NSLock()
        let forwarder=try ScopedDNSForwarder(plan:service.capturePlan!,transport:{query,server,interface in
            queryLock.lock();queryCount += 1
            let record="\(queryCount) \(DNSPacket.name(query) ?? "") \(server)@\(interface)\n"
            if let handle=try? FileHandle(forWritingTo:directory.appendingPathComponent("queries.log")) {handle.seekToEndOfFile();handle.write(Data(record.utf8));try? handle.close()}
            queryLock.unlock()
            if server=="10.20.0.53",queryLock.withLock({dnsUnavailable}) {return nil}
            var answer=query;answer[2]=0x81;answer[3]=0x80
            if query.suffix(4)==Data([0,1,0,1]) {answer[7]=1;answer.append(contentsOf:[0xc0,0x0c,0,1,0,1,0,0,0,0,0,4,127,0,0,1])}
            return answer
        },protectSnapshotAnswers:{plan,revision,name,addresses,resolver,deadline in
            try service.queue.sync {
                guard service.dnsForwarder?.isCurrentRevision(revision)==true,!service.protectedQueriesSuspended,service.capturePlan==plan,Date()<deadline else {throw ProxyError("计划已撤回")}
                for address in addresses {_=try plan.domainRoute(address:address,resolver:resolver)}
            }
        })
        service.dnsForwarder=forwarder;forwarder.start();defer{forwarder.stop()}
        FileManager.default.createFile(atPath:directory.appendingPathComponent("queries.log").path,contents:Data())
        let node=try NodeParser.parse("ss://aes-128-gcm:synthetic@127.0.0.1:\(ports["server"]!)")
        let credentials=MemoryCredentials();try credentials.set(node.secret,for:node.node.credentialRef)
        var state=AppState();state.nodes=[node.node];state.selectedPolicy = .node(node.node.id);state.listenPort=ports["core"]!;state.captureMode = .tun;state.addressFamilyPolicy = .ipv4Only;state.protectedDomains=["private.test"]
        service.activeRequest=TunRequest(operation:"prepare",state:state)
        let control=CoreControlContext(port:ports["control"]!,secret:String(repeating:"a",count:64))
        let data=try TunConfigBuilder.build(state:state,credentials:credentials,control:control,address4:"100.64.1.1/30",address6:"fd71:717a::1/126",originalDNS:["192.0.2.53"],bypass:[],plan:service.capturePlan!,dnsForwardPort:forwarder.port)
        var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        object["inbounds"]=(object["inbounds"] as! [[String:Any]]).filter{$0["type"] as? String != "tun"}
        rules.apply(to:&object,plan:service.capturePlan!)
        // 远端解析同样限于夹具回环转发，不访问任何外部 DNS。
        var configDNS=object["dns"] as! [String:Any]
        configDNS["servers"]=[["type":"udp","tag":"local","server":"127.0.0.1","server_port":forwarder.port],["type":"udp","tag":"remote","server":"127.0.0.1","server_port":forwarder.port]]
        configDNS["disable_cache"]=true;object["dns"]=configDNS
        try SecureFile.write(JSONSerialization.data(withJSONObject:object),to:directory.appendingPathComponent("core.json"))
        print("READY");fflush(stdout)
        while let command=readLine() {
            let status=service.queue.sync {()->String in
                switch command {
                case "up":corporateDNS=true;corporateRoute=true
                case "dns":corporateDNS=true;corporateRoute=false
                case "route":corporateDNS=false;corporateRoute=true
                case "down":corporateDNS=false;corporateRoute=false
                case "interface":corporateInterface="utun7";corporateDNS=true;corporateRoute=true
                case "refuse":queryLock.lock();dnsUnavailable=true;queryLock.unlock()
                case "recover":queryLock.lock();dnsUnavailable=false;queryLock.unlock()
                case "tick":break
                case "stop":try? service.stop()
                default:return "UNKNOWN"
                }
                tick += 1;service.checkNetworkChange()
                return "STATE starts=\(service.starts) stops=\(service.stops) suspended=\(service.protectedQueriesSuspended) phase=\(service.phase)"
            }
            print(status);fflush(stdout)
            if command=="stop" {break}
        }
    }
}
