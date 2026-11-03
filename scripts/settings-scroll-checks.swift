import SwiftUI
import AppKit
import QingzhouKit

@MainActor enum SettingsBenchmarkProbe {
    static var bodies=0
    static func record(){bodies+=1}
}

// 对照版本使用相同固定资产与原线性匹配语义，避免读取日常订阅和凭据。
enum BaselineDomesticRouting {
    static let domains=DomesticRouting.domainCondition as! [String:[String]]
    static var version:String {DomesticRouting.version}
    static func isDomestic(_ host:String)->Bool {
        let value=host.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
        return (domains["domain"] ?? []).contains(value) || (domains["domain_suffix"] ?? []).contains{value==$0 || value.hasSuffix("."+$0)} || (domains["domain_regex"] ?? []).contains{value.range(of:$0,options:.regularExpression) != nil}
    }
    static func conflictingRules(_ state:AppState)->[RoutingRule] {
        state.rules.filter{rule in
            let target=rule.target ?? (rule.action == .direct ? .direct:rule.action == .reject ? .reject:.selected)
            return target != .direct && [.domain,.suffix].contains(rule.kind) && isDomestic(rule.value)
        }
    }
}

@main struct SettingsScrollChecks {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        Task{@MainActor in do{try await run();exit(0)}catch{print("SETTINGS_SCROLL_CHECKS_FAILED \(error)");exit(1)}}
        app.run()
    }
    @MainActor static func run() async throws {
        let args=CommandLine.arguments
        guard let outputIndex=args.firstIndex(of:"--result"),let variantIndex=args.firstIndex(of:"--variant") else{throw ProxyError("缺少检查参数")}
        let variant=args[variantIndex+1],output=URL(fileURLWithPath:args[outputIndex+1])
        let model=AppModel();guard !model.loadingFailed else{throw ProxyError("隔离设置模型初始化失败")}
        model.state.captureMode = .compatible
        model.state.rules=(0..<600).map{RoutingRule(kind:.suffix,value:"node\($0).example",action:.proxy)}
        model.state.rules.append(RoutingRule(kind:.suffix,value:"qq.com",action:.reject))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:720),styleMask:[.titled],backing:.buffered,defer:false)
        let host=NSHostingView(rootView:SettingsView(model:model).padding(24))
        window.contentView=host;window.orderFront(nil)
        try await Task.sleep(nanoseconds:500_000_000);host.layoutSubtreeIfNeeded()
        // 先完成 onAppear 草稿初始化与首次布局，不把启动重绘算成实时数据导致的重绘。
        for index in 0..<5 {
            model.uploadRate=Int64(index)
            try await Task.sleep(nanoseconds:50_000_000)
        }
        host.layoutSubtreeIfNeeded()
        func scrollViews(_ view:NSView)->[NSScrollView] {([view as? NSScrollView].compactMap{$0})+view.subviews.flatMap{scrollViews($0)}}
        guard let scroll=scrollViews(host).first(where:{$0.documentView != nil}) else{throw ProxyError("未找到原生设置滚动容器")}
        let maximum=max(0,(scroll.documentView?.bounds.height ?? 0)-scroll.contentSize.height)
        guard maximum>0 else{throw ProxyError("设置内容没有形成可验证的滚动区域")}
        scroll.contentView.scroll(to:NSPoint(x:0,y:maximum*0.4));scroll.reflectScrolledClipView(scroll.contentView)
        let position=scroll.contentView.bounds.origin.y
        let startBodies=SettingsBenchmarkProbe.bodies
        var intervals:[Double]=[]
        for index in 0..<24 {
            let start=DispatchTime.now().uptimeNanoseconds
            model.uploadRate=Int64(index);model.downloadRate=Int64(index*2)
            model.rateHistory.append(RateSample(upload:Int64(index),download:0))
            try await Task.sleep(nanoseconds:16_666_667)
            intervals.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
        }
        let telemetryBodies=SettingsBenchmarkProbe.bodies-startBodies
        let offsetPreserved=abs(scroll.contentView.bounds.origin.y-position)<2
        model.helperStatus="隔离服务状态更新"
        try await Task.sleep(nanoseconds:100_000_000)
        let helperUpdated=SettingsBenchmarkProbe.bodies>startBodies+telemetryBodies
        let configBodies=SettingsBenchmarkProbe.bodies
        model.state.autoConnect.toggle()
        try await Task.sleep(nanoseconds:100_000_000)
        let configUpdated=SettingsBenchmarkProbe.bodies>configBodies
        let sorted=intervals.sorted()
        let result:[String:Any]=["variant":variant,"rules":model.state.rules.count,"telemetryUpdates":24,"settingsBodiesDuringTelemetry":telemetryBodies,"mainLoopIntervalP50Ms":sorted[sorted.count/2],"mainLoopIntervalP95Ms":sorted[Int(Double(sorted.count)*0.95)],"scrollOffsetPreserved":offsetPreserved,"helperStatusUpdateRendered":helperUpdated,"configurationUpdateRendered":configUpdated,"usesDailyConfiguration":false,"changedSystemNetwork":false]
        try SecureFile.write(JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),to:output)
        guard variant=="baseline" || (telemetryBodies==0 && offsetPreserved && helperUpdated && configUpdated) else{throw ProxyError("设置刷新隔离或滚动位置检查未通过")}
        window.orderOut(nil)
        print("SETTINGS_SCROLL_CHECKS_OK \(variant) telemetryBodies=\(telemetryBodies)")
    }
}
