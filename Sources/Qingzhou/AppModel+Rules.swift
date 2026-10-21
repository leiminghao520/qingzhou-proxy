import Foundation
import SwiftUI
import AppKit
import CoreImage
import QingzhouKit

extension AppModel {
    func addRule(_ rule:RoutingRule) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{try ConfigBuilder.validate(rule);var next=state;next.rules.append(rule);try await apply(store.prepareChange(next))}catch{report(error)}}
    func setRuleFinal(_ ref:PolicyReference) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.ruleFinal=ref;try await apply(store.prepareChange(next))}catch{report(error)}}
    func removeRule(_ id:UUID) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;next.rules.removeAll{$0.id==id};try await apply(store.prepareChange(next))}catch{report(error)}}
    func moveRule(_ id:UUID,by offset:Int) async {guard !locked,let store,let i=state.rules.firstIndex(where:{$0.id==id}),state.rules.indices.contains(i+offset) else{return};busy=true;defer{busy=false};do{var next=state;next.rules.swapAt(i,i+offset);try await apply(store.prepareChange(next))}catch{report(error)}}
    func ruleRevision() throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var data=try encoder.encode(state.rules);data.append(try encoder.encode(state.ruleFinal));data.append(Data((currentProfileID?.uuidString ?? "").utf8));return data
    }
    func applyRuleDraft(_ rules:[RoutingRule],final:PolicyReference,revision:Data) async -> Bool {
        guard !locked,let store else {return false}
        busy=true;defer{busy=false}
        do {
            guard try ruleRevision()==revision else {throw ProxyError("原规则或配置已变化，请撤销草稿后重新编辑")}
            var next=state;next.rules=rules;next.ruleFinal=final
            try PolicyValidator.validate(next);try await apply(store.prepareChange(next));return true
        }catch{report(error);return false}
    }
    func reorderRules(_ order:[UUID],expectedOrder:[UUID]) async -> Bool {
        guard !locked,let store else {return false}
        // 只有用户点击应用才提交排序，预览拖动不生成配置或重连。
        guard state.rules.map(\.id)==expectedOrder,order.count==expectedOrder.count,Set(order)==Set(expectedOrder) else {report(ProxyError("规则列表已变化，请重新排序"));return false}
        guard order != expectedOrder else {return true}
        let rules=Dictionary(uniqueKeysWithValues:state.rules.map {($0.id,$0)})
        var next=state;next.rules=order.compactMap {rules[$0]}
        busy=true;defer{busy=false}
        do {try await apply(store.prepareChange(next));return true} catch {report(error);return false}
    }

    func addRemote(name:String,url:String,target:PolicyReference) async {
        guard !locked,!name.isEmpty,let store else{return};busy=true;defer{busy=false};var source=RemoteRuleSource(name:name,target:target)
        do {source.rules=try await downloadRules(url);source.updatedAt=Date();try credentials.set(url,for:source.sourceRef);var next=state;next.remoteRules.append(source);do{try await apply(store.prepareChange(next))}catch{try? credentials.remove(source.sourceRef);throw error}}catch{report(error)}
    }
    func downloadRules(_ source:String) async throws -> [RoutingRule] {guard let url=URL(string:source),url.scheme=="https" else {throw ProxyError("规则地址必须使用 HTTPS")};let data=try await dependencies.downloader.fetchResponse(url,limit:2*1024*1024).data;guard let text=String(data:data,encoding:.utf8) else {throw ProxyError("规则必须为 UTF-8")};return try RemoteRulesParser.parse(text)}
    func refreshRemote(_ id:UUID,automatic:Bool=false) async {
        guard !locked,let store,let source=state.remoteRules.first(where:{$0.id==id}) else{return};busy=true;defer{busy=false}
        do {let rules=try await downloadRules(credentials.get(source.sourceRef));var next=state;guard let i=next.remoteRules.firstIndex(where:{$0.id==id}) else{return};next.remoteRules[i].rules=rules;next.remoteRules[i].updatedAt=Date();next.remoteRules[i].lastError=nil;next.remoteRules[i].retryCount=0;next.remoteRules[i].retryAfter=nil;try await apply(store.prepareChange(next));log("远程规则更新成功")}
        catch {var next=state;if let i=next.remoteRules.firstIndex(where:{$0.id==id}) {let retry=SubscriptionFailure.retryState(error,previousCount:next.remoteRules[i].retryCount);next.remoteRules[i].retryCount=retry.count;next.remoteRules[i].retryAfter=retry.after;next.remoteRules[i].lastError=SubscriptionFailure.classify(error).localizedDescription;try? persist(next)};if !automatic{report(error)}else{log("规则自动更新失败，保留旧缓存")}}
    }
    func updateRemote(_ id:UUID,auto:Bool?=nil,target:PolicyReference?=nil) async {guard !locked,let store else{return};busy=true;defer{busy=false};do{var next=state;guard let i=next.remoteRules.firstIndex(where:{$0.id==id}) else{return};if let auto{next.remoteRules[i].autoUpdate=auto;next.remoteRules[i].retryCount=0;next.remoteRules[i].retryAfter=nil};if let target{next.remoteRules[i].target=target};try await apply(store.prepareChange(next),reconfigure:target != nil)}catch{report(error)}}
    func moveRemote(_ id:UUID,by offset:Int) async {guard !locked,let store,let i=state.remoteRules.firstIndex(where:{$0.id==id}),state.remoteRules.indices.contains(i+offset) else{return};busy=true;defer{busy=false};do{var next=state;next.remoteRules.swapAt(i,i+offset);try await apply(store.prepareChange(next))}catch{report(error)}}
    func deleteRemote(_ id:UUID) async {guard !locked,let store,let source=state.remoteRules.first(where:{$0.id==id}) else{return};busy=true;defer{busy=false};do{var next=state;next.remoteRules.removeAll{$0.id==id};try await apply(store.prepareChange(next));if !store.catalog.credentialRefs.contains(source.sourceRef){try? credentials.remove(source.sourceRef)}}catch{report(error)}}
}
