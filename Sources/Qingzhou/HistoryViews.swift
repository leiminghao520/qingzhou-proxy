import SwiftUI
import QingzhouKit

struct OptimizationSettings:View {
    @ObservedObject var model:AppModel
    @AppStorage("clipboardRecognitionEnabled") private var clipboard=false
    @State private var showingHistory=false
    var body:some View {
        Section("导入与流量历史") {
            Toggle("窗口激活时识别剪贴板",isOn:$clipboard)
            Text("默认关闭；开启后仅在主窗口激活时检查，确认后才导入。").font(.caption).foregroundStyle(.secondary)
            Button("查看最近30天流量…"){showingHistory=true}
        }.sheet(isPresented:$showingHistory){TrafficHistoryView(model:model,history:model.history)}
    }
}

struct TrafficHistoryView:View {
    @ObservedObject var model:AppModel
    @ObservedObject var history:TrafficHistoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text("最近30天流量").font(.title2.bold());Spacer();Button("完成"){dismiss()}}
            Text("总量来自核心累计增量；节点为轮询观测估算。暂停、重启或跨日间隔可能导致统计不完整。历史不包含目标域名和 IP，也不进入配置备份。")
                .font(.caption).foregroundStyle(.secondary)
            if let error=history.error {Text(error).foregroundStyle(Theme.dangerRed)}
            List(history.rows) {row in
                HStack {
                    Text(row.day,style:.date).frame(width:110,alignment:.leading)
                    VStack(alignment:.leading){Text(model.profiles.first{$0.id.uuidString==row.profileID}?.name ?? "历史配置")
                        Text(row.nodeID.map{model.label($0)+" · 观测估算"} ?? "核心总量").font(.caption).foregroundStyle(.secondary)}
                    Spacer();Text("↑ "+bytes(row.upload)).foregroundStyle(Theme.trafficUpload)
                    Text("↓ "+bytes(row.download)).foregroundStyle(Theme.trafficDownload)
                    if row.incomplete {Text("不完整/估算").font(.caption).foregroundStyle(Theme.amberAccent)}
                }
            }.overlay {if history.rows.isEmpty {ContentUnavailableView("暂无流量历史",systemImage:"chart.bar")}}
            HStack {Button("刷新"){history.reload()};Spacer();Button("清空历史",role:.destructive){confirmClear=true}}
        }.padding(24).frame(minWidth:720,minHeight:460).onAppear{history.reload()}
        .confirmationDialog("清空全部配置的流量历史？",isPresented:$confirmClear,titleVisibility:.visible){Button("清空历史",role:.destructive){history.clear()}}
    }
}
