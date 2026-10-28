import SwiftUI
import QingzhouKit

struct ThroughputPanel:View {
    @ObservedObject var model:AppModel
    @State private var target=""
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                Text("完整下载测试").font(.title2.bold())
                Text("HTTPS 可达不代表持续传输正常。手动下载指定文件，只统计字节，不保存内容；最多 25 秒、32 MiB，以 10 秒为目标预算。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("HTTPS 文件地址（建议约 5 MB）",text:$target).textFieldStyle(.roundedBorder)
                    .disabled(model.throughputRunning)
                HStack {
                    Button("开始完整下载") {model.startThroughput(target)}
                        .disabled(model.locked || model.connection != .connected || model.throughputRunning || target.isEmpty)
                    Button("停止测试") {model.cancelThroughput()}.disabled(!model.throughputRunning)
                    Menu("导出脱敏报告") {
                        Button("文本") {saveDiagnosticData(try? model.throughputResult?.export(json:false),name:"轻舟完整下载.txt")}
                        Button("JSON") {saveDiagnosticData(try? model.throughputResult?.export(json:true),name:"轻舟完整下载.json")}
                    }.disabled(model.throughputResult==nil)
                }
                if model.throughputRunning {
                    ProgressView()
                    Text("已收到 "+ByteCountFormatter.string(fromByteCount:model.throughputBytes,countStyle:.file))
                }
                if let error=model.throughputError {Text(error).foregroundStyle(.orange)}
                if let result=model.throughputResult {
                    Text(result.outcome.label).font(.headline)
                    Text("HTTP：\(result.statusCode.map(String.init) ?? "未取得") · 首包：\(result.firstByteSeconds.map{String(format:"%.3f 秒",$0)} ?? "未取得")")
                    Text("已收：\(ByteCountFormatter.string(fromByteCount:result.receivedBytes,countStyle:.file)) · 总耗时：\(String(format:"%.3f",result.totalSeconds)) 秒")
                    Text("平均速度：\(ByteCountFormatter.string(fromByteCount:Int64(result.bytesPerSecond),countStyle:.file))/s")
                    Text(result.withinBudget ? "已在目标预算内完整结束" : "未达到目标预算；请结合文件大小和对照结果判断")
                    Text("策略节点：\(result.context.nodeID.uuidString)\n接管模式：\(result.context.captureMode) · 核心：\(result.context.coreVersion)\n连接代次：\(result.context.connectionID.uuidString)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("仅按当前规则测试，不自动切换节点或清理其他连接。地址只用于本轮请求，不写入诊断报告。策略节点由核心查询取得，目标仍可能按分流规则直连。").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }.onDisappear {model.cancelThroughput(invalidate:true)}
    }
}
