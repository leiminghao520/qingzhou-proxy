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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(node == nil ? "手动添加代理节点" : "编辑代理节点", systemImage: "network")
                    .font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Form {
                Section("基础配置") {
                    TextField("节点显示名称", text: $name)
                    Picker("代理协议类型", selection: $kind) {
                        ForEach(ProxyKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue.uppercased()).tag(kind)
                        }
                    }
                    HStack {
                        TextField("服务器域名 / IP", text: $host)
                        TextField("端口", text: $port)
                            .frame(width: 80)
                    }
                }
                
                Section("认证凭据") {
                    if kind == .shadowsocks {
                        Picker("加密算法", selection: $method) {
                            ForEach(["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                    }
                    SecureField(kind == .vless ? "UUID 标识符" : "认证密码 / Token", text: $secret)
                    if kind == .hysteria2 {
                        SecureField("混淆密码 (Obfs Password，选填)", text: $obfsSecret)
                    }
                }
                
                Section("高级参数") {
                    Text("每行一个 key=value 参数，例如 sni=yourdomain.com、alpn=h3。密码请填入上方安全框。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $parameters)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 70)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    Toggle("若此节点配置了跳过 TLS 证书校验，我已知晓并确认保留", isOn: $insecureConfirmed)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            
            if let error {
                Text(error)
                    .foregroundStyle(Theme.dangerRed)
                    .font(.caption)
            }
            
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("保存节点") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.locked || host.isEmpty || name.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 600, height: 560)
        .onAppear {
            guard let node else { return }
            name = node.name
            kind = node.kind
            host = node.server
            port = String(node.port)
            method = node.parameters["method"] ?? "aes-128-gcm"
            parameters = node.parameters.filter { $0.key != "method" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            do {
                secret = try model.credentials.get(node.credentialRef)
                obfsSecret = (try? model.credentials.get(node.credentialRef + ".obfs")) ?? ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
    
    private func save() {
        do {
            var c = URLComponents()
            c.scheme = kind == .shadowsocks ? "ss" : kind.rawValue
            c.host = host
            c.port = Int(port)
            c.fragment = name
            if kind == .shadowsocks {
                c.user = method
                c.password = secret
            } else {
                c.user = secret
            }
            var items: [URLQueryItem] = []
            for line in parameters.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                guard let i = line.firstIndex(of: "=") else { throw ProxyError("高级参数必须为 key=value 格式") }
                items.append(URLQueryItem(
                    name: String(line[..<i]).trimmingCharacters(in: .whitespaces),
                    value: String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                ))
            }
            if !obfsSecret.isEmpty {
                items.append(URLQueryItem(name: "obfs-password", value: obfsSecret))
            }
            if !items.isEmpty { c.queryItems = items }
            guard let uri = c.string else { throw ProxyError("节点格式无效") }
            let candidate = try NodeParser.parse(uri)
            guard !candidate.node.insecure || insecureConfirmed else { throw ProxyError("请确认跳过证书验证设置") }
            Task {
                if await model.saveManual(candidate, editingID: node?.id) { dismiss() } else {error=model.errorMessage}
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
