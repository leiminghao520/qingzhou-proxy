import Foundation
import QingzhouKit

final class NetworkPolicyTests:CheckCase {
    func testPreparationRaceAndDNSBudget() throws {
        try NetworkInspection.validatePreparation(interface:"en0",gateway:"192.0.2.1",currentInterface:"en0",currentGateway:"192.0.2.1",vpn:"",routes:"10.56/14 10.251.1.1 UGSc utun6",proxies:[:])
        expectThrows(try NetworkInspection.validatePreparation(interface:"en0",gateway:"192.0.2.1",currentInterface:"utun7",currentGateway:"198.18.0.1",vpn:"",routes:"",proxies:[:]))
        expectThrows(try NetworkInspection.validatePreparation(interface:"en0",gateway:"192.0.2.1",currentInterface:"en0",currentGateway:"192.0.2.1",vpn:"",routes:"0/1 link#22 UCS utun7",proxies:[:]))
        expectThrows(try NetworkInspection.validatePreparation(interface:"en0",gateway:"192.0.2.1",currentInterface:"en0",currentGateway:"192.0.2.1",vpn:"",routes:"",proxies:["HTTPEnable":1]))
        let result=try NetworkInspection.boundedAddresses("synthetic",resolver:{_ in ["192.0.2.4"]})
        expectEqual(result,["192.0.2.4"])
        expectThrows(try NetworkInspection.boundedAddresses("synthetic",resolver:{_ in throw ProxyError("合成解析失败")}))
        let start=Date()
        expectThrows(try NetworkInspection.boundedAddresses("synthetic",timeout:0.01,resolver:{_ in Thread.sleep(forTimeInterval:0.1);return ["192.0.2.4"]}))
        expectTrue(Date().timeIntervalSince(start)<0.08)
    }
    func testTunAddressAllocation() throws {
        let firstDNS=NetworkInspection.tunDNSKey(UUID()),secondDNS=NetworkInspection.tunDNSKey(UUID())
        expectTrue(firstDNS.hasPrefix("State:/Network/Service/Qingzhou-TUN-"))
        expectTrue(firstDNS.hasSuffix("/DNS"))
        expectFalse(firstDNS==secondDNS)

        expectTrue(NetworkInspection.routeScopeMatches("en0",flags:"<UP,GATEWAY,IFSCOPE>",interface:"en0"))
        expectFalse(NetworkInspection.routeScopeMatches(nil,flags:"<UP,GATEWAY,IFSCOPE>",interface:"en0"))
        expectTrue(NetworkInspection.routeScopeMatches(nil,flags:"<UP,GATEWAY>",interface:"utun7"))
        expectFalse(NetworkInspection.routeScopeMatches("en0",flags:"<UP,GATEWAY>",interface:"en0"))
        expectFalse(NetworkInspection.routeScopeMatches("en0",flags:"<UP,GATEWAY,IFSCOPE>",interface:"utun6"))
        expectFalse(NetworkInspection.routeScopeMatches(nil,flags:nil,interface:"en0"))

        let onlink="destination: 169.254.0.0\nmask: 255.255.0.0\ninterface: en0\nflags: <UP,DONE,CLONING,STATIC>"
        expectEqual(NetworkInspection.routeGateway(onlink,index:{_ in 14}),"link#14")
        expectNil(NetworkInspection.routeGateway(onlink,index:{_ in 0}))
        expectNil(NetworkInspection.routeGateway(onlink.replacingOccurrences(of:"<UP,DONE,CLONING,STATIC>",with:"<UP,GATEWAY>"),index:{_ in 14}))
        let viaGateway="gateway: 192.0.2.1\ninterface: en0\nflags: <UP,GATEWAY,DONE>"
        expectEqual(NetworkInspection.routeGateway(viaGateway,index:{_ in 14}),"192.0.2.1")
        expectEqual(NetworkInspection.routeGateway("interface: lo0\nflags: <UP,HOST,DONE,LOCAL>",index:{_ in 1}),"link#1")
        expectEqual(NetworkInspection.routeGateway("interface: en0\nflags: <UP,DONE,MULTICAST,IFSCOPE>",index:{_ in 14}),"link#14")
        expectNil(NetworkInspection.routeGateway("interface: en0\nflags: <REJECT>",index:{_ in 14}))
        expectNil(NetworkInspection.routeGateway("flags: <UP,DONE>",index:{_ in 14}))
        for operation in [NetworkInspection.RouteOperation.add,.delete] {
            expectEqual(NetworkInspection.routeArguments(operation,destination:"169.254.0.0/16",gateway:"link#14",interface:"en0"),["-n",operation.rawValue,"-net","169.254.0.0/16","-interface","en0"])
            expectEqual(NetworkInspection.routeArguments(operation,destination:"ff02::fb/128",gateway:"link#14",ipv6:true,scope:"en0",interface:"en0"),["-n",operation.rawValue,"-inet6","-ifscope","en0","-net","ff02::fb/128","-interface","en0"])
        }
        expectEqual(NetworkInspection.routePrefix(destination:"fe80::%en0",mask:"ffff:ffff:ffff:ffff::"),"fe80::/64")
        expectEqual(NetworkInspection.routePrefix(destination:"ff02::fb%en0",mask:nil,host:true),"ff02::fb/128")
        expectEqual(NetworkInspection.routePrefix(destination:"default",mask:"128.0.0.0"),"0.0.0.0/1")
        expectEqual(NetworkInspection.routePrefix(destination:"default",mask:"8000::"),"::/1")
        expectEqual(NetworkInspection.routePrefix(destination:"default",mask:"0.0.0.0"),"0.0.0.0/0")
        expectFalse(NetworkInspection.samePrefix(NetworkInspection.routePrefix(destination:"default",mask:"128.0.0.0")!,"0.0.0.0/0"))
        expectNil(NetworkInspection.routePrefix(destination:"default",mask:"default"))
        expectNil(NetworkInspection.routePrefix(destination:"default",mask:"255.1.0.0"))
        expectNil(NetworkInspection.routePrefix(destination:"default",mask:"128.0.0.0",host:true))
        expectEqual(NetworkInspection.routeArguments(.get,destination:"111.132.47.193",scope:"en0"),["-n","get","-ifscope","en0","-host","111.132.47.193"])
        expectEqual(NetworkInspection.routeArguments(.add,destination:"0.0.0.0/1",gateway:"192.0.2.1",scope:"en0"),["-n","add","-ifscope","en0","-net","0.0.0.0/1","192.0.2.1"])
        expectEqual(NetworkInspection.routeArguments(.delete,destination:"::/1",gateway:"fe80::1%en0",ipv6:true,scope:"en0"),["-n","delete","-inet6","-ifscope","en0","-net","::/1","fe80::1%en0"])
        expectEqual(NetworkInspection.routeArguments(.delete,destination:"0.0.0.0/1",gateway:"192.168.1.1"),["-n","delete","-net","0.0.0.0/1","192.168.1.1"])

        let abbreviated=TunAddressPlan.routePrefixes("100.64/10 10.251.1.1 UGSc utun6\n127 127.0.0.1 UCS lo0\n172.16/12 10.251.1.1 UGSc utun6\n198.18.0/16 10.251.1.1 UGSc utun6\n192.168.66 link#11 UCS en0\nfe80::%utun0/64 link#13 UcI utun0")
        for destination in ["100.64.0.0/10","127.0.0.0/8","172.16.0.0/12","198.18.0.0/16","192.168.66.0/24","fe80::/64"] {
            expectTrue(TunAddressPlan.containsRoute(destination,prefixes:abbreviated))
        }
        for destination in ["100.64.0.0/11","100.128.0.0/10","192.168.0.0/16","0.0.0.0/1","128.0.0.0/1","::/1","8000::/1"] {
            expectFalse(TunAddressPlan.containsRoute(destination,prefixes:abbreviated))
        }

        let own="nameserver[0] : 198.18.1.1"
        expectNil(NetworkSafety.conflict(proxies:[:],dns:NetworkSafety.excludingOwnedDNS(own,owned:"198.18.1.1")))
        expectTrue(NetworkSafety.conflict(proxies:[:],dns:NetworkSafety.excludingOwnedDNS(own+"\n nameserver[1] : 198.18.0.2",owned:"198.18.1.1")) != nil)
        expectTrue(NetworkSafety.conflict(proxies:[:],dns:NetworkSafety.excludingOwnedDNS(own,owned:nil)) != nil)

        let routes="""
        Destination Gateway Flags Netif
        default 192.168.1.1 UGSc en0
        100.64/10 192.168.1.1 UGSc en0
        198.19/16 10.251.1.1 UGSc utun6
        fe80::%utun0/64 link#13 UcI utun0
        """
        let plan=try TunAddressPlan.make(routes:routes)
        expectTrue(plan.address4.hasPrefix("198.18."))
        expectEqual(plan.gateway4,String(plan.address4.split(separator:"/")[0]))
        expectEqual(TunAddressPlan.routePrefixes("100.64/10 link#1 UCS en0"),["100.64.0.0/10"])
        let corporate=routes+"\n198.18/16 10.251.1.1 UGSc utun6"
        let coexisting=try TunAddressPlan.make(routes:corporate,bypassCIDRs:["100.64.0.0/10"],physicalInterface:"en0")
        expectTrue(coexisting.address4.hasPrefix("100.64."))
        expectTrue(try TunAddressPlan.make(routes:corporate.replacingOccurrences(of:"100.64/10 192.168.1.1 UGSc en0",with:"100.64/10 10.251.1.1 UGSc utun6"),bypassCIDRs:["100.64.0.0/10"],physicalInterface:"en0").address4.hasPrefix("172.31."))
        expectTrue(try TunAddressPlan.make(routes:corporate.replacingOccurrences(of:"100.64/10 192.168.1.1 UGSc en0",with:"100.64/10 link#11 UCI en0"),bypassCIDRs:["100.64.0.0/10"],physicalInterface:"en0").address4.hasPrefix("172.31."))
        let occupied=routes+"\n198.18/15 link#1 UCS utun7"
        expectTrue(try TunAddressPlan.make(routes:occupied).address4.hasPrefix("172.31."))
        let full=occupied+"\n172.16/12 link#1 UCS utun6\n192.168/16 link#1 UCS utun6\n10/8 link#1 UCS utun6"
        expectThrows(try TunAddressPlan.make(routes:full))
        let partial=occupied+"\n172.31.1.2 link#1 UH en0"
        expectTrue(try TunAddressPlan.make(routes:partial).address4.hasPrefix("172.31.2."))
        expectTrue(try TunAddressPlan.make(routes:occupied+"\n172.16/12 link#1 UCS utun6").address4.hasPrefix("192.168."))
        expectTrue(try TunAddressPlan.make(routes:occupied+"\n172.16/12 link#1 UCS utun6\n192.168/16 link#1 UCS utun6").address4.hasPrefix("10.255."))
        let host=try TunAddressPlan.make(routes:"100.64.1.2 link#1 UH en0")
        expectFalse(host.address4.hasPrefix("100.64.1."))
        expectTrue(try TunAddressPlan.make(routes:"default fe80::%utun0 UGcI utun0").address4.hasPrefix("100.64."))
    }
    func testSpecificCorporateRoutesAndSystemTunnels() {
        let routes="""
        Destination Gateway Flags Netif
        10.56/14 10.251.1.1 UGSc utun6
        198.19/16 10.251.1.1 UGSc utun6
        52.52.210.40/32 10.251.1.1 UGSc utun6
        default fe80::%utun0 UGcIg utun0
        fe80::%utun0/64 link#13 UcI utun0
        """
        expectNil(NetworkInspection.conflicts(vpn:"",routes:routes,proxies:[:]))
        expectNil(NetworkInspection.conflicts(vpn:"* (Connected) Corporate VPN",routes:routes,proxies:[:]))
        for row in ["default link#22 UCSg utun7","0/1 link#22 UCS utun7","128.0/1 link#22 UCS utun7","1 link#22 UCS utun7","::/1 fd00::1 UGc utun7"] {
            expectTrue(NetworkInspection.conflicts(vpn:"",routes:routes+"\n"+row,proxies:[:]) != nil)
        }
    }
    func testMigrationAndImport() throws {
        let old=try JSONDecoder().decode(AppState.self,from:Data("{}".utf8))
        expectEqual(old.effectiveAddressFamilyPolicy,.ipv4Only)
        expectTrue(old.addressFamilyPolicy==nil)
        for policy in AddressFamilyPolicy.allCases {
            var state=old;state.addressFamilyPolicy=policy
            expectEqual(try JSONDecoder().decode(AppState.self,from:JSONEncoder().encode(state)).effectiveAddressFamilyPolicy,policy)
        }
        let legacyReply=try JSONDecoder().decode(TunReply.self,from:Data("{\"ok\":true,\"message\":\"old\",\"running\":false}".utf8))
        expectTrue(legacyReply.protocolVersion==nil)
        let request=TunRequest(operation:"prepare",httpCompatibilityPort:27900)
        let decoded=try JSONDecoder().decode(TunRequest.self,from:JSONEncoder().encode(request))
        expectEqual(decoded.protocolVersion,4);expectEqual(decoded.httpCompatibilityPort,27900)
        let resource=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/Resources/shadowrocket-default.json")
        var imported=try JSONDecoder().decode(ShadowrocketConfiguration.self,from:Data(contentsOf:resource))
        imported.general["ipv6"]="false"
        expectEqual(try imported.applying(to:old).effectiveAddressFamilyPolicy,.ipv4Only)
        imported.general["ipv6"]="true";imported.general["prefer-ipv6"]="false"
        expectEqual(try imported.applying(to:old).effectiveAddressFamilyPolicy,.preferIPv4)
        imported.general["prefer-ipv6"]="true"
        expectEqual(try imported.applying(to:old).effectiveAddressFamilyPolicy,.dualStack)
    }
    func testCoreNetworkMatrix() throws {
        let credentials=MemoryCredentials()
        let candidate=try NodeParser.parse("hy2://synthetic@127.0.0.1:19999")
        try credentials.set(candidate.secret,for:candidate.node.credentialRef)
        var state=AppState();state.nodes=[candidate.node];state.selectedPolicy = .node(candidate.node.id)
        state.rules=[RoutingRule(kind:.suffix,value:"corp.example",action:.direct)]
        let context=try CoreControlContext.make()
        for policy in AddressFamilyPolicy.allCases {
            state.addressFamilyPolicy=policy
            for dns in DNSPreference.allCases {
                state.dnsPreference=dns
                var configurations=[try ConfigBuilder.build(node:candidate.node,state:state,credentials:credentials),try ConfigBuilder.build(state:state,credentials:credentials,control:context)]
                state.captureMode = .tun
                configurations.append(try TunConfigBuilder.build(state:state,credentials:credentials,control:context,address4:"100.64.1.1/30",address6:"fd71:717a:1::1/126",originalDNS:["192.0.2.53"],bypass:[]))
                for data in configurations {
                    try validateCore(data)
                    let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
                    let effective=object["dns"] as! [String:Any]
                    expectEqual(effective["strategy"] as? String,policy.strategy)
                    let rules=(object["route"] as! [String:Any])["rules"] as! [[String:Any]]
                    let resolves=rules.filter{$0["action"] as? String == "resolve"};expectTrue(resolves.contains{$0["clash_mode"]==nil});expectTrue(resolves.allSatisfy{$0["strategy"] as? String==policy.strategy})
                    expectEqual(rules.contains{$0["ip_version"] as? Int == 6 && $0["action"] as? String == "reject"},policy == .ipv4Only)
                }
                state.captureMode = .systemProxy
            }
        }
        // 从工程资源读取兼容规则，只使用合成节点和内存凭据。
        let file=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/Resources/shadowrocket-default.json")
        let shadow=try JSONDecoder().decode(ShadowrocketConfiguration.self,from:Data(contentsOf:file))
        state=try shadow.applying(to:state);state.httpCompatibilityEnabled=true;state.addressFamilyPolicy = .ipv4Only;state.captureMode = .tun
        let data=try TunConfigBuilder.build(state:state,credentials:credentials,control:context,address4:"100.64.1.1/30",address6:"fd71:717a:1::1/126",originalDNS:["192.0.2.53"],bypass:[],httpCompatibilityPort:27900)
        try validateCore(data)
        let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let inbounds=object["inbounds"] as! [[String:Any]]
        expectTrue(inbounds.contains{$0["tag"] as? String == "tun-in"})
        expectTrue(inbounds.contains{$0["tag"] as? String == "http-compat-in" && $0["users"] != nil})
        let gateway=try shadow.gatewayData(listenPort:27890,corePort:27891,httpPort:27900,control:context,state:state)
        let gatewayObject=try JSONSerialization.jsonObject(with:gateway) as! [String:Any]
        expectEqual(gatewayObject["addressFamilyPolicy"] as? String,"ipv4Only")
    }
    private func validateCore(_ data:Data) throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("network.json");try SecureFile.write(data,to:file)
        let process=Process();process.executableURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/Vendor/sing-box");process.arguments=["check","-c",file.path]
        let output=Pipe();process.standardOutput=output;process.standardError=output;try process.run()
        let diagnostic=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        expectEqual(process.terminationStatus,0,String(data:diagnostic,encoding:.utf8) ?? "核心校验失败")
    }
}

@MainActor func runCaptureActivationChecks() async {
    for failedPhase in ["none","prepare","compatibility","activate"] {
        var events:[String]=[]
        func step(_ phase:String) throws {events.append(phase);if phase==failedPhase{throw ProxyError("合成阶段失败")}}
        do {try await CaptureActivationTransaction.run(prepare:{try step("prepare")},compatibility:{try step("compatibility")},activate:{try step("activate")},rollback:{events.append("rollback")});expectEqual(failedPhase,"none")}
        catch {expectTrue(failedPhase != "none")}
        let all=["prepare","compatibility","activate"]
        let expected=failedPhase=="none" ? all:Array(all.prefix(all.firstIndex(of:failedPhase)!+1))+["rollback"]
        expectEqual(events,expected)
    }
    do {try await CaptureActivationTransaction.run(prepare:{throw ProxyError("准备失败")},compatibility:{},activate:{},rollback:{throw ProxyError("所有权冲突")});expectTrue(false,"恢复失败不能报告成功")}
    catch {expectTrue(error.localizedDescription.contains("恢复失败"));expectTrue(error.localizedDescription.contains("所有权冲突"))}
    print("PASS CaptureActivation.phaseOrderingAndRollback")
}

@MainActor func runRecoveryContinuationChecks() async {
    for broken in ["proxy","helper","verify",""] {
        var steps:[String]=[]
        do {
            try await CaptureRecoveryTransaction.run(proxy:{steps.append("proxy");if broken=="proxy"{throw ProxyError("外部修改")}},helper:{steps.append("helper");if broken=="helper"{throw ProxyError("服务不可达")}},local:{steps.append("local")},verify:{steps.append("verify");if broken=="verify"{throw ProxyError("残留")}})
            expectEqual(broken,"")
        }catch {expectFalse(broken.isEmpty);expectTrue(error.localizedDescription.contains("恢复未完成"))}
        expectEqual(steps,["proxy","helper","local","verify"])
    }
    print("PASS CaptureRecovery.independentCleanupAndVerification")
}

@MainActor func runHelperRecoveryPolicyChecks() {
    for active in [false,true] {for running in [false,true] {for journal in [false,true] {for available in [false,true] {
        let required=HelperRecoveryPolicy.requiresRecovery(activeTunnel:active,running:running,journalPresent:journal,inspectionAvailable:available)
        if !active && !running && !journal && available {expectFalse(required,"旧 helper 无恢复记录不能阻塞系统代理")}else{expectTrue(required,"实际恢复证据不可忽略")}
    }}}}
    let script=HelperInstaller.authorizationScript(app:URL(fileURLWithPath:"/tmp/轻舟 \"\\ app.app"));expectTrue(script.hasSuffix("with administrator privileges"));expectTrue(script.contains("install-helper.sh"));expectTrue(script.contains("\\\""));print("PASS HelperRecovery.evidenceRequiredInsteadOfSocketPresence")
}

@MainActor func runDNSResolutionPolicyChecks() throws {
    let candidate=try NodeParser.parse("hy2://synthetic@127.0.0.1:19999"),credentials=MemoryCredentials();try credentials.set(candidate.secret,for:candidate.node.credentialRef)
    var state=AppState();state.nodes=[candidate.node];state.selectedPolicy = .node(candidate.node.id);state.rules=[RoutingRule(kind:.suffix,value:"corp.example",action:.direct)]
    for preference in [DNSPreference.system,.httpsProxy] {
        state.dnsPreference=preference
        let data=try ConfigBuilder.build(state:state,credentials:credentials,control:CoreControlContext(port:28999,secret:String(repeating:"a",count:64)))
        let object=try JSONSerialization.jsonObject(with:data) as! [String:Any];let rules=(object["route"] as! [String:Any])["rules"] as! [[String:Any]]
        let resolve=rules.filter{$0["action"] as? String=="resolve"}
        expectNil(resolve.last?["server"])
        let dns=object["dns"] as! [String:Any]
        expectTrue((dns["rules"] as! [[String:Any]]).contains{($0["domain_suffix"] as? [String])==["corp.example"] && $0["server"] as? String=="local"})
    }
    print("PASS DNS.resolveStageRespectsProxyAndCorporatePolicies")
}

@MainActor func runHelperReadinessChecks() async {
    var attempts=0
    do {
        let reply=try await HelperReadiness.wait(timeout:0.2,interval:0.001) {
            attempts+=1
            if attempts<3 {throw HelperConnectionError(code:ECONNREFUSED)}
            return TunReply(ok:true,message:"ready")
        }
        expectEqual(attempts,3);expectEqual(reply.message,"ready")
    }catch{CheckHarness.failure("辅助服务短暂启动错误未恢复",file:#filePath,line:#line)}
    for native in [false,true] {
        attempts=0
        do {
            _=try await HelperReadiness.wait(timeout:0.1,interval:0.001) {
                attempts+=1
                if native {throw HelperConnectionError(code:EINVAL)}
                throw ProxyError("客户端身份不允许")
            }
            CheckHarness.failure("不应吞掉身份或永久连接错误",file:#filePath,line:#line)
        }catch{expectEqual(attempts,1)}
    }
    let started=Date();attempts=0
    do {
        _=try await HelperReadiness.wait(timeout:0.02,interval:0.005) {attempts+=1;throw HelperConnectionError(code:ENOENT)}
        CheckHarness.failure("辅助服务就绪检查应有截止时间",file:#filePath,line:#line)
    }catch{expectTrue(attempts>=2);expectTrue(Date().timeIntervalSince(started)<1)}
    let task=Task {try await HelperReadiness.wait(timeout:5) {throw HelperConnectionError(code:EACCES)}}
    task.cancel()
    do {_=try await task.value;CheckHarness.failure("取消应停止辅助服务重试",file:#filePath,line:#line)}catch{expectTrue(error is CancellationError)}
    print("PASS HelperReadiness.startupRetryDeadlineIdentityAndCancellation")
}
