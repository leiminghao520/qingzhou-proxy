import SwiftUI
import QingzhouKit

// 首页只在缺少线路时显示下一步，完整说明由用户主动打开。
struct FirstConnectionGuide:View {
    @ObservedObject var model:AppModel
    var onImport:()->Void
    var body:some View {
        if model.state.nodes.isEmpty && model.state.mode != .direct {
            HStack(spacing:12) {
                Image(systemName:"link.badge.plus").foregroundStyle(Theme.accentBlue)
                VStack(alignment:.leading,spacing:4) {
                    Text("添加第一条线路").font(.headline)
                    Text("导入服务商的订阅链接或节点，然后选择线路并连接。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加订阅或节点",action:onImport).disabled(model.locked)
            }.padding(14).liquidContentSurface()
        }
    }
}

struct UsageGuideButton:View {
    @ObservedObject var model:AppModel
    var title="使用帮助"
    @State private var showing=false
    var body:some View {
        Button {showing=true} label:{Label(title,systemImage:"questionmark.circle")}
            .buttonStyle(.borderless)
            .sheet(isPresented:$showing) {UsageGuideView(model:model)}
    }
}

private struct UsageGuideView:View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                Text("帮助与使用指南").font(.title2.bold())
                Spacer()
                Button("完成"){dismiss()}.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    guide("开始使用",text:"添加订阅或节点，选择自动优选或手动线路，再点击连接。服务商提供订阅链接，轻舟负责导入与连接。")
                    guide("自动与手动线路",text:"自动选择会在后台切换可用节点，界面保留自动选择并显示实际出口。手动线路发生故障时只重连原节点，不擅自换线。")
                    guide("接管范围",text:model.effectiveState.captureMode.usesTunnel ? "当前使用 TUN 接管系统网络；企业 VPN 与指定出口继续按保护规则处理。":"当前使用系统代理；浏览器等遵循系统设置的应用会使用代理，终端及部分应用需要单独配置。")
                    guide("辅助服务授权",text:"首次连接需要 macOS 管理员授权，以安装网络辅助服务。日常连接复用授权；辅助服务或应用身份更新后，可能需要再次批准。密码由系统授权窗口接收。")
                    guide("确认连接与故障恢复",text:"连接后查看首页的链路状态和实际出口。已接管不等于网络可用；等待网络恢复时可停止自动重连，恢复未完成时可使用恢复网络入口。")
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(24).frame(width:540,height:520)
    }
    private func guide(_ title:String,text:String)->some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
}

struct SubscriptionHealthSummary:View {
    let sub:Subscription
    private var remaining:String {
        guard let usage=sub.usage,let total=usage.total,let upload=usage.upload,let download=usage.download else{return "未知（服务商未提供）"}
        let (used,overflow)=upload.addingReportingOverflow(download)
        let value=overflow || used>=total ? 0:total-used
        return ByteCountFormatter.string(fromByteCount:Int64(min(value,UInt64(Int64.max))),countStyle:.file)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            Text("剩余流量："+remaining)
            if let expiry=sub.usage?.expire,expiry.isFinite,expiry>0,expiry<253402300800 {
                Text("到期时间："+Date(timeIntervalSince1970:expiry).formatted(date:.abbreviated,time:.shortened))
            } else {Text("到期时间：未知（服务商未提供）")}
            Text("上次成功更新："+sub.updatedAt.formatted(date:.abbreviated,time:.shortened))
            if sub.pendingReview {Text("下次更新：等待预览确认")}
            else if !sub.autoUpdate {Text("自动更新已关闭")}
            else if let retry=sub.retryAfter {Text("下次重试："+retry.formatted(date:.abbreviated,time:.shortened))}
            else if sub.retryCount>0 {Text("自动重试已暂停，请检查订阅地址或授权")}
            else {Text("下次检查："+sub.updatedAt.addingTimeInterval(86400).formatted(date:.abbreviated,time:.shortened))}
        }.font(.caption).foregroundStyle(.secondary)
    }
}
