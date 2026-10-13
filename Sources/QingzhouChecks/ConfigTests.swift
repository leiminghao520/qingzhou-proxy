import Foundation
import QingzhouKit

final class ConfigTests: CheckCase {
    func build(_ uri:String,state:AppState = AppState()) throws -> [String:Any] {
        let candidate = try NodeParser.parse(uri);let credentials = MemoryCredentials();try credentials.set(candidate.secret,for:candidate.node.credentialRef)
        if let obfs = candidate.obfsSecret {try credentials.set(obfs,for:candidate.node.credentialRef + ".obfs")}
        return try JSONSerialization.jsonObject(with:ConfigBuilder.build(node:candidate.node,state:state,credentials:credentials)) as! [String:Any]
    }
    func testHysteriaPreservesUserpassAndObfs() throws {
        let config = try build("hy2://user%3Apassword@example.com?obfs=salamander&obfs-password=xyz&mport=443,5000-5010&upmbps=20")
        let outbound = (config["outbounds"] as! [[String:Any]])[0]
        expectEqual(outbound["password"] as? String,"user:password");expectEqual(outbound["server_ports"] as? [String],["443:443","5000:5010"]);expectNil(outbound["server_port"]);expectEqual((outbound["obfs"] as? [String:String])?["password"],"xyz")
        let inbound = (config["inbounds"] as! [[String:Any]])[0];expectEqual(inbound["listen"] as? String,"127.0.0.1");expectEqual(inbound["set_system_proxy"] as? Bool,false)
    }
    func testProtocolConfigurations() throws {
        let id = "12345678-1234-1234-1234-123456789abc"
        let uris = ["ss://aes-128-gcm:p@example.com:8388", "trojan://p@example.com?sni=example.com&alpn=h2", "vless://\(id)@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&fp=chrome", "vless://\(id)@example.com:443?security=reality&sni=example.com&pbk=\(String(repeating:"a",count:43))&sid=abcd&flow=xtls-rprx-vision"]
        for uri in uris {let config = try build(uri);expectEqual((config["outbounds"] as! [[String:Any]])[0]["tag"] as? String,"proxy")}
    }
    func testRulesAndModes() throws {
        var state = AppState();state.rules = [RoutingRule(kind:.domain,value:"example.com",action:.reject),RoutingRule(kind:.suffix,value:"example.org",action:.direct),RoutingRule(kind:.cidr,value:"192.0.2.0/24",action:.proxy)]
        let config = try build("hy2://p@example.com",state:state);let route = config["route"] as! [String:Any];let rules = route["rules"] as! [[String:Any]]
        expectEqual(rules.count,5);expectEqual(rules[2]["action"] as? String,"reject");expectEqual(route["final"] as? String,"proxy")
        state.rulesEnabled = false;let all = try build("hy2://p@example.com",state:state);expectEqual(((all["route"] as! [String:Any])["rules"] as! [[String:Any]]).count,0)
        state.listenPort = 0;expectThrows(try build("hy2://p@example.com",state:state))
    }
    func testRuleValidation() throws {
        for value in ["192.0.2.0/24","::1/128","127.0.0.1","2001:db8::/32"] {try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:value,action:.direct))}
        for value in ["", " example.com", "a b", "*.example.com"] {expectThrows(try ConfigBuilder.validate(RoutingRule(kind:.domain,value:value,action:.direct)))}
        for value in ["192.0.2.0/33","::1/129","999.1.1.1","1.1.1.1/", "1.1.1.1/24/2"] {expectThrows(try ConfigBuilder.validate(RoutingRule(kind:.cidr,value:value,action:.direct)))}
    }
    func testCoreCheckAllSupportedConfigs() throws {
        let binary = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/sing-box")
        let id = "12345678-1234-1234-1234-123456789abc"
        let uris = ["hy2://user%3Ap@example.com?sni=example.com", "hy2://p@example.com?obfs=salamander&obfs-password=o&mport=443,5000-5010", "ss://aes-128-gcm:p@example.com:8388", "ss://aes-256-gcm:p@example.com:8388", "ss://chacha20-ietf-poly1305:p@example.com:8388", "trojan://p@example.com", "vless://\(id)@example.com:443", "vless://\(id)@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&fp=chrome", "vless://\(id)@example.com:443?security=reality&sni=example.com&pbk=\(String(repeating:"a",count:43))&sid=abcd&flow=xtls-rprx-vision"]
        var state = AppState();state.rules = [RoutingRule(kind:.domain,value:"blocked.example",action:.reject),RoutingRule(kind:.suffix,value:"direct.example",action:.direct),RoutingRule(kind:.cidr,value:"192.0.2.0/24",action:.proxy)]
        for uri in uris {
            let config = try build(uri,state:state);let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json");defer {try? FileManager.default.removeItem(at:file)}
            try SecureFile.write(JSONSerialization.data(withJSONObject:config),to:file)
            let p = Process();p.executableURL = binary;p.arguments = ["check","-c",file.path];let pipe = Pipe();p.standardError = pipe;p.standardOutput = pipe;try p.run();p.waitUntilExit()
            let output = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
            expectEqual(p.terminationStatus,0,Redactor.redact(output))
        }
    }
}
