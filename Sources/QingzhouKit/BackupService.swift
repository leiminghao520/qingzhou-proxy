import Foundation
import CryptoKit
import CommonCrypto

public struct BackupSnapshot:Codable,Sendable {
    public var version=1;public var catalog:ProfileCatalog;public var credentials:[String:String]
    public init(catalog:ProfileCatalog,credentials:[String:String]){self.catalog=catalog;self.credentials=credentials}
}
private struct BackupEnvelope:Codable {var version:Int;var rounds:Int;var salt:Data;var sealed:Data}
public enum BackupService {
    public static func snapshot(_ catalog:ProfileCatalog,credentials:CredentialStore) throws -> BackupSnapshot {try catalog.validate();var secrets:[String:String]=[:];for ref in catalog.credentialRefs{secrets[ref]=try credentials.get(ref)};return BackupSnapshot(catalog:catalog,credentials:secrets)}
    private static func key(_ password:String,salt:Data,rounds:Int) throws -> SymmetricKey {
        guard !password.isEmpty,password.utf8.count<=4096,salt.count==16,rounds==600000 else{throw ProxyError("备份口令或格式无效")}
        let bytes=Array(password.utf8);var result=[UInt8](repeating:0,count:32)
        let status=bytes.withUnsafeBytes{p in salt.withUnsafeBytes{s in CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),p.baseAddress!.assumingMemoryBound(to:Int8.self),p.count,s.baseAddress!.assumingMemoryBound(to:UInt8.self),s.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),UInt32(rounds),&result,result.count)}}
        guard status==kCCSuccess else{throw ProxyError("备份密钥生成失败")};return SymmetricKey(data:result)
    }
    public static func encrypt(_ snapshot:BackupSnapshot,password:String) throws -> Data {
        try snapshot.catalog.validate();var salt=Data();for _ in 0..<16{salt.append(UInt8.random(in:0...255))}
        let data=try JSONEncoder().encode(snapshot);guard data.count<=32*1024*1024 else{throw ProxyError("备份超过 32 MiB")}
        let sealed=try AES.GCM.seal(data,using:key(password,salt:salt,rounds:600000),authenticating:Data("QingzhouBackup-v1".utf8)).combined!
        return try JSONEncoder().encode(BackupEnvelope(version:1,rounds:600000,salt:salt,sealed:sealed))
    }
    public static func decrypt(_ data:Data,password:String) throws -> BackupSnapshot {
        guard data.count<=48*1024*1024 else{throw ProxyError("备份文件过大")}
        do {let envelope=try JSONDecoder().decode(BackupEnvelope.self,from:data);guard envelope.version==1 else{throw ProxyError("备份版本不支持")};let plaintext=try AES.GCM.open(AES.GCM.SealedBox(combined:envelope.sealed),using:key(password,salt:envelope.salt,rounds:envelope.rounds),authenticating:Data("QingzhouBackup-v1".utf8));let snapshot=try JSONDecoder().decode(BackupSnapshot.self,from:plaintext);try snapshot.catalog.validate();guard snapshot.version==1,snapshot.catalog.credentialRefs.isSubset(of:Set(snapshot.credentials.keys)),snapshot.credentials.count<=150000 else{throw ProxyError("备份凭据不完整")};return snapshot}catch{throw ProxyError("备份口令错误、文件损坏或版本不支持")}
    }
}

extension BackupService {
    public static func exportLegacy(_ snapshot:BackupSnapshot,to url:URL,credentials:CredentialStore) throws {
        try snapshot.catalog.validate();let state=snapshot.catalog.active
        guard snapshot.version==1,state.groups.allSatisfy({$0.kind != .fallback}),state.captureMode == .systemProxy else{throw ProxyError("该快照含 0.3 专用功能，不能导出给 0.2；请使用升级前快照")}
        var created:[String]=[]
        do{for ref in CredentialReferences.all(state){guard let value=snapshot.credentials[ref] else{throw ProxyError("快照凭据缺失")};if let existing=try? credentials.get(ref){guard existing==value else{throw ProxyError("旧凭据引用发生冲突，未覆盖现有凭据")}}else{created.append(ref);try credentials.set(value,for:ref)}};try SecureFile.write(JSONEncoder().encode(state),to:url)}catch{for ref in created{try? credentials.remove(ref)};throw error}
    }
}
