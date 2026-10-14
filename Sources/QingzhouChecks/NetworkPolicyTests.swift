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

        expectEqual(NetworkInspection.routePrefix(destination:"default",mask:"128.0.0.0"),"0.0.0.0/1")
        expectEqual(NetworkInspection.routePrefix(destination:"default",mask:"8000::"),"::/1")
        expectEqual(NetworkInspection.routePrefix(destination:"default",mask:"0.0.0.0"),"0.0.0.0/0")
        expectFalse(NetworkInspection.samePrefix(NetworkInspection.routePrefix(destination:"default",mask:"128.0.0.0")!,"0.0.0.0/0"))
        expectNil(NetworkInspection.routePrefix(destination:"default",mask:"default"))
        expectNil(NetworkInspection.routePrefix(destination:"default",mask:"255.1.0.0"))
        expectNil(NetworkInspection.routePrefix(destination:"default",mask:"128.0.0.0",host:true))
        expectEqual(NetworkInspection.routeArguments(.get,destination:"111.132.47.193",scope:"en0"),["-n","get","-ifscope","en0","111.132.47.193"])
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
        expectEqual(decoded.protocolVersion,3);expectEqual(decoded.httpCompatibilityPort,27900)
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
                    expectEqual(rules.filter{$0["action"] as? String == "resolve"}.count,2)
                    expectEqual(rules.contains{$0["ip_version"] as? Int == 6 && $0["action"] as? String == "reject"},policy == .ipv4Only)
                }
                state.captureMode = .systemProxy
            }
        }
        // 从工程资源读取兼容规则，只使用合成节点和内存凭据。
        let file=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/Resources/shadowrocket-default.json")
        let shadow=try JSONDecoder().decode(ShadowrocketConfiguration.self,from:Data(contentsOf:file))
        state=try shadow.applying(to:state);state.addressFamilyPolicy = .ipv4Only;state.captureMode = .tun
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
