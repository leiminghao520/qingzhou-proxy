import Foundation
import CryptoKit
import QingzhouKit

final class FullSubscriptionTests:CheckCase {
    func document(_ configuration:ShadowrocketConfiguration) throws -> String {
        let data=try JSONEncoder().encode(configuration)
        let revision=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        let object:[String:Any]=["format":"qingzhou.subscription","version":1,"name":"合成完整配置","revision":revision,"configurationJSON":String(decoding:data,as:UTF8.self),"nodes":["hy2://synthetic@example.com"]]
        return String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
    }
    func configuration() throws -> ShadowrocketConfiguration {
        try JSONDecoder().decode(ShadowrocketConfiguration.self,from:Data(contentsOf:URL(fileURLWithPath:"Resources/shadowrocket-default.json")))
    }
    func testFullSyncPreservesLocalRulesAndRollback() throws {
        let configuration=try configuration()
        let preview=try ProfileImporter.parse(document(configuration))
        expectEqual(preview.fullConfiguration?.rules.count,619)
        expectEqual(preview.rules.count,627)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let credentials=MemoryCredentials();let store=try NodeStore(file:dir.appendingPathComponent("state.json"),credentials:credentials)
        var state=try configuration.applying(to:store.state)
        let local=RoutingRule(kind:.domain,value:"local-only.example",action:.direct)
        state.rules.append(local);state.dnsPreference = .httpsProxy;state.captureMode = .compatible;try store.commit(state)
        let sub=Subscription(name:"合成订阅")
        let tx=try store.prepareImport(preview.candidates,subscription:sub,source:"https://synthetic.example/qingzhou.json",profile:preview,scope:.profile)
        try store.commit(tx)
        expectEqual(store.state.rules.count,628)
        expectEqual(store.state.rules.filter{$0.subscriptionID==nil}.map(\.id),[local.id])
        expectEqual(store.state.dnsPreference,.httpsProxy);expectEqual(store.state.captureMode,.compatible)
        expectEqual(store.state.subscriptions[0].revision,preview.revision)
        var changed=configuration
        let row=changed.rules[0]
        changed.rules.insert(row,at:0)
        let fresh=try ProfileImporter.parse(document(changed))
        let update=try store.prepareImport(fresh.candidates,subscription:store.state.subscriptions[0],source:"https://synthetic.example/qingzhou.json",profile:fresh,scope:.profile)
        store.abort(update)
        expectEqual(store.state.rules.count,628)
        expectEqual(store.state.dnsPreference,.httpsProxy);expectEqual(store.state.captureMode,.compatible)
        expectEqual(store.state.subscriptions[0].revision,preview.revision)
        let success=try store.prepareImport(fresh.candidates,subscription:store.state.subscriptions[0],source:"https://synthetic.example/qingzhou.json",profile:fresh,scope:.profile)
        try store.commit(success)
        expectEqual(store.state.rules.count,629)
        expectEqual(store.state.rules.first?.id,local.id)
        expectEqual(store.state.dnsPreference,.httpsProxy);expectEqual(store.state.captureMode,.compatible)
        expectEqual(store.state.subscriptions[0].revision,fresh.revision)
        expectEqual(try NodeStore(file:store.file,credentials:credentials).state.rules.count,629)
    }
    func testInvalidDocumentsPreserveOldData() throws {
        let text=try document(configuration())
        let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]
        for (key,value) in [("revision","bad" as Any),("version",2),("name",""),("nodes",[]),("configurationJSON","{}"),("nodes",[1])] {
            var invalid=object;invalid[key]=value
            let data=try JSONSerialization.data(withJSONObject:invalid)
            expectThrows(try ProfileImporter.parse(String(decoding:data,as:UTF8.self)))
        }
        expectNil(try FullSubscription.parse("hy2://synthetic@example.com"))
        expectNil(try FullSubscription.parse("{}"))
    }
}
