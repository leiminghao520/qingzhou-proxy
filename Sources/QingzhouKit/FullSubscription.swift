import Foundation
import CryptoKit

public struct FullSubscription:Codable,Sendable {
    public var format:String
    public var version:Int
    public var name:String
    public var revision:String
    public var configurationJSON:String
    public var nodes:[String]
    public func preview() throws -> ImportPreview {
        guard format=="qingzhou.subscription",version==1,!name.isEmpty,name.count<=100,!nodes.isEmpty,nodes.count<=2000,configurationJSON.utf8.count<=1024*1024 else{throw ProxyError("汐航完整订阅版本或结构不支持")}
        let bytes=Data(configurationJSON.utf8)
        let hash=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        guard revision==hash else{throw ProxyError("完整订阅配置校验失败，保留旧配置")}
        let configuration=try JSONDecoder().decode(ShadowrocketConfiguration.self,from:bytes)
        let state=try configuration.applying(to:AppState())
        let candidates=try NodeParser.parseList(nodes.joined(separator:"\n"))
        return ImportPreview(candidates:candidates,rules:state.rules,final:state.ruleFinal,fullConfiguration:configuration,revision:revision,profileName:name)
    }
    public static func parse(_ text:String) throws -> ImportPreview? {
        guard text.hasPrefix("{") else{return nil}
        guard let object=try? JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],object["format"] as? String=="qingzhou.subscription" else{return nil}
        do {return try JSONDecoder().decode(Self.self,from:Data(text.utf8)).preview()}catch let error as ProxyError{throw error}catch{throw ProxyError("完整订阅 JSON 或配置结构无效")}
    }
}
