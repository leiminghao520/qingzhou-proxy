import SwiftUI
import QingzhouKit

struct ConnectionNoticeView:View {
    @ObservedObject var model:AppModel
    @State private var details=false
    var body:some View {
        if model.errorMessage != nil || model.activeRecovery != nil {
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Image(systemName:model.activeRecovery == nil ? "exclamationmark.circle":"arrow.triangle.2.circlepath")
                    Text(model.activeRecovery == nil ? (model.issueTitle ?? "操作未完成，请查看详情"):"已连接 · 使用备用方案").font(.callout.weight(.medium))
                    Spacer()
                    if model.activeRecovery != nil {
                        Button("重试原方案"){Task{await model.retryOriginal()}}.disabled(model.locked)
                        Button("采用当前方案"){model.adoptRecovery()}.disabled(model.locked)
                    } else if model.issueTitle == ConnectionFailureKind.permission.label {
                        Button("安装或更新辅助服务"){Task{await model.installHelper()}}.disabled(model.locked)
                    } else if model.recoveryPending {
                        Button("恢复网络"){Task{await model.recover()}}.disabled(model.recovering)
                    } else if model.connection != .connected {
                        Button("重试连接"){Task{await model.retryOriginal()}}.disabled(model.locked)
                    }
                    Button("查看详情"){details.toggle()}
                    if model.activeRecovery == nil {Button {model.errorMessage=nil} label:{Image(systemName:"xmark")}.buttonStyle(.plain).accessibilityLabel("关闭提示")}
                }
                if let impact=model.recoveryImpact {Text(impact).font(.callout)}
                if model.networkReleased {Text("汐航已停止接管，原有网络设置已恢复；代理目标可能暂时无法访问。").font(.callout)}
                if details {
                    Text(model.effectivePathSummary).font(.caption)
                    if let record=model.activeRecovery {
                        Text(record.kind.label+"；下次连接可检查原方案："+record.retryAfter.formatted(date:.omitted,time:.standard)).font(.caption)
                    }
                    if let detail=model.errorMessage {Text(detail).font(.caption).textSelection(.enabled)}
                }
            }
            .padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).padding(12)
        }
    }
}
