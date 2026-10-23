import SwiftUI
import AppKit
import Combine
import QingzhouKit

private final class OfficeRecorder:@unchecked Sendable {
    private let lock=NSLock()
    private var paths=0
    private var probes=0
    func path() {lock.lock();paths+=1;lock.unlock()}
    func probe()->Int {lock.lock();probes+=1;let result=probes;lock.unlock();return result}
    var values:(Int,Int) {lock.lock();defer{lock.unlock()};return (paths,probes)}
}

private final class OfficeControlProtocol:URLProtocol {
    private static let lock=NSLock()
    private static var connectionReads=0
    private static var policyReads=0
    static var counts:(Int,Int) {lock.lock();defer{lock.unlock()};return (connectionReads,policyReads)}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.lock.lock()
        let body:String
        if request.url?.path=="/connections" {
            Self.connectionReads+=1
            body="{\"uploadTotal\":\(Self.connectionReads*100),\"downloadTotal\":\(Self.connectionReads*200),\"connections\":[]}"
        }else {Self.policyReads+=1;body="{\"proxies\":{}}"}
        Self.lock.unlock()
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct OfficeUIChecks {
    @MainActor static var count=0
    @MainActor static func check(_ value:Bool,_ name:String) throws {
        guard value else {throw ProxyError(name)};count+=1;print("PASS "+name)
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let icon=NSImage(contentsOfFile:".build/AppIcon.icns") {NSApplication.shared.applicationIconImage=icon}
        Task {@MainActor in
            do {try await run();print("OFFICE_UI_CHECKS_OK assertions=\(count)");exit(0)}
            catch {print("OFFICE_UI_CHECKS_FAILED \(error)");exit(1)}
        }
        NSApplication.shared.run()
    }
    @MainActor static func settle(_ milliseconds:UInt64=100) async {try? await Task.sleep(nanoseconds:milliseconds*1_000_000)}
    @MainActor static func run() async throws {
        let args=CommandLine.arguments
        guard let index=args.firstIndex(of:"--output"),index+1<args.count else {throw ProxyError("缺少输出目录")}
        let output=URL(fileURLWithPath:args[index+1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let recorder=OfficeRecorder()
        var dependencies=AppDependencies()
        dependencies.officeHiddenOverride={false}
        dependencies.trafficStream={_ in AsyncThrowingStream<TransferRate,Error>{_ in}}
        dependencies.officePathOverride={target,_,_,_ in
            recorder.path()
            return TargetPathEvidence(rows:[DiagnosticResult("DNS","通过","隔离模拟 DNS",code:"dnsAnswered"),DiagnosticResult("配置预期","说明","隔离模拟规则",code:"ruleSimulation"),DiagnosticResult("系统实际路径","未验证","模拟路径不代表业务连接",code:"businessUnverified")],addresses:["127.0.0.1"],corporate:false)
        }
        dependencies.officeProbeOverride={_,_,_,_ in
            let value=recorder.probe()
            try? await Task.sleep(nanoseconds:value==2 ? 300_000_000:20_000_000)
            return DiagnosticResult("测试连接","通过","隔离模拟连接 \(value)",code:"targetConnectionPassed")
        }
        let model=AppModel(dependencies:dependencies)
        try check(!model.loadingFailed,"使用独立目录初始化，不读取日常配置")
        let target=SavedDiagnosticTarget(name:"内部仓库",host:"git.internal.example",expectedPath:.system)
        try model.saveDiagnosticTargets([target],expected:nil)
        let profile=model.currentProfileID
        let draft=model.drafts.targets(profile:profile,state:model.state)
        draft.values[0].name="未保存的修改"
        let reused=model.drafts.targets(profile:profile,state:model.state)
        try check(reused === draft && reused.dirty,"普通切页保留同一份目标草稿")
        model.drafts.confirmDiscard={_ in false}
        try check(!model.drafts.allowLeaving("关闭目标编辑器",profile:profile),"取消关闭保留目标草稿")
        model.drafts.confirmDiscard={_ in true}
        try check(model.drafts.allowLeaving("关闭目标编辑器",profile:profile) && !draft.dirty,"确认关闭后丢弃草稿")
        let revision=draft.revision
        var changed=target;changed.name="已保存的修改"
        try model.saveDiagnosticTargets([changed],expected:revision)
        do {try model.saveDiagnosticTargets([target],expected:revision);throw ProxyError("版本冲突未被拒绝")}
        catch {try check(model.state.savedDiagnosticTargets?.first?.name==changed.name,"目标版本冲突不覆盖已保存值")}
        model.inspectSavedTarget(changed)
        await settle(150)
        try check(recorder.values.0==1 && recorder.values.1==0,"默认路径检查不调用业务连接探测")
        try check(model.office.sessions[target.id]?.results.contains{$0.code=="businessUnverified"}==true,"路径查询保留业务未验证状态")
        model.connection = .connected
        model.inspectSavedTarget(changed,connect:true);await settle(150)
        try check(recorder.values.1==1 && model.office.label("target-"+target.id.uuidString)=="正常","主动按钮才调用连接探测")
        model.inspectSavedTarget(changed,connect:true);await settle(50)
        let oldNetwork=model.officeNetworkID
        model.invalidateOfficeResults(network:true)
        try check(oldNetwork != model.officeNetworkID && model.office.running.isEmpty,"网络变化取消目标任务并使快照过期")
        model.inspectSavedTarget(changed,connect:true);await settle(150)
        let freshID=model.office.sessions[target.id]?.id
        await settle(300)
        try check(model.office.sessions[target.id]?.id==freshID && model.office.sessions[target.id]?.results.last?.detail=="隔离模拟连接 3","取消后的迟到成功不能覆盖新任务")
        model.inspectSavedTarget(changed,connect:true);await settle(10);model.office.cancel(changed.id);await settle(100)
        try check(!model.office.running.contains(changed.id) && model.office.label("target-"+target.id.uuidString)=="未验证","手动取消不保留检测中或迟到成功")
        model.connection = .disconnected
        await model.createOfficeProfile(name:"隔离家庭",template:.home,domains:["internal.example"],cidrs:[],dns:.system,targets:[target])
        try check(model.currentProfileID==profile,"创建模板不自动切换或连接")
        let home=model.profiles.last!
        try check(home.configuration.protectedDomains.isEmpty && home.configuration.savedDiagnosticTargets==nil && !home.configuration.autoConnect,"家庭模板不继承企业目标或自动连接")
        let dirty=model.drafts.targets(profile:profile,state:model.state);dirty.values[0].name="未应用"
        model.drafts.confirmDiscard={_ in false};await model.changeProfile(home.id)
        try check(model.currentProfileID==profile && dirty.dirty,"切换配置取消时保留原配置和目标草稿")
        model.drafts.confirmDiscard={_ in true};await model.changeProfile(home.id)
        try check(model.currentProfileID==home.id && model.office.sessions.isEmpty,"切换配置清理其他配置的诊断结果")
        await model.changeProfile(profile!)
        try check(model.state.savedDiagnosticTargets?.first?.name==changed.name,"切回原配置恢复其收藏目标")

        let context=model.officeContext
        model.office.set("external",title:"外网 HTTPS",status:.healthy,detail:"隔离模拟 HTTPS 通过",now:Date())
        try check(model.office.health.first{$0.id=="external"}?.isCurrent(context,now:Date())==true,"快照绑定配置、连接与网络代次")
        model.invalidateOfficeResults()
        try check(model.office.label("external").contains("历史"),"旧结果显式标记历史状态")
        let signal=OfficeRefreshSignal(),began=Date()
        let waiting=Task{@MainActor in await signal.wait(30)}
        await settle(30);signal.wake();await waiting.value
        try check(Date().timeIntervalSince(began)<1,"事件唤醒无需高频轮询或等待旧周期结束")
        let cancelledWait=Task{@MainActor in await signal.wait(30)}
        await settle(20);cancelledWait.cancel();await cancelledWait.value
        try check(Date().timeIntervalSince(began)<1,"取消监控会立即终止定时等待")

        var modelChanges=0,trafficChanges=0
        let modelSubscription=model.objectWillChange.sink{modelChanges+=1}
        let trafficSubscription=model.trafficDisplay.objectWillChange.sink{trafficChanges+=1}
        for index in 0..<30 {model.trafficDisplay.receive(upload:Int64(index),download:100,now:Date())}
        try check(modelChanges==0 && trafficChanges==30,"速率采样不广播整个应用模型，单次采样仅发布一次")
        let rateModelPublications=modelChanges,rateTrafficPublications=trafficChanges
        withExtendedLifetime([modelSubscription,trafficSubscription]) {}
        let menuTime=Date(),pagePublications=trafficChanges,appPublications=modelChanges
        model.trafficDisplay.menu.receive(upload:1024,download:2048,now:menuTime)
        try check(model.trafficDisplay.menu.sample.download==2048 && trafficChanges==pagePublications && modelChanges==appPublications,"菜单栏速率发布不刷新页面和整个应用模型")
        model.trafficDisplay.menu.receive(upload:9999,download:9999,now:menuTime.addingTimeInterval(0.5))
        try check(model.trafficDisplay.menu.sample.download==2048,"菜单栏不会随核心高频采样反复发布")
        model.trafficDisplay.menu.receive(upload:4096,download:8192,now:menuTime.addingTimeInterval(1))
        try check(model.trafficDisplay.menu.sample.download==8192,"独立菜单栏在下一秒更新，不等待后台页面的五秒周期")
        model.trafficDisplay.menu.reset()
        try check(model.trafficDisplay.menu.sample==OfficeMenuTrafficSample(),"断开和失去采样时清除菜单栏旧速率")
        withExtendedLifetime([modelSubscription,trafficSubscription]) {}
        // 使用 URLProtocol 模拟核心；不启动核心、设置系统代理或联系辅助服务。
        let control=CoreAPIClient(context:try CoreControlContext.make(),protocolClasses:[OfficeControlProtocol.self])
        var connectivityChecks=0
        model.healthDisplayAwake={true}
        model.state.mode = .direct;model.connection = .connected;model.api=control
        model.connectivityProbe={_,_,_ in connectivityChecks+=1;return [ConnectivityResult("隔离 HTTPS",.passed,"模拟结果")]}
        model.scheduleHealthRefresh(delay:200_000_000);await settle(50)
        model.scheduleHealthRefresh(delay:1_000_000_000);await settle(300)
        try check(connectivityChecks==1,"同一上下文的重复健康请求不取消或推迟在途检查")
        model.cancelHealthRefresh();model.stopTelemetry();await control.shutdown()
        let telemetryControl=CoreAPIClient(context:try CoreControlContext.make(),protocolClasses:[OfficeControlProtocol.self])
        model.busy=true;model.monitorPaused=true
        model.startTelemetry(telemetryControl,profileID:profile)
        await settle(200)
        let firstReads=OfficeControlProtocol.counts
        model.setConnectionsPageVisible(true);await settle(1200)
        let laterReads=OfficeControlProtocol.counts
        try check(laterReads.0>=firstReads.0+2,"连接页可见时立即补刷新并按一秒采样")
        try check(laterReads.1==firstReads.1,"连接列表刷新不连带读取策略")
        await model.history.drain();await settle(100)
        try check(model.history.rows.contains{$0.nodeID==nil && $0.upload>0},"暂停页面监控时历史累计仍独立接收并落盘")
        model.stopTelemetry();model.connection = .disconnected;model.busy=false;model.monitorPaused=false
        await telemetryControl.shutdown()
        try check(model.connectionListTask==nil && model.policyTask==nil && model.telemetryTask==nil,"停止会话取消全部独立监控任务")
        let report:[String:Any]=["assertions":count,"systemNetworkChanged":false,"dailyConfigurationRead":false,"defaultPathBusinessProbeCalls":0,"rateSamples":30,"appModelRatePublications":rateModelPublications,"trafficPublications":rateTrafficPublications]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("model-report.json"))

        let suite="cn.qingzhou.office-checks."+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        defer {preferences.removePersistentDomain(forName:suite)}
        preferences.set("simple",forKey:"interfaceMode")
        model.state.mode = .rule
        model.state.nodes=[Node(name:"办公线路 · 长名称测试 Tokyo Premium Office Route",kind:.shadowsocks,server:"node.invalid",port:443)]
        model.state.selectedPolicy = .node(model.state.nodes[0].id)
        model.state.protectedDomains=["internal.example"]
        model.connection = .connected
        model.office.set("external",title:"外网 HTTPS",status:.healthy,detail:"HTTPS 与 TLS 已校验（模拟状态）",now:Date())
        model.office.set("corporateDNS",title:"企业 DNS",status:.unverified,detail:"尚未查询收藏目标的企业 DNS",now:Date())
        model.office.set("routes",title:"内网保护路由",status:.unverified,detail:"系统代理模式；未主动核验内网路由",now:Date())
        let root=ContentView(model:model).defaultAppStorage(preferences)
        let host=NSHostingView(rootView:AnyView(root))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.contentView=host;window.center();window.makeKeyAndOrderFront(nil)
        var images:[[String:String]]=[]
        func capture(_ name:String,_ appearance:NSAppearance.Name = .aqua) async throws {
            window.appearance=NSAppearance(named:appearance);window.makeKeyAndOrderFront(nil);NSApplication.shared.activate(ignoringOtherApps:true)
            await settle(250);host.layoutSubtreeIfNeeded()
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            process.arguments=["-x","-o","-l",String(window.windowNumber),output.appendingPathComponent(name+".png").path]
            try process.run();process.waitUntilExit()
            if process.terminationStatus==0 {
                images.append(["name":name,"mode":"native-window","file":name+".png"])
            }else {
                // 屏幕休眠或窗口捕获不可用时，仅渲染本程序的模拟视图；不能代替原生材质验收。
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw ProxyError("离屏渲染失败")}
                host.cacheDisplay(in:host.bounds,to:bitmap)
                guard let data=bitmap.representation(using:.png,properties:[:]) else {throw ProxyError("离屏图像编码失败")}
                let file=name+"-offscreen.png";try data.write(to:output.appendingPathComponent(file))
                images.append(["name":name,"mode":"offscreen-view","file":file])
            }
            try check(true,"图像 "+name+" · "+images.last!["mode"]!)
        }
        try await capture("office-home-light");try await capture("office-home-dark",.darkAqua)
        window.setContentSize(NSSize(width:820,height:620));try await capture("office-home-narrow")
        model.office.set("corporateDNS",title:"企业 DNS",status:.failed,detail:"企业解析器未就绪，请检查原网络或查看目标路径",now:Date())
        try await capture("office-home-failure")
        host.rootView=AnyView(root.environment(\._accessibilityReduceTransparency,true).environment(\._colorSchemeContrast,.increased).environment(\._accessibilityReduceMotion,true))
        try await capture("office-home-accessibility")
        window.setContentSize(NSSize(width:1040,height:760))
        host.rootView=AnyView(OverviewView(model:model).padding(20));try await capture("office-overview")
        preferences.set("professional",forKey:"interfaceMode")
        host.rootView=AnyView(root);await settle(100)
        model.connection = .connecting;model.busy=true;model.startupStage="准备核心";model.startupStartedAt=ProcessInfo.processInfo.systemUptime
        try await capture("office-sidebar-connecting")
        model.startupStage="核验企业网络与绕过路由"
        try await capture("office-sidebar-connecting-long-stage")
        model.connection = .connected;model.busy=false;model.startupStage=nil
        try await capture("office-sidebar-connected")
        model.trafficDisplay.menu.receive(upload:1048576,download:2097152,now:Date())
        host.rootView=AnyView(OfficeMenuBarLabel(display:model.trafficDisplay.menu,connected:true,available:true).padding(20))
        try await capture("office-menu-traffic")
        host.rootView=AnyView(DeveloperProxyAssistantView(port:7890,configuredDomains:["internal.example"],cidrs:["10.0.0.0/8"]))
        try await capture("office-developer-tools")
        host.rootView=AnyView(ProfilesView(model:model).padding(20));try await capture("office-profiles")
        try JSONSerialization.data(withJSONObject:images,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("image-report.json"))
        window.close()
        model.connection = .disconnected
        await model.timeline.drain();await model.history.drain()
    }
}
