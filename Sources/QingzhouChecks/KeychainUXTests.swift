import Foundation
import Security
import QingzhouKit

final class KeychainUXTests:CheckCase {
    func testAuthorizationRetryAndCache() throws {
        var calls=0;var status=errSecUserCanceled;var allowed=false
        let store=KeychainStore(read:{query in calls+=1;allowed=(query[kSecUseAuthenticationUI as String] as? String)==(kSecUseAuthenticationUIAllow as String);return (status,status==errSecSuccess ? Data("synthetic".utf8):nil)},update:{_,_ in errSecSuccess},delete:{_ in errSecSuccess})
        expectThrows(try store.get("node")){error in expectTrue(error.localizedDescription.contains("已取消"))};expectTrue(allowed)
        status=errSecSuccess;expectEqual(try store.get("node"),"synthetic");expectEqual(try store.get("node"),"synthetic");expectEqual(calls,2)
        try store.set("changed",for:"node");expectEqual(try store.get("node"),"changed");expectEqual(calls,2)
        try store.remove("node");expectEqual(try store.get("node"),"synthetic");expectEqual(calls,3)
    }
    func testInjectedStoresStayIsolated() throws {
        let first=KeychainStore(read:{_ in (errSecSuccess,Data("first".utf8))})
        let second=KeychainStore(read:{_ in (errSecSuccess,Data("second".utf8))})
        expectEqual(try first.get("same"),"first");expectEqual(try second.get("same"),"second")
    }
    func testHelperComponentComparison() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let app=root.appendingPathComponent("App.app"),installed=root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at:app.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:installed,withIntermediateDirectories:true)
        expectFalse(HelperInstaller.componentsMatch(app:app,directory:installed))
        for name in ["QingzhouHelper","sing-box"] {
            try Data(name.utf8).write(to:app.appendingPathComponent("Contents/Resources/"+name))
            try Data(name.utf8).write(to:installed.appendingPathComponent(name))
        }
        expectTrue(HelperInstaller.componentsMatch(app:app,directory:installed))
        try Data("changed".utf8).write(to:installed.appendingPathComponent("sing-box"))
        expectFalse(HelperInstaller.componentsMatch(app:app,directory:installed))
    }
    func testDistinctErrorsAndAtomicCache() throws {
        for (status,word) in [(errSecItemNotFound,"不存在"),(errSecAuthFailed,"未通过"),(errSecInteractionNotAllowed,"前台"),(errSecNotAvailable,"暂不可用")] {
            let store=KeychainStore(read:{_ in (status,nil)});expectThrows(try store.get("node")){error in expectTrue(error.localizedDescription.contains(word))}
        }
        let corrupt=KeychainStore(read:{_ in (errSecSuccess,Data([255]))});expectThrows(try corrupt.get("node")){error in expectTrue(error.localizedDescription.contains("格式损坏"))}
        expectTrue(KeychainFailure.message(-9999,operation:"读取").contains("-9999"))
        var updateStatus=errSecSuccess;var addStatus=errSecSuccess;var removed=errSecAuthFailed
        let store=KeychainStore(read:{_ in (errSecItemNotFound,nil)},update:{_,_ in updateStatus},add:{_ in addStatus},delete:{_ in removed})
        try store.set("old",for:"node");updateStatus=errSecAuthFailed;expectThrows(try store.set("new",for:"node"));expectEqual(try store.get("node"),"old")
        expectThrows(try store.remove("node"));expectEqual(try store.get("node"),"old");removed=errSecItemNotFound;try store.remove("node");expectThrows(try store.get("node"))
        updateStatus=errSecItemNotFound;addStatus=errSecAuthFailed;expectThrows(try store.set("secret",for:"new"));expectThrows(try store.get("new"))
        addStatus=errSecSuccess;try store.set("saved",for:"new");expectEqual(try store.get("new"),"saved")
    }
}
