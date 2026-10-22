import Foundation
import QingzhouKit

@main struct BypassTrafficFixture {
    static func main() throws {
        let args=CommandLine.arguments
        guard args.count==5,let listen=Int(args[2]),let control=Int(args[3]) else {throw ProxyError("隔离流量夹具参数无效")}
        var state=AppState();state.listenPort=listen;state.mode = .global;state.addressFamilyPolicy = .dualStack
        let node=try NodeParser.parse("ss://aes-128-gcm:isolated@127.0.0.1:9")
        let credentials=MemoryCredentials();try credentials.set(node.secret,for:node.node.credentialRef)
        state.nodes=[node.node];state.selectedID=node.node.id
        let enabled=args[4]=="enabled"
        try state.setBypasses([NetworkBypass(kind:.cidr,value:"127.0.0.1",enabled:enabled),NetworkBypass(kind:.cidr,value:"::1",enabled:enabled)])
        let data=try ConfigBuilder.build(state:state,credentials:credentials,control:CoreControlContext(port:control,secret:String(repeating:"a",count:64)))
        try data.write(to:URL(fileURLWithPath:args[1]))
    }
}
