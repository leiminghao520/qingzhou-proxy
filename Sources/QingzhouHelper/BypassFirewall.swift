import Foundation
import QingzhouKit

extension Service {
    func firewall(_ arguments:[String]) throws -> String {
        try firewallCommand(arguments).components(separatedBy:.newlines).filter{!["No ALTQ support in kernel","ALTQ related functions disabled"].contains($0)}.joined(separator:"\n")
    }
    func installBypassFirewall(_ state:AppState) throws {
        guard !state.pinnedBypasses.isEmpty else{return}
        let routes=try PinnedBypassPolicy.routes(state.pinnedBypasses,services:bypassServicesRead())
        try PinnedBypassPolicy.validateFirewallRoot(firewall(["-sr"]))
        let children=try firewall(["-a","com.apple","-s","Anchors"]).trimmingCharacters(in:.whitespacesAndNewlines)
        guard children.isEmpty else {throw ProxyError("系统保护锚点已有其他组件，无法确认拒绝规则优先级；未覆盖现有防火墙")}
        let anchor="com.apple/qingzhou-"+UUID().uuidString.lowercased()
        let file=root.appendingPathComponent("bypass-firewall.conf")
        try SecureFile.write(Data(PinnedBypassPolicy.firewallRules(routes).utf8),to:file)
        _=try firewall(["-n","-a",anchor,"-f",file.path])
        journal?.firewall=BypassFirewallLease(anchor:anchor);try save()
        _=try firewall(["-a",anchor,"-f",file.path])
        let applied=try firewall(["-a",anchor,"-sr"])
        guard !applied.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw ProxyError("指定出口拒绝规则读取为空，未应用路由")}
        journal?.firewall?.expectedRules=applied;try save()
        let enabled=try firewall(["-E"])
        guard let row=enabled.components(separatedBy:.newlines).first(where:{$0.contains("Token")}),let token=row.split(whereSeparator:{$0.isWhitespace || $0==":"}).last,UInt64(token) != nil else {throw ProxyError("无法取得防火墙启用凭据，保留恢复记录")}
        journal?.firewall?.token=String(token);try save()
        // 只清理受管目标的旧状态，防止此前的跨接口状态越过新拒绝规则。
        for route in routes {_=try firewall(["-k",route.ipv6 ? "::/0":"0.0.0.0/0","-k",route.destination])}
        try verifyBypassFirewall()
        pinnedPaths=routes
    }
    func verifyBypassFirewall() throws {
        guard let lease=journal?.firewall else {return}
        try PinnedBypassPolicy.validateFirewallRoot(firewall(["-sr"]))
        let status=try firewall(["-si"])
        guard status.contains("Status: Enabled"),let expected=lease.expectedRules,try firewall(["-a",lease.anchor,"-sr"])==expected else {throw ProxyError("指定出口拒绝保护已被外部修改，不能确认生效")}
    }
    func restoreBypassFirewall() throws {
        guard let lease=journal?.firewall else{return}
        guard lease.anchor.range(of:"^com\\.apple/qingzhou-[0-9a-f-]{36}$",options:.regularExpression) != nil else {throw ProxyError("拒绝保护恢复记录的锚点标识无效")}
        let current=try firewall(["-a",lease.anchor,"-sr"])
        if !current.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            guard current==lease.expectedRules else {throw ProxyError("拒绝保护已有外部修改或写入状态不明，未清理该锚点；恢复记录已保留")}
            _=try firewall(["-a",lease.anchor,"-F","rules"])
            guard try firewall(["-a",lease.anchor,"-sr"]).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw ProxyError("拒绝保护清理后仍有规则")}
        }
        if let token=lease.token {guard UInt64(token) != nil else {throw ProxyError("拒绝保护启用凭据无效")};_=try firewall(["-X",token])}
        journal?.firewall=nil;try save()
    }
    func startPinnedBypasses(_ request:TunRequest,fd:Int32) throws {
        guard journal==nil,process==nil,let state=request.state,!state.pinnedBypasses.isEmpty else {throw ProxyError("指定出口会话无效或存在待恢复记录")}
        try PolicyValidator.validate(state)
        // 独立路由会话不修改系统 DNS，仍使用统一恢复日志记录拥有的路由及防火墙。
        routeTransaction=UUID();configureRouteCancellation(fd)
        let key=NetworkInspection.tunDNSKey(UUID())
        journal=Journal(transactionID:routeTransaction,pinnedOnly:true,dnsKey:key,previousDNS:nil,expectedDNS:try PropertyListSerialization.data(fromPropertyList:[:],format:.binary,options:0),address4:"",address6:"");try save()
        try installBypassFirewall(state)
        owner=fd;activeRequest=request;phase="active"
        try reconcilePinnedRoutes(state)
        startPinnedMonitor(state)
    }
    func reconcilePinnedRoutes(_ state:AppState) throws {
        try verifyBypassFirewall()
        let services=bypassServicesRead()
        var unavailable:[String]=[]
        for (item,path) in zip(state.pinnedBypasses,pinnedPaths) {
            guard let service=services.first(where:{$0.id==item.serviceID}),service.interface==path.interface,service.active else {unavailable.append(item.value+"：指定网卡未就绪，拒绝其他出口");continue}
            let gateway=try routeInfo(path.gateway,ipv6:path.ipv6,scope:path.interface)
            guard field("interface",gateway)==path.interface else {throw ProxyError("网关不能从指定接口到达："+path.gateway)}
            try addRoute(path.destination,path.gateway,path.interface,ipv6:path.ipv6)
        }
        if !unavailable.isEmpty {lastFailure=unavailable.joined(separator:"；")}
        else if lastFailure?.contains("指定网卡") == true {lastFailure=nil}
    }
    func startPinnedMonitor(_ state:AppState) {
        guard !state.pinnedBypasses.isEmpty else{return}
        pinnedMonitor?.cancel()
        let timer=DispatchSource.makeTimerSource(queue:queue);pinnedMonitor=timer
        timer.schedule(deadline:.now()+1,repeating:1)
        timer.setEventHandler{[weak self] in
            guard let self,self.journal != nil else{return}
            do {try self.reconcilePinnedRoutes(state)}catch {self.lastFailure="指定出口验证失败："+error.localizedDescription}
        };timer.resume()
    }
}
