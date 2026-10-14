import Foundation
import Darwin
import QingzhouKit

@MainActor func runPortReuseChecks() {
    let listener=socket(AF_INET,SOCK_STREAM,0);expectTrue(listener>=0);guard listener>=0 else{return};
    var reuse:Int32=1;expectEqual(setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&reuse,socklen_t(MemoryLayout<Int32>.size)),0)
    var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
    expectEqual(withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}},0)
    expectEqual(listen(listener,1),0)
    var length=socklen_t(MemoryLayout<sockaddr_in>.size)
    expectEqual(withUnsafeMutablePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(listener,$0,&length)}},0)
    let port=Int(UInt16(bigEndian:address.sin_port))
    expectFalse(CoreController.portAvailable(port),"活动监听不能被判定为空闲")
    let client=socket(AF_INET,SOCK_STREAM,0);defer{close(client)}
    expectEqual(withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(client,$0,length)}},0)
    let accepted=accept(listener,nil,nil);expectTrue(accepted>=0)
    close(accepted);var byte:UInt8=0;expectEqual(read(client,&byte,1),0)
    shutdown(listener,SHUT_RDWR);close(listener)
    expectTrue(CoreController.portAvailable(port),"关闭后 TCP 等待状态不能阻止重新连接")
    expectTrue(CoreController.portAvailable(port),"连续重连检查不能占用端口")
    print("PASS PortReuse.activeListenerAndTimeWait")
}
