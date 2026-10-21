import Foundation
import SwiftUI
import AppKit
import CoreImage
import QingzhouKit

extension AppModel {
    func startTelemetry(_ client:CoreAPIClient,profileID:UUID?) {
        stopTelemetry();history.begin();healthFailures=HealthFailureCounter();rateHistory=[];trafficByNode=[:];trafficByTarget=[:];observedConnections=[:];fallbackStates=[:];failedHealthCycles=0;api=client;let token=UUID();epoch=token;monitor=RuntimeMonitorState();monitor.active=true
        healthTask=Task{[weak self] in while !Task.isCancelled {
            if let self,self.epoch==token,!self.locked,!self.healthChecking {self.scheduleHealthRefresh(delay:0)}
            try? await Task.sleep(nanoseconds:60_000_000_000)
        }}
        telemetryTask=Task{[weak self] in
            while !Task.isCancelled {
                guard let self,self.epoch==token else{return}
                let hidden=NSApplication.shared.isHidden || NSApplication.shared.windows.filter{$0.canBecomeMain}.allSatisfy{!$0.isVisible || $0.isMiniaturized}
                do {
                    // 生命周期检查不受“暂停监控”影响，待重连不是核心崩溃。
                    if self.capture.activeMode?.usesTunnel == true {
                        let status=try await self.capture.helperStatus()
                        guard self.epoch==token,!Task.isCancelled else{return}
                        self.updateHelperNetworkStatus(status)
                        if self.networkReconnecting {try? await Task.sleep(nanoseconds:1_000_000_000);continue}
                        if !status.running || status.phase == "networkProtectionFailed" {self.log(status.message);self.helperFailureReason=status.message;self.coreFailed=true;self.drainPendingDisconnect();return}
                    }
                    if !self.monitorPaused {
                        let snapshot=try await client.connections();let info=try await client.proxies()
                        guard self.epoch==token,!Task.isCancelled else{return}
                        if let profileID {self.history.receive(snapshot,profileID:profileID)}
                        self.aggregate(snapshot.connections);self.connections=snapshot.connections;self.uploadTotal=snapshot.uploadTotal;self.downloadTotal=snapshot.downloadTotal
                        let changed=CoreAPIClient.actualTag(self.proxyInfo) != CoreAPIClient.actualTag(info)
                        self.proxyInfo=info;self.monitor.connections = .available
                        if changed,self.connectivityResults != ConnectivityResult.pending {Task{await self.checkConnectivity()}}
                    }
                } catch {if self.epoch==token,!Task.isCancelled{self.monitor.connections = .unavailable}}
                try? await Task.sleep(nanoseconds:hidden ? 5_000_000_000 : 1_000_000_000)
            }
        }
        let trafficStream=dependencies.trafficStream
        trafficTask=Task { [weak self] in
            var last=Date.distantPast
            await TrafficMonitor.run(connect: { try await trafficStream(client) }, receive: { [weak self] rate in
                guard let self, !Task.isCancelled, self.epoch==token else { return }
                if self.monitor.traffic != .available { self.monitor.traffic = .available }
                let hidden=NSApplication.shared.isHidden || NSApplication.shared.windows.filter{$0.canBecomeMain}.allSatisfy{!$0.isVisible || $0.isMiniaturized}
                if !self.monitorPaused && Date().timeIntervalSince(last)>=(hidden ? 5 : 0.8) {
                    self.uploadRate=max(0,rate.up);self.downloadRate=max(0,rate.down);last=Date()
                    self.rateHistory.append(RateSample(upload:self.uploadRate,download:self.downloadRate))
                    self.rateHistory.removeAll{Date().timeIntervalSince($0.time)>1800}
                }
            }, disconnected: { [weak self] in
                guard let self, !Task.isCancelled, self.epoch==token else { return }
                self.monitor.traffic = .unavailable
                self.uploadRate=0;self.downloadRate=0;last = .distantPast
            })
        }
    }
    func updateHelperNetworkStatus(_ status:TunReply) {
        helperStatus=status.message;protectionSummary=status.protectionSummary ?? []
        if status.networkReconnecting {
            if !networkReconnecting {cancelHealthRefresh();connectivityResults=ConnectivityResult.pending;reachability="网络恢复中，正在自动重连";connections=[];log("网络暂未就绪，保留连接意图并等待辅助服务自动重连")}
            networkReconnecting=true;monitor.connections = .unavailable;monitor.traffic = .unavailable;uploadRate=0;downloadRate=0
        } else if networkReconnecting {
            networkReconnecting=false;failedHealthCycles=0;healthFailures=HealthFailureCounter()
            if status.running {log("网络自动重连完成，正在复查连通性");scheduleHealthRefresh(delay:0)}
        }
    }

    func stopTelemetry() {history.finish();networkReconnecting=false;cancelHealthRefresh();epoch=UUID();connectivityEpoch=UUID();healthRefreshPending=false;healthTask?.cancel();healthTask=nil;telemetryTask?.cancel();trafficTask?.cancel();telemetryTask=nil;trafficTask=nil;if let old=api{Task{await old.shutdown()}};api=nil;connections=[];proxyInfo=[:];uploadRate=0;downloadRate=0;uploadTotal=0;downloadTotal=0;monitor=RuntimeMonitorState()}

    func closeConnection(_ id:String?) async {guard !locked,let api else{return};do{if let id{try await api.closeConnection(id)}else{try await api.closeAllConnections()}}catch{report(error)}}
    func aggregate(_ rows:[CoreConnection]) {
        for row in rows{let total=max(0,row.upload)+max(0,row.download);let delta=max(0,total-(observedConnections[row.id] ?? 0));observedConnections[row.id]=total
            let node=row.chains.first{ $0.hasPrefix("node-") } ?? "未提供";if trafficByNode.count<2000 || trafficByNode[node] != nil{trafficByNode[node,default:0]+=delta}
            let target=row.metadata.host?.isEmpty==false ? row.metadata.host! : row.metadata.destinationIP ?? "未提供";if trafficByTarget.count<2000 || trafficByTarget[target] != nil{trafficByTarget[target,default:0]+=delta}
        };let active=Set(rows.map(\.id));observedConnections=observedConnections.filter{active.contains($0.key)}
    }
}
