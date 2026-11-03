import SwiftUI
import AppKit
import QingzhouKit

@main struct BypassInterfaceChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task {@MainActor in do {try await run();exit(0)}catch {print("BYPASS_INTERFACE_FAILED \(error)");exit(1)}}
        NSApplication.shared.run()
    }
    @MainActor static func run() async throws {
        guard let index=CommandLine.arguments.firstIndex(of:"--output") else {throw ProxyError("缺少输出目录")}
        let output=URL(fileURLWithPath:CommandLine.arguments[index+1])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let model=AppModel()
        guard !model.loadingFailed,!model.state.autoConnect else {throw ProxyError("隔离模型无效")}
        var assertions=0
        func check(_ value:Bool,_ message:String) throws {assertions+=1;guard value else{throw ProxyError(message)}}
        let usesDailyRules=CommandLine.arguments.contains("--existing-rules")
        if usesDailyRules {
            // 只读取日常配置快照；事务仍写入 --test-directory 指定的隔离目录。
            let daily=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Qingzhou/state.json")
            let root=try JSONSerialization.jsonObject(with:Data(contentsOf:daily)) as! [String:Any]
            let profiles=root["profiles"] as! [[String:Any]],current=root["currentProfileID"] as! String
            let configuration=profiles.first{$0["id"] as? String==current}!["configuration"]!
            model.state=try JSONDecoder().decode(AppState.self,from:JSONSerialization.data(withJSONObject:configuration))
        } else {model.state.rules=(0..<629).map{RoutingRule(kind:.suffix,value:"rule\($0).example",action:.direct)}}
        let originalIDs=model.state.rules.map(\.id),conversion=model.state.rules.first{(try? NetworkBypassPolicy.convert($0)) != nil}!
        let items=try (0..<4000).map{try NetworkBypass(kind:.domain,value:"target\($0).example",note:"隔离目标 \($0)").normalized()}
        try model.state.setBypasses(items)
        // 使用真实保存事务，整个夹具保持断开，不连接辅助服务或修改系统网络。
        let revision=try model.bypassRevision(),convertedItem=try NetworkBypassPolicy.convert(conversion)
        let saved=await model.applyBypassDraft(items+[convertedItem],converted:[conversion.id],revision:revision)
        try check(saved,"断开时配置保存失败")
        try check(model.state.rules.map(\.id)==originalIDs.filter{$0 != conversion.id},"转换改变其他普通规则的顺序")
        try check(model.state.effectiveBypasses.count==4001,"转换未保存统一列表")
        let stale=await model.applyBypassDraft([],converted:[],revision:revision)
        try check(!stale && model.state.effectiveBypasses.count==4001,"过期草稿覆盖了新配置")
        model.bypassApplyFailure=nil
        let company=TrustedCorporateDNS(name:"隔离公司网络",serviceID:"fixture-wifi",servers:["10.57.82.100","10.57.82.101"],domains:["tongdun.me","tongdun.cn","tongdun.net"])
        let companyRevision=try model.bypassRevision()
        let companySaved=await model.applyBypassDraft(model.state.effectiveBypasses,converted:[],revision:companyRevision,corporateDNS:[company])
        try check(companySaved && model.state.trustedCorporateDNS==[company],"公司 DNS 随正式配置事务保存")
        let companyDraft=model.drafts.bypass(profile:model.currentProfileID,items:model.state.effectiveBypasses,revision:try model.bypassRevision(),corporateDNS:[company])
        companyDraft.corporateDNS=[]
        try check(companyDraft.dirty,"移除公司 DNS 形成待保存草稿")
        companyDraft.discard()
        try check(companyDraft.corporateDNS==[company] && !companyDraft.dirty,"撤销恢复公司 DNS 草稿")
        var capabilityState=AppState();capabilityState.trustedCorporateDNS=[company]
        var oldHelper=TunReply(ok:true,message:"隔离旧辅助服务")
        do {try CaptureController.validateCorporateDNSCapability(state:capabilityState,status:oldHelper);throw ProxyError("旧辅助服务错误地接受公司 DNS")} catch {
            try check(error.localizedDescription.contains("更新辅助服务"),"旧辅助服务必须明确拒绝新能力")
        }
        oldHelper.supportsTrustedCorporateDNS=true
        try CaptureController.validateCorporateDNSCapability(state:capabilityState,status:oldHelper)
        try check(true,"新辅助服务接受公司 DNS 能力")
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:740),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        let host=NSHostingView(rootView:AnyView(NetworkBypassView(model:model).padding(24)))
        window.contentView=host;window.appearance=NSAppearance(named:.aqua);window.orderFront(nil)
        try await Task.sleep(nanoseconds:700_000_000)
        func capture(_ name:String) throws {
            host.layoutSubtreeIfNeeded()
            let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            task.arguments=["-x","-o","-l",String(window.windowNumber),output.appendingPathComponent(name+".png").path]
            try task.run();task.waitUntilExit()
            guard task.terminationStatus==0 else {throw ProxyError("窗口截图失败")}
        }
        try capture("bypass-4001-light")
        func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap{descendants($0)}}
        guard let searchField=descendants(host).compactMap({$0 as? NSTextField}).first(where:{$0.placeholderString=="搜索目标或备注"}) else {throw ProxyError("未找到搜索输入")}
        searchField.stringValue="target2999.example"
        searchField.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:searchField))
        try await Task.sleep(nanoseconds:200_000_000)
        let filteredTables=descendants(host).compactMap{$0 as? NSTableView}
        try check(filteredTables.contains{$0.numberOfRows==1},"实际搜索未将列表过滤到目标行")
        try capture("bypass-search-one")
        searchField.stringValue=""
        searchField.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:searchField))
        try await Task.sleep(nanoseconds:200_000_000)
        func scrollViews(_ view:NSView)->[NSScrollView] {([view as? NSScrollView].compactMap{$0})+view.subviews.flatMap{scrollViews($0)}}
        guard let scroll=scrollViews(host).first(where:{($0.documentView?.bounds.height ?? 0)>$0.contentSize.height}) else{throw ProxyError("未找到大列表滚动区域")}
        let maximum=max(0,(scroll.documentView?.bounds.height ?? 0)-scroll.contentSize.height)
        scroll.contentView.scroll(to:NSPoint(x:0,y:maximum*0.7));scroll.reflectScrolledClipView(scroll.contentView)
        let position=scroll.contentView.bounds.origin.y
        let start=DispatchTime.now().uptimeNanoseconds
        for count in 0..<24 {model.uploadRate=Int64(count);model.downloadRate=Int64(count*2);try await Task.sleep(nanoseconds:16_666_667)}
        let telemetryElapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
        try check(abs(scroll.contentView.bounds.origin.y-position)<2,"流量刷新重置大列表滚动位置")
        window.appearance=NSAppearance(named:.darkAqua)
        try await Task.sleep(nanoseconds:200_000_000)
        try capture("bypass-4001-dark-scrolled")
        host.rootView=AnyView(NetworkBypassView(model:model,conversion:model.state.rules.first{(try? NetworkBypassPolicy.convert($0)) != nil}!).id("conversion").padding(24))
        try await Task.sleep(nanoseconds:650_000_000)
        try capture("bypass-conversion-draft")
        host.rootView=AnyView(SettingsView(model:model).padding(24))
        try await Task.sleep(nanoseconds:650_000_000)
        try capture("settings-bypass-summary")
        let result:[String:Any]=["assertions":assertions,"failures":0,"bypasses":4001,"originalRules":originalIDs.count,"rulesAfterConversion":model.state.rules.count,"usesDailyRules":usesDailyRules,"scrollOffsetPreserved":true,"telemetry24UpdatesMs":telemetryElapsed,"changedSystemNetwork":false,"connectedHelper":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("interface-checks.json"))
        window.orderOut(nil)
        print("RESULT bypass_interface_assertions=\(assertions) failures=0")
    }
}
