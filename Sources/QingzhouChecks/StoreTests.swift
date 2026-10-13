import Foundation
import QingzhouKit

final class FailingCredentials: CredentialStore {
    let underlying = MemoryCredentials(); var fail = false
    func get(_ ref:String) throws -> String {try underlying.get(ref)}
    func set(_ value:String,for ref:String) throws {if fail {throw ProxyError("模拟钥匙串失败")};try underlying.set(value,for:ref)}
    func remove(_ ref:String) throws {try underlying.remove(ref)}
}
final class StoreTests: CheckCase {
    var dir: URL!
    override func setUpWithError() throws {dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)}
    override func tearDownWithError() throws {try FileManager.default.removeItem(at:dir)}
    func testManualDeduplicationAndSecretsNotPersisted() throws {
        let credentials = MemoryCredentials();let file = dir.appendingPathComponent("state.json");let store = try NodeStore(file:file,credentials:credentials)
        let c = try NodeParser.parse("hy2://secret-value@example.com?obfs=salamander&obfs-password=obfs-value")
        expectEqual(try store.importNodes([c]),1);expectEqual(try store.importNodes([c]),0)
        let data = try String(contentsOf:file,encoding:.utf8);expectFalse(data.contains("secret-value"));expectFalse(data.contains("obfs-value"));expectEqual(store.state.selectedID,store.state.nodes.first?.id)
        let attributes = try FileManager.default.attributesOfItem(atPath:file.path);expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        expectEqual(try NodeStore(file:file,credentials:credentials).state.nodes.count,1)
        let node = store.state.nodes[0];try store.deleteNode(node.id);expectTrue(store.state.nodes.isEmpty);expectNil(store.state.selectedID);expectThrows(try credentials.get(node.credentialRef))
    }
    func testSubscriptionUpdateKeepsIDAndManualNodes() throws {
        let credentials = MemoryCredentials();let store = try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:credentials)
        try store.importNodes([try NodeParser.parse("hy2://manual@manual.example")])
        let sub = Subscription(name:"测试订阅");let source = "https://example.com/private-token/hy2.txt"
        try store.importNodes([try NodeParser.parse("hy2://old@node.example")],subscription:sub,source:source)
        let original = store.state.nodes.first {$0.subscriptionID == sub.id}!
        var selected = store.state;selected.selectedID = original.id;try store.commit(selected)
        try store.importNodes([try NodeParser.parse("hy2://new@node.example#改名")],subscription:store.state.subscriptions[0],source:source)
        let updated = store.state.nodes.first {$0.subscriptionID == sub.id}!
        expectEqual(updated.id,original.id);expectEqual(store.state.selectedID,original.id);expectEqual(try credentials.get(updated.credentialRef),"new");expectThrows(try credentials.get(original.credentialRef));expectEqual(store.state.nodes.count,2)
        expectFalse(try String(contentsOf:store.file,encoding:.utf8).contains("private-token"))
        try store.importNodes([try NodeParser.parse("hy2://other@other.example")],subscription:store.state.subscriptions[0],source:source)
        expectNil(store.state.selectedID);try store.deleteSubscription(sub.id);expectEqual(store.state.nodes.count,1);expectTrue(store.state.subscriptions.isEmpty)
    }
    func testFailureLeavesOldStateAndCredentials() throws {
        let credentials = FailingCredentials();let store = try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:credentials)
        let sub = Subscription(name:"订阅");try store.importNodes([try NodeParser.parse("hy2://old@node.example")],subscription:sub,source:"https://example.com/hy2.txt")
        let old = store.state.nodes[0];let data = try Data(contentsOf:store.file)
        credentials.fail = true
        expectThrows(try store.importNodes([try NodeParser.parse("hy2://new@node.example")],subscription:sub))
        expectEqual(store.state.nodes[0],old);expectEqual(try Data(contentsOf:store.file),data);expectEqual(try credentials.get(old.credentialRef),"old")
    }
    func testEditAndConflict() throws {
        let store = try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:MemoryCredentials())
        let a = try NodeParser.parse("hy2://a@example.com"),b = try NodeParser.parse("hy2://b@example.com")
        expectThrows(try store.importNodes([a,b]));expectTrue(store.state.nodes.isEmpty)
        try store.importNodes([a,a]);let id = store.state.nodes[0].id
        try store.importNodes([b],replacingID:id);expectEqual(store.state.nodes[0].id,id);expectEqual(store.state.nodes.count,1)
        expectThrows(try store.importNodes([]))
    }
    func testUnsupportedStateIsNotOverwritten() throws {
        let url = dir.appendingPathComponent("state.json");var state = AppState();state.schemaVersion = 2
        let data = try JSONEncoder().encode(state);try data.write(to:url)
        expectThrows(try NodeStore(file:url,credentials:MemoryCredentials()));expectEqual(try Data(contentsOf:url),data)
    }
}
