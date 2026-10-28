import SwiftUI
import AppKit
import QingzhouKit

// 关闭连接请求由本地协议夹具接收，不访问真实核心。
final class ClosingProtocol:URLProtocol {
    static var paths:[String]=[]
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.paths.append(request.url!.path)
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct PageOptimizationChecks {
    @MainActor static var checks=0
    @MainActor static func check(_ value:Bool,_ message:String) throws {
        guard value else{throw ProxyError(message)}
        checks+=1;print("PASS "+message)
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        Task {@MainActor in
            do {try await run();exit(0)}catch{print("PAGE_OPTIMIZATION_CHECKS_FAILED \(error)");exit(1)}
        }
        app.run()
    }
    static func connections(_ count:Int) throws -> [CoreConnection] {
        let rows=(0..<count).map {i -> [String:Any] in
            ["id":"row-\(i)","metadata":["host":"target-\(i).example","destinationPort":"443","network":i%2==0 ? "tcp":"udp","processPath":"/Applications/Fixture\(i).app"],"upload":i,"download":count-i,"start":String(format:"%05d",i),"chains":["node-\(i%3)"]]
        }
        return try JSONDecoder().decode([CoreConnection].self,from:JSONSerialization.data(withJSONObject:rows))
    }
    @MainActor static func telemetryChecks(_ model:AppModel) throws {
        let rows=try connections(2)
        let snapshot=ConnectionSnapshotFixture.make(rows:rows,up:7,down:11)
        let proxies=try JSONDecoder().decode([String:ProxyInfo].self,from:Data(#"{"proxy":{"type":"Selector","name":"proxy","now":"node-a"},"node-a":{"type":"VLESS","name":"node-a","history":[{"delay":20}]}}"#.utf8))
        var status=TunReply(ok:true,message:"隔离正常",running:true,phase:"active")
        status.protectionSummary=["隔离保护"]
        try check(model.publishTelemetry(snapshot,info:proxies),"首个出口发布仍报告变化")
        model.updateHelperNetworkStatus(status)
        var publications=0
        let subscription=model.objectWillChange.sink {publications+=1}
        for _ in 0..<20 {
            try check(!model.publishTelemetry(snapshot,info:proxies),"相同遥测不报告出口变化")
            model.updateHelperNetworkStatus(status)
        }
        try check(publications==0,"相同连接、策略和保护摘要连续二十轮不发布更新")
        _=model.publishTelemetry(ConnectionSnapshotFixture.make(rows:rows,up:9,down:13),info:proxies)
        try check(publications==2 && model.uploadTotal==9 && model.downloadTotal==13,"连接不变时累计计数仍独立更新")
        var historyChanged=proxies;historyChanged["node-a"]!.history![0].delay=35
        publications=0
        try check(!model.publishTelemetry(snapshot,info:historyChanged) && publications==3,"延迟历史变化仍发布策略信息，不误报出口切换")
        var targetChanged=historyChanged;targetChanged["proxy"]!.now="node-b"
        try check(model.publishTelemetry(snapshot,info:targetChanged),"实际出口切换仍触发连通性复查信号")
        var updatedRows=rows;updatedRows[0].upload+=5
        _=model.publishTelemetry(ConnectionSnapshotFixture.make(rows:updatedRows,up:12,down:13),info:targetChanged)
        try check(model.connections[0].upload==updatedRows[0].upload && model.trafficByNode["node-0"]==7,"连接计数变化仍更新列表及节点流量增量")
        _=model.publishTelemetry(ConnectionSnapshotFixture.make(rows:[],up:12,down:13),info:targetChanged)
        try check(model.connections.isEmpty && model.observedConnections.isEmpty,"连接消失仍清除列表及累计基线")
        _=model.publishTelemetry(snapshot,info:targetChanged)
        status.protectionSummary=["保护发生变化"];publications=0
        model.updateHelperNetworkStatus(status)
        try check(publications==1,"保护变化立即发布")
        status.phase="networkReconnecting"
        model.updateHelperNetworkStatus(status);publications=0
        model.updateHelperNetworkStatus(status)
        try check(publications==0 && model.networkReconnecting && model.connections.isEmpty,"重连期间重复状态不重绘，首次仍清理旧连接")
        subscription.cancel()
        // 仅重置隔离模型，不访问辅助服务或真实核心。
        model.networkReconnecting=false;model.proxyInfo=[:];model.connections=[];model.observedConnections=[:]
        model.trafficByNode=[:];model.trafficByTarget=[:]
    }
    @MainActor static func run() async throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[CommandLine.arguments.firstIndex(of:"--output")!+1])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let projection=ListProjection<Int,Int>()
        try check(projection.resolve(1){42}==42 && projection.resolve(1){0}==42,"通用缓存复用已有结果")
        try check(projection.resolve(2){7}==7 && projection.computations==2,"输入变化仅重算一次")
        for count in [0,999,1000,1001,2501] {
            let page=ConnectionListModel(),source=try connections(count)
            let rows=page.rows(source,labels:["node-0":"企业节点"])
            try check(rows.count==count && rows.prefix(page.limit).count==min(count,1000),"连接数量边界 \(count)")
            page.loadMore();page.loadMore()
            try check(rows.prefix(page.limit).count==count,"连接分批加载 \(count)")
            _=page.rows(source,labels:["node-0":"企业节点"])
            try check(page.projection.computations==1,"加载额度不重复排序 \(count)")
            page.query="unmatched";try check(page.limit==1000 && page.rows(source,labels:[:]).isEmpty,"无匹配与额度重置 \(count)")
            page.clearFilters();page.network="TCP"
            try check(page.rows(source,labels:[:]).count==(count+1)/2,"协议筛选完整数据 \(count)")
            page.clearFilters();page.order="持续时间"
            try check(page.rows(source,labels:[:]).map(\.id)==source.map(\.id),"持续时间排序 \(count)")
            page.loadMore();page.order="目标";try check(page.limit==1000,"排序变化重置额度")
            _=page.rows(source,labels:[:]);page.query="企业节点"
            try check(page.rows(source,labels:["node-0":"企业节点"]).count==(count+2)/3,"节点标签参与筛选")
            page.clearFilters();page.query="/Applications/Fixture0.app"
            try check(page.rows(source,labels:[:]).count==(count>0 ? 1:0),"进程路径筛选")
            page.clearFilters();var changed=source
            if !changed.isEmpty {changed[0].download+=10000;changed[0].rule="规则已变更"}
            _=page.rows(changed,labels:[:])
            try check(page.rows([],labels:[:]).isEmpty,"连接消失不会保留旧行")
        }
        let sparse=try JSONDecoder().decode(CoreConnection.self,from:Data(#"{"id":"sparse","metadata":{},"upload":0,"download":0,"start":"","chains":[]}"#.utf8))
        let sparsePage=ConnectionListModel();sparsePage.query="不存在"
        try check(sparsePage.rows([sparse],labels:[:]).isEmpty,"核心未提供进程路径时仍可筛选")
        let store=SessionDraftStore(),a=UUID(),b=UUID();var state=AppState()
        let settings=store.settings(profile:a,state:state)
        try check(!store.hasDirty(profile:a),"初始设置无草稿")
        settings.port="12345"
        try check(settings.dirty && store.hasDirty(profile:a),"仅端口修改也纳入离开保护")
        settings.network.capture = .compatible;settings.shortcut.key=2
        try check(store.settings(profile:a,state:AppState()) === settings,"普通切页复用草稿对象")
        try check(!store.settings(profile:b,state:state).dirty,"配置之间草稿隔离")
        var prompts=0;store.confirmDiscard={_ in prompts+=1;return false}
        try check(!store.allowLeaving("切换配置",profile:a) && settings.port=="12345","取消离开保留所有设置")
        state.listenPort=23456;state.captureMode = .tun;state.shortcutKey=15;settings.sync(state)
        try check(settings.networkConflict && settings.portConflict && settings.shortcutConflict,"外部修改保留输入并标记冲突")
        settings.acceptNetwork(state)
        try check(settings.port=="12345" && settings.shortcut.key==2,"网络保存仅清除对应草稿")
        store.confirmDiscard={_ in prompts+=1;return true}
        try check(store.allowLeaving("切换配置",profile:a) && !settings.dirty && settings.port=="23456","确认丢弃恢复最新基线")
        settings.sync(state);settings.acceptPort(state);settings.acceptShortcut(state)
        let emptyProfile=store.settings(profile:nil,state:state)
        try check(store.settings(profile:nil,state:state) === emptyProfile,"未命名配置的设置共享")
        try check(store.settings(profile:UUID(uuidString:"00000000-0000-0000-0000-000000000000"),state:state) !== emptyProfile,"未命名配置与零标识配置不冲突")
        let nilRules=store.rules(profile:nil);nilRules.input="未保存"
        try check(store.hasDirty() && store.allowLeaving("离开未命名配置"),"未命名配置离开处理")
        _=store.bypass(profile:nil,items:[],revision:nil)
        let rule=store.rules(profile:a)
        rule.text="非法规则原始文本";rule.textBaseline="原始文本";rule.revision=Data([1])
        try check(rule.dirty && store.rules(profile:a).text=="非法规则原始文本","无效规则文本保持原样")
        rule.begin(state:state,revision:Data([2]));rule.begin(state:AppState(),revision:Data([3]))
        try check(rule.revision==Data([1]),"文本打开时版本保留至接受草稿")
        rule.input="未加入的规则";rule.discardText()
        try check(rule.rules != nil && rule.revision==Data([1]) && rule.input=="未加入的规则","关闭文本不清除上层规则草稿")
        rule.discard();rule.text="x";rule.discardText();try check(rule.revision==nil && !rule.dirty,"仅文本草稿可独立清除")
        let item=NetworkBypass(kind:.cidr,value:"192.0.2.0/24")
        let bypass=store.bypass(profile:a,items:[],revision:Data([1]))
        var unchangedNotifications=0
        let bypassSubscription=bypass.objectWillChange.sink {unchangedNotifications+=1}
        bypass.sync(items:[],revision:Data([1]))
        try check(unchangedNotifications==0,"干净绕过列表同步不发布重复数据")
        bypassSubscription.cancel()
        bypass.items=[item];bypass.converted.insert(UUID())
        bypass.sync(items:[],revision:Data([2]))
        try check(bypass.dirty && bypass.revision==Data([1]),"绕过草稿保留原始事务版本")
        try check(store.bypass(profile:a,items:[],revision:nil) === bypass,"绕过跨页面共享")
        bypass.accept(items:[item],revision:Data([3]));bypass.sync(items:[],revision:Data([4]))
        try check(!bypass.dirty && bypass.items.isEmpty && bypass.revision==Data([4]),"绕过成功保存和外部更新同步")
        let editor=EditorValueDraft(""),editorID=UUID();editor.value="未加入父草稿"
        store.registerEditor(editorID,profile:b,draft:editor)
        try check(store.hasDirty(profile:b) && store.hasDirty(all:true),"嵌套编辑器纳入退出检查")
        store.confirmDiscard={_ in false}
        try check(!store.allowLeaving("退出",all:true) && editor.dirty,"取消退出保留嵌套编辑内容")
        store.confirmDiscard={_ in true};try check(store.allowLeaving("退出",all:true) && !editor.dirty,"确认离开清理嵌套编辑内容")
        store.unregisterEditor(editorID);store.unregisterEditor(editorID)
        try check(store.allowLeaving("无草稿离开",all:true),"干净页面直接离开")
        try check(!SessionDraftStore().hasDirty(all:true),"新应用会话不恢复旧草稿")
        var benchmark:[[String:Any]]=[]
        for count in (CommandLine.arguments.contains("--quick") ? [24]:[1000,10000]) {
            var input=AppState();input.nodes=(0..<count).map{Node(name:"节点\(count-$0)",kind:ProxyKind.allCases[$0%4],server:"n\($0).example",port:443)}
            for (index,node) in input.nodes.enumerated() {
                if index%7==0 {input.favorites.insert(node.id)}
                input.latency[node.id.uuidString]=LatencyResult(milliseconds:index%300,testedAt:Date())
                input.recentUse[node.id.uuidString]=Date(timeIntervalSince1970:Double(index))
                input.notes[node.id.uuidString]="备注 \(index)"
            }
            let now=Date(),invalidated=now.addingTimeInterval(-60),page=NodeListViewModel(),legacy=LegacyNodeListViewModel()
            for order in ["HTTPS 延迟","节点名称","协议","最近使用"] {
                page.sort=order;legacy.sort=order
                try check(page.nodes(state:input,invalidatedAt:invalidated,now:now).map(\.id)==legacy.nodes(state:input,invalidatedAt:invalidated,now:now).map(\.id),"节点排序对照 \(count) \(order)")
            }
            page.sort="HTTPS 延迟";legacy.sort="HTTPS 延迟"
            _=page.nodes(state:input,invalidatedAt:invalidated,now:now)
            let computations=page.projection.computations,start=ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 {_=page.nodes(state:input,invalidatedAt:invalidated,now:now)}
            let cached=(ProcessInfo.processInfo.systemUptime-start)*1000,baseStart=ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 {_=legacy.nodes(state:input,invalidatedAt:invalidated,now:now)}
            let baseline=(ProcessInfo.processInfo.systemUptime-baseStart)*1000
            try check(page.projection.computations==computations,"连续 100 次无关更新不重复排序 \(count)")
            benchmark.append(["nodes":count,"reads":100,"cachedMs":cached,"baselineMs":baseline,"additionalSorts":page.projection.computations-computations])
            page.query="备注 9";legacy.query=page.query;page.favoriteOnly=true;legacy.favoriteOnly=true
            page.selectedKind = .shadowsocks;legacy.selectedKind = .shadowsocks
            try check(page.nodes(state:input,invalidatedAt:invalidated,now:now).map(\.id)==legacy.nodes(state:input,invalidatedAt:invalidated,now:now).map(\.id),"组合筛选对照")
            page.clearFilters();let first=input.nodes[0].id
            input.nodes[0].name="改名";_=page.nodes(state:input,invalidatedAt:invalidated,now:now)
            let revision=page.projection.computations
            input.notes[first.uuidString]="新备注";_=page.nodes(state:input,invalidatedAt:invalidated,now:now)
            try check(page.projection.computations==revision+1,"备注变化使缓存失效")
            input.latency[first.uuidString]=LatencyResult(milliseconds:1,testedAt:now)
            _=page.nodes(state:input,invalidatedAt:now,now:now)
            let epochRevision=page.projection.computations
            _=page.nodes(state:input,invalidatedAt:now,now:now.addingTimeInterval(301))
            try check(page.projection.computations==epochRevision+1,"延迟过期使缓存失效")
            let expiredRevision=page.projection.computations
            input.latency[first.uuidString]=LatencyResult(milliseconds:1,testedAt:now.addingTimeInterval(302))
            _=page.nodes(state:input,invalidatedAt:now,now:now.addingTimeInterval(302),profile:a)
            try check(page.projection.computations==expiredRevision+1,"重新测速与配置切换使缓存失效")
            page.query="不存在";try check(page.nodes(state:input,invalidatedAt:now,now:now,simple:true).isEmpty,"简洁线路无匹配")
        }
        var timed=AppState();let timedNode=Node(name:"即将过期",kind:.shadowsocks,server:"timer.invalid",port:443)
        timed.nodes=[timedNode];timed.latency[timedNode.id.uuidString]=LatencyResult(milliseconds:10,testedAt:Date().addingTimeInterval(-299.92))
        let timedPage=NodeListViewModel();var expiryNotifications=0
        let subscription=timedPage.objectWillChange.sink {expiryNotifications+=1}
        _=timedPage.nodes(state:timed,invalidatedAt:Date().addingTimeInterval(-600),now:Date(),profile:a)
        try await Task.sleep(nanoseconds:150_000_000)
        try check(expiryNotifications>0,"延迟到期主动通知页面刷新")
        let beforeProfile=timedPage.projection.computations
        _=timedPage.nodes(state:timed,invalidatedAt:.distantPast,now:Date(),profile:a)
        _=timedPage.nodes(state:timed,invalidatedAt:.distantPast,now:Date(),profile:b)
        try check(timedPage.projection.computations==beforeProfile+2,"配置单独变化使缓存失效")
        subscription.cancel()
        timedPage.selection=[timedNode.id]
        try check(timedPage.selection.contains(timedNode.id),"节点选择独立于结果缓存")
        _=timedPage.$selection;_=timedPage.$query;_=timedPage.$sort;_=timedPage.$selectedKind;_=timedPage.$favoriteOnly
        let bindings=ConnectionListModel();_=bindings.$query;_=bindings.$network;_=bindings.$order;_=bindings.$limit
        let sameName=Node(id:UUID(uuidString:"00000000-0000-0000-0000-000000000002")!,name:"同名",kind:.vless,server:"fixture.invalid",port:443)
        var tied=AppState();var earlier=sameName;earlier.id=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!;tied.nodes=[sameName,earlier]
        let tiedPage=NodeListViewModel()
        try check(tiedPage.nodes(state:tied,invalidatedAt:.distantPast,now:Date()).map(\.id)==[earlier.id,sameName.id],"专业节点同名按标识排序")
        tiedPage.sort="最近使用"
        try check(tiedPage.nodes(state:tied,invalidatedAt:.distantPast,now:Date()).map(\.id)==[earlier.id,sameName.id],"无使用记录时回退到名称和标识")
        try check(tiedPage.nodes(state:tied,invalidatedAt:.distantPast,now:Date(),simple:true).map(\.id)==[earlier.id,sameName.id],"简洁线路同名按标识稳定排序")
        let parent=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        let child=NSWindow(contentRect:NSRect(x:0,y:0,width:300,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false;child.isReleasedWhenClosed=false
        parent.beginSheet(child,completionHandler:nil)
        let guardView=EditorCloseGuard.GuardView();var closeAllowed=false;guardView.allowClose={closeAllowed};child.contentView=guardView;guardView.attach()
        try check(!guardView.windowShouldClose(child),"编辑弹窗原生关闭可取消")
        closeAllowed=true;try check(guardView.windowShouldClose(child),"编辑弹窗确认后允许关闭")
        guardView.detach();parent.endSheet(child);child.close();parent.close()
        let defaultConfirmation=SessionDraftStore()
        let cancelTimer=Timer(timeInterval:0.05,repeats:true) {timer in
            if NSApp.modalWindow != nil {NSApp.stopModal(withCode:.alertFirstButtonReturn);timer.invalidate()}
        }
        RunLoop.main.add(cancelTimer,forMode:.modalPanel)
        try check(!defaultConfirmation.confirm("隔离取消确认检查"),"默认确认框继续编辑不丢弃")
        let discardTimer=Timer(timeInterval:0.05,repeats:true) {timer in
            if NSApp.modalWindow != nil {NSApp.stopModal(withCode:.alertSecondButtonReturn);timer.invalidate()}
        }
        RunLoop.main.add(discardTimer,forMode:.modalPanel)
        try check(defaultConfirmation.confirm("隔离丢弃确认检查"),"默认确认框明确丢弃才继续")
        let model=AppModel();try check(!model.loadingFailed,"隔离应用模型初始化")
        try telemetryChecks(model)
        await model.createProfile(name:"隔离第二配置",copy:false)
        let secondProfile=model.profiles.last!.id
        let profile=model.currentProfileID
        let draft=model.drafts.settings(profile:profile,state:model.state);draft.port="未保存端口"
        model.drafts.confirmDiscard={_ in false};model.connection = .connected
        let quitResult=await model.quit()
        try check(!quitResult && model.connection == .connected && draft.port=="未保存端口","退出取消先于任何网络释放")
        await model.changeProfile(secondProfile)
        try check(model.currentProfileID==profile && model.connection == .connected,"配置切换取消不改变当前连接")
        model.connection = .disconnected
        let rules=model.drafts.rules(profile:profile);rules.begin(state:model.state,revision:Data([0]));rules.input="保留输入"
        let saved=await model.applyRuleDraft([],final:.selected,revision:Data([0]))
        try check(!saved && rules.dirty && rules.input=="保留输入","规则版本冲突保留草稿")
        let bypassSaved=await model.applyBypassDraft([item],converted:[],revision:Data([0]))
        try check(!bypassSaved,"绕过版本冲突在提交前拒绝")
        await model.savePort(0);try check(draft.port=="未保存端口","保存失败保留设置输入")
        model.errorMessage=nil
        let closingClient=CoreAPIClient(context:try CoreControlContext.make(),protocolClasses:[ClosingProtocol.self])
        model.api=closingClient;model.connections=try connections(2501)
        let closingPage=ConnectionListModel();closingPage.query="没有匹配"
        _=closingPage.rows(model.connections,labels:[:])
        await model.closeConnection(nil)
        try check(ClosingProtocol.paths==["/connections"],"关闭全部连接不受筛选或分页限制")
        await closingClient.shutdown();model.api=nil;model.connections=[]
        model.drafts.confirmDiscard={_ in true}
        await model.changeProfile(secondProfile)
        try check(model.currentProfileID==secondProfile && !model.drafts.hasDirty(profile:profile),"确认切换配置丢弃相关草稿并完成隔离保存")
        try await screenshots(model:model,output:output)
        let report:[String:Any]=["checks":checks,"benchmark":benchmark,"changedSystemNetwork":false,"dailyConfigurationRead":false,"swiftBranchCoverage":"unavailable","PIT":"not applicable to Swift"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        print("PAGE_OPTIMIZATION_CHECKS_OK checks=\(checks) benchmark=\(benchmark)")
    }
    @MainActor static func screenshots(model:AppModel,output:URL) async throws {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:AnyView(EmptyView()));window.contentView=host;window.orderFront(nil)
        func capture(_ name:String,_ view:AnyView,_ appearance:NSAppearance.Name) async throws {
            window.appearance=NSAppearance(named:appearance);host.rootView=AnyView(view.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.windowBackgroundColor)))
            try await Task.sleep(nanoseconds:160_000_000)
            host.layoutSubtreeIfNeeded()
            guard let image=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{throw ProxyError("截图创建失败")}
            host.cacheDisplay(in:host.bounds,to:image)
            guard let data=image.representation(using:.png,properties:[:]) else{throw ProxyError("截图编码失败")}
            try data.write(to:output.appendingPathComponent(name+".png"))
        }
        model.state.captureMode = .compatible
        let node=Node(name:String(repeating:"很长的企业线路名称",count:8),kind:.shadowsocks,server:"fixture.invalid",port:443)
        model.state.nodes=[node];model.state.selectedPolicy = .node(node.id)
        model.protectionSummary=[String(repeating:"企业网络保护详情 ",count:15)]
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            try await capture("overview-\(appearance.rawValue)",AnyView(OverviewView(model:model).padding(24)),appearance)
            try await capture("connections-\(appearance.rawValue)",AnyView(ConnectionsView(model:model).padding(24)),appearance)
            try await capture("settings-\(appearance.rawValue)",AnyView(SettingsView(model:model).padding(24)),appearance)
        }
        let sessionSettings=model.drafts.settings(profile:model.currentProfileID,state:model.state)
        sessionSettings.port="23456"
        let sessionRules=model.drafts.rules(profile:model.currentProfileID)
        sessionRules.begin(state:model.state,revision:try? model.ruleRevision())
        let rule=RoutingRule(kind:.domain,value:"preserved.example",action:.direct)
        sessionRules.rules!.append(rule)
        try await capture("rules-draft-dark",AnyView(RuleView(model:model).padding(24)),.darkAqua)
        let sessionBypass=model.drafts.bypass(profile:model.currentProfileID,items:model.state.effectiveBypasses,revision:try? model.bypassRevision())
        let bypass=NetworkBypass(kind:.cidr,value:"192.0.2.0/24");sessionBypass.items.append(bypass)
        try await capture("bypass-draft-dark",AnyView(NetworkBypassView(model:model).padding(24)),.darkAqua)
        try await capture("settings-return-dark",AnyView(SettingsView(model:model).padding(24)),.darkAqua)
        try check(sessionSettings.port=="23456" && sessionRules.rules!.contains{$0.id==rule.id} && sessionBypass.items.contains{$0.id==bypass.id},"真实页面销毁重建后保留各类草稿")
        window.setContentSize(NSSize(width:600,height:700))
        try await capture("overview-narrow-dark",AnyView(OverviewView(model:model).padding(24)),.darkAqua)
        var closePrompts=0;model.drafts.confirmDiscard={_ in closePrompts+=1;return false}
        window.close()
        try check(closePrompts==0 && model.drafts.hasDirty(all:true),"关闭主窗口保留草稿且不触发退出")
    }
}

private enum ConnectionSnapshotFixture {
    static func make(rows:[CoreConnection],up:Int64,down:Int64) -> ConnectionSnapshot {
        let data=try! JSONSerialization.data(withJSONObject:["uploadTotal":up,"downloadTotal":down,"connections":rows.map {row in
            ["id":row.id,"metadata":["host":row.metadata.host ?? ""],"upload":row.upload,"download":row.download,"start":row.start,"chains":row.chains] as [String:Any]
        }])
        return try! JSONDecoder().decode(ConnectionSnapshot.self,from:data)
    }
}
