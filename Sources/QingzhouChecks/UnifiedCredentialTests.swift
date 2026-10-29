import Foundation
import Security
import QingzhouKit

private final class VaultFixture: CredentialStore {
    var values:[String:String]=[:]
    var reads:[String]=[]
    var writes=0
    var failWrite=false
    var readFailure:Error?
    func get(_ ref:String) throws -> String {
        reads.append(ref)
        if let readFailure {throw readFailure}
        guard let value=values[ref] else {throw MissingCredential()};return value
    }
    func set(_ value:String,for ref:String) throws {
        writes+=1;if failWrite {throw ProxyError("模拟保存失败")};values[ref]=value
    }
    func remove(_ ref:String) throws {values.removeValue(forKey:ref)}
}
final class UnifiedCredentialTests: CheckCase {
    func testMergeAndSingleRead() throws {
        let backend=VaultFixture();backend.values=["one":"alpha","two":"beta"]
        let first=UnifiedCredentialStore(legacy:backend)
        expectEqual(try first.get("one"),"alpha");expectEqual(try first.get("two"),"beta")
        expectEqual(backend.reads,[UnifiedCredentialStore.account,"one","two"])
        expectEqual(backend.values["one"],"alpha")
        backend.reads=[]
        let restarted=UnifiedCredentialStore(legacy:backend)
        expectEqual(try restarted.get("two"),"beta");expectEqual(try restarted.get("one"),"alpha")
        expectEqual(backend.reads,[UnifiedCredentialStore.account])
        try restarted.set("gamma",for:"three");expectEqual(try restarted.get("three"),"gamma")
        expectEqual(backend.reads,[UnifiedCredentialStore.account])
    }
    func testMissingAndTombstones() throws {
        let backend=VaultFixture();backend.values=["node":"old"]
        let first=UnifiedCredentialStore(legacy:backend)
        expectThrows(try first.get("missing"))
        try first.remove("node")
        let restarted=UnifiedCredentialStore(legacy:backend)
        expectThrows(try restarted.get("node"))
        expectTrue(backend.values["node"] != nil)
        try restarted.set("new",for:"node")
        expectEqual(try UnifiedCredentialStore(legacy:backend).get("node"),"new")
        expectThrows(try restarted.get(UnifiedCredentialStore.account))
        expectThrows(try restarted.set("bad",for:UnifiedCredentialStore.account))
        expectThrows(try restarted.remove(UnifiedCredentialStore.account))
    }
    func testFailureAtomicity() throws {
        let backend=VaultFixture();backend.values=["node":"legacy"]
        let store=UnifiedCredentialStore(legacy:backend)
        backend.failWrite=true
        expectEqual(try store.get("node"),"legacy")
        expectTrue(backend.values[UnifiedCredentialStore.account]==nil)
        expectThrows(try store.set("changed",for:"node"))
        backend.failWrite=false;expectEqual(try store.get("node"),"legacy")
        try store.set("saved",for:"node")
        backend.failWrite=true;expectThrows(try store.remove("node"));expectEqual(try store.get("node"),"saved")
        expectEqual(try UnifiedCredentialStore(legacy:backend).get("node"),"saved")
    }
    func testCorruptionAndDeniedAreNotMissing() throws {
        for value in ["bad","{\"version\":2,\"values\":{},\"removed\":[]}","{\"version\":1,\"values\":{\"qingzhou.credentials.unified.v1\":\"bad\"},\"removed\":[]}"] {
            let backend=VaultFixture();backend.values=[UnifiedCredentialStore.account:value,"node":"old"]
            let store=UnifiedCredentialStore(legacy:backend)
            expectThrows(try store.get("node"));expectThrows(try store.set("new",for:"node"));expectEqual(backend.writes,0)
            expectFalse(backend.reads.contains("node"))
        }
        let backend=VaultFixture();backend.readFailure=ProxyError("已取消")
        let store=UnifiedCredentialStore(legacy:backend)
        expectThrows(try store.get("node"));expectEqual(backend.reads,[UnifiedCredentialStore.account]);expectEqual(backend.writes,0)
    }
    func testCancellationStopsOperation() throws {
        var reads=0
        let store=KeychainStore(read:{_ in reads+=1;return (errSecUserCanceled,nil)})
        try CredentialAuthorization.$attempt.withValue(CredentialAuthorization.Attempt()) {
            expectThrows(try store.get("one"))
            expectThrows(try store.get("two"))
            expectThrows(try store.set("value",for:"three"))
        }
        expectEqual(reads,1)
        try CredentialAuthorization.$attempt.withValue(CredentialAuthorization.Attempt()) {expectThrows(try store.get("one"))}
        expectEqual(reads,2)
        var writes=0,deletes=0
        let deniedWrite=KeychainStore(update:{_,_ in writes+=1;return errSecUserCanceled},delete:{_ in deletes+=1;return errSecSuccess})
        try CredentialAuthorization.$attempt.withValue(CredentialAuthorization.Attempt()) {
            expectThrows(try deniedWrite.set("value",for:"one"))
            expectThrows(try deniedWrite.set("value",for:"two"))
            expectThrows(try deniedWrite.remove("three"))
        }
        expectEqual(writes,1);expectEqual(deletes,0)
    }
    func testSilentPolicyAndSessionCache() throws {
        var policies:[String]=[]
        let keychain=KeychainStore(read:{query in
            policies.append(query[kSecUseAuthenticationUI as String] as? String ?? "")
            return (CredentialAuthorization.allowsInteraction ? errSecSuccess : errSecInteractionNotAllowed,CredentialAuthorization.allowsInteraction ? Data("allowed".utf8):nil)
        })
        try CredentialAuthorization.$allowsInteraction.withValue(false) {expectThrows(try keychain.get("node"))}
        expectEqual(try keychain.get("node"),"allowed")
        try CredentialAuthorization.$allowsInteraction.withValue(false) {expectEqual(try keychain.get("node"),"allowed")}
        expectEqual(policies,[kSecUseAuthenticationUIFail as String,kSecUseAuthenticationUIAllow as String])
        var writes:[Bool]=[]
        let writeStore=KeychainStore(update:{query,_ in writes.append((query[kSecUseAuthenticationUI as String] as? String)==(kSecUseAuthenticationUIFail as String));return errSecItemNotFound},add:{query in writes.append((query[kSecUseAuthenticationUI as String] as? String)==(kSecUseAuthenticationUIFail as String));return errSecSuccess},delete:{query in writes.append((query[kSecUseAuthenticationUI as String] as? String)==(kSecUseAuthenticationUIFail as String));return errSecSuccess})
        try CredentialAuthorization.$allowsInteraction.withValue(false) {try writeStore.set("new",for:"node");try writeStore.remove("node")}
        expectEqual(writes,[true,true,true])
    }
}
