import Foundation

public struct ConnectionStageTiming: Codable, Sendable, Equatable {
    public let stage: String
    public let milliseconds: Int
    public let succeeded: Bool
    public var count: Int?
    public init(stage: String, milliseconds: Int, succeeded: Bool, count: Int? = nil) {
        self.stage = stage; self.milliseconds = milliseconds; self.succeeded = succeeded; self.count = count
    }
    public var summary: String {"连接计时 stage=\(stage) elapsedMs=\(milliseconds) result=\(succeeded ? "通过" : "失败")"+(count.map{" count=\($0)"} ?? "")}
}

// 每个连接尝试独立计时，使用单调时钟，不受系统时间校准影响。
public final class ConnectionTiming {
    private var stage: String?
    private var began: UInt64 = 0
    public private(set) var samples: [ConnectionStageTiming] = []
    public init() {}
    public func begin(_ next: String) {
        finish()
        stage = next; began = DispatchTime.now().uptimeNanoseconds
    }
    public func finish(succeeded: Bool = true) {
        guard let stage else { return }
        let elapsed = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        samples.append(ConnectionStageTiming(stage: stage, milliseconds: Int(min(elapsed, UInt64(Int.max))), succeeded: succeeded))
        self.stage = nil
    }
}

// 同一辅助服务请求内累计操作次数与单调时钟耗时，不包含命令参数或凭据。
public final class RouteOperationMetrics {
    private var values:[String:(nanoseconds:UInt64,count:Int,succeeded:Bool)]=[:]
    public init() {}
    public func measure<T>(_ name:String,_ body:() throws -> T) rethrows -> T {
        let began=DispatchTime.now().uptimeNanoseconds
        var succeeded=false
        defer {
            let old=values[name] ?? (0,0,true)
            values[name]=(old.nanoseconds+DispatchTime.now().uptimeNanoseconds-began,old.count+1,old.succeeded && succeeded)
        }
        let result=try body();succeeded=true;return result
    }
    public var samples:[ConnectionStageTiming] {
        values.keys.sorted().map {key in
            let value=values[key]!
            return ConnectionStageTiming(stage:key,milliseconds:Int(value.nanoseconds/1_000_000),succeeded:value.succeeded,count:value.count)
        }
    }
}
