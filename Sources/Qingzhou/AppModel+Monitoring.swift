import Foundation
import SwiftUI
import AppKit
import CoreImage
import QingzhouKit

extension AppModel {
    func startTelemetry(_ client:CoreAPIClient,profileID:UUID?) {
        stopTelemetry();history.begin();healthFailures=HealthFailureCounter();exitHealth=ExitHealthTracker();lastAutomaticRefresh = .distantPast;automaticRefreshRequested=true;rateHistory=[];trafficByNode=[:];trafficByTarget=[:];observedConnections=[:];fallbackStates=[:];failedHealthCycles=0;api=client;let token=UUID();epoch=token;monitor=RuntimeMonitorState();monitor.active=true
        healthTask=Task{[weak self] in while !Task.isCancelled {
            if let self,self.epoch==token,!self.locked,!self.healthChecking {self.scheduleHealthRefresh(delay:0)}
            try? await Task.sleep(nanoseconds:self?.usesAutomaticExit()==true ? 15_000_000_000:60_000_000_000)
        }}
        telemetryRefreshRequested=true;policyRefreshRequested=true
        // 辅助服务生命周期独立核验，不随连接列表和策略刷新降频。
        telemetryTask=Task{[weak self] in
            while !Task.isCancelled {
                guard let self,self.epoch==token else{return}
                if self.capture.activeMode?.usesTunnel == true || self.capture.helperRunning {
                    do {
                        let status=try await self.capture.helperStatus()
                        guard self.epoch==token,!Task.isCancelled else{return}
                        self.updateHelperNetworkStatus(status)
                        if !self.networkReconnecting && (!status.running || status.phase == "networkProtectionFailed") {self.recordEvent(.network,.failed,.helperFailed);self.log(status.message);self.helperFailureReason=status.message;self.coreFailed=true;self.drainPendingDisconnect();return}
                    }catch {
                        self.office.set("routes",title:"内网保护路由",status:.unverified,detail:"辅助服务状态暂不可读，未认定保护正常",now:self.dependencies.now())
                    }
                }
                try? await Task.sleep(nanoseconds:self.telemetryHidden ? 5_000_000_000:1_000_000_000)
            }
        }
        connectionListTask=Task{[weak self] in
            var last=Date.distantPast
            while !Task.isCancelled {
                guard let self,self.epoch==token else{return}
                let interval=OfficeTelemetryCadence.connections(hidden:self.telemetryHidden,pageVisible:self.connectionsPageVisible)
                if !self.networkReconnecting && (self.telemetryRefreshRequested || Date().timeIntervalSince(last)>=interval) {
                    self.telemetryRefreshRequested=false;last=Date()
                    do {
                        let snapshot=try await client.connections()
                        guard self.epoch==token,!Task.isCancelled else{return}
                        // 历史总量在暂停页面刷新时仍累计，不依赖速率展示。
                        if let profileID {self.history.receive(snapshot,profileID:profileID)}
                        if !self.monitorPaused {_=self.publishTelemetry(snapshot,info:self.proxyInfo)}
                    } catch {if self.epoch==token,!Task.isCancelled,self.monitor.connections != .unavailable {self.monitor.connections = .unavailable}}
                }
                await self.connectionRefreshSignal.wait(self.networkReconnecting ? interval:max(0.05,interval-Date().timeIntervalSince(last)))
            }
        }
        policyTask=Task{[weak self] in
            var last=Date.distantPast
            while !Task.isCancelled {
                guard let self,self.epoch==token else{return}
                if !self.networkReconnecting && (self.policyRefreshRequested || Date().timeIntervalSince(last)>=OfficeTelemetryCadence.policies(hidden:self.telemetryHidden)) {
                    self.policyRefreshRequested=false;last=Date()
                    do {
                        let info=try await client.proxies()
                        guard self.epoch==token,!Task.isCancelled else{return}
                        let changed=self.publishPolicyInfo(info)
                        if changed,self.connectivityResults != ConnectivityResult.pending {
                            if CoreAPIClient.actualTag(info) != self.verifiedSelectionTag {self.scheduleHealthRefresh()}
                            self.verifiedSelectionTag=nil
                        }
                    } catch { /* 策略查询失败不覆盖上次节点，也不伪造新出口。 */ }
                }
                await self.policyRefreshSignal.wait(self.networkReconnecting ? OfficeTelemetryCadence.policies(hidden:self.telemetryHidden):max(0.05,OfficeTelemetryCadence.policies(hidden:self.telemetryHidden)-Date().timeIntervalSince(last)))
            }
        }
        let trafficStream=dependencies.trafficStream
        trafficTask=Task { [weak self] in
            var last=Date.distantPast
            await TrafficMonitor.run(connect: { try await trafficStream(client) }, receive: { [weak self] rate in
                guard let self, !Task.isCancelled, self.epoch==token else { return }
                if self.monitor.traffic != .available { self.monitor.traffic = .available }
                if !self.monitorPaused {self.trafficDisplay.menu.receive(upload:rate.up,download:rate.down,now:Date())}
                let hidden=NSApplication.shared.isHidden || NSApplication.shared.windows.filter{$0.canBecomeMain}.allSatisfy{!$0.isVisible || $0.isMiniaturized}
                if !self.monitorPaused && Date().timeIntervalSince(last)>=OfficeTelemetryCadence.traffic(hidden:hidden) {
                    last=Date();self.trafficDisplay.receive(upload:rate.up,download:rate.down,now:last)
                }
            }, disconnected: { [weak self] in
                guard let self, !Task.isCancelled, self.epoch==token else { return }
                self.monitor.traffic = .unavailable
                self.trafficDisplay.menu.reset()
                self.uploadRate=0;self.downloadRate=0;last = .distantPast
            })
        }
    }
    // 返回实际出口是否变化；历史累计仍由每轮原始采样独立接收。
    @discardableResult func publishTelemetry(_ snapshot:ConnectionSnapshot,info:[String:ProxyInfo]) -> Bool {
        if connections != snapshot.connections {aggregate(snapshot.connections);connections=snapshot.connections}
        if uploadTotal != snapshot.uploadTotal {uploadTotal=snapshot.uploadTotal}
        if downloadTotal != snapshot.downloadTotal {downloadTotal=snapshot.downloadTotal}
        let changed=publishPolicyInfo(info)
        if monitor.connections != .available {monitor.connections = .available}
        return changed
    }
    func requestOfficeRefresh() {telemetryRefreshRequested=true;policyRefreshRequested=true;connectionRefreshSignal.wake();policyRefreshSignal.wake()}
    func setConnectionsPageVisible(_ visible:Bool) {connectionsPageVisible=visible;telemetryRefreshRequested=true;connectionRefreshSignal.wake()}
    var telemetryHidden:Bool {dependencies.officeHiddenOverride?() ?? (NSApplication.shared.isHidden || NSApplication.shared.windows.filter{$0.canBecomeMain}.allSatisfy{!$0.isVisible || $0.isMiniaturized})}
    @discardableResult func publishPolicyInfo(_ info:[String:ProxyInfo])->Bool {
        let changed=CoreAPIClient.actualTag(proxyInfo) != CoreAPIClient.actualTag(info)
        if changed {cancelThroughput(invalidate:true);invalidateOfficeResults();if CoreAPIClient.actualTag(info)==verifiedSelectionTag {publishOfficeConnectivity()};recordEvent(.node,.changed,.nodeSelected)}
        if proxyInfo != info {proxyInfo=info}
        return changed
    }
    func updateHelperNetworkStatus(_ status:TunReply) {
        if status.message == "网络变化，正在重新检查",helperStatus != status.message {invalidateOfficeResults(network:true)}
        networkWaiting=status.phase == "networkWaiting"
        publishOfficeHelper(status)
        if helperStatus != status.message {helperStatus=status.message}
        let summary=status.protectionSummary ?? []
        if protectionSummary != summary {protectionSummary=summary}
        if status.networkReconnecting {
            if !networkReconnecting {recordEvent(.network,.started,.reconnecting);cancelHealthRefresh();connectivityResults=ConnectivityResult.pending;reachability="网络恢复中，正在自动重连";connections=[];log("网络暂未就绪，保留连接意图并等待辅助服务自动重连")}
            if !networkReconnecting {networkReconnecting=true}
            if monitor.connections != .unavailable {monitor.connections = .unavailable}
            if monitor.traffic != .unavailable {monitor.traffic = .unavailable}
            if uploadRate != 0 {uploadRate=0}
            if downloadRate != 0 {downloadRate=0}
        } else if networkReconnecting {
            let healthy=status.running && status.phase != "networkProtectionFailed"
            recordEvent(.network,healthy ? .succeeded:.failed,healthy ? .reconnected:.helperFailed)
            networkReconnecting=false;failedHealthCycles=0;healthFailures=HealthFailureCounter()
            if healthy {automaticRefreshRequested=true;networkReleased=false;log("网络自动重连完成，正在复查连通性");scheduleHealthRefresh(delay:0)}
        }
    }

    func stopTelemetry() {trafficDisplay.menu.reset();verifiedSelectionTag=nil;history.finish();networkReconnecting=false;cancelHealthRefresh();epoch=UUID();connectivityEpoch=UUID();healthRefreshPending=false;healthTask?.cancel();healthTask=nil;telemetryTask?.cancel();connectionListTask?.cancel();policyTask?.cancel();trafficTask?.cancel();telemetryTask=nil;connectionListTask=nil;policyTask=nil;trafficTask=nil;if let old=api{Task{await old.shutdown()}};api=nil;connections=[];proxyInfo=[:];uploadRate=0;downloadRate=0;uploadTotal=0;downloadTotal=0;monitor=RuntimeMonitorState()}

    func closeConnection(_ id:String?) async {guard !locked,let api else{return};do{if let id{try await api.closeConnection(id)}else{try await api.closeAllConnections()}}catch{report(error)}}
    func aggregate(_ rows:[CoreConnection]) {
        for row in rows{let total=max(0,row.upload)+max(0,row.download);let delta=max(0,total-(observedConnections[row.id] ?? 0));observedConnections[row.id]=total
            let node=row.chains.first{ $0.hasPrefix("node-") } ?? "未提供";if trafficByNode.count<2000 || trafficByNode[node] != nil{trafficByNode[node,default:0]+=delta}
            let target=row.metadata.host?.isEmpty==false ? row.metadata.host! : row.metadata.destinationIP ?? "未提供";if trafficByTarget.count<2000 || trafficByTarget[target] != nil{trafficByTarget[target,default:0]+=delta}
        };let active=Set(rows.map(\.id));observedConnections=observedConnections.filter{active.contains($0.key)}
    }
}
