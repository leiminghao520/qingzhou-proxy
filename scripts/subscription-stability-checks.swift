import Foundation
import QingzhouKit

@main struct SubscriptionStabilityChecks {
    static var checks=0
    static func check(_ value:Bool,_ message:String)throws {
        checks+=1
        if !value {throw ProxyError(message)}
    }
    static func main() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let credentials=MemoryCredentials()
        let store=try NodeStore(file:folder.appendingPathComponent("state.json"),credentials:credentials)
        let manual=try NodeParser.parse("vless://11111111-1111-4111-8111-111111111111@192.0.2.1:443#手动旧节点")
        try store.importNodes([manual])
        let id=store.state.nodes[0].id
        let oldRef=store.state.nodes[0].credentialRef
        var state=store.state
        state.notes[id.uuidString]="我的备注";state.favorites.insert(id);state.selectedID=id;state.selectedPolicy = .node(id)
        let group=PolicyGroup(name:"选择组",kind:.select,members:[.node(id)],selected:.node(id))
        state.groups=[group];state.ruleFinal = .node(id)
        try store.commit(state)
        let fresh=try NodeParser.parse("vless://22222222-2222-4222-8222-222222222222@192.0.2.1:443#订阅新节点")
        let sub=Subscription(name:"设备订阅")
        try check(NodeSubscriptionSupport.source(store.state.nodes[0],state:store.state)=="手动添加","手动来源")
        try check(NodeSubscriptionSupport.guidance(manual.node,state:state)==nil,"无重复时不提示")
        let matches=NodeSubscriptionSupport.matches(state:store.state,incoming:[fresh.node])
        try check(matches.count==1 && matches[0].id==id,"唯一端点生成建议")
        var ambiguous=store.state;ambiguous.nodes.append(manual.node)
        try check(NodeSubscriptionSupport.matches(state:ambiguous,incoming:[fresh.node]).isEmpty,"多手动节点拒绝猜测")
        try check(NodeSubscriptionSupport.matches(state:state,incoming:[fresh.node,fresh.node]).isEmpty,"多传入节点拒绝猜测")
        let preview=ImportPreview(candidates:[fresh])
        try check(UpdateDiff.compare(old:state,preview:preview,subscriptionID:sub.id).requiresReview,"自动更新需确认手动冲突")
        let cancelled=try store.prepareImport([fresh],subscription:sub,adoptingManual:[id])
        store.abort(cancelled)
        try check(store.state.nodes.count==1 && store.state.nodes[0].name=="手动旧节点","取消不改旧节点")
        try check(try credentials.get(oldRef)==manual.secret,"取消不删凭据")
        let without=try store.prepareImport([fresh],subscription:sub)
        try check(without.next.nodes.count==2,"不勾选保留手动节点")
        try check(NodeSubscriptionSupport.guidance(manual.node,state:without.next) != nil,"重复时提示检查旧凭据")
        store.abort(without)
        do {_=try store.prepareImport([fresh],subscription:sub,adoptingManual:[UUID()]);throw ProxyError("错误迁移被接受")}
        catch let error as ProxyError {try check(error.message.contains("重新预览"),"过期建议拒绝")}
        do {_=try store.prepareImport([fresh],adoptingManual:[id]);throw ProxyError("无订阅迁移被接受")}
        catch let error as ProxyError {try check(error.message.contains("重新预览"),"无订阅不迁移")}
        let tx=try store.prepareImport([fresh],subscription:sub,adoptingManual:[id])
        try store.commit(tx)
        let current=store.state.nodes[0]
        try check(store.state.nodes.count==1 && current.id==id && current.subscriptionID==sub.id,"迁移单一节点并保持身份")
        try check(store.state.favorites.contains(id) && store.state.notes[id.uuidString]=="我的备注","保留收藏备注")
        try check(store.state.selectedID==id && store.state.selectedPolicy == .node(id),"保留选择")
        try check(store.state.groups[0].members==[.node(id)] && store.state.groups[0].selected == .node(id) && store.state.ruleFinal == .node(id),"保留策略引用")
        try check(try credentials.get(current.credentialRef)==fresh.secret,"新凭据生效")
        try check(NodeSubscriptionSupport.source(current,state:store.state)=="订阅：设备订阅","订阅来源")
        var missing=store.state;missing.subscriptions=[]
        try check(NodeSubscriptionSupport.source(current,state:missing)=="订阅：来源不可用","丢失来源降级")
        try check(NodeSubscriptionSupport.guidance(current,state:store.state)==nil,"订阅节点不误提示")
        try check(!UpdateDiff.compare(old:store.state,preview:preview,subscriptionID:sub.id).manualNodeConflicts,"稳定更新不重复提示")
        for (values,expected) in [(["超时","TLS"],NodeDetectionFailure.timeout),(["TLS"],.tls),(["HTTP 响应"],.http),(["鉴权"],.unknown),([],.unknown)] {
            let failure=NodeDetectionFailure.classify(values)
            try check(failure==expected,"失败分类")
            let result=LatencyResult(milliseconds:nil,failure:failure)
            let decoded=try JSONDecoder().decode(LatencyResult.self,from:JSONEncoder().encode(result))
            try check(decoded.failure==expected,"分类序列化")
            try check(LatencyPresentation.label(decoded,invalidatedAt:.distantPast).contains(expected.label),"界面失败文案")
        }
        let legacy=Data("{\"testedAt\":0}".utf8)
        let old=try JSONDecoder().decode(LatencyResult.self,from:legacy)
        try check(old.failure==nil && old.milliseconds==nil,"旧记录兼容")
        try check(LatencyPresentation.label(old,invalidatedAt:.distantPast).contains("检测失败"),"旧失败记录展示")
        print("订阅稳定性检查通过：\(checks) 项断言")
    }
}
