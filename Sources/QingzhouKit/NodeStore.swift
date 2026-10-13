import Foundation

public final class StoreTransaction {
    public let previous:AppState
    public var next:AppState
    fileprivate let created:[String]
    fileprivate let retired:[String]
    fileprivate var finished=false
    fileprivate init(previous:AppState,next:AppState,created:[String]=[],retired:[String]=[]) {self.previous=previous;self.next=next;self.created=created;self.retired=retired}
}
public final class NodeStore {
    public private(set) var state:AppState
    public let credentials:CredentialStore
    public let file:URL
    public init(file:URL,credentials:CredentialStore) throws {
        self.file=file;self.credentials=credentials
        if FileManager.default.fileExists(atPath:file.path) {
            let data=try Data(contentsOf:file);state=try JSONDecoder().decode(AppState.self,from:data)
            guard (1...2).contains(state.schemaVersion) else {throw ProxyError("配置版本暂不支持")}
            if state.schemaVersion==1 {
                let backup=file.deletingLastPathComponent().appendingPathComponent("state-v1-backup.json")
                if !FileManager.default.fileExists(atPath:backup.path){try SecureFile.write(data,to:backup)}
                state.schemaVersion=2;try SecureFile.write(JSONEncoder().encode(state),to:file)
            }
        } else {state=AppState()}
    }
    public func commit(_ next:AppState) throws {guard next.schemaVersion==2 else {throw ProxyError("不能保存未知配置版本")};try SecureFile.write(JSONEncoder().encode(next),to:file);state=next}
    public func prepareChange(_ next:AppState) -> StoreTransaction {StoreTransaction(previous:state,next:next)}
    public func commit(_ tx:StoreTransaction) throws {
        guard !tx.finished else {throw ProxyError("更新事务已经结束")};try commit(tx.next);tx.finished=true
        for ref in tx.retired {try? credentials.remove(ref)}
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
                mapping[candidate.node.id]=node.id;node.subscriptionID=subscription?.id;node.credentialRef=UUID().uuidString
                created.append(node.credentialRef);try credentials.set(candidate.secret,for:node.credentialRef)
                if let value=candidate.obfsSecret {created.append(node.credentialRef+".obfs");try credentials.set(value,for:node.credentialRef+".obfs")}
                next.nodes.append(node)
            }
            if var sub=subscription {
                sub.updatedAt=Date();sub.pendingReview=false;sub.lastError=nil;sub.retryCount=0;sub.retryAfter=nil;sub.scope=scope;if let profile{sub.usage=profile.usage}
                if let source, (try? credentials.get(sub.sourceRef)) != source {if let old=state.subscriptions.first(where:{$0.id==sub.id}){retired.append(old.sourceRef)};sub.sourceRef=UUID().uuidString;created.append(sub.sourceRef);try credentials.set(source,for:sub.sourceRef)}
                next.subscriptions.removeAll{$0.id==sub.id};next.subscriptions.append(sub)
            }
            if scope == .profile,let profile {
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
