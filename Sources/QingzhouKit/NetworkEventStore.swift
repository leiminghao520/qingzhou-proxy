import Foundation

public enum NetworkEventCategory:String,Codable,CaseIterable,Sendable {case connection,network,node,configuration,recovery,diagnostic,history}
public enum NetworkEventOutcome:String,Codable,CaseIterable,Sendable {case started,succeeded,failed,cancelled,changed}
public enum NetworkEventPhase:String,Codable,Sendable {
    case corePreparation,fallback,preCaptureProbe,captureActivation,postCaptureProbe,systemProxyActivation,recovery
    public var label:String {switch self {case .corePreparation:return "准备网络与核心";case .fallback:return "检查代理通道";case .preCaptureProbe:return "接管前验证";case .captureActivation:return "应用接管";case .postCaptureProbe:return "接管后验证";case .systemProxyActivation:return "应用系统代理";case .recovery:return "恢复网络"}}
}
public enum NetworkEventReason:String,Codable,Sendable {
    case systemSleep,systemWake,wakeCheckFailed,wakeRetryWaiting,wakeRecovered,wakeStopped
    case userRequest,startFailed,connected,disconnected,nodeSelected,environmentChanged,ownershipChanged,coreExited
    case reconnecting,reconnected,helperFailed,recoverySucceeded,recoveryConflict,configurationApplied,configurationFailed
    case diagnosisComplete,diagnosisCancelled,diagnosisTimeout,historyRestored,historyFailed
    public var label:String {
        switch self {
        case .systemSleep:return "系统睡眠"
        case .systemWake:return "正式唤醒"
        case .wakeCheckFailed:return "唤醒复查失败或未验证"
        case .wakeRetryWaiting:return "等待唤醒重连"
        case .wakeRecovered:return "唤醒恢复成功"
        case .wakeStopped:return "唤醒恢复停止"
        case .userRequest:return "开始连接"
        case .startFailed:return "连接阶段失败"
        case .connected:return "连接成功"
        case .disconnected:return "连接已断开"
        case .nodeSelected:return "实际节点或策略变化"
        case .environmentChanged:return "网络环境变化"
        case .ownershipChanged:return "网络所有权变化"
        case .coreExited:return "核心异常退出"
        case .reconnecting:return "正在自动重连"
        case .reconnected:return "自动重连完成"
        case .helperFailed:return "辅助服务不可用"
        case .recoverySucceeded:return "原网络恢复完成"
        case .recoveryConflict:return "恢复冲突，需要检查"
        case .configurationApplied:return "配置应用成功"
        case .configurationFailed:return "配置应用失败"
        case .diagnosisComplete:return "诊断完成"
        case .diagnosisCancelled:return "诊断已取消"
        case .diagnosisTimeout:return "诊断超时"
        case .historyRestored:return "历史配置恢复完成"
        case .historyFailed:return "配置历史保存或恢复失败"
        }
    }
}
// 字段只接受有限枚举和不透明标识，不接受原始错误、域名、订阅地址或逐条业务连接。
public struct NetworkEvent:Codable,Sendable,Identifiable,Equatable {
    public var id=UUID()
    public var time:Date
    public var lastTime:Date
    public var uptime:TimeInterval
    public var sessionID:UUID
    public var profileID:UUID?
    public var category:NetworkEventCategory
    public var outcome:NetworkEventOutcome
    public var reason:NetworkEventReason
    public var phase:NetworkEventPhase?
    public var diagnosticID:UUID?
    public var historyTransactionID:UUID?
    public var recoveryID:UUID?
    public var originalSessionID:UUID?
    public var recoveryAttempt:Int?
    public var recoveryReason:WakeRecoveryReason?
    public var count=1
    public init(sessionID:UUID,profileID:UUID?,category:NetworkEventCategory,outcome:NetworkEventOutcome,reason:NetworkEventReason,phase:NetworkEventPhase?=nil,recoveryID:UUID?=nil,originalSessionID:UUID?=nil,recoveryReason:WakeRecoveryReason?=nil,recoveryAttempt:Int?=nil,diagnosticID:UUID?=nil,historyTransactionID:UUID?=nil,time:Date=Date(),uptime:TimeInterval=ProcessInfo.processInfo.systemUptime) {
        self.recoveryAttempt=recoveryAttempt;self.recoveryID=recoveryID;self.originalSessionID=originalSessionID;self.recoveryReason=recoveryReason
        self.sessionID=sessionID;self.profileID=profileID;self.category=category;self.outcome=outcome;self.reason=reason;self.phase=phase;self.diagnosticID=diagnosticID;self.historyTransactionID=historyTransactionID;self.time=time;self.lastTime=time;self.uptime=uptime
    }
    public var recoveryDetails:String {
        var values:[String]=[]
        if let recoveryReason {values.append(recoveryReason.label)}
        if let recoveryAttempt,recoveryAttempt>0 {values.append("重建第 \(recoveryAttempt)/3 次")}
        if let recoveryID {values.append("恢复任务 "+String(recoveryID.uuidString.prefix(8)))}
        if let originalSessionID {values.append("原会话 "+String(originalSessionID.uuidString.prefix(8)))}
        return values.joined(separator:" · ")
    }

}

// 所有调用由模型的后台串行队列执行；原子重写保持文件上限，损坏行单独跳过。
public final class NetworkEventStore {
    public let url:URL
    public private(set) var records:[NetworkEvent]=[]
    public var write:(Data,URL) throws -> Void = {try SecureFile.write($0,to:$1)}
    private let maximumBytes:Int
    private let retention:TimeInterval
    private let now:()->Date
    public init(url:URL,now:@escaping ()->Date=Date.init,maximumBytes:Int=2*1024*1024,retention:TimeInterval=7*86400) throws {
        self.url=url;self.now=now;self.maximumBytes=max(1024,maximumBytes);self.retention=retention
        if FileManager.default.fileExists(atPath:url.path) {
            let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,(attributes[.size] as? NSNumber)?.intValue ?? Int.max <= self.maximumBytes else {throw ProxyError("事件文件类型或大小异常")}
            let data=try Data(contentsOf:url)
            records=data.split(separator:10).compactMap{try? JSONDecoder().decode(NetworkEvent.self,from:Data($0))}.filter{$0.time>=now().addingTimeInterval(-retention) && $0.count>0}
        }
        if !records.isEmpty || FileManager.default.fileExists(atPath:url.path) {try append([])}
    }
    public func append(_ events:[NetworkEvent]) throws {
        var next=records
        for event in events.suffix(1000) {
            if let last=next.last,last.sessionID==event.sessionID,last.profileID==event.profileID,last.category==event.category,last.reason==event.reason,last.outcome==event.outcome,last.phase==event.phase,last.diagnosticID==event.diagnosticID,last.historyTransactionID==event.historyTransactionID,last.recoveryID==event.recoveryID,last.recoveryAttempt==event.recoveryAttempt,last.recoveryReason==event.recoveryReason,last.originalSessionID==event.originalSessionID,event.uptime>=last.uptime,event.uptime-last.uptime<=30,event.time>=last.time {
                next[next.count-1].count=min(1_000_000_000,last.count+1);next[next.count-1].lastTime=event.time
            }else{next.append(event)}
        }
        next.removeAll{$0.time<now().addingTimeInterval(-retention)}
        let encoder=JSONEncoder()
        var lines:[Data]=[],size=0,retained:[NetworkEvent]=[]
        for event in next.reversed() {
            var line=try encoder.encode(event);line.append(10)
            guard size+line.count<=maximumBytes else{break}
            size+=line.count;lines.append(line);retained.append(event)
        }
        var bytes=Data();for line in lines.reversed(){bytes.append(line)}
        try write(bytes,url);records=retained.reversed()
    }
    public func clear() throws {try write(Data(),url);records=[]}
    public static func export(_ events:[NetworkEvent],json:Bool) throws -> Data {
        if json {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return try encoder.encode(events)}
        return Data(events.map{$0.time.formatted()+" · "+$0.category.label+" · "+$0.outcome.label+" · "+$0.reason.label+($0.recoveryDetails.isEmpty ? "":" · "+$0.recoveryDetails)+" ×"+String($0.count)}.joined(separator:"\n").utf8)
    }
}

public extension NetworkEventCategory {
    var label:String {switch self {case .connection:return "连接";case .network:return "网络";case .node:return "节点";case .configuration:return "配置";case .recovery:return "恢复";case .diagnostic:return "诊断";case .history:return "历史"}}
}
public extension NetworkEventOutcome {
    var label:String {switch self {case .started:return "开始";case .succeeded:return "成功";case .failed:return "失败";case .cancelled:return "取消";case .changed:return "变化"}}
}
