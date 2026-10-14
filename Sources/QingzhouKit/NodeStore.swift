import Foundation

public final class StoreTransaction {
    public let previous:AppState
    public var next:AppState
    public var nextCatalog:ProfileCatalog?
    fileprivate let created:[String]
    fileprivate let retired:[String]
    fileprivate var finished=false
    fileprivate init(previous:AppState,next:AppState,created:[String]=[],retired:[String]=[]) {self.previous=previous;self.next=next;self.created=created;self.retired=retired}
}
public final class NodeStore {
    public private(set) var state:AppState
    public private(set) var catalog:ProfileCatalog
    public let credentials:CredentialStore
    public let file:URL
    public init(file:URL,credentials:CredentialStore) throws {
        self.file=file;self.credentials=credentials;state=AppState();catalog=ProfileCatalog()
        if FileManager.default.fileExists(atPath:file.path) {
            let data=try Data(contentsOf:file)
            if let root=try? JSONDecoder().decode(ProfileCatalog.self,from:data){try root.validate();catalog=root;state=root.active;return}
            state=try JSONDecoder().decode(AppState.self,from:data)
            guard (1...2).contains(state.schemaVersion) else {throw ProxyError("配置版本暂不支持")}
            if state.schemaVersion==1 {
                let backup=file.deletingLastPathComponent().appendingPathComponent("state-v1-backup.json")
                if !FileManager.default.fileExists(atPath:backup.path){try SecureFile.write(data,to:backup)}
                state.schemaVersion=2
            }
        } else {state=AppState();if let defaults=try ShadowrocketConfiguration.bundled(){state=try defaults.applying(to:state)}}
        catalog=ProfileCatalog(state:state)
        if FileManager.default.fileExists(atPath:file.path) {
            let snapshot=try BackupService.snapshot(catalog,credentials:credentials);let ref="migration-v3-"+UUID().uuidString;let password=UUID().uuidString+UUID().uuidString
            try credentials.set(password,for:ref)
            do {let backup=file.deletingLastPathComponent().appendingPathComponent("migration-v3.qzb");try SecureFile.write(BackupService.encrypt(snapshot,password:password),to:backup);try SecureFile.write(Data(ref.utf8),to:file.deletingLastPathComponent().appendingPathComponent("migration-v3.keyref"));catalog.backupIndex.append(BackupIndex(fileName:"migration-v3.qzb"));try SecureFile.write(JSONEncoder().encode(catalog),to:file)}catch{try? credentials.remove(ref);throw error}
        }
    }
    public func commit(_ next:AppState) throws {guard next.schemaVersion==2 else {throw ProxyError("不能保存未知配置版本")};var root=catalog;root.updateActive(next);try root.validate();try SecureFile.write(JSONEncoder().encode(root),to:file);catalog=root;state=next}
    public func prepareCatalog(_ root:ProfileCatalog) throws -> StoreTransaction {try root.validate();let tx=StoreTransaction(previous:state,next:root.active,retired:Array(catalog.credentialRefs.subtracting(root.credentialRefs)));tx.nextCatalog=root;return tx}
    public func prepareRestore(_ snapshot:BackupSnapshot) throws -> StoreTransaction {
        var root=snapshot.catalog;var created:[String]=[]
        try root.validate();guard snapshot.version==1,root.credentialRefs.isSubset(of:Set(snapshot.credentials.keys)) else{throw ProxyError("备份凭据或版本不完整")}
        do {var mapping:[String:String]=[:];let bases=Set(root.profiles.flatMap{p in p.configuration.nodes.map(\.credentialRef)+p.configuration.subscriptions.map(\.sourceRef)+p.configuration.remoteRules.map(\.sourceRef)});for ref in bases{let new=UUID().uuidString;guard let value=snapshot.credentials[ref] else{throw ProxyError("备份凭据缺失")};mapping[ref]=new;created.append(new);try credentials.set(value,for:new)}
            for p in root.profiles.indices {for n in root.profiles[p].configuration.nodes.indices {let old=root.profiles[p].configuration.nodes[n].credentialRef;let new=mapping[old]!;root.profiles[p].configuration.nodes[n].credentialRef=new;if let obfs=snapshot.credentials[old+".obfs"]{let ref=new+".obfs";if !created.contains(ref){created.append(ref);try credentials.set(obfs,for:ref)}}};for s in root.profiles[p].configuration.subscriptions.indices{let old=root.profiles[p].configuration.subscriptions[s].sourceRef;root.profiles[p].configuration.subscriptions[s].sourceRef=mapping[old]!};for r in root.profiles[p].configuration.remoteRules.indices{let old=root.profiles[p].configuration.remoteRules[r].sourceRef;root.profiles[p].configuration.remoteRules[r].sourceRef=mapping[old]!}}
            let tx=StoreTransaction(previous:state,next:root.active,created:created,retired:Array(catalog.credentialRefs));tx.nextCatalog=root;return tx
        }catch{for ref in created{try? credentials.remove(ref)};throw error}
    }
    public func prepareChange(_ next:AppState) -> StoreTransaction {StoreTransaction(previous:state,next:next)}
    public func commit(_ tx:StoreTransaction) throws {
        guard !tx.finished else {throw ProxyError("更新事务已经结束")};if var root=tx.nextCatalog {root.updateActive(tx.next);try root.validate();try SecureFile.write(JSONEncoder().encode(root),to:file);catalog=root;state=root.active}else{try commit(tx.next)};tx.finished=true
        for ref in tx.retired where !catalog.credentialRefs.contains(ref) {try? credentials.remove(ref)}
    }
    public func abort(_ tx:StoreTransaction) {guard !tx.finished else{return};tx.finished=true;for ref in tx.created {try? credentials.remove(ref)}}
    public func prepareImport(_ candidates:[Candidate],subscription:Subscription?=nil,source:String?=nil,replacingID:UUID?=nil,profile:ImportPreview?=nil,scope:ImportScope = .nodes) throws -> StoreTransaction {
        guard !candidates.isEmpty else {throw ProxyError("没有可导入节点")}
        var next=state,created:[String]=[],retired:[String]=[];var mapping:[UUID:UUID]=[:];var seen:[String:Candidate]=[:]
        let oldNodes=subscription.map{sub in state.nodes.filter{$0.subscriptionID==sub.id}} ?? replacingID.map{id in state.nodes.filter{$0.id==id}} ?? []
        if let sub=subscription {next.nodes.removeAll{$0.subscriptionID==sub.id}}
        if let id=replacingID {next.nodes.removeAll{$0.id==id}}
        retired=oldNodes.flatMap{[$0.credentialRef,$0.credentialRef+".obfs"]}
        do {
            for candidate in candidates {
                let fingerprint=candidate.node.fingerprint
                if let duplicate=seen[fingerprint] {
                    guard duplicate.secret==candidate.secret,duplicate.obfsSecret==candidate.obfsSecret else {throw ProxyError("同一服务器参数包含冲突凭据，请分开导入")}
                    mapping[candidate.node.id]=mapping[duplicate.node.id];continue
                }
                seen[fingerprint]=candidate
                if subscription==nil && replacingID==nil,let existing=next.nodes.first(where:{$0.subscriptionID==nil && $0.fingerprint==fingerprint}),(try? credentials.get(existing.credentialRef))==candidate.secret,(try? credentials.get(existing.credentialRef+".obfs"))==candidate.obfsSecret {mapping[candidate.node.id]=existing.id;continue}
                var node=candidate.node
                node.id=replacingID ?? oldNodes.first{$0.fingerprint==fingerprint}?.id ?? node.id
                if let old=oldNodes.first(where:{$0.kind==node.kind && $0.server==node.server && $0.port==node.port}),oldNodes.filter({$0.kind==node.kind && $0.server==node.server && $0.port==node.port}).count==1 {
                    if let note=state.notes[old.id.uuidString]{next.notes[node.id.uuidString]=note};if state.favorites.contains(old.id){next.favorites.insert(node.id)}
                    if let recent=state.recentUse[old.id.uuidString]{next.recentUse[node.id.uuidString]=recent}
                }
                mapping[candidate.node.id]=node.id;node.subscriptionID=subscription?.id;node.credentialRef=UUID().uuidString
                created.append(node.credentialRef);try credentials.set(candidate.secret,for:node.credentialRef)
                if let value=candidate.obfsSecret {created.append(node.credentialRef+".obfs");try credentials.set(value,for:node.credentialRef+".obfs")}
                next.nodes.append(node)
            }
            if var sub=subscription {
                sub.updatedAt=Date();sub.pendingReview=false;sub.lastError=nil;sub.retryCount=0;sub.retryAfter=nil;sub.scope=scope;if let profile{sub.usage=profile.usage;sub.revision=profile.revision;if let name=profile.profileName{sub.name=name}}
                if let source, (try? credentials.get(sub.sourceRef)) != source {if let old=state.subscriptions.first(where:{$0.id==sub.id}){retired.append(old.sourceRef)};sub.sourceRef=UUID().uuidString;created.append(sub.sourceRef);try credentials.set(source,for:sub.sourceRef)}
                next.subscriptions.removeAll{$0.id==sub.id};next.subscriptions.append(sub)
            }
            if scope == .profile,let profile {
                if let configuration=profile.fullConfiguration {
                    guard let sub=subscription else{throw ProxyError("完整订阅需要保存订阅来源")}
                    guard !next.subscriptions.contains(where:{$0.id != sub.id && $0.revision != nil}) else{throw ProxyError("当前配置只能关联一个完整配置订阅")}
                    // 首次接入时只移除仍与已迁移默认规则完全一致的前缀，本地新增和修改保留。
                    if state.subscriptions.first(where:{$0.id==sub.id})?.revision==nil,let previous=state.shadowrocket {
                        let baseline=try previous.applying(to:AppState()).rules
                        func signature(_ rule:RoutingRule)->String {"\(rule.kind)|\(rule.value)|\(rule.action)|\(rule.target?.tag ?? "")|\(rule.noResolve ?? false)"}
                        if next.rules.count>=baseline.count,Array(next.rules.prefix(baseline.count)).allSatisfy({$0.subscriptionID==nil}),next.rules.prefix(baseline.count).map(signature)==baseline.map(signature) {next.rules.removeFirst(baseline.count)}
                    }
                    let merged=try configuration.applying(to:next)
                    next.shadowrocket=configuration;next.dnsPreference=merged.dnsPreference;next.tunExcludedCIDRs=merged.tunExcludedCIDRs;next.captureMode = .systemProxy
                }
                guard profile.unsupported.isEmpty else {throw ProxyError("完整导入包含不支持内容，请选择仅节点")}
                let oldGroups=subscription.map{sub in state.groups.filter{$0.subscriptionID==sub.id}} ?? []
                if let sub=subscription {next.groups.removeAll{$0.subscriptionID==sub.id};next.rules.removeAll{$0.subscriptionID==sub.id}}
                var groupMap:[UUID:UUID]=[:]
                for group in profile.groups {groupMap[group.id]=oldGroups.first{$0.name==group.name}?.id ?? group.id}
                func remap(_ ref:PolicyReference) -> PolicyReference {switch ref {case .node(let id):return .node(mapping[id] ?? id);case .group(let id):return .group(groupMap[id] ?? id);default:return ref}}
                for var group in profile.groups {group.id=groupMap[group.id]!;group.members=group.members.map(remap);group.selected=group.selected.map(remap);group.subscriptionID=subscription?.id;next.groups.append(group)}
                for var rule in profile.rules {rule.target=rule.target.map(remap);rule.subscriptionID=subscription?.id;next.rules.append(rule)}
                if let final=profile.final {next.ruleFinal=remap(final)}
            }
            PolicyValidator.repair(&next)
            if state.nodes.isEmpty && state.activePolicy==nil {next.selectedID=next.nodes.first?.id;next.selectedPolicy=next.selectedID.map(PolicyReference.node)}
            try PolicyValidator.validate(next)
            return StoreTransaction(previous:state,next:next,created:created,retired:retired)
        } catch {for ref in created {try? credentials.remove(ref)};throw error}
    }
    @discardableResult public func importNodes(_ candidates:[Candidate],subscription:Subscription?=nil,source:String?=nil,replacingID:UUID?=nil) throws -> Int {
        let tx=try prepareImport(candidates,subscription:subscription,source:source,replacingID:replacingID)
        let old=state.nodes.count
        do {try commit(tx)} catch {abort(tx);throw error}
        return subscription != nil || replacingID != nil ? candidates.count : state.nodes.count-old
    }
    public func prepareDeleteNodes(_ ids:Set<UUID>) -> StoreTransaction {
        var next=state;let old=state.nodes.filter{ids.contains($0.id)};next.nodes.removeAll{ids.contains($0.id)};PolicyValidator.repair(&next)
        return StoreTransaction(previous:state,next:next,retired:old.flatMap{[$0.credentialRef,$0.credentialRef+".obfs"]})
    }
    public func prepareDeleteNode(_ id:UUID) -> StoreTransaction {
        var next=state;let old=next.nodes.first{$0.id==id};next.nodes.removeAll{$0.id==id};PolicyValidator.repair(&next)
        return StoreTransaction(previous:state,next:next,retired:old.map{[$0.credentialRef,$0.credentialRef+".obfs"]} ?? [])
    }
    public func deleteNode(_ id:UUID) throws {try commit(prepareDeleteNode(id))}
    public func prepareDeleteSubscription(_ id:UUID) -> StoreTransaction {
        var next=state;let old=state.nodes.filter{$0.subscriptionID==id};let sub=state.subscriptions.first{$0.id==id}
        next.nodes.removeAll{$0.subscriptionID==id};next.groups.removeAll{$0.subscriptionID==id};next.rules.removeAll{$0.subscriptionID==id};next.subscriptions.removeAll{$0.id==id};PolicyValidator.repair(&next)
        return StoreTransaction(previous:state,next:next,retired:old.flatMap{[$0.credentialRef,$0.credentialRef+".obfs"]}+(sub.map{[$0.sourceRef]} ?? []))
    }
    public func deleteSubscription(_ id:UUID) throws {try commit(prepareDeleteSubscription(id))}
}
