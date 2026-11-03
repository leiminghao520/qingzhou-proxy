import Foundation
import Mobile
import Darwin

final class ProbeHost:NSObject,QZMobileHostProtocol {
    func isExtension()->Bool {false}
    func protectSocket(_ fd:Int32)throws {}
    func openTun(_ options:String?,ret0_:UnsafeMutablePointer<Int32>?)throws {throw NSError(domain:"Qingzhou",code:40)}
    func interfaces(_ error:NSErrorPointer)->String {do{return try interfacesValue()}catch let failure{error?.pointee=failure as NSError;return ""}}
    func defaultInterface(_ error:NSErrorPointer)->String {
        do {let raw=try interfacesValue();let rows=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [[String:Any]];let first=rows.sorted{($0["Name"] as! String)<($1["Name"] as! String)}.first;let result:[String:Any]=["Name":first?["Name"] ?? "","Index":first?["Index"] ?? -1,"Expensive":first?["Metered"] ?? false,"Constrained":false];return String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!}
        catch let failure{error?.pointee=failure as NSError;return ""}
    }
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
