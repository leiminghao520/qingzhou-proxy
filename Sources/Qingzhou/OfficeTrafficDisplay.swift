import SwiftUI
import QingzhouKit

struct OfficeTrafficSample {
    var upload:Int64=0
    var download:Int64=0
    var history:[RateSample]=[]
}
@MainActor final class OfficeTrafficDisplay:ObservableObject {
    @Published var sample=OfficeTrafficSample()
    func receive(upload:Int64,download:Int64,now:Date) {
        var next=sample;next.upload=max(0,upload);next.download=max(0,download)
        next.history.append(RateSample(upload:next.upload,download:next.download))
        next.history.removeAll{now.timeIntervalSince($0.time)>1800};sample=next
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
    var body:some View {RateChart(samples:display.sample.history)}
}
