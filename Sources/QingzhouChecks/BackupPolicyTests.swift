import Foundation
import CryptoKit
import CommonCrypto
import QingzhouKit

// 按旧版格式构造备份，用于确认短口令的历史备份在新长度限制下仍可恢复。
func legacyBackup(_ snapshot:BackupSnapshot,password:String) throws -> Data {
    struct Envelope:Encodable {var version:Int;var rounds:Int;var salt:Data;var sealed:Data}
    let salt=Data((0..<16).map{_ in UInt8.random(in:0...255)});let bytes=Array(password.utf8);var key=[UInt8](repeating:0,count:32)
    let status=bytes.withUnsafeBytes{p in salt.withUnsafeBytes{s in CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),p.baseAddress!.assumingMemoryBound(to:Int8.self),p.count,s.baseAddress!.assumingMemoryBound(to:UInt8.self),s.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),600000,&key,key.count)}}
    guard status==kCCSuccess else{throw ProxyError("测试密钥生成失败")}
    let sealed=try AES.GCM.seal(JSONEncoder().encode(snapshot),using:SymmetricKey(data:key),authenticating:Data("QingzhouBackup-v1".utf8)).combined!
    return try JSONEncoder().encode(Envelope(version:1,rounds:600000,salt:salt,sealed:sealed))
}
