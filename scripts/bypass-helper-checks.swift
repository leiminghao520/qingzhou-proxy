import Foundation
import QingzhouKit

// 链接正式拒绝保护及路由写入实现，所有管理员命令均替换为内存夹具。
struct OwnedRoute:Codable {var destination:String;var gateway:String;var interface:String;var ipv6:Bool;var scope:String?=nil}
struct Journal {
    var interface:String?=nil
    var transactionID:UUID?
    var pinnedOnly:Bool?
    var firewall:BypassFirewallLease?
    var dnsKey:String
    var previousDNS:Data?
    var expectedDNS:Data
    var address4:String
    var address6:String
    var routes:[OwnedRoute]=[]
}
final class Service {
    var routeTransaction=UUID()
    func configureRouteCancellation(_ fd:Int32) {}
    func checkRouteOwner() throws {}
    func measured<T>(_ name:String,_ body:() throws -> T) rethrows -> T {try body()}
    func sampledRoutes() throws -> NetworkRouteSample {try routeSample()}
    let root:URL
    let queue=DispatchQueue(label:"qingzhou.bypass.fixture")
    var journal:Journal?
    var pinnedPaths:[ProtectedRoute]=[]
    var pinnedMonitor:DispatchSourceTimer?
    var process:Process?
    var owner:Int32?
    var activeRequest:TunRequest?
    var phase="idle"
    var lastFailure:String?
    var saves=0
    var writes=0
    var table:[ProtectedRoute]=[]
    var firewallCommand:([String]) throws -> String={_ in fatalError("夹具禁止真实管理员命令")}
    var bypassServicesRead:()->[BypassNetworkService] = {[]}
    init(root:URL) {self.root=root}
    func save() throws {saves += 1}
    func field(_ label:String,_ text:String)->String? {label=="gateway" ? NetworkInspection.routeGateway(text):NetworkInspection.routeField(label,text)}
    func prefix(_ info:String)->String? {NetworkInspection.routePrefix(destination:field("destination",info),mask:field("mask",info),host:info.contains("HOST"))}
    func routeInfo(_ destination:String,ipv6:Bool,scope:String?=nil,deadline:Date?=nil) throws -> String {
        let route=table.first{NetworkInspection.samePrefix($0.destination,destination)}
        let gateway=route?.gateway ?? (scope=="en6" ? "13.2.4.254":"192.168.1.1")
        let interface=route?.interface ?? scope ?? "en0"
        let exists=route != nil || scope != nil
        return "destination: \(exists ? destination.split(separator:"/")[0]:"default")\nmask: \(exists ? "255.255.255.255":"0.0.0.0")\ngateway: \(gateway)\ninterface: \(interface)\nflags: <UP,GATEWAY\(exists ? ",HOST":"")\(scope != nil ? ",IFSCOPE":"")>"
    }
    func routeSample() throws -> NetworkRouteSample {
        try NetworkRouteSample(read:{"Internet:\ndefault 192.168.1.1 UGSc en0\n"+self.table.map{$0.destination+" "+$0.gateway+" UGHS "+$0.interface}.joined(separator:"\n")})
    }
    func writeRoute(_ args:[String],deadline:Date?) throws -> String {
        writes += 1
        guard let route=journal?.routes.last else {throw ProxyError("路由意图未持久化")}
        table.append(ProtectedRoute(destination:route.destination,gateway:route.gateway,interface:route.interface,scope:route.scope))
        return "add host: gateway: fixture"
    }
}
final class FirewallFixture {
    var rules=""
    var enabled=false
    var root="anchor \"com.apple/*\" all\n"
    var children=""
    var commands:[[String]]=[]
    var failLoad=false
    func run(_ args:[String]) throws -> String {
        commands.append(args)
        if args==["-sr"] {return root}
        if args==["-a","com.apple","-s","Anchors"] {return children}
        if args.contains("-n") {return ""}
        if args.contains("-f") {if failLoad {throw ProxyError("注入加载失败")};rules="block drop out quick on ! en6 inet from any to 13.2.34.203/32\npass out quick on en6 inet from any to 13.2.34.203/32 no state\n";return ""}
        if args.contains("-sr") {return rules}
        if args==["-E"] {enabled=true;return "pf enabled\nToken : 12345\n"}
        if args==["-si"] {return enabled ? "Status: Enabled":"Status: Disabled"}
        if args.first=="-k" {return "0 states killed"}
        if args.contains("-F") {rules="";return ""}
        if args==["-X","12345"] {enabled=false;return ""}
        throw ProxyError("夹具未允许的管理员命令")
    }
}
@main struct BypassHelperChecks {
    static var assertions=0
    static var failures=0
    static func check(_ condition:Bool,_ message:String) {assertions += 1;if !condition {failures += 1;print("FAIL "+message)}}
    static func rejects(_ body:() throws -> Void,_ message:String) {do {try body();check(false,message)}catch{check(true,message)}}
    static func main() throws {
        let directory=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("qingzhou-bypass-helper-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let service=Service(root:directory),firewall=FirewallFixture()
        service.firewallCommand=firewall.run
        var active=true
        service.bypassServicesRead={[BypassNetworkService(id:"bank",name:"银行网卡",interface:"en6",active:active)]}
        var state=AppState();try state.setBypasses([NetworkBypass(kind:.cidr,value:"13.2.34.203",exit:.pinned,serviceID:"bank",gateway:"13.2.4.254")])
        try service.startPinnedBypasses(TunRequest(operation:"pinBypasses",state:state),fd:99)
        service.pinnedMonitor?.cancel();service.pinnedMonitor=nil
        check(service.journal?.pinnedOnly==true,"独立路由会话")
        check(service.owner==99,"控制通道归属")
        check(service.journal?.routes.count==1 && service.writes==1,"写入前记录路由意图")
        check(service.journal?.firewall?.token=="12345","启用凭据已保存")
        check(firewall.commands.contains(["-k","0.0.0.0/0","-k","13.2.34.203/32"]),"仅清理受管目标的旧连接状态")
        try service.reconcilePinnedRoutes(state)
        check(service.writes==1,"已有相同路由不重复写入")
        active=false;service.table=[]
        try service.reconcilePinnedRoutes(state)
        check(service.writes==1,"掉线不向其他接口写路由")
        check(!firewall.rules.isEmpty && firewall.enabled,"掉线时拒绝规则始终保留")
        check(service.lastFailure?.contains("拒绝其他出口")==true,"掉线状态明确可见")
        active=true;try service.reconcilePinnedRoutes(state)
        check(service.writes==2,"恢复后重新核验并补齐路由")
        check(service.lastFailure==nil,"恢复后清除掉线状态")
        firewall.rules += "# external-change\n"
        rejects({try service.verifyBypassFirewall()},"外部改写不能视为已验证")
        rejects({try service.restoreBypassFirewall()},"恢复不覆盖外部改写")
        check(service.journal?.firewall != nil,"冲突保留恢复记录")
        firewall.rules=service.journal!.firewall!.expectedRules!
        try service.restoreBypassFirewall()
        check(firewall.rules.isEmpty && !firewall.enabled,"仅释放本次锚点和启用凭据")
        check(service.journal?.firewall==nil,"恢复完成清理拥有记录")
        firewall.root="anchor \"com.sangfor.vpn\" all\n"
        let before=service.writes
        rejects({try service.installBypassFirewall(state)},"企业防火墙不兼容必须拒绝应用")
        check(service.writes==before && service.journal?.firewall==nil,"不兼容环境不写路由和防火墙")
        firewall.root="anchor \"com.apple/*\" all\n";firewall.children="external-anchor"
        rejects({try service.installBypassFirewall(state)},"存在其他锚点不能猜测优先级")
        firewall.children="";firewall.failLoad=true
        rejects({try service.installBypassFirewall(state)},"加载失败明确报告")
        check(service.journal?.firewall != nil,"加载失败保留写入意图")
        try service.restoreBypassFirewall()
        check(service.journal?.firewall==nil,"空锚点可以回滚")
        // 原有外部同出口路由只核验，不写入拥有列表。
        service.journal?.routes=[];service.table=[ProtectedRoute(destination:"13.2.34.203/32",gateway:"13.2.4.254",interface:"en6")]
        try service.addRoute("13.2.34.203/32","13.2.4.254","en6",ipv6:false)
        check(service.journal?.routes.isEmpty==true,"不认领既有外部路由")
        service.table=[ProtectedRoute(destination:"13.2.34.203/32",gateway:"192.168.1.1",interface:"en0")]
        rejects({try service.addRoute("13.2.34.203/32","13.2.4.254","en6",ipv6:false)},"冲突外部路由不覆盖")
        print("RESULT bypass_helper_assertions=\(assertions) failures=\(failures)")
        if failures>0 {exit(1)}
    }
}
