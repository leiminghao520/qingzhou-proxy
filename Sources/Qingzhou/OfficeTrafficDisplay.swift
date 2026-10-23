import SwiftUI
import QingzhouKit

struct OfficeTrafficSample {
    var upload:Int64=0
    var download:Int64=0
    var history:[RateSample]=[]
}
@MainActor final class OfficeTrafficDisplay:ObservableObject {
    let menu=OfficeMenuTrafficDisplay()
    @Published var sample=OfficeTrafficSample()
    func receive(upload:Int64,download:Int64,now:Date) {
        var next=sample;next.upload=max(0,upload);next.download=max(0,download)
        next.history.append(RateSample(upload:next.upload,download:next.download))
        next.history.removeAll{now.timeIntervalSince($0.time)>1800};sample=next
    }
}

struct OfficeMenuTrafficSample:Equatable {
    var upload:Int64=0
    var download:Int64=0
}
// 菜单栏单独发布速率；后台保持每秒更新，不唤醒整个页面展示模型。
@MainActor final class OfficeMenuTrafficDisplay:ObservableObject {
    @Published private(set) var sample=OfficeMenuTrafficSample()
    private var last=Date.distantPast
    func receive(upload:Int64,download:Int64,now:Date) {
        guard now.timeIntervalSince(last)>=1 else{return}
        last=now;sample=OfficeMenuTrafficSample(upload:max(0,upload),download:max(0,download))
    }
    func reset() {last = .distantPast;sample=OfficeMenuTrafficSample()}
}

struct OfficeMenuBarLabel:View {
    @ObservedObject var display:OfficeMenuTrafficDisplay
    let connected:Bool
    let available:Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func height(_ rate:Int64)->CGFloat {3+15*CGFloat(min(1,log2(Double(max(0,rate))/1024+1)/14))}
    var body:some View {
        HStack(spacing:4) {
            Image(systemName:connected ? "paperplane.fill":"paperplane")
            HStack(alignment:.bottom,spacing:2) {
                Capsule().frame(width:2,height:connected && available ? height(display.sample.upload):3)
                Capsule().frame(width:2,height:connected && available ? height(display.sample.download):3)
            }.frame(width:6,height:18,alignment:.bottom)
                .animation(reduceMotion ? nil:.easeOut(duration:0.18),value:display.sample)
            VStack(alignment:.leading,spacing:0) {
                Text(connected ? "↑ "+(available ? formatRate(display.sample.upload):"—"):"未连接")
                Text(connected ? "↓ "+(available ? formatRate(display.sample.download):"—"):"—")
            }.font(.system(size:9,design:.monospaced)).monospacedDigit()
                .frame(width:76,alignment:.leading).lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(connected ? "轻舟代理，上传 "+(available ? formatRate(display.sample.upload):"未验证")+"，下载 "+(available ? formatRate(display.sample.download):"未验证"):"轻舟代理，未连接")
    }
}
struct OfficeMenuRateLine:View {
    @ObservedObject var display:OfficeMenuTrafficDisplay
    let available:Bool
    var body:some View {Text("↑ "+(available ? formatRate(display.sample.upload):"不可用")+"  ↓ "+(available ? formatRate(display.sample.download):"不可用")).monospacedDigit()}
}
struct OfficeRateLine:View {
    @ObservedObject var display:OfficeTrafficDisplay
    let available:Bool
    var body:some View {Text("↑ "+(available ? formatRate(display.sample.upload):"不可用")+"  ↓ "+(available ? formatRate(display.sample.download):"不可用")).monospacedDigit()}
}
struct OfficeLiveRateCards:View {
    @ObservedObject var display:OfficeTrafficDisplay
    let available:Bool
    var body:some View {
        HStack(spacing:14) {
            ModernStatCard(title:"实时下载速率",value:available ? formatRate(display.sample.download):"不可用",icon:"arrow.down.circle.fill",iconColor:Theme.trafficDownload)
            ModernStatCard(title:"实时上传速率",value:available ? formatRate(display.sample.upload):"不可用",icon:"arrow.up.circle.fill",iconColor:Theme.trafficUpload)
        }
    }
}
struct OfficeRateChart:View {
    @ObservedObject var display:OfficeTrafficDisplay
    var body:some View {RateChart(samples:display.sample.history)}
}
