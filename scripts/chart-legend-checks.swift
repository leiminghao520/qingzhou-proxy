import SwiftUI
import AppKit
import Charts
import QingzhouKit

// 直接渲染源码中的图表组件，不读取配置、不访问钥匙串或网络。
@main struct ChartLegendChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {try await run();exit(0)}
            catch {print("LEGEND_RENDER_FAILED \(error)");exit(1)}
        }
        NSApplication.shared.run()
    }
    @MainActor static func run() async throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let samples=(0..<30).map { minute -> RateSample in
            var sample=RateSample(upload:Int64(10000+minute*800),download:Int64(200000+abs(sin(Double(minute)*0.4))*1700000))
            sample.time=Date(timeIntervalSince1970:1793250000).addingTimeInterval(Double(minute)*60)
            return sample
        }
        var screenshots=0
        for (name,width,embedded) in [("embedded-wide",CGFloat(640),true),("embedded-narrow",CGFloat(340),true),("standalone",CGFloat(420),false)] {
            for dark in [false,true] {
                let root=RateChart(samples:samples,embedded:embedded)
                    .padding(embedded ? 20 : 0)
                    .background(Theme.cardBackground,in:RoundedRectangle(cornerRadius:Theme.cardCornerRadius))
                    .frame(width:width,alignment:.topLeading).padding(24)
                    .background(Theme.secondaryBackground)
                    .environment(\.colorScheme,dark ? .dark : .light)
                let host=NSHostingView(rootView:root)
                let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width+48,height:265),styleMask:[.titled],backing:.buffered,defer:false)
                window.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
                window.contentView=host;window.orderFrontRegardless()
                try await Task.sleep(nanoseconds:400_000_000)
                host.layoutSubtreeIfNeeded()
                guard let image=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw NSError(domain:"图表渲染",code:1)}
                host.cacheDisplay(in:host.bounds,to:image)
                guard let data=image.representation(using:.png,properties:[:]) else {throw NSError(domain:"图表渲染",code:2)}
                try data.write(to:output.appendingPathComponent(name+(dark ? "-dark.png":"-light.png")))
                screenshots+=1;window.orderOut(nil)
            }
        }
        print("LEGEND_RENDER_OK screenshots=\(screenshots)")
    }
}
