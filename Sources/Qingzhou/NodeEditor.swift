import SwiftUI
import QingzhouKit
struct NodeEditor: View {
    @ObservedObject var model: AppModel
    let node: Node?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = ProxyKind.hysteria2
    @State private var host = ""
    @State private var port = "443"
    @State private var secret = ""
    @State private var method = "aes-128-gcm"
    @State private var parameters = ""
    @State private var obfsSecret = ""
    @State private var error: String?
    @State private var insecureConfirmed = false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(node == nil ? "手动添加节点" : "编辑节点").font(.title2.bold())
            Form {
                TextField("名称",text:$name)
                Picker("协议",selection:$kind) {ForEach(ProxyKind.allCases,id:\.self) {Text($0.rawValue).tag($0)}}
                TextField("服务器",text:$host)
                TextField("端口",text:$port)
                if kind == .shadowsocks {Picker("加密方法",selection:$method) {ForEach(["aes-128-gcm","aes-256-gcm","chacha20-ietf-poly1305"],id:\.self) {Text($0).tag($0)}}}
                SecureField(kind == .vless ? "UUID" : "认证 / 密码",text:$secret)
                SecureField("混淆密码（仅 Hysteria2）",text:$obfsSecret)
                Text("高级参数，每行 key=value；例如 sni=example.com。密码请填上面的安全输入框。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text:$parameters).font(.system(.caption,design:.monospaced)).frame(height:100)
                Toggle("若配置跳过证书验证，我确认保留该设置",isOn:$insecureConfirmed)
            }
            if let error {Text(error).foregroundStyle(.red).font(.caption)}
            HStack {Button("取消") {dismiss()};Spacer();Button("保存") {save()}.buttonStyle(.borderedProminent).disabled(model.locked)}
        }.padding(26).frame(width:590)
        .onAppear {
            guard let node else {return}
            name = node.name;kind = node.kind;host = node.server;port = String(node.port);method = node.parameters["method"] ?? "aes-128-gcm"
            parameters = node.parameters.filter {$0.key != "method"}.sorted {$0.key < $1.key}.map {"\($0.key)=\($0.value)"}.joined(separator:"\n")
            do {secret = try model.credentials.get(node.credentialRef);obfsSecret = (try? model.credentials.get(node.credentialRef + ".obfs")) ?? ""} catch {self.error = error.localizedDescription}
        }
    }
    private func save() {
        do {
            var c = URLComponents();c.scheme = kind == .shadowsocks ? "ss" : kind.rawValue;c.host = host;c.port = Int(port);c.fragment = name
            if kind == .shadowsocks {c.user = method;c.password = secret} else {c.user = secret}
            var items: [URLQueryItem] = []
            for line in parameters.components(separatedBy:.newlines).filter({!$0.trimmingCharacters(in:.whitespaces).isEmpty}) {guard let i = line.firstIndex(of:"=") else {throw ProxyError("高级参数必须为 key=value")};items.append(URLQueryItem(name:String(line[..<i]).trimmingCharacters(in:.whitespaces),value:String(line[line.index(after:i)...]).trimmingCharacters(in:.whitespaces)))}
            if !obfsSecret.isEmpty {items.append(URLQueryItem(name:"obfs-password",value:obfsSecret))}
            if !items.isEmpty {c.queryItems = items}
            guard let uri = c.string else {throw ProxyError("节点输入无效")}
            let candidate = try NodeParser.parse(uri)
            guard !candidate.node.insecure || insecureConfirmed else {throw ProxyError("请确认跳过证书验证设置")}
            Task {await model.saveManual(candidate,editingID:node?.id); if model.errorMessage == nil {dismiss()}}
        } catch {self.error = error.localizedDescription}
    }
}
