import SwiftUI
import AppKit
import CoreImage
import Charts
import QingzhouKit

// MARK: - Profiles View
struct ProfilesView: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var office = ""
    @State private var copy = false
    @State private var officeTemplate=OfficeSceneTemplate.bank
    @State private var officeCIDRs=""
    @State private var officeTargets=""
    @State private var officeDNS=DNSPreference.system
    @State private var backup = false
    @State private var historyProfile: UUID?
    @State private var showingHistory = false
    @State private var renaming: ClientProfile?
    @State private var rename = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "配置方案管理",
                subtitle: "每份配置独立保存节点、订阅、策略与分流规则。连接中切换配置采用原子校验与回滚保障。",
                actionTitle: "备份与恢复",
                actionIcon: "externaldrive.badge.icloud"
            ) {
                backup = true
            }
            
            // 单份配置的历史入口
            Button("查看全部历史（含已删除配置）") { historyProfile=nil;showingHistory=true }
            // 配置列表
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.profiles) { profile in
                        let isCurrent = model.currentProfileID == profile.id
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isCurrent ? Theme.connectedGreen.opacity(0.15) : Color.secondary.opacity(0.1))
                                    .frame(width: 44, height: 44)
                                Image(systemName: isCurrent ? "checkmark.circle.fill" : "folder.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(isCurrent ? Theme.connectedGreen : Color.secondary)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(profile.name)
                                        .font(.headline)
                                    if isCurrent {
                                        Text("当前运行配置")
                                            .font(.caption2.bold())
                                            .foregroundStyle(Theme.connectedGreen)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.connectedGreen.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(profile.configuration.nodes.count) 个节点 · \(profile.configuration.rules.count) 条规则 · \(profile.configuration.subscriptions.count) 个订阅")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 8) {
                                if !isCurrent {
                                    Button("应用并切换") {
                                        Task { await model.requestProfileChange(profile.id) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                
                                Button("查看历史") {historyProfile=profile.id;showingHistory=true}
                                Button("重命名") {
                                    rename = profile.name
                                    renaming = profile
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                
                                Button(role: .destructive) {
                                    Task { await model.deleteProfile(profile.id) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isCurrent)
                            }
                        }
                        .padding(14)
                        .background(Theme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                .stroke(isCurrent ? Theme.connectedGreen.opacity(0.4) : Theme.subtleBorder, lineWidth: isCurrent ? 1.5 : 1)
                        )
                    }
                }
            }
            .frame(minHeight: 180)
            .sheet(isPresented:$showingHistory) {ProfileHistoryView(model:model,profileID:historyProfile)}
            
            // Create Profile Card
            VStack(alignment: .leading, spacing: 14) {
                Text("新建配置方案")
                    .font(.headline)
                
                HStack(spacing: 12) {
                    TextField("配置方案名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                    
                    Toggle("从当前配置复制", isOn: $copy)
                        .toggleStyle(.checkbox)
                }
                
                if !copy {
                    Picker("场景模板",selection:$officeTemplate) {
                        ForEach(OfficeSceneTemplate.allCases,id:\.self) {Text($0.label).tag($0)}
                    }.pickerStyle(.segmented)
                    if officeTemplate == .bank {
                        TextField("内网域名（逗号分隔）",text:$office).textFieldStyle(.roundedBorder)
                        TextField("绕行 CIDR（逗号分隔，可留空）",text:$officeCIDRs).textFieldStyle(.roundedBorder)
                        TextField("常用目标域名或 IP（逗号分隔，可留空）",text:$officeTargets).textFieldStyle(.roundedBorder)
                        Picker("DNS 偏好",selection:$officeDNS) {Text("原系统解析").tag(DNSPreference.system);Text("外网通过代理 HTTPS DNS").tag(DNSPreference.httpsProxy)}
                        Text("常用目标默认跟随系统路由、HTTPS 443；创建后可在目标管理中设置端口与测试类型。").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("模板不含公司地址、节点或凭据，默认关闭自动连接。").font(.caption).foregroundStyle(.secondary)
                }
                
                Button {
                    Task {
                        model.errorMessage=nil
                        if copy {await model.createProfile(name:name,copy:true)}
                        else {
                            let split:(String)->[String] = {$0.split(whereSeparator:{$0=="," || $0=="\n"}).map{String($0).trimmingCharacters(in:.whitespaces)}}
                            let targets=split(officeTargets).map{SavedDiagnosticTarget(name:$0,host:$0)}
                            await model.createOfficeProfile(name:name,template:officeTemplate,domains:split(office),cidrs:split(officeCIDRs),dns:officeDNS,targets:targets)
                        }
                        if model.errorMessage == nil {name="";office="";officeCIDRs="";officeTargets=""}
                    }
                } label: {
                    Label("创建新配置", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.locked || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                    .stroke(Theme.subtleBorder, lineWidth: 1)
            )
        }
        .sheet(isPresented: $backup) { BackupView(model: model) }
        .sheet(item: $renaming) { profile in
            VStack(spacing: 18) {
                Text("修改配置名称").font(.headline)
                TextField("名称", text: $rename).textFieldStyle(.roundedBorder)
                HStack {
                    Button("取消") { renaming = nil }
                    Spacer()
                    Button("保存修改") {
                        Task {
                            await model.renameProfile(profile.id, name: rename)
                            if model.errorMessage == nil { renaming = nil }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
    }
}

// MARK: - Backup & Restore View
struct BackupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var snapshot: BackupSnapshot?
    @State private var message = ""
    @State private var working = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("本地加密备份与迁移", systemImage: "lock.shield.fill")
                    .font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Text("备份包含全部配置、策略、规则以及节点密码与订阅地址凭据。采用安全加密：AES-GCM · PBKDF2-SHA256 600,000 次，口令不会写入备份文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 12) {
                SecureField("输入备份或恢复口令", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("导出时请再次确认口令", text: $confirm)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack(spacing: 12) {
                Button("导出加密备份 (.qzb)") { export() }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || password != confirm || working)
                
                Button("打开备份文件并预览") { load() }
                    .buttonStyle(.bordered)
                    .disabled(password.isEmpty || working)
                
                Button("预览历史升级快照") {
                    do {
                        snapshot = try model.migrationSnapshot()
                        message = "已成功读取升级前快照，尚未写入现有配置。"
                    } catch {
                        message = "升级前快照不存在或无法解密；未修改现有数据。"
                    }
                }
                .buttonStyle(.bordered)
                .disabled(working)
            }
            
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    Text("快照恢复预览：共 \(snapshot.catalog.profiles.count) 份配置、\(snapshot.catalog.profiles.reduce(0) { $0 + $1.configuration.nodes.count }) 个节点。")
                        .font(.headline)
                        .foregroundStyle(Theme.accentBlue)
                    Text("确认恢复将安全替换当前配置集合，若执行启动失败将自动回滚上一份配置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 12) {
                        Button("导出 0.2 回退数据") {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "state-0.2.json"
                            panel.begin { response in
                                if response == .OK, let url = panel.url {
                                    do {
                                        try BackupService.exportLegacy(snapshot, to: url, credentials: model.credentials)
                                        message = "0.2 回退数据已导出。请另存当前 state.json 后替换。"
                                    } catch {
                                        message = Redactor.redact(error.localizedDescription)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        Button("确认恢复全部配置", role: .destructive) {
                            Task {
                                working = true
                                await model.restoreBackup(snapshot)
                                working = false
                                if model.errorMessage == nil {
                                    password = ""; confirm = ""; self.snapshot = nil
                                    dismiss()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            
            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在进行加解密运算，请稍候...").font(.caption)
                }
            }
            
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.amberAccent)
            }
        }
        .padding(26)
        .frame(width: 640)
    }
    
    private func export() {
        guard let store = model.store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "轻舟配置.qzb"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            working = true
            Task {
                do {
                    let value = try BackupService.snapshot(store.catalog, credentials: model.credentials)
                    let secret = password
                    let data = try await Task.detached { try BackupService.encrypt(value, password: secret) }.value
                    try SecureFile.write(data, to: url)
                    model.recordBackup(url)
                    message = "加密备份导出成功！"
                } catch {
                    message = Redactor.redact(error.localizedDescription)
                }
                working = false
            }
        }
    }
    
    private func load() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            working = true
            snapshot = nil
            Task {
                do {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
                    guard size <= 48 * 1024 * 1024 else { throw ProxyError("备份超过大小限制") }
                    let data = try Data(contentsOf: url)
                    let secret = password
                    snapshot = try await Task.detached { try BackupService.decrypt(data, password: secret) }.value
                    message = "口令校验通过，请预览并确认恢复。"
                } catch {
                    message = "备份无法读取、口令错误或文件损坏；未修改现有配置。"
                }
                working = false
            }
        }
    }
}

// 综合诊断界面
struct ComprehensiveDiagnosticsView: View {
    @ObservedObject var model: AppModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "系统与网络健康诊断",
                subtitle: "全链路分步检查代理核心、系统权限、端口绑定、TUN 路由、DNS 解析及连通性状态。"
            )
            
            HStack(spacing: 12) {
                Button {
                    Task { await model.diagnose() }
                } label: {
                    Label(model.diagnosing ? "诊断进行中..." : "一键开始诊断", systemImage: "stethoscope")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.locked || model.diagnosing)
                
                Button("停止诊断") {model.cancelDiagnostic()}.disabled(!model.diagnosing)
                Button("导出 JSON") {exportDiagnostic(json:true)}.disabled(model.diagnosticSession==nil)
                Button("恢复原网络设置") {
                    Task { await model.recover() }
                }
                .buttonStyle(.bordered)
                .disabled(model.loadingFailed || model.recovering)
                
                Spacer()
                
                Button {
                    exportDiagnostic(json:false)
                } label: {
                    Label("导出脱敏报告", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.diagnosticRows.isEmpty)
            }
            
            if !model.protectionSummary.isEmpty || !model.connectivityResults.isEmpty {
                DisclosureGroup("网络保护与连通性详情") {
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:6) {
                            ForEach(Array(model.protectionSummary.enumerated()),id:\.offset) {_,text in Text(text).textSelection(.enabled)}
                            ForEach(Array(model.connectivityResults.enumerated()),id:\.offset) {_,result in Text(result.summary).textSelection(.enabled)}
                        }.font(.caption).frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(maxHeight:220)
                }
            }

            if model.diagnosticRows.isEmpty {
                ContentUnavailableView(
                    "尚未执行诊断",
                    systemImage: "waveform.path.ecg",
                    description: Text("点击上方「一键开始诊断」检测核心组件、路由与网络连接状况。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(model.diagnosticRows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(statusColor(row.status).opacity(0.14))
                                        .frame(width: 32, height: 32)
                                    Image(systemName: statusIcon(row.status))
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(statusColor(row.status))
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(row.stage)
                                            .font(.headline)
                                        Spacer()
                                        Text(row.status)
                                            .font(.caption.bold())
                                            .foregroundStyle(statusColor(row.status))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(statusColor(row.status).opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                    Text(row.checkedAt.formatted()+" · "+(row.milliseconds.map{String($0)+" ms"} ?? "耗时未取得")).font(.caption2).foregroundStyle(.secondary)
                                    Text(row.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(14)
                            .background(Theme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                                    .stroke(Theme.subtleBorder, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }
    
    private func exportDiagnostic(json:Bool) {
        guard let session=model.diagnosticSession else{return}
        saveDiagnosticData(try? session.export(json:json),name:"轻舟诊断报告."+(json ? "json":"txt"))
    }
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "通过": return Theme.connectedGreen
        case "失败": return Theme.dangerRed
        case "需检查": return Theme.amberAccent
        default: return Color.secondary
        }
    }
    
    private func statusIcon(_ status: String) -> String {
        switch status {
        case "通过": return "checkmark"
        case "失败": return "xmark"
        case "需检查": return "exclamationmark"
        default: return "minus"
        }
    }
}

// MARK: - Rule Explanation Simulation View
struct RuleExplanationView: View {
    @ObservedObject var model: AppModel
    @State private var input = ""
    @State private var explanation: RuleExplanation?
    @State private var message = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "分流规则模拟匹配",
                subtitle: "输入域名或 IP 测试匹配链路与命中顺序（包含私网直连、自定义规则、远程规则集及默认兜底策略）。"
            )
            
            HStack(spacing: 10) {
                TextField("输入需要测试的域名或 IP 地址（例如 github.com, 1.1.1.1）", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { evaluate() }
                
                Button("开始测试") { evaluate() }
                    .buttonStyle(.borderedProminent)
            }
            
            if let explanation {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("命中策略结果：")
                            .font(.headline)
                        Text(explanation.target.map { model.state.label($0) } ?? "需要实际 DNS 结果后确定")
                            .font(.headline.bold())
                            .foregroundStyle(Theme.accentBlue)
                    }
                    
                    Divider()
                    
                    Text("判定执行链路：").font(.subheadline.bold())
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(explanation.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(index + 1).")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Text(step)
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    
                    if let limit = explanation.uncertainty {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                            Text(limit)
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.amberAccent)
                    }
                }
                .padding(16)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .stroke(Theme.subtleBorder, lineWidth: 1)
                )
            }
            
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.dangerRed)
            }
            
            Spacer()
        }
    }
    
    private func evaluate() {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            explanation = try RuleEvaluator.explain(input, state: model.state)
            message = ""
        } catch {
            explanation = nil
            message = error.localizedDescription
        }
    }
}

// MARK: - Share Node Modal
struct ShareRequest: Identifiable {
    let id = UUID()
    let node: Node
}

struct ShareView: View {
    @ObservedObject var model: AppModel
    let node: Node
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var link = ""
    @State private var qr: NSImage?
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分享节点")
                        .font(.title2.bold())
                    Text(node.name)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            if !acknowledged {
                VStack(spacing: 14) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Theme.amberAccent)
                    Text("安全提醒")
                        .font(.headline)
                    Text("分享链接与二维码内包含解密后的节点密码与服务器凭据。接收者将具备完全使用权限，请务必只分享给值得信赖的人。")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    
                    Button("确认生成安全二维码与分享链接") {
                        generate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            } else {
                VStack(spacing: 16) {
                    if let qr {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(14)
                        }
                        .frame(width: 240, height: 240)
                    }
                    
                    HStack(spacing: 12) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                        } label: {
                            Label("复制分享链接", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button {
                            saveImage()
                        } label: {
                            Label("保存二维码图片", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Text("关闭窗口后分享内容将从界面内存立即擦除。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(26)
        .frame(width: 520)
    }
    
    private func generate() {
        do {
            link = try NodeShare.link(node, credentials: model.credentials)
            let filter = CIFilter(name: "CIQRCodeGenerator")!
            filter.setValue(Data(link.utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            if let output = filter.outputImage,
               let cg = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) {
                qr = NSImage(cgImage: cg, size: NSSize(width: 280, height: 280))
            }
            acknowledged = true
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
    
    private func saveImage() {
        guard let qr,
              let tiff = qr.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(node.name)-二维码.png"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? SecureFile.write(png, to: url)
            }
        }
    }
}

// MARK: - 稳定的实时速率图表
struct RateChart: View {
    let samples: [RateSample]
    @State private var upperBound: Double = 1024

    // 固定三十分钟窗口，每分钟移动一次，避免每个样本都缩放时间轴。
    private var timeDomain: ClosedRange<Date> {
        let latest = samples.last?.time ?? Date()
        let end = Date(timeIntervalSince1970: (floor(latest.timeIntervalSince1970 / 60) + 1) * 60)
        return end.addingTimeInterval(-1800)...end
    }

    // 同一会话只按倍数扩展纵轴，不随瞬时速率上下收缩。
    private func updateScale() {
        guard !samples.isEmpty else { upperBound = 1024; return }
        let peak = Double(samples.map { max($0.upload, $0.download) }.max() ?? 0)
        if peak > upperBound {
            upperBound = pow(2, ceil(log2(max(1024, peak * 1.15))))
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("实时速率波动 (最近 30 分钟)", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.trafficUpload).frame(width: 7, height: 7)
                        Text("上传").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Theme.trafficDownload).frame(width: 7, height: 7)
                        Text("下载").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            
            if samples.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无网络速率数据，连接代理后实时绘制")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 155)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Chart {
                    ForEach(samples) { sample in
                        AreaMark(
                            x: .value("时间", sample.time),
                            y: .value("速率", sample.download),
                            series: .value("方向", "下载"),
                            stacking: .unstacked
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.trafficDownload.opacity(0.28), Theme.trafficDownload.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.linear)
                        
                        LineMark(
                            x: .value("时间", sample.time),
                            y: .value("速率", sample.download),
                            series: .value("方向", "下载")
                        )
                        .foregroundStyle(Theme.trafficDownload)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.linear)
                        
                        AreaMark(
                            x: .value("时间", sample.time),
                            y: .value("速率", sample.upload),
                            series: .value("方向", "上传"),
                            stacking: .unstacked
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.trafficUpload.opacity(0.25), Theme.trafficUpload.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.linear)
                        
                        LineMark(
                            x: .value("时间", sample.time),
                            y: .value("速率", sample.upload),
                            series: .value("方向", "上传")
                        )
                        .foregroundStyle(Theme.trafficUpload)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                        .interpolationMethod(.linear)
                    }
                }
                .chartXScale(domain: timeDomain)
                .chartYScale(domain: 0...upperBound)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, upperBound / 3, upperBound * 2 / 3, upperBound]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel {
                            if let n = value.as(Double.self) {
                                Text(formatRate(Int64(n)))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 72, alignment: .trailing)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            .foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 155)
            }
        }
        .onAppear { updateScale() }
        .onChange(of: samples.last?.id) { _, _ in updateScale() }
        .transaction { $0.animation = nil }
        .padding(14)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Theme.subtleBorder, lineWidth: 1)
        )
    }
}

// MARK: - Rule Draft Modal
struct RuleDraftView: View {
    @ObservedObject var model: AppModel
    var draft: RoutingRule
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var target = PolicyReference.selected
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认添加分流规则").font(.title2.bold())
            Text("从实时连接的目标地址直接生成，确认后添加至当前规则配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextField(draft.kind == .domain ? "目标域名" : "IP / CIDR 网段", text: $value)
                .textFieldStyle(.roundedBorder)
            
            RuleTargetPicker(state: model.state, target: $target)
            
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("确认添加规则") {
                    var next = draft
                    next.value = value
                    next.target = target
                    next.action = target == .direct ? .direct : target == .reject ? .reject : .proxy
                    Task {
                        await model.addRule(next)
                        if model.errorMessage == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.locked || value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 520)
        .onAppear { value = draft.value }
    }
}
