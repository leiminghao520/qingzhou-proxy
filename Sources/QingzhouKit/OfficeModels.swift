import Foundation
import Darwin

public enum TargetConnectionTest:String,Codable,CaseIterable,Sendable {case tcp,tls,https
    public var label:String {rawValue.uppercased()}
}
public enum TargetExpectedPath:String,Codable,CaseIterable,Sendable {case proxy,direct,system
    public var label:String {switch self {case .proxy:return "代理";case .direct:return "直连";case .system:return "跟随系统路由"}}
}
public struct SavedDiagnosticTarget:Codable,Identifiable,Equatable,Sendable {
    public var id:UUID
    public var name:String
    public var host:String
    public var port:Int?
    public var test:TargetConnectionTest
    public var expectedPath:TargetExpectedPath
    public init(id:UUID=UUID(),name:String,host:String,port:Int?=nil,test:TargetConnectionTest = .https,expectedPath:TargetExpectedPath = .system) {
        self.id=id;self.name=name;self.host=host;self.port=port;self.test=test;self.expectedPath=expectedPath
    }
    public var effectivePort:Int {port ?? 443}
    public static func isIP(_ host:String)->Bool {
        var v4=in_addr(),v6=in6_addr()
        return host.withCString{inet_pton(AF_INET,$0,&v4)==1 || inet_pton(AF_INET6,$0,&v6)==1}
    }
    public func validated() throws -> Self {
        var value=self
        value.name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        value.host=host.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if value.host.hasSuffix(".") {value.host.removeLast()}
        guard !value.name.isEmpty,value.name.count<=100,!value.name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),port.map({(1...65535).contains($0)}) ?? true else {throw ProxyError("目标名称或端口无效")}
        if !Self.isIP(value.host) {
            // 允许单标签内网主机名，但拒绝 URL、路径、通配符及命令片段。
            guard !value.host.isEmpty,value.host.utf8.count<=253,value.host.split(separator:".",omittingEmptySubsequences:false).allSatisfy({label in
                !label.isEmpty && label.count<=63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy{(97...122).contains($0) || (48...57).contains($0) || $0==45}
            }) else {throw ProxyError("请输入不含协议、端口和路径的域名或 IP")}
        }
        return value
    }
    public static func validate(_ values:[Self]) throws {
        guard values.count<=100,Set(values.map(\.id)).count==values.count else {throw ProxyError("收藏目标超过上限或标识重复")}
        for value in values {_=try value.validated()}
    }
    public static func revision(_ values:[Self]) throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(values)
    }
}

public enum OfficeHealthStatus:String,Sendable {case healthy="正常",failed="异常",checking="检测中",unverified="未验证",notApplicable="不适用"}
public struct OfficeHealthContext:Equatable,Sendable {
    public var profileID:UUID?
    public var connectionID:UUID
    public var networkID:UUID
    public init(profileID:UUID?,connectionID:UUID,networkID:UUID) {self.profileID=profileID;self.connectionID=connectionID;self.networkID=networkID}
}
public struct OfficeHealthSnapshot:Identifiable,Equatable,Sendable {
    public var id:String
    public var title:String
    public var status:OfficeHealthStatus
    public var detail:String
    public var checkedAt:Date
    public var context:OfficeHealthContext
    public var stale=false
    public init(id:String,title:String,status:OfficeHealthStatus,detail:String,checkedAt:Date=Date(),context:OfficeHealthContext) {
        self.id=id;self.title=title;self.status=status;self.detail=detail;self.checkedAt=checkedAt;self.context=context
    }
    public func isCurrent(_ value:OfficeHealthContext,now:Date)->Bool {context==value && !stale && now>=checkedAt && now.timeIntervalSince(checkedAt)<=120}
}

public enum OfficeSceneTemplate:String,CaseIterable,Sendable {case bank,home,temporary
    public var label:String {switch self {case .bank:return "银行办公";case .home:return "家庭";case .temporary:return "临时网络"}}
    public func configuration(domains:[String]=[],cidrs:[String]=[],dns:DNSPreference = .system,targets:[SavedDiagnosticTarget]=[]) throws -> AppState {
        var state=AppState();state.autoConnect=false;state.loginAtStartup=false;state.captureMode = .systemProxy
        guard self == .bank else {return state}
        state.protectedDomains=try ProtectedDomainPolicy.normalize(domains);state.dnsPreference=dns
        for domain in state.protectedDomains {state.rules.append(RoutingRule(kind:.suffix,value:domain,action:.direct))}
        for cidr in cidrs {try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:cidr,action:.direct));state.rules.append(RoutingRule(kind:.cidr,value:cidr,action:.direct))}
        state.tunExcludedCIDRs=try cidrs.map{try NetworkBypassPolicy.canonicalCIDR($0)}
        try SavedDiagnosticTarget.validate(targets);state.savedDiagnosticTargets=targets
        return state
    }
}

public enum OfficeTelemetryCadence {
    public static func connections(hidden:Bool,pageVisible:Bool)->TimeInterval {hidden ? 10:pageVisible ? 1:5}
    public static func policies(hidden:Bool)->TimeInterval {hidden ? 10:5}
    public static func traffic(hidden:Bool)->TimeInterval {hidden ? 5:1}
    public static func menuNodes(_ state:AppState,actualTag:String?)->[Node] {
        let current=state.nodes.filter{PolicyReference.node($0.id).tag==actualTag || state.activePolicy == .node($0.id)}
        let favorites=state.nodes.filter{state.favorites.contains($0.id)}
        let recent=state.nodes.filter{state.recentUse[$0.id.uuidString] != nil}.sorted{(state.recentUse[$0.id.uuidString] ?? .distantPast)>(state.recentUse[$1.id.uuidString] ?? .distantPast)}
        var seen=Set<UUID>()
        return Array((current+favorites+recent).filter{seen.insert($0.id).inserted}.prefix(15))
    }
}
