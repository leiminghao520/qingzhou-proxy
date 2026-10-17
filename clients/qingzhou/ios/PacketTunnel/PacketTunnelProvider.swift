import Foundation
import Network
import NetworkExtension
import Mobile
import Darwin

final class PacketTunnelProvider: NEPacketTunnelProvider, QZMobileHostProtocol {
    private let worker=DispatchQueue(label:"cn.qingzhou.tunnel")
    private let monitor=NWPathMonitor()
    private let pathLock=NSLock()
    private var path: Network.NWPath?
    private var session: QZMobileSession?
    private var watchdog:DispatchSourceTimer?
    override func startTunnel(options:[String:NSObject]?,completionHandler:@escaping(Error?)->Void) {
        guard let account=options?["requestAccount"] as? String else {completionHandler(NSError(domain:"Qingzhou",code:1));return}
        do {let data=try TunnelSecrets.consume(account);guard let request=String(data:data,encoding:.utf8),let root=FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:TunnelSecrets.group) else {throw NSError(domain:"Qingzhou",code:2)}
            let firstPath=DispatchSemaphore(value:0)
            monitor.pathUpdateHandler={ [weak self] path in guard let self else{return};self.pathLock.lock();self.path=path;self.pathLock.unlock();firstPath.signal()}
            monitor.start(queue:DispatchQueue(label:"cn.qingzhou.path"))
            worker.async {
                do {guard firstPath.wait(timeout:.now()+10) == .success else {throw NSError(domain:"Qingzhou",code:3)}
                    var error:NSError?
                    guard let core=QZMobileNewSession(root.appendingPathComponent("runtime").path,self,&error) else {throw error ?? NSError(domain:"Qingzhou",code:4)}
                    self.session=core;try core.start(request)
                    let watchdog=DispatchSource.makeTimerSource(queue:self.worker);watchdog.schedule(deadline:.now()+2,repeating:2);watchdog.setEventHandler{[weak self] in if self?.session?.running() == false {self?.cancelTunnelWithError(NSError(domain:"Qingzhou",code:20))}};self.watchdog=watchdog;watchdog.resume()
                    completionHandler(nil)
                } catch {try? self.session?.stop();self.session=nil;self.monitor.cancel();completionHandler(NSError(domain:"Qingzhou",code:5))}
            }
        } catch {completionHandler(NSError(domain:"Qingzhou",code:6))}
    }
    override func stopTunnel(with reason:NEProviderStopReason,completionHandler:@escaping()->Void) {
        worker.async {self.watchdog?.cancel();self.watchdog=nil;try? self.session?.stop();self.session=nil;self.monitor.cancel();self.setTunnelNetworkSettings(nil){_ in completionHandler()}}
    }
    override func handleAppMessage(_ messageData:Data,completionHandler:((Data?)->Void)?) {
        worker.async {
            var response:[String:Any]=[:]
            do {guard messageData.count<=4*1024*1024,let call=try JSONSerialization.jsonObject(with:messageData) as? [String:String],let core=self.session else {throw NSError(domain:"Qingzhou",code:7)}
                if call["method"] == "query" {var error:NSError?;let value=core.query(call["arguments"],error:&error);if let error{throw error};response["value"]=value}
                else if call["method"] == "delay" {var ms:Int64=0;try core.delay(call["arguments"],ret0_:&ms);let data=try JSONSerialization.data(withJSONObject:["milliseconds":ms]);response["value"]=String(data:data,encoding:.utf8)!}
                else if call["method"] == "select" {try core.select(call["arguments"])}
                else {throw NSError(domain:"Qingzhou",code:8)}
            } catch {response=["error":"扩展操作失败"]}
            completionHandler?(try? JSONSerialization.data(withJSONObject:response))
        }
    }
    func isExtension()->Bool {true}
    func openTun(_ options:String?,ret0_:UnsafeMutablePointer<Int32>?) throws {
        guard let options,let o=try JSONSerialization.jsonObject(with:Data(options.utf8)) as? [String:Any],let addresses=o["addresses"] as? [String],let dns=o["dns"] as? [String],(o["excludes"] as? [String] ?? []).isEmpty else {throw NSError(domain:"Qingzhou",code:9)}
        let settings=NEPacketTunnelNetworkSettings(tunnelRemoteAddress:"127.0.0.1");settings.mtu=o["mtu"] as? NSNumber ?? 1500
        let v4=addresses.filter{!$0.contains(":")}.map{$0.components(separatedBy:"/")}
        let v6=addresses.filter{$0.contains(":")}.map{$0.components(separatedBy:"/")}
        if !v4.isEmpty {let ip=NEIPv4Settings(addresses:v4.map{$0[0]},subnetMasks:v4.map{mask(Int($0[1])!)});ip.includedRoutes=[NEIPv4Route.default()];settings.ipv4Settings=ip}
        if !v6.isEmpty {let ip=NEIPv6Settings(addresses:v6.map{$0[0]},networkPrefixLengths:v6.map{NSNumber(value:Int($0[1])!)});ip.includedRoutes=[NEIPv6Route.default()];settings.ipv6Settings=ip}
        settings.dnsSettings=NEDNSSettings(servers:dns);settings.dnsSettings?.matchDomains=[""]
        if o["httpProxy"] as? Bool == true,let port=o["httpPort"] as? Int {let proxy=NEProxySettings();proxy.httpEnabled=true;proxy.httpsEnabled=true;proxy.httpServer=NEProxyServer(address:"127.0.0.1",port:port);proxy.httpsServer=NEProxyServer(address:"127.0.0.1",port:port);proxy.matchDomains=[""];settings.proxySettings=proxy}
        let done=DispatchSemaphore(value:0);var failure:Error?
        setTunnelNetworkSettings(settings){error in failure=error;done.signal()}
        guard done.wait(timeout:.now()+15) == .success else {throw NSError(domain:"Qingzhou",code:10)}
        if let failure {throw failure};let fd=QZMobileTunnelFD();guard fd>=0 else {throw NSError(domain:"Qingzhou",code:11)};ret0_?.pointee=fd
    }
    private func mask(_ n:Int)->String {let value:UInt32=n==0 ? 0 : UInt32.max << (32-n);return [24,16,8,0].map{String((value>>$0)&255)}.joined(separator:".")}
    func protectSocket(_ fd:Int32)throws {
        pathLock.lock();let interface=path?.availableInterfaces.first;pathLock.unlock()
        guard let interface else {throw NSError(domain:"Qingzhou",code:12)}
        var index=UInt32(interface.index);var address=sockaddr_storage();var length=socklen_t(MemoryLayout<sockaddr_storage>.size)
        let family=withUnsafeMutablePointer(to:&address){ptr -> Int32 in ptr.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&length)}}
        guard family==0 else {throw NSError(domain:"Qingzhou",code:13)}
        let result=setsockopt(fd,address.ss_family==AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP,address.ss_family==AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF,&index,socklen_t(MemoryLayout<UInt32>.size))
        guard result==0 else {throw NSError(domain:"Qingzhou",code:14)}
    }
    func defaultInterface(_ error:NSErrorPointer)->String {do{return try defaultInterfaceValue()}catch let failure {error?.pointee=failure as NSError;return ""}}
    private func defaultInterfaceValue()throws->String {
        pathLock.lock();defer{pathLock.unlock()}
        let i=path?.availableInterfaces.first
        return String(data:try JSONSerialization.data(withJSONObject:["Name":i?.name ?? "","Index":i?.index ?? -1,"Expensive":path?.isExpensive ?? false,"Constrained":path?.isConstrained ?? false]),encoding:.utf8)!
    }
    func interfaces(_ error:NSErrorPointer)->String {do{return try interfacesValue()}catch let failure {error?.pointee=failure as NSError;return ""}}
    private func interfacesValue()throws->String {
        var first:UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first)==0 else {throw NSError(domain:"Qingzhou",code:15)};defer{freeifaddrs(first)}
        var rows:[String:[String:Any]]=[:];var cursor=first
        while let item=cursor {defer{cursor=item.pointee.ifa_next};guard let address=item.pointee.ifa_addr,let namePointer=item.pointee.ifa_name else{continue};let family=address.pointee.sa_family;let name=String(cString:namePointer)
            guard (family==AF_INET||family==AF_INET6),!name.hasPrefix("utun"),name != "lo0",item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else {continue}
            var buffer=[CChar](repeating:0,count:Int(NI_MAXHOST));guard getnameinfo(address,socklen_t(address.pointee.sa_len),&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST)==0 else{continue}
            var prefix=0;if let netmask=item.pointee.ifa_netmask {let offset=family==AF_INET ? MemoryLayout<sockaddr_in>.offset(of:\.sin_addr)! : MemoryLayout<sockaddr_in6>.offset(of:\.sin6_addr)!;let count=family==AF_INET ? 4:16;let bytes=UnsafeRawPointer(netmask).advanced(by:offset).assumingMemoryBound(to:UInt8.self);for n in 0..<count{prefix+=bytes[n].nonzeroBitCount}}
            let text=String(cString:buffer).components(separatedBy:"%")[0]+"/\(prefix)"
            var row=rows[name] ?? ["Name":name,"Index":if_nametoindex(name),"MTU":1500,"Addresses":[String](),"DNS":[String](),"Type":name.hasPrefix("pdp_ip") ? 2:1,"Metered":name.hasPrefix("pdp_ip")]
            row["Addresses"]=(row["Addresses"] as! [String])+[text];rows[name]=row
        }
        return String(data:try JSONSerialization.data(withJSONObject:Array(rows.values)),encoding:.utf8)!
    }
}
