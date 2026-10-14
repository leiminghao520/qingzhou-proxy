import Foundation
import Darwin

public enum DNSPacket {
    public static func name(_ data:Data)->String? {
        let bytes=[UInt8](data);guard bytes.count>=17,bytes[2]&0x80==0,bytes[4]==0,bytes[5]==1 else{return nil}
        var offset=12;var labels:[String]=[]
        while offset<bytes.count {
            let length=Int(bytes[offset]);offset+=1
            if length==0 {guard offset+4<=bytes.count else{return nil};return labels.joined(separator:".").lowercased()}
            guard length<=63,offset+length<=bytes.count,let label=String(bytes:bytes[offset..<offset+length],encoding:.utf8),!label.contains(".") else{return nil}
            labels.append(label);offset+=length
            if labels.joined(separator:".").utf8.count>253 {return nil}
        }
        return nil
    }
    public static func failure(_ query:Data)->Data {var bytes=[UInt8](query);if bytes.count>=12 {bytes[2]=(bytes[2]|0x80)&0xfd;bytes[3]=(bytes[3]&0xf0)|2;for i in 6..<12 {bytes[i]=0}};return Data(bytes)}
    public static func acceptable(_ response:Data,query:Data)->Bool {
        guard response.count>=12,query.count>=12,response[0]==query[0],response[1]==query[1],response[2]&0x80 != 0 else{return false}
        let code=response[3]&15;return code != 2 && code != 5
    }
}
// 转发器只监听回环；按原 DNS 作用域选择接口，企业域名绝不退回公共解析器。
public final class ScopedDNSForwarder {
    public let port:Int
    private let descriptor:Int32
    private let plan:CapturePlan
    private let transport:((Data,String,String)->Data?)?
    private let limit=DispatchSemaphore(value:32)
    private let lock=NSLock()
    private var stopped=false
    private var started=false
    public init(plan:CapturePlan,transport:((Data,String,String)->Data?)?=nil) throws {
        self.plan=plan;self.transport=transport
        let fd=socket(AF_INET,SOCK_DGRAM,0);guard fd>=0 else{throw ProxyError("DNS 转发监听创建失败")}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        guard result==0,withUnsafeMutablePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&size)}})==0 else{close(fd);throw ProxyError("DNS 回环监听失败")}
        descriptor=fd;port=Int(UInt16(bigEndian:address.sin_port))
        var timeout=timeval(tv_sec:1,tv_usec:0);_ = setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
    }
    deinit {if !started {close(descriptor)}}
    public func start() {lock.lock();guard !started,!stopped else{lock.unlock();return};started=true;lock.unlock();DispatchQueue.global().async{[self] in receive()}}
    public func stop() {lock.lock();stopped=true;lock.unlock()}
    private var isStopped:Bool {lock.lock();defer{lock.unlock()};return stopped}
    private func receive() {
        defer{lock.lock();close(descriptor);lock.unlock()}
        while !isStopped {
            var buffer=[UInt8](repeating:0,count:65535);var sender=sockaddr_storage();var size=socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count=withUnsafeMutablePointer(to:&sender){$0.withMemoryRebound(to:sockaddr.self,capacity:1){recvfrom(descriptor,&buffer,buffer.count,0,$0,&size)}}
            guard count>0 else{continue};let query=Data(buffer.prefix(count));guard let name=DNSPacket.name(query) else{continue}
            guard limit.wait(timeout:.now()) == .success else{continue}
            DispatchQueue.global().async{[self,sender,size] in
                defer{limit.signal()};let response=resolve(query,name:name);var peer=sender
                lock.lock();defer{lock.unlock()};guard !stopped else{return}
                _=response.withUnsafeBytes{bytes in withUnsafePointer(to:&peer){$0.withMemoryRebound(to:sockaddr.self,capacity:1){sendto(descriptor,bytes.baseAddress,response.count,0,$0,size)}}}
            }
        }
    }
    public func resolve(_ query:Data,name:String,exchange:((Data,String,String)->Data?)?=nil)->Data {
        let deadline=Date().addingTimeInterval(5)
        for resolver in plan.resolvers(for:name) {for server in resolver.servers {
            guard Date()<deadline else{return DNSPacket.failure(query)}
            if let response=(exchange ?? transport ?? Self.exchange)(query,server,resolver.interface),DNSPacket.acceptable(response,query:query){return response}
        }}
        return DNSPacket.failure(query)
    }
    public func probe(_ resolver:DNSResolverScope)->Bool {
        let query=Data([0x71,0x7a,1,0,0,1,0,0,0,0,0,0,0,0,2,0,1])
        for server in resolver.servers {if let response=(transport ?? Self.exchange)(query,server,resolver.interface),DNSPacket.acceptable(response,query:query) {return true}}
        return false
    }
    private static func exchange(_ query:Data,_ server:String,_ interface:String)->Data? {
        let ipv6=server.contains(":");let family=ipv6 ? AF_INET6:AF_INET
        var storage=sockaddr_storage();var size:socklen_t=0
        if ipv6 {
            var address=sockaddr_in6();address.sin6_len=UInt8(MemoryLayout<sockaddr_in6>.size);address.sin6_family=sa_family_t(AF_INET6);address.sin6_port=UInt16(53).bigEndian;address.sin6_scope_id=server.lowercased().hasPrefix("fe80:") ? if_nametoindex(interface):0
            guard server.components(separatedBy:"%")[0].withCString({inet_pton(AF_INET6,$0,&address.sin6_addr)})==1 else{return nil}
            size=socklen_t(MemoryLayout<sockaddr_in6>.size);withUnsafeMutableBytes(of:&storage){destination in withUnsafeBytes(of:&address){destination.copyBytes(from:$0)}}
        }else{
            var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(53).bigEndian
            guard server.withCString({inet_pton(AF_INET,$0,&address.sin_addr)})==1 else{return nil}
            size=socklen_t(MemoryLayout<sockaddr_in>.size);withUnsafeMutableBytes(of:&storage){destination in withUnsafeBytes(of:&address){destination.copyBytes(from:$0)}}
        }
        func connected(_ type:Int32)->Int32? {
            let fd=socket(family,type,0);guard fd>=0 else{return nil}
            var index=if_nametoindex(interface);var timeout=timeval(tv_sec:1,tv_usec:0);var noSignal:Int32=1
            guard index>0,setsockopt(fd,ipv6 ? IPPROTO_IPV6:IPPROTO_IP,ipv6 ? IPV6_BOUND_IF:IP_BOUND_IF,&index,socklen_t(MemoryLayout<UInt32>.size))==0 else{close(fd);return nil}
            _=setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
            _=setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));_=setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
            // TCP 连接使用非阻塞等待，避免企业解析器不可达时耗尽启动预算。
            if type==SOCK_STREAM {_=fcntl(fd,F_SETFL,O_NONBLOCK)}
            let result=withUnsafePointer(to:&storage){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,size)}}
            if result != 0 {
                guard type==SOCK_STREAM,errno==EINPROGRESS else{close(fd);return nil}
                var event=pollfd(fd:fd,events:Int16(POLLOUT),revents:0);var error:Int32=0;var length=socklen_t(MemoryLayout<Int32>.size)
                guard poll(&event,1,1000)>0,getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length)==0,error==0 else{close(fd);return nil}
            }
            if type==SOCK_STREAM {_=fcntl(fd,F_SETFL,0)}
            return fd
        }
        guard let udp=connected(SOCK_DGRAM) else{return nil};defer{close(udp)}
        guard query.withUnsafeBytes({Darwin.send(udp,$0.baseAddress,query.count,0)})==query.count else{return nil}
        var buffer=[UInt8](repeating:0,count:65535);let count=recv(udp,&buffer,buffer.count,0);guard count>=12 else{return nil}
        let response=Data(buffer.prefix(count));guard response[2]&2 != 0 else{return response}
        guard let tcp=connected(SOCK_STREAM) else{return nil};defer{close(tcp)}
        let packet=Data([UInt8(query.count>>8),UInt8(query.count&255)])+query
        var sent=0
        while sent<packet.count {let count=packet.withUnsafeBytes{Darwin.send(tcp,$0.baseAddress!.advanced(by:sent),packet.count-sent,0)};guard count>0 else{return nil};sent+=count}
        func read(_ length:Int)->Data? {var data=Data(count:length);var offset=0;while offset<length {let count=data.withUnsafeMutableBytes{recv(tcp,$0.baseAddress!.advanced(by:offset),length-offset,0)};guard count>0 else{return nil};offset+=count};return data}
        guard let header=read(2) else{return nil};return read(Int(header[0])*256+Int(header[1]))
    }
}
