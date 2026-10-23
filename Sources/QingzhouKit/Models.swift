import Foundation
import CryptoKit

public enum ProxyKind: String, Codable, CaseIterable, Sendable { case hysteria2, shadowsocks, trojan, vless }
public struct ProxyError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct Node: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProxyKind
    public var server: String
    public var port: Int
    public var parameters: [String: String]
    public var credentialRef: String
    public var subscriptionID: UUID?
    public init(id: UUID = UUID(), name: String, kind: ProxyKind, server: String, port: Int, parameters: [String:String] = [:], credentialRef: String = UUID().uuidString, subscriptionID: UUID? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.server = server; self.port = port; self.parameters = parameters; self.credentialRef = credentialRef; self.subscriptionID = subscriptionID
    }
    public var fingerprint: String {
        let value = "\(kind.rawValue)|\(server.lowercased())|\(port)|" + parameters.sorted(by: {$0.key < $1.key}).map {"\($0.key)=\($0.value)"}.joined(separator: "&")
        return SHA256.hash(data: Data(value.utf8)).map {String(format: "%02x", $0)}.joined()
    }
    public var insecure: Bool { parameters["insecure"] == "1" }
}
public struct Candidate: Sendable {
    public var node: Node
    public var secret: String
    public var obfsSecret: String?
    public init(node: Node, secret: String, obfsSecret: String? = nil) { self.node = node; self.secret = secret; self.obfsSecret = obfsSecret }
}
public struct UsageInfo: Codable, Sendable {
    public var upload: UInt64?; public var download: UInt64?; public var total: UInt64?; public var expire: TimeInterval?
    public init(upload: UInt64? = nil, download: UInt64? = nil, total: UInt64? = nil, expire: TimeInterval? = nil) {self.upload=upload;self.download=download;self.total=total;self.expire=expire}
    public static func parse(_ header: String?) -> UsageInfo? {
        guard let header else {return nil};var fields:[String:String]=[:]
        for part in header.split(separator:";") {let p=part.split(separator:"=",maxSplits:1);if p.count==2 {fields[p[0].trimmingCharacters(in:.whitespaces).lowercased()]=p[1].trimmingCharacters(in:.whitespaces)}}
        let result=UsageInfo(upload:fields["upload"].flatMap(UInt64.init),download:fields["download"].flatMap(UInt64.init),total:fields["total"].flatMap(UInt64.init),expire:fields["expire"].flatMap(Double.init))
        return result.upload == nil && result.download == nil && result.total == nil && result.expire == nil ? nil : result
    }
}
public enum ImportScope: String, Codable, Sendable {case nodes, profile}
public struct Subscription: Codable, Identifiable, Sendable {
    public var revision:String?
    public var id: UUID; public var name: String; public var sourceRef: String; public var updatedAt: Date
    public var autoUpdate: Bool; public var scope: ImportScope; public var usage: UsageInfo?; public var lastError: String?; public var pendingReview: Bool; public var retryCount: Int; public var retryAfter: Date?
    public init(id: UUID = UUID(), name: String, sourceRef: String = UUID().uuidString, updatedAt: Date = Date()) {self.id=id;self.name=name;self.sourceRef=sourceRef;self.updatedAt=updatedAt;autoUpdate=true;scope = .nodes;pendingReview=false;retryCount=0}
    enum CodingKeys: String,CodingKey {case revision,id,name,sourceRef,updatedAt,autoUpdate,scope,usage,lastError,pendingReview,retryCount,retryAfter}
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self);revision=try c.decodeIfPresent(String.self,forKey:.revision);id=try c.decode(UUID.self,forKey:.id);name=try c.decode(String.self,forKey:.name);sourceRef=try c.decode(String.self,forKey:.sourceRef);updatedAt=try c.decode(Date.self,forKey:.updatedAt)
        autoUpdate=try c.decodeIfPresent(Bool.self,forKey:.autoUpdate) ?? true;scope=try c.decodeIfPresent(ImportScope.self,forKey:.scope) ?? .nodes;usage=try c.decodeIfPresent(UsageInfo.self,forKey:.usage);lastError=try c.decodeIfPresent(String.self,forKey:.lastError);pendingReview=try c.decodeIfPresent(Bool.self,forKey:.pendingReview) ?? false;retryCount=try c.decodeIfPresent(Int.self,forKey:.retryCount) ?? 0;retryAfter=try c.decodeIfPresent(Date.self,forKey:.retryAfter)
    }
}
public enum ProxyMode: String, Codable, CaseIterable, Sendable {case rule, global, direct
    public var label: String {self == .rule ? "规则" : self == .global ? "全部代理" : "全部直连"}
}
public enum PolicyReference: Codable, Hashable, Sendable {
    case node(UUID), group(UUID), automatic, selected, direct, reject
    public var tag: String {switch self {case .node(let id):return "node-"+id.uuidString.lowercased();case .group(let id):return "group-"+id.uuidString.lowercased();case .automatic:return "auto";case .selected:return "proxy";case .direct:return "direct";case .reject:return "reject"}}
}
public enum GroupKind: String,Codable,CaseIterable,Sendable {case select, urltest, fallback}
public struct PolicyGroup: Codable,Identifiable,Sendable {
    public var id: UUID;public var name: String;public var kind: GroupKind;public var members:[PolicyReference];public var selected:PolicyReference?;public var subscriptionID:UUID?
    public init(id:UUID=UUID(),name:String,kind:GroupKind,members:[PolicyReference],selected:PolicyReference?=nil,subscriptionID:UUID?=nil) {self.id=id;self.name=name;self.kind=kind;self.members=members;self.selected=selected;self.subscriptionID=subscriptionID}
}
public struct LatencyResult:Codable,Sendable {public var milliseconds:Int?;public var testedAt:Date;public init(milliseconds:Int?,testedAt:Date=Date()){self.milliseconds=milliseconds;self.testedAt=testedAt}}
public enum RuleKind: String, Codable, CaseIterable, Sendable { case domain, suffix, keyword, cidr, match, geoip, asn, userAgent }
public enum RuleAction: String, Codable, CaseIterable, Sendable { case direct, proxy, reject }
public struct RoutingRule: Codable, Identifiable, Equatable, Sendable {
    public var noResolve:Bool?;public var id = UUID();public var kind: RuleKind;public var value: String;public var action: RuleAction;public var target:PolicyReference?;public var subscriptionID:UUID?
    public init(kind: RuleKind, value: String, action: RuleAction,target:PolicyReference?=nil,subscriptionID:UUID?=nil) {self.kind=kind;self.value=value;self.action=action;self.target=target;self.subscriptionID=subscriptionID}
}
public struct RemoteRuleSource:Codable,Identifiable,Sendable {
    public var id=UUID();public var name:String;public var sourceRef:String;public var target:PolicyReference;public var rules:[RoutingRule]=[];public var updatedAt:Date?;public var autoUpdate=true;public var lastError:String?;public var retryCount=0;public var retryAfter:Date?
    public init(name:String,sourceRef:String=UUID().uuidString,target:PolicyReference = .selected){self.name=name;self.sourceRef=sourceRef;self.target=target}
}
public struct AppState: Codable, Sendable {
    public var savedDiagnosticTargets:[SavedDiagnosticTarget]?
    public var networkBypasses:[NetworkBypass]?
    public var httpCompatibilityEnabled=false
    public var usesHTTPCompatibility:Bool {httpCompatibilityEnabled && shadowrocket != nil}
    public var shadowrocket:ShadowrocketConfiguration?;public var schemaVersion = 2;public var nodes:[Node]=[];public var subscriptions:[Subscription]=[];public var rules:[RoutingRule]=[]
    public var mode:ProxyMode = .rule;public var listenPort=7890;public var selectedID:UUID?;public var selectedPolicy:PolicyReference?;public var groups:[PolicyGroup]=[];public var remoteRules:[RemoteRuleSource]=[];public var favorites:Set<UUID>=[];public var latency:[String:LatencyResult]=[:];public var ruleFinal:PolicyReference?;public var autoConnect=false;public var loginAtStartup=false
    public var addressFamilyPolicy:AddressFamilyPolicy?
    public var effectiveAddressFamilyPolicy:AddressFamilyPolicy {addressFamilyPolicy ?? .ipv4Only}
    public var captureMode:CaptureMode = .systemProxy;public var dnsPreference:DNSPreference = .httpsProxy;public var notes:[String:String]=[:];public var recentUse:[String:Date]=[:];public var compactNodes=false;public var shortcutEnabled=false;public var shortcutKey:UInt32=35;public var shortcutModifiers:UInt32=2304;public var tunExcludedCIDRs:[String]=[];public var protectedDomains:[String]=[]
    public var rulesEnabled:Bool {get {mode == .rule} set {mode = newValue ? .rule : .global}}
    public var activePolicy:PolicyReference? {selectedPolicy ?? selectedID.map(PolicyReference.node)}
    public init() {}
    enum CodingKeys:String,CodingKey {case savedDiagnosticTargets,networkBypasses,httpCompatibilityEnabled,protectedDomains,addressFamilyPolicy,shadowrocket,shortcutEnabled,shortcutKey,shortcutModifiers,tunExcludedCIDRs,captureMode,dnsPreference,notes,recentUse,compactNodes,schemaVersion,nodes,subscriptions,rules,mode,listenPort,selectedID,selectedPolicy,groups,remoteRules,favorites,latency,ruleFinal,autoConnect,loginAtStartup}
    enum LegacyKeys:String,CodingKey {case rulesEnabled}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self);savedDiagnosticTargets=try c.decodeIfPresent([SavedDiagnosticTarget].self,forKey:.savedDiagnosticTargets);try SavedDiagnosticTarget.validate(savedDiagnosticTargets ?? []);httpCompatibilityEnabled=try c.decodeIfPresent(Bool.self,forKey:.httpCompatibilityEnabled) ?? false;shadowrocket=try c.decodeIfPresent(ShadowrocketConfiguration.self,forKey:.shadowrocket);schemaVersion=try c.decodeIfPresent(Int.self,forKey:.schemaVersion) ?? 1
        nodes=try c.decodeIfPresent([Node].self,forKey:.nodes) ?? [];subscriptions=try c.decodeIfPresent([Subscription].self,forKey:.subscriptions) ?? [];rules=try c.decodeIfPresent([RoutingRule].self,forKey:.rules) ?? []
        let old=try decoder.container(keyedBy:LegacyKeys.self);mode=try c.decodeIfPresent(ProxyMode.self,forKey:.mode) ?? ((try old.decodeIfPresent(Bool.self,forKey:.rulesEnabled) ?? true) ? .rule : .global)
        listenPort=try c.decodeIfPresent(Int.self,forKey:.listenPort) ?? 7890;selectedID=try c.decodeIfPresent(UUID.self,forKey:.selectedID);selectedPolicy=try c.decodeIfPresent(PolicyReference.self,forKey:.selectedPolicy)
        groups=try c.decodeIfPresent([PolicyGroup].self,forKey:.groups) ?? [];remoteRules=try c.decodeIfPresent([RemoteRuleSource].self,forKey:.remoteRules) ?? [];favorites=try c.decodeIfPresent(Set<UUID>.self,forKey:.favorites) ?? [];latency=try c.decodeIfPresent([String:LatencyResult].self,forKey:.latency) ?? [:];ruleFinal=try c.decodeIfPresent(PolicyReference.self,forKey:.ruleFinal)
        addressFamilyPolicy=try c.decodeIfPresent(AddressFamilyPolicy.self,forKey:.addressFamilyPolicy);captureMode=try c.decodeIfPresent(CaptureMode.self,forKey:.captureMode) ?? .systemProxy;dnsPreference=try c.decodeIfPresent(DNSPreference.self,forKey:.dnsPreference) ?? .httpsProxy;notes=try c.decodeIfPresent([String:String].self,forKey:.notes) ?? [:];recentUse=try c.decodeIfPresent([String:Date].self,forKey:.recentUse) ?? [:];compactNodes=try c.decodeIfPresent(Bool.self,forKey:.compactNodes) ?? false;shortcutEnabled=try c.decodeIfPresent(Bool.self,forKey:.shortcutEnabled) ?? false;shortcutKey=try c.decodeIfPresent(UInt32.self,forKey:.shortcutKey) ?? 35;shortcutModifiers=try c.decodeIfPresent(UInt32.self,forKey:.shortcutModifiers) ?? 2304;protectedDomains=try c.decodeIfPresent([String].self,forKey:.protectedDomains) ?? [];tunExcludedCIDRs=try c.decodeIfPresent([String].self,forKey:.tunExcludedCIDRs) ?? []
        if let items=try c.decodeIfPresent([NetworkBypass].self,forKey:.networkBypasses) {networkBypasses=try NetworkBypassPolicy.normalize(items)}
        autoConnect=try c.decodeIfPresent(Bool.self,forKey:.autoConnect) ?? false;loginAtStartup=try c.decodeIfPresent(Bool.self,forKey:.loginAtStartup) ?? false
    }
    public func label(_ ref:PolicyReference?) -> String {
        guard let ref else {return "未选择"}
        switch ref {case .node(let id):return nodes.first{$0.id==id}?.name ?? "节点已移除";case .group(let id):return groups.first{$0.id==id}?.name ?? "分组已移除";case .automatic:return "自动选择";case .selected:return "当前选择";case .direct:return "直连";case .reject:return "拒绝"}
    }
}
public enum UpdateSchedule {
    public static func due(updatedAt:Date?,enabled:Bool,pending:Bool=false,retryCount:Int=0,retryAfter:Date?=nil,now:Date=Date()) -> Bool {
        guard enabled,!pending else{return false}
        if retryCount>0 {return retryAfter.map{$0<=now} == true}
        return updatedAt.map{now.timeIntervalSince($0)>=86400} ?? true
    }
    public static func nextRetry(_ count:Int,now:Date=Date()) -> Date? {guard (1...3).contains(count) else{return nil};return now.addingTimeInterval([60.0,300,1800][count-1])}
}
public protocol CredentialStore: AnyObject {
    func get(_ ref: String) throws -> String
    func set(_ value: String, for ref: String) throws
    func remove(_ ref: String) throws
}
public final class MemoryCredentials: CredentialStore {
    private var values: [String:String] = [:]
    public init() {}
    public func get(_ ref: String) throws -> String { guard let v = values[ref] else { throw ProxyError("凭据不存在，请重新导入节点") }; return v }
    public func set(_ value: String, for ref: String) throws { values[ref] = value }
    public func remove(_ ref: String) throws { values.removeValue(forKey: ref) }
}
public enum Redactor {
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var value = text
        for secret in secrets.sorted(by: {$0.count > $1.count}) where !secret.isEmpty { value = value.replacingOccurrences(of: secret, with: "[已隐藏]") }
        let patterns = [#"(?i)(?:https?|hy2|hysteria2|ss|trojan|vless)://[^\s\"<>]+"#, #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, #"(?i)(password|token|authorization|auth)\s*[:=]\s*[^\s,]+"#]
        for p in patterns { value = value.replacingOccurrences(of: p, with: "[已隐藏]", options: .regularExpression) }
        return String(value.prefix(2048))
    }
}
