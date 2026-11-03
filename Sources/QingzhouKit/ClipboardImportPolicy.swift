import Foundation
import CryptoKit

// 仅保存摘要用于去重；原文由前台提示暂存，拒绝或关闭时立即释放。
public struct ClipboardImportPolicy {
    private var lastChange:Int?
    private var digest:Data?
    public init() {}
    public mutating func inspect(enabled:Bool,foreground:Bool,change:Int,read:()->String?) -> String? {
        guard enabled,foreground,lastChange != change else{return nil}
        lastChange=change
        guard let text=read(),text.utf8.count<=2*1024*1024 else{return nil}
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        let hash=Data(SHA256.hash(data:Data(value.utf8)))
        guard hash != digest else{return nil}
        digest=hash
        if value.lowercased().hasPrefix("https://"),let url=URL(string:value),url.host != nil,!value.contains(where:{$0.isWhitespace}) {return value}
        guard (try? ProfileImporter.parse(value)) != nil else{return nil}
        return value
    }
}
