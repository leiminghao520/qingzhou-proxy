import Foundation
import AppKit
import Combine
import Darwin
import QingzhouKit

@main struct OfficePublicationBenchmark {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task {@MainActor in
            do {
                guard let index=CommandLine.arguments.firstIndex(of:"--output") else {throw ProxyError("缺少输出文件")}
                let model=AppModel();guard !model.loadingFailed else {throw ProxyError("隔离初始化失败")}
                var publications=0
                let subscription=model.objectWillChange.sink{publications+=1}
                var samples:[Double]=[]
                for trial in 0..<20 {
                    let start=ProcessInfo.processInfo.systemUptime
                    for sample in 0..<30 {
                        model.uploadRate=Int64(trial+sample);model.downloadRate=Int64(sample)
                        model.rateHistory=[RateSample(upload:Int64(sample),download:100)]
                    }
                    samples.append((ProcessInfo.processInfo.systemUptime-start)*1000)
                }
                withExtendedLifetime(subscription) {}
                var usage=rusage();getrusage(RUSAGE_SELF,&usage)
                let sorted=samples.sorted()
                let result:[String:Any]=["kind":"isolated-rate-publication-only","trials":20,"samplesPerTrial":30,"appModelPublications":publications,"p50Ms":sorted[10],"p95Ms":sorted[18],"maxRSSBytes":usage.ru_maxrss,"samplesMs":samples,"liveNetworkChanged":false,"coreHelperResourceUsage":"未测量","startupAndRecoveryPerformance":"未测量"]
                let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
                try data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
                await model.timeline.drain();await model.history.drain();print("OFFICE_PUBLICATION_BENCHMARK_OK publications=\(publications)");exit(0)
            }catch {print("OFFICE_PUBLICATION_BENCHMARK_FAILED \(error)");exit(1)}
        }
        NSApplication.shared.run()
    }
}
