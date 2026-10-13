import Foundation
import QingzhouKit

struct ControlFixture:Codable {var port:Int;var secret:String}
struct FeatureFixture:Codable {var nodes:[UUID];var groups:[UUID]}
func writeFeatureConfig(_ args:[String]) throws {
    guard args.count>=8 else {throw ProxyError("测试配置参数缺失")}
    let preview=try ProfileImporter.parse(String(contentsOfFile:args[2],encoding:.utf8))
    guard !preview.candidates.isEmpty,preview.unsupported.isEmpty else {throw ProxyError("测试配置导入失败")}
    let context=try JSONDecoder().decode(ControlFixture.self,from:Data(contentsOf:URL(fileURLWithPath:args[5])))
    let credentials=MemoryCredentials();var state=AppState();state.nodes=preview.candidates.map(\.node);state.groups=preview.groups;state.rules=preview.rules;state.ruleFinal=preview.final;state.selectedPolicy=state.nodes.first.map{.node($0.id)};state.listenPort=Int(args[4]) ?? 0;state.mode=ProxyMode(rawValue:args[7]) ?? .global
    for c in preview.candidates {try credentials.set(c.secret,for:c.node.credentialRef);if let obfs=c.obfsSecret{try credentials.set(obfs,for:c.node.credentialRef+".obfs")}}
    try SecureFile.write(ConfigBuilder.build(state:state,credentials:credentials,control:CoreControlContext(port:context.port,secret:context.secret)),to:URL(fileURLWithPath:args[3]))
    try SecureFile.write(JSONEncoder().encode(FeatureFixture(nodes:state.nodes.map(\.id),groups:state.groups.map(\.id))),to:URL(fileURLWithPath:args[6]))
    print("V02_CONFIG_OK")
}
func runFeatureAPIChecks(_ args:[String]) async throws {
    let context=try JSONDecoder().decode(ControlFixture.self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
    let fixture=try JSONDecoder().decode(FeatureFixture.self,from:Data(contentsOf:URL(fileURLWithPath:args[3])))
    let client=CoreAPIClient(context:CoreControlContext(port:context.port,secret:context.secret))
    let wrong=CoreAPIClient(context:CoreControlContext(port:context.port,secret:"wrong-secret"))
    do{_=try await wrong.proxies();CheckHarness.failure("错误密钥不应允许访问",file:#filePath,line:#line)}catch{expectFalse(error.localizedDescription.contains(context.secret))};await wrong.shutdown();print("PASS FeatureAPI.invalidAuthenticationRejected")
    let proxies=try await client.proxies();expectTrue(proxies["proxy"] != nil);expectTrue(proxies["auto"] != nil);expectEqual(proxies["auto"]?.all?.count,fixture.nodes.count);expectFalse(proxies["auto"]?.all?.contains("direct") ?? true);print("PASS FeatureAPI.strategyInventory")
    try await client.select(.node(fixture.nodes[1]));let selected=try await client.proxies();expectEqual(selected["proxy"]?.now,PolicyReference.node(fixture.nodes[1]).tag);print("PASS FeatureAPI.hotSelectNode")
    if let group=fixture.groups.first {try await client.select(.node(fixture.nodes[0]),group:PolicyReference.group(group).tag);try await client.select(.group(group));let p=try await client.proxies();expectEqual(CoreAPIClient.actualTag(p),PolicyReference.node(fixture.nodes[0]).tag);print("PASS FeatureAPI.nestedGroupSelection")}
    try await client.setMode(.direct);try await client.setMode(.global);print("PASS FeatureAPI.modeAPI")
    let delay=try await client.delay(fixture.nodes[0]);expectTrue(delay>=0);print("PASS FeatureAPI.realHTTPSDelay")
    if fixture.nodes.count>=3 {do{_=try await client.delay(fixture.nodes[2]);CheckHarness.failure("不可用节点不应返回延迟",file:#filePath,line:#line)}catch{};print("PASS FeatureAPI.unavailableNodeDelayFails")}
    if fixture.nodes.count>=4 {
        let began=Date();let test=Task{try await client.delay(fixture.nodes[3])};try await Task.sleep(nanoseconds:100_000_000);test.cancel()
        do{_=try await test.value;CheckHarness.failure("取消测速不应成功",file:#filePath,line:#line)}catch{}
        expectTrue(Date().timeIntervalSince(began)<2);print("PASS FeatureAPI.cancelHTTPSDelay")
        let timeoutStart=Date();do{_=try await client.delay(fixture.nodes[3]);CheckHarness.failure("超时节点不应成功",file:#filePath,line:#line)}catch{}
        let elapsed=Date().timeIntervalSince(timeoutStart);expectTrue(elapsed>=7 && elapsed<10);print("PASS FeatureAPI.eightSecondTimeout")
    }
    let first=try await client.connections();expectTrue(first.uploadTotal>0);expectTrue(first.downloadTotal>0);expectTrue(first.connections.count>=2);print("PASS FeatureAPI.realConnectionCounters")
    if first.connections.count>=2 {let close=first.connections[0].id,keep=first.connections[1].id;try await client.closeConnection(close);try await Task.sleep(nanoseconds:200_000_000);let second=try await client.connections();expectFalse(second.connections.contains{$0.id==close});expectTrue(second.connections.contains{$0.id==keep});print("PASS FeatureAPI.closeOnlySelectedConnection")}
    let stream=try await client.traffic();var iterator=stream.makeAsyncIterator();if let rate=try await iterator.next(){expectTrue(rate.up>=0);expectTrue(rate.down>=0);print("PASS FeatureAPI.websocketTraffic")}
    try await client.closeAllConnections();try await Task.sleep(nanoseconds:100_000_000);let empty=try await client.connections();expectTrue(empty.connections.isEmpty);print("PASS FeatureAPI.closeAllConnections")
    await client.shutdown()
}
