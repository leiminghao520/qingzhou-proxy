import Foundation
import QingzhouKit
import Darwin

final class CapturePlanTests:CheckCase {
    func fixture()->NetworkSnapshot {
        NetworkSnapshot(primaryInterface:"en0",routes:[ProtectedRoute(destination:"10.20.0.0/16",gateway:"link#15",interface:"utun6",scope:"utun6"),ProtectedRoute(destination:"203.0.113.0/24",gateway:"link#15",interface:"utun6"),ProtectedRoute(destination:"fd12::/48",gateway:"link#15",interface:"utun6"),ProtectedRoute(destination:"192.168.66.0/24",gateway:"link#4",interface:"en0")],resolvers:[DNSResolverScope(service:"corp",interface:"utun6",servers:["10.20.0.53","10.20.0.54"],domains:["corp.example"],searchDomains:["corp.example"],order:100),DNSResolverScope(service:"wifi",interface:"en0",servers:["192.168.66.1","192.168.66.2"])])
    }
    func testProtectionAndResolverSelection() throws {
        let plan=try CapturePlan.make(snapshot:fixture(),extraCIDRs:["100.64.0.0/10"],extraDomains:["private.example"])
        expectEqual(plan.originalInterface(for:"203.0.113.10"),"utun6");expectEqual(plan.originalInterface(for:"8.8.8.8"),"en0")
        expectEqual(try plan.nodeInterfaces(["node":["203.0.113.10"]],family:.ipv4Only)["node"],"utun6")
        expectThrows(try plan.nodeInterfaces(["node":["203.0.113.10","8.8.8.8"]],family:.dualStack))
        expectEqual(plan.protectedRoutes.count,4);expectTrue(plan.summary.contains("203.0.113.0/24 → utun6"))
        expectEqual(plan.resolvers(for:"api.corp.example").first?.interface,"utun6")
        expectEqual(plan.resolvers(for:"notcorp.example").first?.interface,"en0")
        expectEqual(plan.resolvers(for:"host.private.example").first?.servers,["10.20.0.53","10.20.0.54"])
        expectEqual(plan.resolvers(for:"shortname").first?.interface,"utun6")
        var nested=fixture();nested.resolvers.insert(DNSResolverScope(service:"nested",interface:"utun7",servers:["10.21.0.53"],domains:["dev.corp.example"],order:10),at:0)
        expectEqual(try CapturePlan.make(snapshot:nested,extraCIDRs:[],extraDomains:[]).resolvers(for:"a.dev.corp.example").map(\.service),["nested"])
        var bad=fixture();bad.routes.append(ProtectedRoute(destination:"0.0.0.0/1",gateway:"link#15",interface:"utun6"));expectThrows(try CapturePlan.make(snapshot:bad,extraCIDRs:[],extraDomains:[]))
        expectThrows(try CapturePlan.make(snapshot:fixture(),extraCIDRs:["0.0.0.0/0"],extraDomains:[]))
        expectThrows(try CapturePlan.make(snapshot:fixture(),extraCIDRs:[],extraDomains:["*.bad"]))
        var noVPN=fixture();noVPN.resolvers.removeAll{$0.interface=="utun6"};expectThrows(try CapturePlan.make(snapshot:noVPN,extraCIDRs:[],extraDomains:["private.example"]))
    }
    func query(_ name:String)->Data {var bytes:[UInt8]=[0x12,0x34,1,0,0,1,0,0,0,0,0,0];for label in name.split(separator:"."){bytes.append(UInt8(label.utf8.count));bytes+=label.utf8};bytes += [0,0,1,0,1];return Data(bytes)}
    func testDNSRetriesAndNoPublicFallback() throws {
        let plan=try CapturePlan.make(snapshot:fixture(),extraCIDRs:[],extraDomains:[]),relay=try ScopedDNSForwarder(plan:plan),request=query("api.corp.example")
        expectEqual(DNSPacket.name(request),"api.corp.example");expectNil(DNSPacket.name(Data()));expectNil(DNSPacket.name(Data([UInt8](repeating:0,count:12))))
        var contacted:[String]=[]
        let answer=relay.resolve(request,name:"api.corp.example",exchange:{data,server,interface in contacted.append(server+"@"+interface);if server=="10.20.0.53"{return DNSPacket.failure(data)};var response=data;response[2]|=0x80;return response})
        expectEqual(answer[3]&15,0);expectEqual(contacted,["10.20.0.53@utun6","10.20.0.54@utun6"])
        contacted=[]
        let failed=relay.resolve(request,name:"api.corp.example",exchange:{data,server,_ in contacted.append(server);return nil})
        expectEqual(failed[3]&15,2);expectEqual(contacted,["10.20.0.53","10.20.0.54"])
        var mismatched=answer;mismatched[0]=0;expectFalse(DNSPacket.acceptable(mismatched,query:request))
        var nxdomain=answer;nxdomain[3]=3;expectTrue(DNSPacket.acceptable(nxdomain,query:request))
        relay.stop()
    }
    func testLoopbackRelay() throws {
        let plan=try CapturePlan.make(snapshot:fixture(),extraCIDRs:[],extraDomains:[])
        let relay=try ScopedDNSForwarder(plan:plan,transport:{data,_,interface in guard interface=="utun6" else{return nil};var response=data;response[2]|=0x80;return response})
        relay.start();defer{relay.stop()};expectTrue(relay.probe(plan.snapshot.resolvers[0]))
        let descriptor=socket(AF_INET,SOCK_DGRAM,0);defer{close(descriptor)}
        var timeout=timeval(tv_sec:2,tv_usec:0);_=setsockopt(descriptor,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(relay.port).bigEndian;address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let request=query("socket.corp.example")
        let sent=request.withUnsafeBytes{bytes in withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){sendto(descriptor,bytes.baseAddress,request.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}};expectEqual(sent,request.count)
        var buffer=[UInt8](repeating:0,count:4096);let length=recv(descriptor,&buffer,buffer.count,0);expectTrue(length>0);if length>0 {expectTrue(DNSPacket.acceptable(Data(buffer.prefix(length)),query:request))}
    }
    func testRouteParsingAndOwnership() throws {
        let rows="10.20/16 link#15 UCSI utun6\n203.0.113 link#15 UCS utun6\nfd12::/48 link#15 Uc utun6\n172.217.0.1 192.168.66.1 UHW en0\nfe80::%utun6/64 link#15 UcI utun6"
        let parsed=NetworkSnapshot.parseRoutes(rows);expectEqual(parsed.count,4);expectEqual(parsed[0].destination,"10.20.0.0/16");expectEqual(parsed[0].scope,"utun6")
        let original:[String:Any]=["ExceptionsList":["old.example"],"ExcludeSimpleHostnames":0]
        var applied=ProxyRecovery.applied(to:original,port:27890);applied["ExceptionsList"]=["corp.example"];applied["ExcludeSimpleHostnames"]=1
        expectEqual(ProxyRecovery.restored(original:original,applied:applied,current:applied)?["ExceptionsList"] as? [String],["old.example"])
        var external=applied;external["ExceptionsList"]=["external.example"];expectNil(ProxyRecovery.restored(original:original,applied:applied,current:external))
        expectEqual(ProxyRecovery.changedOwnedKeys(expected:applied,current:external,protectsExceptions:true),["ExceptionsList"])
        let encoded=try JSONEncoder().encode(AppState());expectEqual(try JSONDecoder().decode(AppState.self,from:encoded).captureMode,.systemProxy)
        var state=AppState();state.captureMode = .compatible;state.protectedDomains=["corp.example"];let decoded=try JSONDecoder().decode(AppState.self,from:JSONEncoder().encode(state));expectEqual(decoded.captureMode,.compatible);expectEqual(decoded.protectedDomains,["corp.example"])
        expectTrue(CaptureMode.compatible.usesTunnel);expectFalse(CaptureMode.systemProxy.usesTunnel)
    }
    func testCoreConfigurationProtectionPrecedence() throws {
        let candidate=try NodeParser.parse("ss://YWVzLTEyOC1nY206cA==@127.0.0.1:19999"),credentials=MemoryCredentials();try credentials.set(candidate.secret,for:candidate.node.credentialRef)
        var state=AppState();state.nodes=[candidate.node];state.selectedPolicy = .node(candidate.node.id);state.captureMode = .compatible
        let plan=try CapturePlan.make(snapshot:fixture(),extraCIDRs:[],extraDomains:[])
        let data=try TunConfigBuilder.build(state:state,credentials:credentials,control:CoreControlContext(port:28999,secret:String(repeating:"a",count:64)),address4:"100.64.1.1/30",address6:"fd71:717a:1::1/126",originalDNS:["192.168.66.1"],bypass:[],plan:plan,dnsForwardPort:29000)
        let object=try JSONSerialization.jsonObject(with:data) as! [String:Any],route=object["route"] as! [String:Any],rules=route["rules"] as! [[String:Any]]
        let protection=rules.firstIndex{$0["outbound"] as? String == "protected-utun6"}!,reject=rules.firstIndex{$0["ip_version"] as? Int==6 && $0["action"] as? String == "reject"}!
        expectTrue(protection<reject)
        let dns=object["dns"] as! [String:Any],servers=dns["servers"] as! [[String:Any]];expectEqual(servers.first?["server_port"] as? Int,29000)
        let domainRule=(dns["rules"] as! [[String:Any]]).first!;expectEqual(domainRule["server"] as? String,"local")
        let file=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString+".json");try data.write(to:file);defer{try? FileManager.default.removeItem(at:file)}
        let core=Process();core.executableURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/sing-box");core.arguments=["check","-c",file.path];try core.run();core.waitUntilExit();expectEqual(core.terminationStatus,0)
    }
}
