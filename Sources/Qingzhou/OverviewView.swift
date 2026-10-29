import SwiftUI
import QingzhouKit

struct OverviewView: View {
    @ObservedObject var model: AppModel
    var onLines: () -> Void = {}
    var onSubscriptions: () -> Void = {}

    var body: some View {
        ScrollView(showsIndicators:false) {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("概览").font(.title2.bold())
                        Text("连接、线路与流量，一目了然").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    UsageGuideButton(model:model)
                    XihangModeMenu(model:model)
                }
                FirstConnectionGuide(model:model,onImport:{model.office.importRequested=true})
                XihangConnectionHeader(model:model,onImport:{model.office.importRequested=true},onLines:onLines)
                XihangTrafficPanel(display:model.trafficDisplay,connected:model.connection == .connected,available:model.monitor.traffic == .available && !model.monitorPaused,total:model.downloadTotal + model.uploadTotal,connections:model.connections.count)
                ViewThatFits(in:.horizontal) {
                    HStack(alignment:.top,spacing:16) { XihangSubscriptionSummary(model:model,onOpen:onSubscriptions).frame(minWidth:260); quickActions.frame(minWidth:300) }
                    VStack(spacing:16) { XihangSubscriptionSummary(model:model,onOpen:onSubscriptions); quickActions }
                }
                if model.connection == .connected || !model.trafficByNode.isEmpty || !model.trafficByTarget.isEmpty {
                    HStack(alignment:.top,spacing:16) {
                        ranking("节点流量",items:model.trafficByNode.sorted{$0.value > $1.value}.prefix(5).map{(model.label($0.key),$0.value)})
                        ranking("目标流量",items:model.trafficByTarget.sorted{$0.value > $1.value}.prefix(5).map{($0.key,$0.value)})
                    }
                }
            }.padding(.bottom,8)
        }
    }
    private var quickActions: some View {
        VStack(alignment:.leading,spacing:16) {
            Label("常用操作",systemImage:"sparkles").font(.headline)
            LazyVGrid(columns:[GridItem(.flexible(),alignment:.leading),GridItem(.flexible(),alignment:.leading)],alignment:.leading,spacing:12) {
                Button { Task { await model.selectPolicy(.automatic) } } label: { Label("自动选择",systemImage:"bolt.badge.automatic") }.disabled(model.locked || model.state.nodes.isEmpty)
                Button { if model.measuring {model.cancelMeasurement()} else {model.measure()} } label: { Label(model.measuring ? "取消测速":"检测延迟",systemImage:"waveform.path.ecg") }.disabled(model.busy || model.state.nodes.isEmpty)
                Button { Task { await model.refreshAll() } } label: { Label("更新资源",systemImage:"arrow.clockwise") }.disabled(model.locked)
                Button { model.office.developerRequested=true } label: { Label("终端助手",systemImage:"terminal") }
            }.buttonStyle(.bordered).controlSize(.regular)
            if model.measuring {Text(model.measurementProgress).font(.caption).foregroundStyle(.secondary)}
        }.padding(20).frame(maxWidth:.infinity,minHeight:140,alignment:.topLeading).liquidContentSurface()
    }
    private func ranking(_ title:String,items:[(String,Int64)])->some View {
        VStack(alignment:.leading,spacing:14) {
            Text(title+" · Top 5").font(.headline)
            if items.isEmpty {Text("暂无观测数据").font(.caption).foregroundStyle(.secondary)}
            ForEach(Array(items.enumerated()),id:\.offset) { _, item in
                VStack(spacing:7) {
                    HStack {Text(item.0).lineLimit(1).help(item.0);Spacer();Text(bytes(item.1)).monospacedDigit().foregroundStyle(.secondary)}.font(.caption)
                    ProgressView(value:Double(item.1),total:Double(max(1,items.first?.1 ?? 1))).tint(Theme.accentBlue)
                }
            }
        }.padding(20).frame(maxWidth:.infinity,minHeight:150,alignment:.topLeading).liquidContentSurface()
    }
}
