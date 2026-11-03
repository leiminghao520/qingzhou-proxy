import SwiftUI
import AppKit
import QingzhouKit

@main struct DiagnosticUIChecks {
    @MainActor static var count=0
    @MainActor static func check(_ condition:Bool,_ name:String)throws {guard condition else{throw ProxyError(name)};count+=1;print("PASS "+name)}
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task {@MainActor in do {try await run();print("DIAGNOSTIC_UI_CHECKS_OK assertions=\(count)");exit(0)}catch {print("DIAGNOSTIC_UI_CHECKS_FAILED \(error)");exit(1)}}
        NSApplication.shared.run()
    }
    @MainActor static func run() async throws {
        var opened=0
        let dormant=NetworkTimelineModel(url:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),now:Date.init,autoload:false,makeStore:{url in opened+=1;return try NetworkEventStore(url:url)})
        dormant.record(NetworkEvent(sessionID:UUID(),profileID:nil,category:.network,outcome:.changed,reason:.environmentChanged))
        await dormant.clear();await dormant.drain()
        try check(opened==0 && dormant.pendingCount==0,"未取得单实例锁时不读取或写入事件文件")
        var seen:[String]=[],helpers=0
        var dependency=AppDependencies()
        dependency.diagnosticDNS={host in seen.append(host);try? await Task.sleep(nanoseconds:80_000_000);return DiagnosticResult("DNS","通过",host,code:"fixtureDNS")}
        dependency.diagnosticHelper={helpers+=1;throw ProxyError("隔离入口禁止调用真实辅助服务")}
        let model=AppModel(dependencies:dependency)
        guard let store=model.store else{throw ProxyError("隔离模型加载失败")}
        let a=try NodeParser.parse("trojan://one-secret@one.example:443#节点一"),b=try NodeParser.parse("trojan://two-secret@two.example:443#节点二")
        try store.commit(store.prepareImport([a,b]));model.state=store.state
        let nodes=model.state.nodes
        var next=model.state;next.selectedPolicy = .node(nodes[1].id);next.selectedID=nodes[1].id;try model.persist(next)
        await model.diagnose()
        try check(seen.last=="two.example" && model.diagnosticSession?.nodeID==nodes[1].id,"断开诊断使用明确选中节点")
        try check(helpers==0,"系统代理诊断不请求辅助服务")
        next=model.state;next.selectedPolicy = .automatic;try model.persist(next);seen=[]
        await model.diagnose()
        try check(seen.isEmpty && model.diagnosticRows.contains{$0.code=="nodeUnverified"},"无法确定节点时不使用列表首项")
        next.selectedPolicy = .node(nodes[0].id);try model.persist(next)
        let delayed=Task {await model.diagnose()}
        while !model.diagnosing {await Task.yield()}
        model.cancelDiagnostic();await delayed.value
        try check(model.diagnosticRows.contains{$0.code=="cancelled"} && model.connection == .disconnected,"停止诊断及时返回且不改变连接状态")
        let old=Task {await model.diagnose()}
        while !model.diagnosing {await Task.yield()}
        model.epoch=UUID();await old.value
        try check(model.diagnosticSession==nil && model.diagnosticRows.isEmpty,"连接代次改变后迟到结果失效")
        let first=Task {await model.diagnose()}
        while !model.diagnosing {await Task.yield()}
        let oldID=model.diagnosticSession?.id
        let second=Task {await model.diagnose()}
        await first.value;await second.value
        try check(model.diagnosticSession?.id != oldID && !model.diagnosing,"连续诊断只发布最新独立会话")
        model.connection = .connected
        let tag=PolicyReference.node(nodes[1].id).tag
        model.proxyInfo=try JSONDecoder().decode([String:ProxyInfo].self,from:Data(("{\"proxy\":{\"type\":\"Selector\",\"name\":\"proxy\",\"now\":\""+tag+"\"}}").utf8))
        await model.diagnose()
        try check(model.diagnosticSession?.nodeID==nodes[1].id && seen.last=="two.example","连接时冻结实际出站节点而非界面选中策略")
        let liveVersion=try model.profileHistory.versions().first!
        let liveRevision=try ProfileHistoryStore.revision(model.profiles.first{$0.id==liveVersion.profileID}!)
        let unconfirmed=await model.restoreHistory(liveVersion,expectedRevision:liveRevision)
        try check(!unconfirmed && model.connection == .connected,"运行配置恢复缺少明确重连确认时禁止执行")
        model.connection = .disconnected
        let version=try model.profileHistory.versions().first!
        let current=model.profiles.first{$0.id==version.profileID}!
        let revision=try ProfileHistoryStore.revision(current)
        let draft=model.drafts.settings(profile:current.id,state:model.state);draft.port="45678"
        model.drafts.confirmDiscard={_ in false}
        let refused=await model.restoreHistory(version,expectedRevision:revision)
        try check(!refused && draft.port=="45678","历史恢复尊重未保存草稿的取消")
        model.drafts.confirmDiscard={_ in true}
        next=model.state;next.listenPort+=1;try model.persist(next)
        let stale=await model.restoreHistory(version,expectedRevision:revision)
        try check(!stale,"预览后配置已变化时必须重新预览")
        let currentRevision=try ProfileHistoryStore.revision(model.profiles.first{$0.id==version.profileID}!)
        let restored=await model.restoreHistory(version,expectedRevision:currentRevision)
        try check(restored && model.connection == .disconnected,"断开时历史恢复只保存配置")
        await model.timeline.drain()
        var appPublications=0
        let subscription=model.objectWillChange.sink{appPublications+=1}
        for _ in 0..<10001 {model.recordEvent(.network,.changed,.environmentChanged)}
        try check(model.timeline.pendingCount<=1000 && model.timeline.dropped>=9001,"高频事件待写队列严格有界")
        await model.timeline.drain()
        try check(appPublications==0,"时间线刷新不会发布整个应用")
        try check(model.timeline.rows.count<=1000 && model.timeline.rows.last?.count==1000,"时间线内存有界且重复原因合并")
        subscription.cancel()
        let blocked=NetworkTimelineModel(url:model.directory.appendingPathComponent("events-fail.jsonl"),now:Date.init,makeStore:{url in let store=try NetworkEventStore(url:url);store.write={_,_ in throw ProxyError("磁盘注入失败")};return store})
        blocked.record(NetworkEvent(sessionID:UUID(),profileID:nil,category:.connection,outcome:.failed,reason:.startFailed))
        await blocked.drain();let message=blocked.error
        blocked.record(NetworkEvent(sessionID:UUID(),profileID:nil,category:.connection,outcome:.failed,reason:.startFailed));await blocked.drain()
        try check(message != nil && blocked.error==message && blocked.rows.isEmpty,"时间线写入失败提示一次且不影响代理")
        try await render(DiagnosticsView(model:model),name:"diagnostics",model:model)
        try await render(TargetPathPanel(model:model),name:"target-path",model:model)
        try await render(NetworkTimelineView(timeline:model.timeline,profiles:model.profiles),name:"timeline",model:model)
        try await render(ProfileHistoryView(model:model,profileID:model.currentProfileID),name:"history",model:model)
        model.maintainHistory();await model.timeline.drain()
        try check(model.nextHistoryMaintenance>dependency.now(),"长时间运行时按小时维护历史与事件保留期")
        await model.timeline.clear()
        try check(model.timeline.rows.isEmpty,"清空事件不改变当前配置")
    }
    @MainActor static func render<V:View>(_ view:V,name:String,model:AppModel) async throws {
        let host=NSHostingView(rootView:view.padding().frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.windowBackgroundColor)));host.frame=NSRect(x:0,y:0,width:1060,height:720)
        let window=NSWindow(contentRect:host.frame,styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.aqua);window.contentView=host;window.orderFront(nil)
        try await Task.sleep(nanoseconds:200_000_000);host.layoutSubtreeIfNeeded()
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{throw ProxyError("无法生成界面图像")}
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]) else{throw ProxyError("图像编码失败")}
        let output=model.directory.deletingLastPathComponent().appendingPathComponent("evidence").appendingPathComponent(name+".png")
        try SecureFile.write(data,to:output);window.orderOut(nil)
        try check(!data.isEmpty,"界面渲染："+name)
    }
}
