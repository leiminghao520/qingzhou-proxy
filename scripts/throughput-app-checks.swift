import Foundation
import AppKit
import SwiftUI
import QingzhouKit

final class ThroughputControlProtocol:URLProtocol {
    static var node=UUID()
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let tag=PolicyReference.node(Self.node).tag
        let body=Data("{\"proxies\":{\"proxy\":{\"type\":\"Selector\",\"name\":\"proxy\",\"now\":\"\(tag)\"}}}".utf8)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct ThroughputAppChecks {
    @MainActor static var assertions=0
    @MainActor static func check(_ value:Bool,_ message:String)throws {
        assertions+=1
        guard value else{throw ProxyError(message)}
        print("PASS "+message)
    }
    @MainActor static func wait(_ condition:()->Bool) async throws {
        for _ in 0..<400 {
            if condition(){return}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        throw ProxyError("异步夹具未及时完成")
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {try await run();print("THROUGHPUT_APP_CHECKS_OK assertions=\(assertions)");exit(0)}
            catch {print("THROUGHPUT_APP_CHECKS_FAILED \(error)");exit(1)}
        }
        NSApplication.shared.run()
    }
    @MainActor static func run() async throws {
        var deps=AppDependencies()
        var versionEntered=false,blockVersion=false
        deps.throughputCoreVersion={_ in
            versionEntered=true
            if blockVersion {try? await Task.sleep(nanoseconds:100_000_000)}
            return "fixture-core"
        }
        deps.makeThroughputProbe={ThroughputProbe(context:$0,timeout:1,protocolClasses:[ThroughputFixtureProtocol.self])}
        let model=AppModel(dependencies:deps)
        model.startThroughput("https://fixture.invalid/success")
        try check(!model.throughputRunning,"断开时不自动连接或启动下载")
        model.connection = .connected
        model.state.mode = .direct
        model.startThroughput("https://fixture.invalid/success")
        try check(!model.throughputRunning && model.throughputError != nil,"全部直连时不误标代理节点")
        model.state.mode = .rule
        model.startThroughput("http://fixture.invalid/")
        try check(model.throughputError != nil,"拒绝非 HTTPS 地址")
        model.startThroughput("https://fixture.invalid/success")
        try await wait{!model.throughputRunning}
        try check(model.throughputError != nil && model.throughputResult==nil,"实际节点未知时不发起下载")
        let client=CoreAPIClient(context:CoreControlContext(port:32199,secret:"fixture-control"),protocolClasses:[ThroughputControlProtocol.self]);model.api=client
        model.startThroughput("https://fixture.invalid/slow?token=private-value")
        try await wait{!model.throughputRunning}
        try check(model.throughputResult?.outcome == .completed,"完整下载发布结果")
        try check(model.throughputResult?.context.nodeID==ThroughputControlProtocol.node && model.throughputResult?.context.coreVersion=="fixture-core" && model.throughputResult?.context.connectionID==model.epoch,"冻结实际节点核心与连接代次")
        try check(model.throughputBytes==8 && model.connection == .connected,"计量更新不改变代理连接")
        let view=NSHostingView(rootView:ThroughputPanel(model:model))
        view.frame=NSRect(x:0,y:0,width:900,height:700);view.layoutSubtreeIfNeeded()
        try check(view.fittingSize.height>0,"诊断面板可以布局")
        model.startThroughput("https://fixture.invalid/hang")
        try await wait{model.throughputProbe != nil}
        model.cancelThroughput()
        try await wait{!model.throughputRunning}
        try check(model.throughputResult?.outcome == .cancelled && model.connection == .connected,"手动取消只停止本轮测试")
        model.startThroughput("https://fixture.invalid/hang")
        try await wait{model.throughputProbe != nil}
        model.epoch=UUID()
        try await Task.sleep(nanoseconds:30_000_000)
        try check(!model.throughputRunning && model.throughputResult==nil,"连接代次改变清理迟到结果")
        model.startThroughput("https://fixture.invalid/hang")
        try await wait{model.throughputProbe != nil}
        let info=try JSONDecoder().decode([String:ProxyInfo].self,from:Data("{\"proxy\":{\"type\":\"Selector\",\"name\":\"proxy\",\"now\":\"node-\(UUID().uuidString.lowercased())\"}}".utf8))
        model.publishPolicyInfo(info)
        try check(!model.throughputRunning && model.throughputResult==nil,"自动策略实际节点变化取消测试")
        model.startThroughput("https://fixture.invalid/hang")
        try await wait{model.throughputProbe != nil}
        model.cancelThroughput(invalidate:true)
        try check(!model.throughputRunning && model.throughputTask==nil && model.throughputResult==nil,"退出页面清除会话")
        model.startThroughput("https://fixture.invalid/hang")
        model.cancelThroughput()
        try await Task.sleep(nanoseconds:30_000_000)
        try check(!model.throughputRunning,"准备阶段取消不遗留运行状态")
        blockVersion=true;versionEntered=false
        model.startThroughput("https://fixture.invalid/hang")
        try await wait{versionEntered}
        model.cancelThroughput()
        try await wait{!model.throughputRunning}
        try await Task.sleep(nanoseconds:20_000_000)
        try check(model.throughputResult==nil,"读取核心版本期间取消不启动网络请求")
        versionEntered=false
        model.startThroughput("https://fixture.invalid/hang")
        try await wait{versionEntered}
        model.epoch=UUID()
        try await Task.sleep(nanoseconds:20_000_000)
        try check(model.throughputResult==nil && !model.throughputRunning,"版本读取迟到后不跨连接代次发布")
        blockVersion=false
        model.state.captureMode = .compatible
        model.startThroughput("https://fixture.invalid/success")
        try await wait{!model.throughputRunning}
        try check(model.throughputResult?.context.captureMode=="compatible","TUN 测试冻结接管模式")
        await client.shutdown();model.api=nil;model.connection = .disconnected
    }
}
