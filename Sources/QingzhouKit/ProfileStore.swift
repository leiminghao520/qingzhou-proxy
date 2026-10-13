import Foundation

public enum CaptureMode:String,Codable,CaseIterable,Sendable {case systemProxy,tun}
public enum DNSPreference:String,Codable,CaseIterable,Sendable {case system,httpsProxy}
public struct ClientProfile:Codable,Identifiable,Sendable {
    public var id=UUID();public var name:String;public var configuration:AppState
    public init(name:String,configuration:AppState=AppState()){self.name=name;self.configuration=configuration}
}
public struct BackupIndex:Codable,Identifiable,Sendable {public var id=UUID();public var date=Date();public var fileName:String;public init(fileName:String){self.fileName=fileName}}
public struct ProfileCatalog:Codable,Sendable {
    public var schemaVersion=3;public var profiles:[ClientProfile];public var currentProfileID:UUID;public var backupIndex:[BackupIndex]=[]
    public init(state:AppState=AppState()){let profile=ClientProfile(name:"默认配置",configuration:state);profiles=[profile];currentProfileID=profile.id}
    enum CodingKeys:String,CodingKey{case schemaVersion,profiles,currentProfileID,backupIndex}
    public init(from decoder:Decoder) throws{let c=try decoder.container(keyedBy:CodingKeys.self);schemaVersion=try c.decode(Int.self,forKey:.schemaVersion);profiles=try c.decode([ClientProfile].self,forKey:.profiles);currentProfileID=try c.decode(UUID.self,forKey:.currentProfileID);backupIndex=try c.decodeIfPresent([BackupIndex].self,forKey:.backupIndex) ?? []}
    public var active:AppState {profiles.first{$0.id==currentProfileID}!.configuration}
    public mutating func updateActive(_ state:AppState){if let i=profiles.firstIndex(where:{$0.id==currentProfileID}){profiles[i].configuration=state}}
    public func validate() throws {
        guard schemaVersion==3,!profiles.isEmpty,profiles.count<=30,Set(profiles.map(\.id)).count==profiles.count,profiles.contains(where:{$0.id==currentProfileID}) else {throw ProxyError("配置集合无效")}
        for profile in profiles {guard !profile.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,profile.name.count<=100,profile.configuration.schemaVersion==2 else {throw ProxyError("配置名称或版本无效")};try PolicyValidator.validate(profile.configuration)}
    }
    public var credentialRefs:Set<String>{Set(profiles.flatMap{CredentialReferences.all($0.configuration)})}
}
public enum CredentialReferences {
    public static func all(_ state:AppState)->[String]{state.nodes.flatMap{[$0.credentialRef]+($0.parameters["obfs"] != nil ? [$0.credentialRef+".obfs"]:[])}+state.subscriptions.map(\.sourceRef)+state.remoteRules.map(\.sourceRef)}
}
public enum ProfileStore {
    public static func create(in catalog:ProfileCatalog,name:String,copyID:UUID?=nil,officeDomains:[String]=[]) throws -> ProfileCatalog {
        var next=catalog
        var state=copyID.flatMap{id in catalog.profiles.first{$0.id==id}?.configuration} ?? AppState()
        for domain in officeDomains {let rule=RoutingRule(kind:.suffix,value:domain,action:.direct);try ConfigBuilder.validate(rule);state.rules.append(rule)}
        let profile=ClientProfile(name:name,configuration:state);next.profiles.append(profile);try next.validate();return next
    }
    public static func switchTo(_ id:UUID,in catalog:ProfileCatalog) throws -> ProfileCatalog {var next=catalog;next.currentProfileID=id;try next.validate();return next}
    public static func rename(_ id:UUID,to name:String,in catalog:ProfileCatalog) throws -> ProfileCatalog {var next=catalog;guard let i=next.profiles.firstIndex(where:{$0.id==id}) else{throw ProxyError("配置不存在")};next.profiles[i].name=name;try next.validate();return next}
    public static func remove(_ id:UUID,in catalog:ProfileCatalog) throws -> ProfileCatalog {guard catalog.profiles.count>1,id != catalog.currentProfileID else{throw ProxyError("请先切换配置，不能删除当前或唯一配置")};var next=catalog;next.profiles.removeAll{$0.id==id};try next.validate();return next}
}
