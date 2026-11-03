import Foundation
import QingzhouKit

final class ReadinessProtocol:URLProtocol {
    static let lock=NSLock()
    static var calls:[Int:Int]=[:]
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let port=request.url!.port!
        Self.lock.lock();Self.calls[port,default:0]+=1;let count=Self.calls[port]!;Self.lock.unlock()
        if port==18421,count<3 {client?.urlProtocol(self,didFailWithError:URLError(.cannotConnectToHost));return}
        let status=port==18422 ? 401:200
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data((port==18423 ? "invalid":"{\"proxies\":{}}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct CoreReadinessChecks {
    static var checks=0
    static func check(_ value:Bool,_ message:String)throws {guard value else{throw ProxyError(message)};checks+=1;print("PASS "+message)}
    static func main() async {
        do {
            var clock=0.0,calls=0,budgets:[Double]=[]
            try await CoreAPIReadiness.wait(timeout:1,interval:0.1,uptime:{clock},sleep:{clock += $0}) {budget in
                calls+=1;budgets.append(budget)
                if calls<4 {throw CoreAPIError("连接",transportCode:URLError.cannotConnectToHost.rawValue)}
            }
            try check(calls==4 && budgets.allSatisfy{$0>0 && $0<=1},"控制接口延迟就绪时重试读取而不重启核心")
            calls=0;clock=0
            do {
                try await CoreAPIReadiness.wait(timeout:0.25,interval:0.1,uptime:{clock},sleep:{clock += $0}) {_ in calls+=1;throw CoreAPIError("连接",transportCode:URLError.cannotConnectToHost.rawValue)}
                throw ProxyError("未执行超时")
            }catch let error as CoreAPIError {try check(error.category=="控制接口就绪超时" && clock==0.25 && calls==3,"持续拒绝连接按总预算退出，不无限重试")}
            for category in ["鉴权","控制接口响应格式","控制接口"] {
                calls=0
                do {try await CoreAPIReadiness.wait {_ in calls+=1;throw CoreAPIError(category)};throw ProxyError("未保留原错误")}
                catch let error as CoreAPIError {try check(calls==1 && error.category==category,"\(category)失败立即回滚")}
            }
            let cancel=Task {try await CoreAPIReadiness.wait {_ in throw CoreAPIError("连接",transportCode:URLError.cannotConnectToHost.rawValue)}}
            cancel.cancel()
            do {try await cancel.value;throw ProxyError("取消未生效")}catch is CancellationError {try check(true,"启动等待支持立即取消")}
            clock=0
            do {try await CoreAPIReadiness.wait(timeout:0.1,uptime:{clock}) {_ in clock=1};throw ProxyError("超预算成功未拒绝")}
            catch let error as CoreAPIError {try check(error.category=="控制接口就绪超时","超时后迟到成功不进入激活阶段")}
            let valid=CoreAPIClient(context:CoreControlContext(port:18421,secret:"fixture"),protocolClasses:[ReadinessProtocol.self])
            try await valid.waitUntilReady()
            _=try await valid.proxies()
            try check(ReadinessProtocol.calls[18421]==4,"真实客户端重试两次后复用控制会话")
            for (port,category) in [(18422,"鉴权"),(18423,"控制接口响应格式")] {
                let client=CoreAPIClient(context:CoreControlContext(port:port,secret:"fixture"),protocolClasses:[ReadinessProtocol.self])
                do {try await client.waitUntilReady();throw ProxyError("错误端点未拒绝")}
                catch let error as CoreAPIError {try check(error.category==category && ReadinessProtocol.calls[port]==1,"客户端保留\(category)分类且不重试")}
                await client.shutdown()
            }
            await valid.shutdown()
            try check(!CoreAPIError("连接").retryableDuringStartup,"没有结构化传输错误码时不根据提示文字重试")
            print("CORE_API_READINESS_CHECKS_OK assertions=\(checks)")
        }catch{print("CORE_API_READINESS_CHECKS_FAILED \(error)");exit(1)}
    }
}
