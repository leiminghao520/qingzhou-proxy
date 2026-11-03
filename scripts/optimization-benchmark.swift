import Foundation
import Darwin
import QingzhouKit

private final class BenchmarkProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        Thread.sleep(forTimeInterval:0.003)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(repeating:120,count:16384));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
@main struct OptimizationBenchmark {
    static func main() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let old=BaselineDiagnosticLog(url:directory.appendingPathComponent("old.log")),new=DiagnosticLog(url:directory.appendingPathComponent("new.log"))
        let lines=(0..<50).map{"受控日志样本 \($0) "+String(repeating:"x",count:100)}
        var before:[Double]=[],after:[Double]=[],oldDownload:[Double]=[],newDownload:[Double]=[]
        func milliseconds()->Double{Double(DispatchTime.now().uptimeNanoseconds)/1e6}
        var initial=rusage();getrusage(RUSAGE_SELF,&initial)
        for _ in 0..<100 {
            var start=milliseconds();try old.appendBatch(lines);before.append(milliseconds()-start)
            start=milliseconds();try new.appendBatch(lines);after.append(milliseconds()-start)
        }
        let client=ExternalDownloadClient(protocolClasses:[BenchmarkProtocol.self]);defer{client.shutdown()}
        let url=URL(string:"https://fixture.invalid/subscription")!
        // 预热并交替执行顺序，减小首次会话初始化和固定先后顺序的偏差。
        for _ in 0..<10 {
            _=try await BaselineBoundedDownload.fetch(url,protocolClasses:[BenchmarkProtocol.self])
            _=try await client.fetchResponse(url,limit:2*1024*1024)
        }
        func baselineDownload() async throws {
            let start=milliseconds();_=try await BaselineBoundedDownload.fetch(url,protocolClasses:[BenchmarkProtocol.self]);oldDownload.append(milliseconds()-start)
        }
        func candidateDownload() async throws {
            let start=milliseconds();_=try await client.fetchResponse(url,limit:2*1024*1024);newDownload.append(milliseconds()-start)
        }
        for iteration in 0..<200 {
            if iteration.isMultiple(of:2) {try await baselineDownload();try await candidateDownload()}
            else {try await candidateDownload();try await baselineDownload()}
        }
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        func summary(_ samples:[Double])->[String:Any]{let values=samples.sorted();return ["p50Ms":values[values.count/2],"p95Ms":values[min(values.count-1,Int(Double(values.count)*0.95))],"samplesMs":samples]}
        func cpu(_ value:rusage)->Double{Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1e6}
        let payload=lines.reduce(0){$0+Data(($1+"\n").utf8).count}*100
        let result:[String:Any]=["buildMode":"debug-Onone","scope":"同进程隔离算法与 URLProtocol 基准；不是实网、应用启动或应用与核心总内存验收","logBefore":summary(before),"logAfter":summary(after),"downloadBefore":summary(oldDownload),"downloadAfter":summary(newDownload),"baselineLogWrittenBytes":old.writtenBytes,"candidateLogPayloadBytes":payload,"cpuSeconds":cpu(usage)-cpu(initial),"benchmarkPeakRSSBytes":usage.ru_maxrss,"downloadRequestsPerVariant":200,"warmupRequestsPerVariant":10,"baselineSessions":210,"candidateSessions":1,"realNetworkVerified":false]
        try SecureFile.write(JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("OPTIMIZATION_BENCHMARK_OK synthetic-only")
    }
}
