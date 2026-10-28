import Foundation
import QingzhouKit

extension AppModel {
    func cancelThroughput(invalidate:Bool=false) {
        throughputProbe?.cancel(); throughputTask?.cancel()
        if !invalidate,throughputProbe==nil {throughputRunning=false;throughputTask=nil;throughputError="测试已取消"}
        if invalidate {
            throughputGeneration=UUID(); throughputTask=nil; throughputProbe=nil
            throughputRunning=false; throughputResult=nil; throughputBytes=0; throughputError=nil
        }
    }
    func startThroughput(_ input:String) {
        guard !locked, connection == .connected, !throughputRunning else {return}
        guard state.mode != .direct else {
            throughputError="全部直连模式没有代理节点，未发起代理吞吐测试";return
        }
        guard let url=URL(string:input),url.scheme?.lowercased()=="https",url.host != nil,url.user==nil,url.password==nil else {
            throughputError="请输入不含用户名或密码的 HTTPS 下载地址"; return
        }
        cancelThroughput(invalidate:true)
        let generation=throughputGeneration,connectionID=epoch,profile=currentProfileID,mode=state.captureMode
        let port=mode.usesTunnel ? nil:state.listenPort, client=api
        throughputRunning=true
        throughputTask=Task { [weak self] in
            guard let self else{return}
            // 只读查询当前实际节点；不能把自动组或过期的界面选择当作实际出站。
            let proxies=try? await client?.proxies()
            let tag=proxies.flatMap(CoreAPIClient.actualTag)
            guard self.throughputGeneration==generation,!Task.isCancelled else{return}
            guard let tag,tag.hasPrefix("node-"),let node=UUID(uuidString:String(tag.dropFirst(5))) else {
                self.throughputError="无法确认实际代理节点，未发起下载测试"
                self.throughputRunning=false; self.throughputTask=nil; return
            }
            let version=await self.dependencies.throughputCoreVersion(self.core.binary.path)
            guard self.throughputGeneration==generation,!Task.isCancelled else {
                if self.throughputGeneration==generation {self.throughputRunning=false; self.throughputTask=nil}
                return
            }
            let context=ThroughputContext(profileID:profile,connectionID:connectionID,nodeID:node,captureMode:mode.rawValue,coreVersion:version)
            let probe=self.dependencies.makeThroughputProbe(context); self.throughputProbe=probe
            let result=await probe.run(URLRequest(url:url),proxyPort:port) { [weak self] count in
                Task { @MainActor in
                    guard let self,self.throughputGeneration==generation,self.throughputRunning else{return}
                    self.throughputBytes=max(self.throughputBytes,count)
                }
            }
            guard self.throughputGeneration==generation,self.epoch==connectionID,self.currentProfileID==profile else{return}
            self.throughputResult=result; self.throughputBytes=result.receivedBytes
            self.throughputRunning=false; self.throughputProbe=nil; self.throughputTask=nil
        }
    }
}
