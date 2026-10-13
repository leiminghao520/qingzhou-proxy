import Foundation
import Yams

public enum ProfileImporter {
    private static func containsAliases(_ text:String) -> Bool {
        let bytes=Array(text.utf8);var i=0,quote:UInt8=0;var comment=false
        let separators:Set<UInt8>=[9,10,13,32,91,123,44,58]
        while i<bytes.count {
            let b=bytes[i]
            if comment {if b==10{comment=false};i+=1;continue}
            if quote==34 {if b==92{i+=2;continue};if b==34{quote=0};i+=1;continue}
            if quote==39 {if b==39 {if i+1<bytes.count && bytes[i+1]==39{i+=2;continue};quote=0};i+=1;continue}
            let boundary=i==0 || separators.contains(bytes[i-1])
            if b==35 && boundary{comment=true;i+=1;continue}
            if (b==34 || b==39) && boundary{quote=b;i+=1;continue}
            if (b==38 || b==42) && boundary && i+1<bytes.count {let next=bytes[i+1];if (48...57).contains(next) || (65...90).contains(next) || (97...122).contains(next) || next==95 || next==45{return true}}
            i+=1
        }
        return false
    }
    public static func yaml(_ text:String) throws -> Any {
        // 限制别名和锚点，避免小输入通过重复引用展开成巨大对象。
        guard !containsAliases(text) else {throw ProxyError("YAML 锚点和别名暂不支持")}
        do {guard let value=try Yams.load(yaml:text) else {throw ProxyError("配置为空")};return value} catch {throw ProxyError("YAML 解析失败，请检查格式")}
    }
    public static func parse(_ input:String) throws -> ImportPreview {
        guard input.utf8.count<=2*1024*1024 else {throw ProxyError("导入内容超过 2 MiB")}
        let text=input.replacingOccurrences(of:"\u{feff}",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
        let first=text.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespaces)}.first{!$0.isEmpty && !$0.hasPrefix("#")} ?? ""
        if ["hy2://","hysteria2://","ss://","trojan://","vless://"].contains(where:{first.lowercased().hasPrefix($0)}) {return ImportPreview(candidates:try NodeParser.parseList(text))}
        let compact=text.filter{!$0.isWhitespace};var padded=compact.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");padded+=String(repeating:"=",count:(4-padded.count%4)%4)
        if let data=Data(base64Encoded:padded),let decoded=String(data:data,encoding:.utf8),["hy2://","hysteria2://","ss://","trojan://","vless://"].contains(where:{decoded.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix($0)}) {return ImportPreview(candidates:try NodeParser.parseList(decoded))}
        guard let root=try yaml(text) as? [String:Any],let entries=root["proxies"] as? [[String:Any]] else {throw ProxyError("需要节点链接列表或包含 proxies 的 Clash/Mihomo YAML")}
        guard entries.count<=2000 else {throw ProxyError("节点数量超过 2000")}
        var result=ImportPreview(candidates:[])
        for (i,entry) in entries.enumerated() {do {result.candidates.append(try convertNode(entry))} catch {result.unsupported.append("节点 \(i+1)："+Redactor.redact(error.localizedDescription))}}
        let nodeNames=result.candidates.map{$0.node.name}
        if Set(nodeNames).count != nodeNames.count {result.unsupported.append("节点名称重复，策略引用存在歧义")}
        let rawGroups=root["proxy-groups"] as? [[String:Any]] ?? []
        guard rawGroups.count<=200 else {throw ProxyError("策略组超过 200")}
        var definitions:[(String,UUID,[String:Any])]=[]
        for entry in rawGroups {guard let name=entry["name"] as? String,!name.isEmpty else {result.unsupported.append("策略组缺少名称");continue};if definitions.contains(where:{$0.0==name}) || nodeNames.contains(name) {result.unsupported.append("策略组名称重复或与节点重名");continue};definitions.append((name,UUID(),entry))}
        func resolve(_ name:String) throws -> PolicyReference {
            if name.uppercased()=="DIRECT" {return .direct};if name.uppercased()=="REJECT" {return .reject}
            if let node=result.candidates.first(where:{$0.node.name==name}) {return .node(node.node.id)}
            if let group=definitions.first(where:{$0.0==name}) {return .group(group.1)}
            throw ProxyError("配置引用了不存在的节点或策略")
        }
        for (_,id,entry) in definitions {
            do {
                guard let name=entry["name"] as? String,let type=entry["type"] as? String,let members=entry["proxies"] as? [String],!members.isEmpty else {throw ProxyError("策略组格式无效")}
                guard ["select","url-test"].contains(type) else {throw ProxyError("仅支持 select 和 url-test 策略组")}
                let unknown=Set(entry.keys).subtracting(["name","type","proxies","url","interval","tolerance","lazy","icon"])
                guard unknown.isEmpty else {throw ProxyError("策略组含有不支持的参数")}
                if entry["url"] != nil || entry["interval"] != nil || entry["tolerance"] != nil {result.ignored.append("策略测速统一使用应用的检测页、5 分钟间隔和 50 ms 容差")}
                let refs=try members.map(resolve);guard !refs.contains(.reject) else {throw ProxyError("策略组中的 REJECT 成员暂不支持，请使用拒绝规则")}
                result.groups.append(PolicyGroup(id:id,name:name,kind:type=="select" ? .select : .urltest,members:refs,selected:refs.first))
            } catch {result.unsupported.append("策略组："+Redactor.redact(error.localizedDescription))}
        }
        if let rows=root["rules"] as? [String] {
            guard rows.count<=50000 else {throw ProxyError("规则超过 50000 条")}
            var sawMatch=false
            for (i,row) in rows.enumerated() {
                do {
                    let parts=row.split(separator:",",omittingEmptySubsequences:false).map{$0.trimmingCharacters(in:.whitespaces)}
                    if parts.first?.uppercased()=="MATCH" {guard parts.count==2,!sawMatch,i==rows.count-1 else {throw ProxyError("MATCH 必须唯一且位于最后")};result.final=try resolve(parts[1]);sawMatch=true;continue}
                    guard parts.count==3 || (parts.count==4 && parts[3]=="no-resolve") else {throw ProxyError("规则格式不支持")}
                    let target=try resolve(parts[2]);var rule=try RemoteRulesParser.clashCondition(parts[0],parts[1]);rule.action=target == .direct ? .direct : target == .reject ? .reject : .proxy;rule.target=target;result.rules.append(rule)
                } catch {result.unsupported.append("规则 \(i+1)："+Redactor.redact(error.localizedDescription))}
            }
        } else if root["rules"] != nil {result.unsupported.append("rules 必须为字符串列表")}
        let ignored:Set<String>=["port","socks-port","mixed-port","redir-port","tproxy-port","allow-lan","bind-address","external-controller","secret","external-ui","mode","log-level","ipv6","profile","unified-delay","tcp-concurrent"]
        let supported:Set<String>=["proxies","proxy-groups","rules"]
        for key in root.keys.sorted() where !supported.contains(key) {if ignored.contains(key) {result.ignored.append("未接管配置项："+key)} else {result.unsupported.append("完整导入暂不支持配置项："+key)}}
        var state=AppState();state.nodes=result.candidates.map(\.node);state.groups=result.groups;state.rules=result.rules;state.ruleFinal=result.final
        do {try PolicyValidator.validate(state)} catch {result.unsupported.append(Redactor.redact(error.localizedDescription))}
        result.ignored=Array(Set(result.ignored)).sorted()
        return result
    }
    private static func convertNode(_ p:[String:Any]) throws -> Candidate {
        guard let type=p["type"] as? String,let name=p["name"] as? String,let server=p["server"] as? String,let port=(p["port"] as? NSNumber)?.intValue,(1...65535).contains(port) else {throw ProxyError("名称、协议、地址或端口缺失")}
        var allowed:Set<String>=["name","type","server","port","udp"]
        var scheme=type,user="",password:String?;var params:[String:String]=[:]
        func string(_ key:String) throws -> String {guard let value=p[key] as? String,!value.isEmpty else {throw ProxyError("必需协议字段缺失")};return value}
        if let value=p["skip-cert-verify"] as? Bool {params["insecure"]=value ? "1" : "0"}
        if let sni=(p["sni"] ?? p["servername"]) as? String {params["sni"]=sni}
        if let alpn=p["alpn"] as? [String] {params["alpn"]=alpn.joined(separator:",")}
        switch type {
        case "hysteria2":
            allowed.formUnion(["password","sni","skip-cert-verify","alpn","obfs","obfs-password","ports","up","down"]);user=try string("password")
            for key in ["obfs","obfs-password"] {if let value=p[key] as? String {params[key]=value}}
            if let ports=p["ports"] as? String {params["mport"]=ports}
            for (key,target) in [("up","upmbps"),("down","downmbps")] {if let value=p[key] {let text=String(describing:value).replacingOccurrences(of:"Mbps",with:"",options:.caseInsensitive).trimmingCharacters(in:.whitespaces);guard Int(text) != nil else {throw ProxyError("Hysteria2 带宽参数不支持")};params[target]=text}}
        case "ss":scheme="ss";allowed.formUnion(["cipher","password"]);user=try string("cipher");password=try string("password")
        case "trojan":allowed.formUnion(["password","sni","skip-cert-verify","alpn","network"]);user=try string("password");if let network=p["network"] as? String {params["type"]=network}
        case "vless":
            allowed.formUnion(["uuid","tls","servername","sni","skip-cert-verify","alpn","network","flow","reality-opts","client-fingerprint","ws-opts"]);user=try string("uuid");params["security"]=(p["tls"] as? Bool)==true ? "tls" : "none"
            if let value=p["network"] as? String {params["type"]=value};if let value=p["flow"] as? String {params["flow"]=value};if let value=p["client-fingerprint"] as? String {params["fp"]=value}
            if let reality=p["reality-opts"] as? [String:Any] {guard Set(reality.keys).isSubset(of:["public-key","short-id"]),let key=reality["public-key"] as? String else {throw ProxyError("Reality 参数无效")};params["security"]="reality";params["pbk"]=key;if let id=reality["short-id"] as? String,!id.isEmpty {params["sid"]=id}}
            if let ws=p["ws-opts"] as? [String:Any] {guard Set(ws.keys).isSubset(of:["path","headers"]) else {throw ProxyError("WebSocket 参数不支持")};params["type"]="ws";params["path"]=ws["path"] as? String ?? "/";if let headers=ws["headers"] as? [String:String] {guard Set(headers.keys.map{$0.lowercased()}).isSubset(of:["host"]) else {throw ProxyError("仅支持 WebSocket Host 请求头")};params["host"]=headers.first{$0.key.lowercased()=="host"}?.value}}
        default:throw ProxyError("节点协议暂不支持")
        }
        guard Set(p.keys).isSubset(of:allowed) else {throw ProxyError("节点含有不支持的协议参数")}
        var c=URLComponents();c.scheme=scheme;c.host=server;c.port=port;c.user=user;c.password=password;c.fragment=name
        if !params.isEmpty {c.queryItems=params.sorted{$0.key<$1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}}
        guard let uri=c.string else {throw ProxyError("节点格式无效")};return try NodeParser.parse(uri)
    }
}
