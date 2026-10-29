import SwiftUI
import AppKit
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
    let connected:Bool
    var status:String=""
    var body:some View {
        // 菜单栏只保留固定尺寸图标，避免实时速率更新挤动其他菜单项。
        Image(nsImage:XihangMenuIcon.image)
            .frame(width:18,height:18)
            .accessibilityLabel(status.isEmpty ? (connected ? "汐航，已连接":"汐航，未连接") : "汐航，"+status)
            .help(status)
    }
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
    var body:some View {RateChart(samples:display.sample.history).equatable()}
}

// 菜单栏使用模板图，随系统自动反色；连接状态通过辅助功能与菜单正文表达。
enum XihangMenuIcon {
    static let image: NSImage = {
        let image=NSImage(size:NSSize(width:18,height:18),flipped:false) { rect in
            NSColor.black.setFill()
            let p=NSBezierPath();p.move(to:NSPoint(x:2,y:6));p.curve(to:NSPoint(x:14,y:17),controlPoint1:NSPoint(x:6,y:10),controlPoint2:NSPoint(x:9,y:14));p.curve(to:NSPoint(x:16,y:7),controlPoint1:NSPoint(x:13,y:12),controlPoint2:NSPoint(x:13,y:9));p.curve(to:NSPoint(x:2,y:6),controlPoint1:NSPoint(x:10,y:8),controlPoint2:NSPoint(x:6,y:7));p.close();p.fill()
            let tide=NSBezierPath();tide.move(to:NSPoint(x:2,y:3));tide.curve(to:NSPoint(x:16,y:4),controlPoint1:NSPoint(x:7,y:6),controlPoint2:NSPoint(x:10,y:0));tide.lineWidth=1.5;tide.lineCapStyle = .round;tide.stroke()
            return true
        }
        image.isTemplate=true;image.accessibilityDescription="汐航";return image
    }()
}
