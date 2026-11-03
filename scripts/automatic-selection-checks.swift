import Foundation
import QingzhouKit

final class AutomaticFixture:URLProtocol {
    static let lock=NSLock()
    static var ready=false
    static var failing=false
    static var warmed=0
    static let leaf="node-11111111-1111-4111-8111-111111111111"
    static func reset(failing:Bool=false){lock.lock();defer{lock.unlock()};ready=false;warmed=0;Self.failing=failing}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        Self.lock.lock()
        let delay=request.url!.path.hasSuffix("/delay")
        if delay{Self.warmed+=1;if !Self.failing{Self.ready=true}}
        let ready=Self.ready,fail=Self.failing
        Self.lock.unlock()
        let body:Data
        if delay {body=Data("{\"delay\":25}".utf8)}
        else {body=try! JSONSerialization.data(withJSONObject:["proxies":[
            "proxy":["type":"Selector","name":"proxy","now":"auto"],
            "auto":["type":"URLTest","name":"auto","now":ready ? Self.leaf:"","all":[Self.leaf]],
            Self.leaf:["type":"Hysteria2","name":Self.leaf],
            "GLOBAL":["type":"Fallback","name":"GLOBAL","now":"direct"]]])}
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:delay && fail ? 503:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}

@main struct AutomaticSelectionChecks {
    static var checks=0
    static func check(_ condition:Bool,_ message:String)throws {checks+=1;if !condition{throw ProxyError(message)}}
    static func info(_ object:[String:Any])throws->[String:ProxyInfo]{try JSONDecoder().decode([String:ProxyInfo].self,from:JSONSerialization.data(withJSONObject:object))}
    static func main() async throws {
        let node=AutomaticFixture.leaf
        let initial:[String:Any]=["proxy":["type":"Selector","name":"proxy","now":"auto"],"auto":["type":"URLTest","name":"auto","now":"","all":[node]],node:["type":"Hysteria2","name":node],"GLOBAL":["type":"Fallback","name":"GLOBAL","now":"direct"]]
        try check(CoreAPIClient.actualTag(try info(initial))==nil,"空选择不能成为节点标签")
        try check(CoreAPIClient.pendingAutomaticNodes(try info(initial))==[UUID(uuidString:String(node.dropFirst(5)))!],"只预热当前自动组成员")
        var missing=initial;missing.removeValue(forKey:node)
        try check(CoreAPIClient.pendingAutomaticNodes(try info(missing)).isEmpty,"缺少成员元数据时不猜测")
        var invalid=initial;invalid["auto"]=["type":"URLTest","name":"auto","now":"","all":["bad","node-invalid","node-22222222-2222-4222-8222-222222222222"]]
        try check(CoreAPIClient.pendingAutomaticNodes(try info(invalid)).isEmpty,"拒绝无效成员和未知成员")
        var absent=initial;absent["auto"]=["type":"URLTest","name":"auto","all":[node]]
        try check(CoreAPIClient.actualTag(try info(absent))==nil,"缺失 now 也是尚未选择")
        try check(CoreAPIClient.pendingAutomaticNodes(try info(absent)).count==1,"兼容缺失 now")
        var cycle=initial;cycle["auto"]=["type":"Selector","name":"auto","now":"proxy"]
        try check(CoreAPIClient.actualTag(try info(cycle))==nil && CoreAPIClient.pendingAutomaticNodes(try info(cycle)).isEmpty,"循环不能借用 GLOBAL")
        try check(CoreAPIClient.pendingAutomaticNodes(try info([:])).isEmpty,"空控制响应不猜测")
        var pinned=initial;pinned["proxy"]=["type":"Selector","name":"proxy","now":node]
        try check(CoreAPIClient.actualTag(try info(pinned))==node && CoreAPIClient.pendingAutomaticNodes(try info(pinned)).isEmpty,"手动选择不预热自动组")
        var noMembers=initial;noMembers["auto"]=["type":"URLTest","name":"auto","now":""]
        try check(CoreAPIClient.pendingAutomaticNodes(try info(noMembers)).isEmpty,"缺少候选不放行")
        AutomaticFixture.reset()
        let client=CoreAPIClient(context:CoreControlContext(port:18517,secret:"fixture"),protocolClasses:[AutomaticFixture.self])
        let result=await ConnectivityProbe.wakeNode(client:client,mode:.rule)
        try check(result.status == .passed && result.milliseconds==25,"冷启动自动组先预热再验证真实节点")
        try check(AutomaticFixture.warmed>0,"通过真实成员延迟接口建立选择")
        let before=AutomaticFixture.warmed
        let settled=try await client.preparedProxies()
        try check(CoreAPIClient.actualTag(settled)==node && AutomaticFixture.warmed==before,"已有实际选择时不重复预热")
        await client.shutdown()
        AutomaticFixture.reset(failing:true)
        let failed=CoreAPIClient(context:CoreControlContext(port:18517,secret:"fixture"),protocolClasses:[AutomaticFixture.self])
        let unavailable=await ConnectivityProbe.wakeNode(client:failed,mode:.rule)
        try check(unavailable.status == .failed,"成员均失败不能绕过启动保护")
        await failed.shutdown()
        AutomaticFixture.reset()
        let cancelled=CoreAPIClient(context:CoreControlContext(port:18517,secret:"fixture"),protocolClasses:[AutomaticFixture.self])
        let task=Task{try Task.checkCancellation();return try await cancelled.preparedProxies()};task.cancel()
        do{_=try await task.value;throw ProxyError("取消未传播")}catch is CancellationError{checks+=1}
        await cancelled.shutdown()
        print("AUTOMATIC_SELECTION_CHECKS_OK assertions=\(checks)")
        // 可选实核模式由外部隔离启动核心，验证核心返回的空 now，而不是替代真实响应。
        if CommandLine.arguments.count==3 {
            let live=CoreAPIClient(context:CoreControlContext(port:Int(CommandLine.arguments[1])!,secret:CommandLine.arguments[2]))
            let checked=await ConnectivityProbe.wakeNode(client:live,mode:.rule)
            print("REAL_CORE_NODE_PROBE status=\(checked.status.rawValue) category=\(checked.category)")
            await live.shutdown()
            try check(checked.status == .passed,"真实核心自动选择检测未通过")
        }
    }
}
