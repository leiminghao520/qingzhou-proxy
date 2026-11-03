import Foundation
import CryptoKit

public enum ConnectionFailureKind:String,Codable,Sendable {
    case network,dns,tunnel,ownership,permission,configuration,unavailable,recovery
    public var label:String {switch self {
    case .network:return "网络暂未就绪"
    case .dns:return "当前 DNS 不可用"
    case .tunnel:return "当前接管方式不可用"
    case .ownership:return "其他网络服务正在接管"
    case .permission:return "需要安装或授权辅助服务"
    case .configuration:return "请检查连接配置"
    case .unavailable:return "当前线路暂不可用"
    case .recovery:return "网络恢复尚未完成"
    }}
    public var retryable:Bool {[Self.network,.dns,.tunnel,.unavailable].contains(self)}
    public static func classify(_ error:Error)->Self {
        if error is NetworkEnvironmentNotReady {return .network}
        if error is NetworkCaptureConflict {return .ownership}
        if let failure=error as? HelperOperationFailure {return failure.kind}
        if let failure=error as? ConnectionFailure {return failure.kind}
        if let failure=error as? WakeRecoveryError {
            switch failure.reason {case .networkNotReady:return .network;case .nodeUnavailable,.pathUnavailable:return .unavailable;case .ownershipConflict:return .ownership;default:return .configuration}
        }
        // 兼容旧辅助服务的中文错误；未知错误保守处理，不能据此改变流量路径。
        let message=error.localizedDescription
        if ["恢复未完成","恢复失败","恢复记录仍"].contains(where:message.contains){return .recovery}
        if ["外部修改","其他连接","其他代理","已有系统代理","所有权","正在接管"].contains(where:message.contains){return .ownership}
        if ["授权","权限","辅助服务协议","首次使用","安装或更新"].contains(where:message.contains){return .permission}
        if ["兼容代理汇总状态","TUN DNS 生效验证失败","TUN 网卡未就绪"].contains(where:message.contains) {return .tunnel}
        return .configuration
    }
}
public struct ConnectionFailure:Error,LocalizedError,Sendable {
    public let kind:ConnectionFailureKind
    public let detail:String
    public init(_ kind:ConnectionFailureKind,_ detail:String){self.kind=kind;self.detail=detail}
    public var errorDescription:String? {detail}
}
public struct HelperOperationFailure:Error,LocalizedError,Sendable {
    public let phase:String?
    public let kind:ConnectionFailureKind
    public let detail:String
    public init(phase:String?,kind:ConnectionFailureKind,detail:String){self.phase=phase;self.kind=kind;self.detail=detail}
    public var errorDescription:String? {detail}
}
public struct RecoveryPlan:Codable,Equatable,Sendable {
    public var capture:CaptureMode
    public var dns:DNSPreference
    public init(_ state:AppState){capture=state.captureMode;dns=state.dnsPreference}
    public func applying(to state:AppState)->AppState {var next=state;next.captureMode=capture;next.dnsPreference=dns;return next}
}
public struct ConnectionRecoveryRecord:Codable,Sendable {
    public var key:String
    public var kind:ConnectionFailureKind
    public var plan:RecoveryPlan
    public var failures:Int
    public var retryAfter:Date
    public var lastSuccess:Date?
    public var verified:Bool
}
// 只保存摘要、错误类别和运行选项，不保存订阅地址、节点凭据或完整配置。
@MainActor public final class ConnectionRecoveryStore {
    private let url:URL
    public private(set) var records:[String:ConnectionRecoveryRecord]=[:]
    public private(set) var readError:String?
    public init(url:URL){
        self.url=url
        guard FileManager.default.fileExists(atPath:url.path) else{return}
        do {
            let data=try Data(contentsOf:url)
            guard data.count<=256*1024 else{throw ProxyError("回退记录过大")}
            let decoded=try JSONDecoder().decode([String:ConnectionRecoveryRecord].self,from:data)
            guard decoded.count<=64,decoded.allSatisfy({$0.key==$0.value.key && $0.value.failures>0}) else{throw ProxyError("回退记录无效")}
            records=decoded
        }catch{readError="回退记录无法读取，原配置未改变"}
    }
    public static func key(state:AppState,environment:String)->String {
        var relevant=state
        relevant.latency=[:];relevant.recentUse=[:];relevant.notes=[:];relevant.favorites=[]
        relevant.autoConnect=false;relevant.loginAtStartup=false
        relevant.savedDiagnosticTargets=nil;relevant.compactNodes=false;relevant.shortcutEnabled=false
        relevant.shortcutKey=35;relevant.shortcutModifiers=2304
        for index in relevant.subscriptions.indices {
            relevant.subscriptions[index].name="";relevant.subscriptions[index].updatedAt=Date(timeIntervalSince1970:0)
            relevant.subscriptions[index].usage=nil;relevant.subscriptions[index].lastError=nil
            relevant.subscriptions[index].retryCount=0;relevant.subscriptions[index].retryAfter=nil
            relevant.subscriptions[index].pendingReview=false
        }
        for index in relevant.remoteRules.indices {relevant.remoteRules[index].updatedAt=nil;relevant.remoteRules[index].lastError=nil;relevant.remoteRules[index].retryCount=0;relevant.remoteRules[index].retryAfter=nil}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var data=(try? encoder.encode(relevant)) ?? Data()
        data.append(Data(environment.utf8))
        return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    public func preferred(key:String,now:Date,force:Bool=false)->ConnectionRecoveryRecord? {
        guard !force,let record=records[key],record.verified,now<record.retryAfter else{return nil}
        return record
    }
    public func failed(key:String,kind:ConnectionFailureKind,plan:RecoveryPlan,now:Date) throws {
        let old=records[key],count=min((old?.failures ?? 0)+1,1000)
        let delay:TimeInterval=count==1 ? 60:count==2 ? 300:1800
        records[key]=ConnectionRecoveryRecord(key:key,kind:kind,plan:plan,failures:count,retryAfter:now.addingTimeInterval(delay),lastSuccess:old?.lastSuccess,verified:old?.plan==plan && old?.verified==true)
        try save()
    }
    public func unavailable(key:String,now:Date) throws {
        guard var record=records[key] else{return}
        record.failures=min(record.failures+1,1000)
        record.retryAfter=now.addingTimeInterval(record.failures==1 ? 60:record.failures==2 ? 300:1800)
        record.verified=false;records[key]=record;try save()
    }
    public func verified(key:String,now:Date) throws {
        guard var record=records[key] else{return}
        record.verified=true;record.lastSuccess=now;records[key]=record;try save()
    }
    public func stableOriginal(key:String) throws {records.removeValue(forKey:key);try save()}
    private func save() throws {
        if records.count>64 {let keep=records.values.sorted{$0.retryAfter>$1.retryAfter}.prefix(64);records=Dictionary(uniqueKeysWithValues:keep.map{($0.key,$0)})}
        let data=try JSONEncoder().encode(records)
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}
