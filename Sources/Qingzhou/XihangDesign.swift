import SwiftUI
import AppKit
import Pow
import QingzhouKit

// 品牌图形只负责呈现，不持有连接或网络状态。
struct XihangSail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        p.move(to: point(0.10, 0.72))
        p.addCurve(to: point(0.78, 0.05), control1: point(0.33, 0.50), control2: point(0.46, 0.28))
        p.addCurve(to: point(0.88, 0.66), control1: point(0.71, 0.32), control2: point(0.73, 0.50))
        p.addCurve(to: point(0.10, 0.72), control1: point(0.58, 0.58), control2: point(0.34, 0.63))
        p.closeSubpath()
        return p
    }
}
struct XihangMark: View {
    var monochrome = false
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                XihangSail().fill(monochrome ? AnyShapeStyle(Color.primary) : AnyShapeStyle(LinearGradient(colors: [Color(red:0.70,green:1,blue:0.94), Theme.accentBlue, Theme.purpleAccent], startPoint:.topLeading,endPoint:.bottomTrailing)))
                Path { p in
                    p.move(to: CGPoint(x:proxy.size.width*0.08,y:proxy.size.height*0.87))
                    p.addCurve(to:CGPoint(x:proxy.size.width*0.92,y:proxy.size.height*0.80),control1:CGPoint(x:proxy.size.width*0.34,y:proxy.size.height*0.71),control2:CGPoint(x:proxy.size.width*0.60,y:proxy.size.height*1.02))
                }.stroke(monochrome ? Color.primary : Theme.cyanAccent,style:StrokeStyle(lineWidth:max(1.5,proxy.size.width*0.045),lineCap:.round))
            }
        }.accessibilityHidden(true)
    }
}
struct XihangHover: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius:Theme.cardCornerRadius).strokeBorder(Theme.accentBlue.opacity(hovered ? 0.28 : 0),lineWidth:1).allowsHitTesting(false))
            .onHover { value in withAnimation(reduceMotion ? nil : .easeOut(duration:0.15)) { hovered=value } }
    }
}
struct XihangStatusPill: View {
    let title: String
    var color: Color = Theme.accentBlue
    var body: some View {
        Text(title).font(.system(size:10,weight:.semibold)).lineLimit(1)
            .padding(.horizontal,8).padding(.vertical,4).foregroundStyle(color)
            .background(color.opacity(0.12),in:Capsule())
    }
}
struct XihangConnectionHeader: View {
    @ObservedObject var model: AppModel
    var onImport: () -> Void
    var onLines: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var needsImport: Bool { model.state.nodes.isEmpty && model.state.mode != .direct }
    private var needsSelection: Bool { model.state.mode != .direct && (model.state.activePolicy.map { !PolicyValidator.exists($0,in:model.state) } ?? true) }
    private var statusColor: Color { model.connectionAvailable ? Theme.connectedGreen : model.hasConnectionActivity || model.recoveryPending ? Theme.amberAccent : Theme.accentBlue }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.top,spacing:16) { hero.frame(minWidth:300,maxWidth:.infinity); route.frame(width:210) }
                VStack(spacing:12) { hero; route }
            }
            if model.recoveryPending {
                HStack {
                    Label("网络设置尚未恢复",systemImage:"exclamationmark.triangle.fill").foregroundStyle(Theme.amberAccent)
                    Spacer()
                    Button("恢复网络") { Task { await model.recover() } }.disabled(model.loadingFailed || model.recovering)
                }.font(.callout).padding(12).liquidContentSurface()
            }
            if model.connection == .connecting, let stage=model.startupStage {
                ConnectionProgressView(stage:stage,startedAt:model.startupStartedAt)
            }
            if model.wakeRecoveryStatus.phase != .idle && model.wakeRecoveryStatus.phase != .cancelled {
                Text(model.wakeRecoveryStatus.label).font(.caption).foregroundStyle(model.wakeRecoveryStatus.phase == .manual ? Theme.amberAccent : Color.secondary)
            }
        }
    }
    private var hero: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:7) {
                    Text("让连接，自然流动").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                    Text(model.connectionTitle).font(.system(size:25,weight:.bold,design:.rounded)).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("connectionStatus")
                    if model.connection == .connected {
                        Label(model.linkStatusLabel,systemImage:model.connectionAvailable ? "checkmark.circle.fill":"circle.dotted").font(.caption).foregroundStyle(statusColor)
                    } else {
                        Text(model.connection == .error ? "连接未完成，可查看诊断或重新尝试" : model.connection == .connecting ? "正在建立连接，请稍候" : model.connection == .disconnecting ? "正在释放网络接管" : model.networkWaiting ? "等待网络恢复" : "选择一条线路，即可开始").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength:8)
                XihangMark().frame(width:64,height:68).rotationEffect(.degrees(model.connection == .connected && !reduceMotion ? -5 : 0))
                    .changeEffect(.shine(duration:0.3),value:model.connection == .connected,isEnabled:!reduceMotion && model.connection == .connected)
            }
            HStack {
                if needsImport && !model.hasConnectionActivity {
                    Button("添加订阅或节点",action:onImport).buttonStyle(.borderedProminent).disabled(model.locked)
                } else {
                    Button {
                        Task { if model.hasConnectionActivity { await model.disconnect() } else { await model.connect() } }
                    } label: {
                        Label(model.networkWaiting ? "停止自动重连" : model.connection == .connected ? "断开连接" : model.connection == .connecting ? "取消连接" : model.connection == .disconnecting ? "正在断开" : "连接",systemImage:model.hasConnectionActivity ? "stop.fill":"power")
                            .font(.system(size:13,weight:.semibold)).padding(.horizontal,10).padding(.vertical,5)
                    }.buttonStyle(.borderedProminent)
                        .tint(model.hasConnectionActivity ? Color.secondary : Theme.accentBlue)
                        .disabled(model.stopDisabled || (!model.hasConnectionActivity && (needsSelection || model.recoveryPending)))
                        .accessibilityIdentifier("primaryConnectionButton")
                }
                Spacer(minLength:6)
                if let since=model.connectedSince,model.connection == .connected {
                    Text(since,style:.timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else { XihangStatusPill(title:model.effectiveState.captureMode.label,color:statusColor) }
            }
        }
        .padding(22).frame(maxWidth:.infinity,minHeight:192,alignment:.topLeading)
        .background {
            RoundedRectangle(cornerRadius:24).fill(Theme.cardBackground)
            if !reduceTransparency && contrast != .increased {
                RoundedRectangle(cornerRadius:24).fill(LinearGradient(colors:[Theme.brand.opacity(0.16),Theme.purpleAccent.opacity(0.07),.clear],startPoint:.topLeading,endPoint:.bottomTrailing))
            }
        }
        .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(Theme.accentBlue.opacity(contrast == .increased ? 0.7 : 0.2),lineWidth:1))
        .animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:model.connection)
    }
    private var route: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Label("当前线路",systemImage:"point.topleft.down.to.point.bottomright.curvepath").font(.caption).foregroundStyle(.secondary);Spacer() }
            Text(model.state.mode == .direct ? "直接连接" : model.selectedName).font(.system(size:16,weight:.semibold)).lineLimit(2).help(model.selectedName)
            if model.connection == .connected && model.state.mode != .direct {
                Text("实际出口："+model.actualName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(model.actualName)
            } else if let node=model.selected {
                VStack(alignment:.leading,spacing:8) {
                    ProtocolBadge(kind:node.kind)
                    LatencyBadge(delayText:latency(node,model))
                }
            } else { Text("自动调度与规则分流").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength:0)
            HStack {
                Text("\(model.state.nodes.count) 条线路").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("切换",action:onLines).buttonStyle(.borderless).disabled(model.locked)
            }
        }.padding(20).frame(maxWidth:.infinity,minHeight:192,maxHeight:192,alignment:.topLeading).liquidContentSurface().modifier(XihangHover())
    }
}
struct XihangTrafficPanel: View {
    @ObservedObject var display: OfficeTrafficDisplay
    let connected: Bool
    let available: Bool
    let total: Int64
    let connections: Int
    var expanded = true
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            ViewThatFits(in:.horizontal) {
                HStack(spacing:24) { rates; Spacer(minLength:0); auxiliary }
                VStack(alignment:.leading,spacing:16) { rates; auxiliary }
            }
            if expanded && connected && available { Divider().opacity(0.5); RateChart(samples:display.sample.history,embedded:true).equatable() }
            else if expanded {
                HStack(spacing:10) {
                    XihangMark(monochrome:true).frame(width:24,height:26).foregroundStyle(.secondary)
                    Text(connected ? "实时速率暂时无法获取，请查看诊断" : "连接后，这里会显示实时流量轨迹").font(.caption).foregroundStyle(.secondary)
                }.padding(.top,4)
            }
        }.padding(20).liquidContentSurface()
    }
    private var rates: some View {
        HStack(spacing:28) {
            metric("下载",value:connected && available ? formatRate(display.sample.download) : "—",icon:"arrow.down",color:Theme.trafficDownload)
            metric("上传",value:connected && available ? formatRate(display.sample.upload) : "—",icon:"arrow.up",color:Theme.trafficUpload)
        }
    }
    private var auxiliary: some View {
        HStack(spacing:22) {
            metric("会话流量",value:bytes(total),icon:"chart.pie",color:.secondary)
            metric("活动连接",value:connected ? String(connections) : "—",icon:"network",color:.secondary)
        }
    }
    private func metric(_ title:String,value:String,icon:String,color:Color)->some View {
        VStack(alignment:.leading,spacing:7) {
            Label(title,systemImage:icon).font(.system(size:10,weight:.medium)).foregroundStyle(color)
            Text(value).font(.system(size:expanded ? 21 : 16,weight:.semibold,design:.rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}
struct XihangSubscriptionSummary: View {
    @ObservedObject var model: AppModel
    var onOpen: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Label("订阅资源",systemImage:"square.stack.3d.up").font(.headline);Spacer();Button("查看",action:onOpen).buttonStyle(.borderless) }
            Text(model.state.subscriptions.isEmpty ? "还没有订阅" : "\(model.state.subscriptions.count) 份订阅 · \(model.state.nodes.count) 条线路").font(.title3.weight(.semibold))
            if let latest=model.state.subscriptions.map(\.updatedAt).max() {
                Text("最近更新："+latest.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
            } else { Text("导入订阅，即可管理和更新线路").font(.caption).foregroundStyle(.secondary) }
            if model.state.subscriptions.contains(where: \.pendingReview) { XihangStatusPill(title:"更新需要确认",color:Theme.amberAccent) }
            else if model.state.subscriptions.contains(where: { $0.lastError != nil }) { XihangStatusPill(title:"更新异常，原线路已保留",color:Theme.amberAccent) }
        }.padding(20).frame(maxWidth:.infinity,minHeight:140,alignment:.topLeading).liquidContentSurface()
    }
}
struct XihangAboutView: View {
    var body: some View {
        VStack(spacing:18) {
            XihangMark().frame(width:92,height:96).padding(24).background(Color(red:0.05,green:0.09,blue:0.17),in:RoundedRectangle(cornerRadius:28))
            Text("汐航").font(.largeTitle.bold())
            Text("Xihang · 网络代理客户端").foregroundStyle(.secondary)
            Text("让连接，自然流动").font(.headline).foregroundStyle(Theme.accentBlue)
            Text("版本 \(BuildVersion.current) (\(BuildVersion.build))").font(.caption).foregroundStyle(.secondary)
            Text("关闭窗口后，可在菜单栏继续使用汐航。").font(.caption).foregroundStyle(.secondary)
        }.padding(40).frame(minWidth:380)
    }
}

struct XihangSubscriptionUsage: View {
    let usage: UsageInfo?
    var body: some View {
        if let usage {
            VStack(alignment:.leading,spacing:8) {
                if let upload=usage.upload,let download=usage.download,let total=usage.total,total > 0 {
                    let used=min(Double(total),Double(upload)+Double(download))
                    ProgressView(value:used,total:Double(total)).tint(Theme.accentBlue)
                    Text("已用 \(bytes(Int64(min(Double(Int64.max-1024),Double(upload)+Double(download)))))) / \(bytes(Int64(clamping:total)))").font(.caption).foregroundStyle(.secondary)
                }
                if let expiry=usage.expire,expiry.isFinite,expiry > 0,expiry < 253402300800 {
                    Text("到期："+Date(timeIntervalSince1970:expiry).formatted(date:.abbreviated,time:.omitted)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct XihangModeMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu {
            ForEach(ProxyMode.allCases,id:\.self) { mode in
                Button {Task {await model.setMode(mode)}} label: {
                    if mode == model.state.mode {Label(mode.label,systemImage:"checkmark")} else {Text(mode.label)}
                }
            }
        } label: {
            Text(model.state.mode.label).font(.callout).foregroundStyle(Color.primary)
        }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal,12).padding(.vertical,7)
            .background(Theme.cardBackground,in:RoundedRectangle(cornerRadius:10))
            .disabled(model.locked).accessibilityLabel("代理模式："+model.state.mode.label)
    }
}
