import Foundation
import CryptoKit

public struct ProfileHistoryVersion:Codable,Sendable,Identifiable {
    public var id:UUID
    public var profileID:UUID
    public var name:String
    public var date:Date
    public var source:String
    public var connectionVerified:Bool
    public var digest:Data
}
public struct ProfileHistorySnapshot:Codable,Sendable {
    public var profile:ClientProfile
    public var credentials:[String:String]
}
private struct HistoryEnvelope:Codable {var version=1;var sealed:Data}
private struct HistoryPending:Codable {var id:UUID;var versions:[ProfileHistoryVersion]}

// 历史与普通备份使用不同的密钥及认证标签；索引和快照均为密文。
public final class ProfileHistoryStore {
    public let directory:URL
    public let credentials:CredentialStore
    public private(set) var enabled=true
    public private(set) var lastError:String?
    public var now:()->Date
    public var write:(Data,URL) throws -> Void = {try SecureFile.write($0,to:$1,durable:true)}
    private var optionsInvalid=false
    private let keyRef="qingzhou.profile-history.key.v1"
    private let maximumBytes:Int
    private let maximumVersions:Int
    private let retention:TimeInterval
    public init(directory:URL,credentials:CredentialStore,now:@escaping ()->Date=Date.init,maximumBytes:Int=100*1024*1024,maximumVersions:Int=20,retention:TimeInterval=30*86400) {
        self.directory=directory;self.credentials=credentials;self.now=now;self.maximumBytes=maximumBytes;self.maximumVersions=maximumVersions;self.retention=retention
        let options=directory.appendingPathComponent("options.json")
        if FileManager.default.fileExists(atPath:options.path) {
            do {enabled=try JSONDecoder().decode(Bool.self,from:Data(contentsOf:options))}
            catch {optionsInvalid=true;lastError="历史设置损坏，历史未就绪"}
        }
    }
    private func key() throws -> SymmetricKey {
        if let value=try? credentials.get(keyRef),let data=Data(base64Encoded:value),data.count==32 {return SymmetricKey(data:data)}
        let files=(try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? []
        guard !files.contains(where:{$0.hasSuffix(".qzh")}) else {throw ProxyError("历史密钥不可用；未覆盖已有历史")}
        let key=SymmetricKey(size:.bits256),data=key.withUnsafeBytes{Data($0)}
        try credentials.set(data.base64EncodedString(),for:keyRef);return key
    }
    private func ensureDirectory() throws {
        let manager=FileManager.default
        try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let attributes=try manager.attributesOfItem(atPath:directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {throw ProxyError("历史目录类型异常")}
        try manager.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
    }
    private func file(_ name:String)->URL {directory.appendingPathComponent(name)}
    private func seal<T:Encodable>(_ value:T,name:String) throws {
        try ensureDirectory()
        let bytes=try JSONEncoder().encode(value)
        guard bytes.count<=48*1024*1024 else {throw ProxyError("单份历史超过 48 MiB")}
        let sealed=try AES.GCM.seal(bytes,using:key(),authenticating:Data(("QingzhouProfileHistory-v1/"+name).utf8)).combined!
        try write(JSONEncoder().encode(HistoryEnvelope(sealed:sealed)),file(name))
    }
    private func read<T:Decodable>(_ type:T.Type,name:String) throws -> T {
        let url=file(name),attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,(attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 66*1024*1024 else {throw ProxyError("历史文件类型或大小无效")}
        do {
            let envelope=try JSONDecoder().decode(HistoryEnvelope.self,from:Data(contentsOf:url))
            guard envelope.version==1 else {throw ProxyError("历史版本不支持")}
            let data=try AES.GCM.open(AES.GCM.SealedBox(combined:envelope.sealed),using:key(),authenticating:Data(("QingzhouProfileHistory-v1/"+name).utf8))
            return try JSONDecoder().decode(type,from:data)
        }catch {throw ProxyError("历史文件损坏或密钥不可用，未覆盖历史")}
    }
    private func index() throws -> [ProfileHistoryVersion] {
        if !FileManager.default.fileExists(atPath:file("index.qzh").path) {return []}
        return try read([ProfileHistoryVersion].self,name:"index.qzh")
    }
    private func name(_ id:UUID)->String {id.uuidString+".qzh"}
    public func setEnabled(_ value:Bool) throws {try ensureDirectory();try write(JSONEncoder().encode(value),file("options.json"));enabled=value;optionsInvalid=false;if !value {lastError=nil}}
    public func versions() throws -> [ProfileHistoryVersion] {try index().sorted{$0.date>$1.date}}
    public func snapshot(_ version:ProfileHistoryVersion) throws -> ProfileHistorySnapshot {
        guard try index().contains(where:{$0.id==version.id}) else {throw ProxyError("历史版本已清理，请刷新列表")}
        let result=try read(ProfileHistorySnapshot.self,name:name(version.id))
        guard result.profile.id==version.profileID,try Self.digest(result)==version.digest else {throw ProxyError("历史版本身份不一致")}
        return result
    }
    private func capture(_ profile:ClientProfile) throws -> ProfileHistorySnapshot {
        var secrets:[String:String]=[:]
        for ref in CredentialReferences.all(profile.configuration) {secrets[ref]=try credentials.get(ref)}
        return ProfileHistorySnapshot(profile:profile,credentials:secrets)
    }
    // 去掉运行观测字段；凭据引用在逻辑比较时替换为内容摘要，避免订阅换引用产生重复版本。
    public static func revision(_ profile:ClientProfile) throws -> Data {
        var state=profile.configuration
        state.latency=[:];state.recentUse=[:]
        for i in state.subscriptions.indices {state.subscriptions[i].updatedAt = .distantPast;state.subscriptions[i].usage=nil;state.subscriptions[i].lastError=nil;state.subscriptions[i].retryCount=0;state.subscriptions[i].retryAfter=nil;state.subscriptions[i].pendingReview=false}
        for i in state.remoteRules.indices {state.remoteRules[i].updatedAt=nil;state.remoteRules[i].lastError=nil;state.remoteRules[i].retryCount=0;state.remoteRules[i].retryAfter=nil}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var object=try JSONSerialization.jsonObject(with:encoder.encode(state)) as! [String:Any]
        object.removeValue(forKey:"favorites");object.removeValue(forKey:"notes");object.removeValue(forKey:"compactNodes")
        return try JSONSerialization.data(withJSONObject:["name":profile.name,"configuration":object],options:[.sortedKeys])
    }
    public static func digest(_ snapshot:ProfileHistorySnapshot) throws -> Data {
        var profile=snapshot.profile
        var mapping:[String:String]=[:]
        for (ref,value) in snapshot.credentials {mapping[ref]=Data(SHA256.hash(data:Data(value.utf8))).base64EncodedString()}
        for i in profile.configuration.nodes.indices {let old=profile.configuration.nodes[i].credentialRef;profile.configuration.nodes[i].credentialRef=(mapping[old] ?? "missing")+"/"+(mapping[old+".obfs"] ?? "")}
        for i in profile.configuration.subscriptions.indices {let old=profile.configuration.subscriptions[i].sourceRef;profile.configuration.subscriptions[i].sourceRef=mapping[old] ?? "missing"}
        for i in profile.configuration.remoteRules.indices {let old=profile.configuration.remoteRules[i].sourceRef;profile.configuration.remoteRules[i].sourceRef=mapping[old] ?? "missing"}
        return Data(SHA256.hash(data:try revision(profile)))
    }
    private func save(_ snapshot:ProfileHistorySnapshot,source:String,verified:Bool=false) throws -> ProfileHistoryVersion {
        let id=UUID(),version=ProfileHistoryVersion(id:id,profileID:snapshot.profile.id,name:snapshot.profile.name,date:now(),source:source,connectionVerified:verified,digest:try Self.digest(snapshot))
        var saved=false
        defer {if !saved {try? FileManager.default.removeItem(at:file(name(id)))}}
        try seal(snapshot,name:name(id))
        // 写入后解密校验，保证清理旧钥匙串凭据前已有独立可读的快照。
        let restored=try read(ProfileHistorySnapshot.self,name:name(id))
        guard try Self.digest(restored)==version.digest else {throw ProxyError("历史写入核验失败")}
        saved=true;return version
    }
    private func discardUncommitted(_ ids:[UUID]) {
        // 索引可能已完成原子替换后才报告同步失败，先回读以免误删已提交版本。
        guard let committed=try? index() else{return}
        let live=Set(committed.map(\.id))
        for id in ids where !live.contains(id) {try? FileManager.default.removeItem(at:file(name(id)))}
    }
    public func initialize(_ catalog:ProfileCatalog) throws {
        guard enabled else{return}
        var created:[UUID]=[]
        do {
            guard !optionsInvalid else {throw ProxyError("历史设置损坏，请关闭历史后重新开启")}
            try reconcile(catalog)
            var versions=try index()
            for profile in catalog.profiles where !versions.contains(where:{$0.profileID==profile.id}) {
                let item=try save(capture(profile),source:"初始基线");versions.append(item);created.append(item.id)
                try seal(versions,name:"index.qzh")
            }
            try prune();lastError=nil
        }catch {discardUncommitted(created);lastError="历史未就绪："+error.localizedDescription;throw error}
    }
    public func prepare(previous:ProfileCatalog,next:ProfileCatalog,source:String) throws -> UUID? {
        guard enabled else{return nil}
        do {
            guard !optionsInvalid else {throw ProxyError("历史设置损坏，请关闭历史后重新开启")}
            try reconcile(previous)
            let oldProfiles=Dictionary(uniqueKeysWithValues:previous.profiles.map{($0.id,$0)})
            if previous.profiles.count==next.profiles.count,try next.profiles.allSatisfy({profile in
                guard let old=oldProfiles[profile.id] else{return false}
                return try Self.revision(old)==Self.revision(profile)
            }) {return nil}
            var versions=try index(),candidates:[ProfileHistoryVersion]=[],protected=Set<UUID>()
            var created:[UUID]=[]
            do {
                for profileID in Set(previous.profiles.map(\.id)+next.profiles.map(\.id)) {
                    let old=previous.profiles.first{$0.id==profileID},new=next.profiles.first{$0.id==profileID}
                    if let old,let new,try Self.revision(old)==Self.revision(new) {continue}
                    let before=try old.map{try capture($0)},after=try new.map{try capture($0)}
                    if let before,let after,try Self.digest(before)==Self.digest(after) {continue}
                    if let before {
                        let digest=try Self.digest(before)
                        if let existing=versions.first(where:{$0.profileID==profileID && $0.digest==digest && $0.date>=now().addingTimeInterval(-retention)}) {_ = try snapshot(existing);protected.insert(existing.id)}
                        else {let item=try save(before,source:"变更前");versions.append(item);created.append(item.id);protected.insert(item.id)}
                    }
                    if let after {let item=try save(after,source:source);candidates.append(item);created.append(item.id)}
                }
                guard !candidates.isEmpty || Set(previous.profiles.map(\.id)) != Set(next.profiles.map(\.id)) else {return nil}
                try seal(versions,name:"index.qzh")
                let pending=HistoryPending(id:UUID(),versions:candidates)
                try seal(pending,name:"pending.qzh")
                // 总预算在改变运行配置前核验；只淘汰已提交的旧历史，不清理本次候选。
                try prune(reserving:candidates,protecting:protected)
                return pending.id
            }catch {discardUncommitted(created);throw error}
        }catch {lastError="历史保存失败，本次配置未应用："+error.localizedDescription;throw error}
    }
    public func finish(_ id:UUID,verified:Bool) throws {
        let pending=try read(HistoryPending.self,name:"pending.qzh")
        guard pending.id==id else {throw ProxyError("历史事务标识不一致")}
        var versions=try index()
        for var item in pending.versions where !versions.contains(where:{$0.id==item.id}) {
            let restored=try read(ProfileHistorySnapshot.self,name:name(item.id))
            guard restored.profile.id==item.profileID,try Self.digest(restored)==item.digest else {throw ProxyError("候选历史快照核验失败")}
            item.connectionVerified=verified;versions.append(item)
        }
        try seal(versions,name:"index.qzh")
        try FileManager.default.removeItem(at:file("pending.qzh"));lastError=nil
    }
    public func reconcile(_ catalog:ProfileCatalog) throws {
        guard FileManager.default.fileExists(atPath:file("pending.qzh").path) else{return}
        let pending=try read(HistoryPending.self,name:"pending.qzh")
        if catalog.lastHistoryTransactionID==pending.id {try finish(pending.id,verified:false)}
        else {try abort(pending.id)}
    }
    public func abort(_ id:UUID) throws {
        guard FileManager.default.fileExists(atPath:file("pending.qzh").path) else{return}
        let pending=try read(HistoryPending.self,name:"pending.qzh")
        guard pending.id==id else{throw ProxyError("历史取消事务不一致")}
        let committed=Set(try index().map(\.id))
        for item in pending.versions where !committed.contains(item.id) {try? FileManager.default.removeItem(at:file(name(item.id)))}
        try FileManager.default.removeItem(at:file("pending.qzh"))
    }
    public func maintain(_ catalog:ProfileCatalog) throws {
        guard enabled else{return}
        do {
            guard !optionsInvalid else {throw ProxyError("历史设置损坏，请关闭历史后重新开启")}
            try reconcile(catalog);try prune();lastError=nil
        }catch {lastError="历史维护未完成："+error.localizedDescription;throw error}
    }
    public func noteFinalizationFailure() {lastError="配置已提交，历史收尾待对账；下一次变更前将重新核对"}
    private func prune(reserving:[ProfileHistoryVersion]=[],protecting:Set<UUID>=[]) throws {
        let versions=try index().sorted{$0.date>$1.date}
        var counts=Dictionary(grouping:reserving,by: \.profileID).mapValues(\.count)
        var keep=versions.filter{protecting.contains($0.id)}
        for version in keep {counts[version.profileID,default:0]+=1}
        let cutoff=now().addingTimeInterval(-retention)
        for version in versions where !protecting.contains(version.id) && version.date>=cutoff {
            if counts[version.profileID,default:0]<maximumVersions {keep.append(version);counts[version.profileID,default:0]+=1}
        }
        func size(_ name:String)->Int {((try? FileManager.default.attributesOfItem(atPath:file(name).path)[.size]) as? NSNumber)?.intValue ?? 0}
        func total(_ kept:[ProfileHistoryVersion]) throws -> Int {
            let indexBytes=try JSONEncoder().encode(kept+reserving).count
            return (kept+reserving).reduce(0){$0+size(name($1.id))}+size("pending.qzh")+size("options.json")+(indexBytes+28+2)/3*4+128
        }
        while try total(keep)>maximumBytes {
            guard let i=keep.indices.reversed().first(where:{!protecting.contains(keep[$0].id)}) else {throw ProxyError("变更前快照及候选超过历史总容量限制")}
            keep.remove(at:i)
        }
        let retained=Set(keep.map(\.id));try seal(keep,name:"index.qzh")
        for item in versions where !retained.contains(item.id) {try? FileManager.default.removeItem(at:file(name(item.id)))}
        // 只移除本目录中不属于索引或未决事务的历史快照，不触碰普通备份。
        let live=retained.union(reserving.map(\.id))
        for url in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] {
            if url.pathExtension=="qzh",let id=UUID(uuidString:url.deletingPathExtension().lastPathComponent),!live.contains(id) {try? FileManager.default.removeItem(at:url)}
        }
    }
    public func clear() throws {
        let fm=FileManager.default
        for url in (try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] {
            let base=url.deletingPathExtension().lastPathComponent
            if url.pathExtension=="qzh" && (["index","pending"].contains(base) || UUID(uuidString:base) != nil) {try fm.removeItem(at:url)}
        }
        lastError=nil
    }
}
