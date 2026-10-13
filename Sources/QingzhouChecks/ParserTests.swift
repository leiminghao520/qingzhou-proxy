import Foundation
import QingzhouKit

final class ParserTests: CheckCase {
    func testHysteriaAuthenticationAndIPv6() throws {
        let candidate = try NodeParser.parse("hysteria2://user%3Ap%40ss%3Aword@[::1]:443/?sni=example.com#%E6%B5%8B%E8%AF%95")
        expectEqual(candidate.secret,"user:p@ss:word"); expectEqual(candidate.node.server,"::1"); expectEqual(candidate.node.name,"测试"); expectFalse(candidate.node.insecure)
        let short = try NodeParser.parse("hy2://user:password@example.com?sni=example.com&insecure=true&obfs=salamander&obfs-password=obfs123&mport=443,5000-5010&upmbps=10&downmbps=20")
        expectEqual(short.secret,"user:password"); expectEqual(short.node.port,443); expectTrue(short.node.insecure); expectEqual(short.obfsSecret,"obfs123")
        expectNil(short.node.parameters["obfs-password"])
    }
    func testShadowsocksEncoding() throws {
        for method in ["aes-128-gcm","aes-256-gcm","chacha20-ietf-poly1305"] {
            let auth = Data("\(method):pa:ss@word".utf8).base64EncodedString()
            let c = try NodeParser.parse("ss://\(auth)@example.com:8388#SS")
            expectEqual(c.secret,"pa:ss@word"); expectEqual(c.node.parameters["method"],method)
        }
        let legacy = Data("aes-128-gcm:password@example.com:8388".utf8).base64EncodedString()
        expectEqual(try NodeParser.parse("ss://\(legacy)#legacy").secret,"password")
        expectEqual(try NodeParser.parse("ss://aes-128-gcm:password@example.com:8388").secret,"password")
    }
    func testTrojanAndVless() throws {
        expectEqual(try NodeParser.parse("trojan://p%3Ass@example.com?peer=example.com&allowInsecure=0").secret,"p:ss")
        let id = "12345678-1234-1234-1234-123456789abc"
        let ws = try NodeParser.parse("vless://\(id)@example.com:443?type=ws&security=tls&path=%2Fproxy&host=example.com&fp=chrome&encryption=none&alpn=h2,http%2F1.1")
        expectEqual(ws.node.parameters["path"],"/proxy")
        let reality = try NodeParser.parse("vless://\(id)@example.com:443?security=reality&pbk=\(String(repeating:"a",count:43))&sid=abcd&sni=example.com&flow=xtls-rprx-vision")
        expectEqual(reality.node.parameters["flow"],"xtls-rprx-vision")
    }
    func testInvalidInputsAreRejectedWithoutSecrets() {
        let id = "12345678-1234-1234-1234-123456789abc"
        let bad = ["", "[General]\nloglevel=info", "https://secret-token@example.com/sub", "hy2://@example.com", "hy2://secret@example.com:0", "hy2://secret@example.com:65536", "hy2://secret@example.com?unknown=1", "hy2://secret@example.com?sni=a&peer=b", "hy2://secret@example.com?insecure=maybe", "hy2://secret@example.com?obfs=salamander", "hy2://secret@example.com?obfs-password=p", "hy2://secret@example.com?mport=5000-4000", "hy2://secret@example.com?upmbps=-1", "hy2://secret@example.com/path", "ss://broken@example.com:8388", "ss://rc4:secret@example.com:8388", "ss://aes-128-gcm:secret@example.com:8388?plugin=v2ray", "trojan://secret@example.com?type=ws", "vless://invalid@example.com:443", "vless://\(id)@example.com:443?security=reality", "vless://\(id)@example.com:443?type=grpc", "vless://\(id)@example.com:443?flow=xtls-rprx-vision", "vless://\(id)@example.com:443?host=example.com", "vless://\(id)@example.com:443?security=tls&fp=bad"]
        for input in bad { expectThrows(try NodeParser.parse(input),input) {error in expectFalse(error.localizedDescription.contains("secret"))} }
    }
    func testListIsAtomicAndBounded() throws {
        expectEqual(try NodeParser.parseList("#注释\n\nhy2://p@example.com\r\nhy2://p@example.org").count,2)
        expectThrows(try NodeParser.parseList("hy2://p@example.com\n[General]")) {expectTrue($0.localizedDescription.hasPrefix("第 2 行"))}
        expectThrows(try NodeParser.parseList("#只有注释"))
        expectThrows(try NodeParser.parseList(Array(repeating:"hy2://p@example.com",count:2001).joined(separator:"\n")))
        expectThrows(try NodeParser.parse("hy2://" + String(repeating:"x",count:17000)))
    }
    func testPortRanges() throws {
        for s in ["443","443,5000-5010","1-65535"] {try NodeParser.validatePorts(s)}
        for s in ["","0","65536","443,","-1","5-3","1-2-3"] {expectThrows(try NodeParser.validatePorts(s))}
    }
    func testRedaction() {
        let input = "https://example.com/sub/private-token hy2://user:password@host password=abc 12345678-1234-1234-1234-123456789abc raw-secret"
        let output = Redactor.redact(input,secrets:["raw-secret"])
        for sensitive in ["private-token","password@","abc","12345678","raw-secret"] {expectFalse(output.contains(sensitive))}
        expectAtMost(Redactor.redact(String(repeating:"x",count:3000)).count,2048)
    }
}
