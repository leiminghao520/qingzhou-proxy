import Foundation
import SwiftUI
import AppKit
import CoreImage
import QingzhouKit

extension AppModel {
    func importPreview(_ input:String) async {guard !locked else{return};busy=true;defer{busy=false};do{pendingSubscription=nil;previewDiff=nil;preview=try await ImportService.preview(input,downloader:dependencies.downloader)}catch{report(error)}}
    func importFile(_ url:URL) async {
        guard !locked else{return};busy=true;defer{busy=false};let granted=url.startAccessingSecurityScopedResource();defer{if granted{url.stopAccessingSecurityScopedResource()}}
        do {let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max)<=2*1024*1024 else {throw ProxyError("文件超过 2 MiB")};let data=try Data(contentsOf:url);let text:String
            if ["png","jpg","jpeg","heic","tiff","gif"].contains(url.pathExtension.lowercased()) {
                guard let image=CIImage(data:data),image.extent.width*image.extent.height<=20_000_000,let detector=CIDetector(ofType:CIDetectorTypeQRCode,context:CIContext(),options:[CIDetectorAccuracy:CIDetectorAccuracyHigh]) else{throw ProxyError("二维码图片无效或尺寸过大")}
                let links=detector.features(in:image).compactMap{($0 as? CIQRCodeFeature)?.messageString};guard !links.isEmpty,links.count<=20 else{throw ProxyError("未识别到二维码或二维码数量超过限制")};text=links.joined(separator:"\n")
            }else{guard let decoded=String(data:data,encoding:.utf8) else{throw ProxyError("文件必须为 UTF-8 或本地二维码图片")};text=decoded}
            pendingSubscription=nil;previewDiff=nil;preview=try ProfileImporter.parse(text)}catch{report(error)}
    }
    func confirmImport(scope:ImportScope = .nodes,adoptingManual:Set<UUID>=[]) async {
        guard !locked,let preview,let store else{return};busy=true;defer{busy=false}
        do {
            var sub=pendingSubscription
            if sub==nil,let source=preview.source {sub=state.subscriptions.first{(try? credentials.get($0.sourceRef))==source} ?? Subscription(name:"订阅 \(state.subscriptions.count+1)")}
            let effectiveScope:ImportScope=preview.fullConfiguration != nil ? .profile:scope
            let tx=try store.prepareImport(preview.candidates,subscription:sub,source:preview.source,profile:preview,scope:effectiveScope,adoptingManual:adoptingManual)
            try await apply(tx,source:"订阅更新");self.preview=nil;pendingSubscription=nil;log("导入已完成")
        } catch {report(error)}
    }
    func cancelPreview(){preview=nil;previewDiff=nil;pendingSubscription=nil}
    func refresh(_ sub:Subscription) async {guard !locked else{return};busy=true;defer{busy=false};do{let result=try await ImportService.preview(credentials.get(sub.sourceRef),downloader:dependencies.downloader);pendingSubscription=sub;previewDiff=UpdateDiff.compare(old:state,preview:result,subscriptionID:sub.id,credentials:credentials);preview=result}catch{recordSubscriptionFailure(sub.id,error:error);report(error)}}
    @discardableResult
    func updateSubscription(_ id:UUID,name:String?=nil,auto:Bool?=nil) -> Bool {guard !locked else{return false};do{var next=state;guard let i=next.subscriptions.firstIndex(where:{$0.id==id}) else{return false};if let name{guard !name.trimmingCharacters(in:.whitespaces).isEmpty else {throw ProxyError("订阅名称不能为空")};next.subscriptions[i].name=name};if let auto{next.subscriptions[i].autoUpdate=auto;next.subscriptions[i].retryCount=0;next.subscriptions[i].retryAfter=nil};try persist(next);return true}catch{report(error);return false}}
    func recordSubscriptionFailure(_ id:UUID,error:Error) {
        let failure=SubscriptionFailure.classify(error);guard failure != .cancelled else{return}
        var next=state;guard let i=next.subscriptions.firstIndex(where:{$0.id==id}) else{return}
        let retry=SubscriptionFailure.retryState(error,previousCount:next.subscriptions[i].retryCount,now:dependencies.now())
        next.subscriptions[i].retryCount=retry.count;next.subscriptions[i].retryAfter=retry.after
        next.subscriptions[i].lastError=failure.localizedDescription;try? persist(next)
    }

    func automaticRefresh(_ id:UUID) async {
        guard !locked,let sub=state.subscriptions.first(where:{$0.id==id}),let store else{return};busy=true;defer{busy=false}
        do {
            let result=try await ImportService.preview(credentials.get(sub.sourceRef),downloader:dependencies.downloader)
            let old=state.nodes.filter{$0.subscriptionID==id}
            let insecure=result.candidates.contains{candidate in candidate.node.insecure && !old.contains{$0.fingerprint==candidate.node.fingerprint && $0.insecure}}
            if insecure || UpdateDiff.compare(old:state,preview:result,subscriptionID:id,credentials:credentials).requiresReview || (sub.scope == .profile && !result.unsupported.isEmpty) || (sub.scope == .nodes && !result.unsupported.filter{!$0.hasPrefix("完整导入") && !$0.hasPrefix("规则") && !$0.hasPrefix("策略")}.isEmpty) {
                var next=state;if let i=next.subscriptions.firstIndex(where:{$0.id==id}){next.subscriptions[i].pendingReview=true;next.subscriptions[i].lastError="更新需要人工预览确认"};try persist(next);log("订阅更新需要人工确认，保留旧节点");return
            }
            let tx=try store.prepareImport(result.candidates,subscription:sub,source:result.source,profile:result,scope:result.fullConfiguration != nil ? .profile:sub.scope);try await apply(tx,source:"订阅更新");log("订阅自动更新成功")
        }catch{recordSubscriptionFailure(id,error:error);log("订阅自动更新失败，保留旧节点")}
    }
    func maintenance() async {
        latencyClock=dependencies.now()
        guard !locked,!wakeRecovery.active,!networkWaiting else{return}
        if transientRefreshPending {rescheduleTransientUpdates()}
        maintainHistory()
        let subs=state.subscriptions.filter{UpdateSchedule.due(updatedAt:$0.updatedAt,enabled:$0.autoUpdate,pending:$0.pendingReview,retryCount:$0.retryCount,retryAfter:$0.retryAfter,now:dependencies.now())}.map(\.id)
        for id in subs {if Task.isCancelled{return};await automaticRefresh(id)}
        let sources=state.remoteRules.filter{UpdateSchedule.due(updatedAt:$0.updatedAt,enabled:$0.autoUpdate,retryCount:$0.retryCount,retryAfter:$0.retryAfter,now:dependencies.now())}.map(\.id)
        for id in sources {if Task.isCancelled{return};await refreshRemote(id,automatic:true)}
    }
    func refreshAll() async {guard !locked else{return};for id in state.subscriptions.map(\.id){await automaticRefresh(id)};for id in state.remoteRules.map(\.id){await refreshRemote(id)}}
    func rescheduleTransientUpdates() {
        transientRefreshPending=true
        guard !locked,!wakeRecovery.active,wakeNetworkReady(),let store else{return}
        var next=state
        let retryAt=dependencies.now()
        for index in next.subscriptions.indices where next.subscriptions[index].autoUpdate && !next.subscriptions[index].pendingReview && SubscriptionFailure.isTransientMessage(next.subscriptions[index].lastError) {
            next.subscriptions[index].retryAfter=retryAt
        }
        for index in next.remoteRules.indices where next.remoteRules[index].autoUpdate && SubscriptionFailure.isTransientMessage(next.remoteRules[index].lastError) {
            next.remoteRules[index].retryAfter=retryAt
        }
        do {try store.commit(next);state=store.state;transientRefreshPending=false}
        catch{log("网络恢复后的订阅重试调度未保存："+error.localizedDescription)}
    }
}
