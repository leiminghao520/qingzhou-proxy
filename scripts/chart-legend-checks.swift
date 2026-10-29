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
        #if VALIDATE_PROJECTION
        try projectionChecks()
        #endif
        if CommandLine.arguments.contains("--performance") {try await benchmark(output:output)}
        let longSamples=(0..<1800).map { i -> RateSample in
            var sample=RateSample(upload:Int64(10000+abs(sin(Double(i)*0.8))*900000),download:Int64(100000+abs(sin(Double(i)*0.35))*4000000))
            sample.time=Date(timeIntervalSince1970:1793250000+Double(i));return sample
        }
        var screenshots=0
        for (name,width,embedded) in [("embedded-wide",CGFloat(640),true),("embedded-narrow",CGFloat(340),true),("standalone",CGFloat(420),false),("long-session",CGFloat(640),true)] {
            for dark in [false,true] {
                let root=RateChart(samples:name == "long-session" ? longSamples : samples,embedded:embedded)
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
    #if VALIDATE_PROJECTION
    @MainActor static func projectionChecks() throws {
        var assertions=0
        func check(_ condition:Bool) throws {assertions+=1;if !condition {throw NSError(domain:"图表投影校验",code:assertions)}}
        var samples=(0..<1800).map { i -> RateSample in
            var value=RateSample(upload:Int64(100+i%97),download:Int64(300+i%79))
            value.time=Date(timeIntervalSince1970:1793250000+Double(i));return value
        }
        samples[333].upload=9000000;samples[334].download=9900000
        samples[335].upload=0;samples[336].download=0
        let plotted=RateChart.plottingSamples(samples),ids=Set(plotted.map(\.id))
        try check(plotted.count<=256)
        try check(plotted.first?.id==samples.first?.id && plotted.last?.id==samples.last?.id)
        try check(zip(plotted,plotted.dropFirst()).allSatisfy{$0.time<$1.time})
        try check(plotted.allSatisfy{value in samples.contains{$0.id==value.id}})
        for bucket in 0..<63 {
            let start=1+bucket*1798/63,end=1+(bucket+1)*1798/63
            let values=Array(samples[start..<end]),visible=values.filter{ids.contains($0.id)}
            try check(visible.map(\.upload).max()==values.map(\.upload).max())
            try check(visible.map(\.upload).min()==values.map(\.upload).min())
            try check(visible.map(\.download).max()==values.map(\.download).max())
            try check(visible.map(\.download).min()==values.map(\.download).min())
        }
        try check(RateChart.plottingSamples([]).isEmpty)
        try check(RateChart.plottingSamples(Array(samples.prefix(30))).map(\.id)==samples.prefix(30).map(\.id))
        try check(RateChart.plottingSamples(samples,limit:6).count<=6)
        try check(RateChart(samples:samples)==RateChart(samples:samples))
        var changed=samples;changed[500].upload+=1
        try check(RateChart(samples:samples) != RateChart(samples:changed))
        changed=samples;changed[500].time.addTimeInterval(0.1)
        try check(RateChart(samples:samples) != RateChart(samples:changed))
        try check(RateChart(samples:samples,embedded:true) != RateChart(samples:samples))
        try check(samples.count==1800 && samples[333].upload==9000000)
        print("CHART_PROJECTION_OK assertions=\(assertions) raw=\(samples.count) plotted=\(plotted.count)")
    }
    #endif

    @MainActor static func benchmark(output:URL) async throws {
        var values=(0..<1800).map { i -> RateSample in
            var sample=RateSample(upload:Int64(10000+abs(sin(Double(i)*0.8))*900000),download:Int64(100000+abs(sin(Double(i)*0.35))*4000000))
            sample.time=Date(timeIntervalSince1970:1793250000+Double(i));return sample
        }
        let host=NSHostingView(rootView:RateChart(samples:values,embedded:true))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:210),styleMask:[],backing:.buffered,defer:false)
        window.contentView=host;window.orderFrontRegardless()
        try await Task.sleep(nanoseconds:200_000_000)
        var times:[Double]=[]
        for iteration in 0..<8 {
            var next=RateSample(upload:Int64(30000+iteration),download:Int64(800000+iteration))
            next.time=values.last!.time.addingTimeInterval(1);values.removeFirst();values.append(next)
            let began=DispatchTime.now().uptimeNanoseconds
            host.rootView=RateChart(samples:values,embedded:true)
            host.layoutSubtreeIfNeeded()
            guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw NSError(domain:"图表性能渲染",code:1)}
            host.cacheDisplay(in:host.bounds,to:bitmap)
            let elapsed=Double(DispatchTime.now().uptimeNanoseconds-began)/1000000
            if iteration>0 {times.append(elapsed)}
            await Task.yield()
        }
        window.orderOut(nil)
        let sorted=times.sorted()
        let result:[String:Any]=["rawSamples":1800,"updates":times.count,"renderMilliseconds":times,"medianMilliseconds":sorted[sorted.count/2],"maxMilliseconds":sorted.last!,"scope":"隔离视图更新、布局与位图渲染耗时，非实机滚动帧率"]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("chart-performance.json"))
        print("CHART_RENDER_BENCHMARK median_ms=\(sorted[sorted.count/2]) max_ms=\(sorted.last!) samples=1800")
    }

}
