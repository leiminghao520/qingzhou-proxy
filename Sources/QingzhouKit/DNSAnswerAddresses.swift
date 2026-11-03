import Foundation
import Darwin

extension DNSPacket {
    // 只采纳问题域名或其 CNAME 链的回答，避免附加段将无关地址加入保护路由。
    public static func addresses(_ data:Data) throws -> [String] {
        let bytes=[UInt8](data)
        guard bytes.count>=12 else {throw ProxyError("DNS 回答过短")}
        func word(_ at:Int)->Int {Int(bytes[at])<<8 | Int(bytes[at+1])}
        func name(_ start:Int) throws -> (String,Int) {
            var at=start,end:Int?,seen=Set<Int>(),labels:[String]=[]
            while at<bytes.count,seen.insert(at).inserted,seen.count<128 {
                let length=Int(bytes[at]);at+=1
                if length==0 {return (labels.joined(separator:".").lowercased(),end ?? at)}
                if length&0xc0==0xc0 {
                    guard at<bytes.count else {break}
                    if end==nil {end=at+1};at=((length&0x3f)<<8)|Int(bytes[at]);continue
                }
                guard length<=63,at+length<=bytes.count,let part=String(bytes:bytes[at..<at+length],encoding:.utf8) else {break}
                labels.append(part);at+=length
            }
            throw ProxyError("DNS 域名编码无效")
        }
        guard word(4)==1,word(6)<=256 else {throw ProxyError("DNS 回答数量无效")}
        let question=try name(12);var offset=question.1+4
        guard offset<=bytes.count else {throw ProxyError("DNS 问题截断")}
        var aliases:[(String,String)]=[],records:[(String,String)]=[]
        for _ in 0..<word(6) {
            let owner=try name(offset);offset=owner.1
            guard offset+10<=bytes.count else {throw ProxyError("DNS 记录截断")}
            let type=word(offset),klass=word(offset+2),length=word(offset+8);offset+=10
            guard offset+length<=bytes.count else {throw ProxyError("DNS 地址截断")}
            if klass==1 && type==5 {let alias=try name(offset);guard alias.1<=offset+length else {throw ProxyError("DNS 别名长度异常")};aliases.append((owner.0,alias.0))}
            if klass==1 && ((type==1 && length==4) || (type==28 && length==16)) {
                var output=[CChar](repeating:0,count:Int(INET6_ADDRSTRLEN))
                let raw=Array(bytes[offset..<offset+length]);let result=raw.withUnsafeBytes{inet_ntop(type==1 ? AF_INET:AF_INET6,$0.baseAddress,&output,socklen_t(output.count))}
                guard result != nil else {throw ProxyError("DNS 地址无效")};records.append((owner.0,String(cString:output)))
            }
            offset+=length
        }
        var allowed:Set<String>=[question.0]
        for _ in 0..<aliases.count {for (owner,target) in aliases where allowed.contains(owner) {allowed.insert(target)}}
        return Array(Set(records.filter{allowed.contains($0.0)}.map(\.1))).sorted()
    }
}
