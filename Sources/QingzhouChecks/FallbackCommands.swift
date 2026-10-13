import Foundation
import QingzhouKit

func runFallbackChecks(_ args:[String]) async throws {
    let context=try JSONDecoder().decode(ControlFixture.self,from:Data(contentsOf:URL(fileURLWithPath:args[2])));let fixture=try JSONDecoder().decode(FeatureFixture.self,from:Data(contentsOf:URL(fileURLWithPath:args[3])));guard fixture.nodes.count>=3,fixture.groups.count>=2 else{throw ProxyError("回退测试夹具不完整")}
    let client=CoreAPIClient(context:CoreControlContext(port:context.port,secret:context.secret));let group=PolicyReference.group(fixture.groups[1]).tag;let a=fixture.nodes[0],b=fixture.nodes[1],dead=fixture.nodes[2];let priority=[dead,a,b];var controller=FallbackController();let now=Date()
    try await client.select(.node(dead),group:group);try await client.select(.group(fixture.groups[1]))
    var results:[UUID:Bool]=[:];for id in priority{results[id]=(try? await client.delay(id)) != nil};expectFalse(results[dead] ?? true);expectTrue(results[a] ?? false);expectTrue(results[b] ?? false)
    let first=controller.evaluate(priority:priority,current:dead,results:results,now:now);expectEqual(first.selected,dead)
    let second=controller.evaluate(priority:priority,current:dead,results:results,now:now.addingTimeInterval(60));expectEqual(second.selected,a);if let selected=second.selected{try await client.select(.node(selected),group:group)}
    let info=try await client.proxies();expectEqual(CoreAPIClient.actualTag(info),PolicyReference.node(a).tag);print("PASS FallbackAPI.realHTTPSHealthAndSelectorSwitch")
    let unavailable=controller.evaluate(priority:[dead],current:dead,results:[dead:false],now:now.addingTimeInterval(120));expectTrue(unavailable.unavailable);expectNil(unavailable.selected);print("PASS FallbackAPI.noDirectBackupOnAllFailure")
    await client.shutdown()
}
