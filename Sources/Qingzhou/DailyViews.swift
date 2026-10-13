import SwiftUI
import AppKit
import CoreImage
import Charts
import QingzhouKit

struct ProfilesView:View {
    @ObservedObject var model:AppModel
    @State private var name=""
    @State private var office=""
    @State private var copy=false
    @State private var backup=false
    @State private var renaming:ClientProfile?
    @State private var rename=""
    var body:some View {
        VStack(alignment:.leading,spacing:14){
            Text("每份配置独立保存节点、订阅、策略、规则与选择。切换连接中的配置失败时回滚。").font(.caption).foregroundStyle(.secondary)
            List(model.profiles){profile in HStack{VStack(alignment:.leading){Text(profile.name).font(.headline);Text("\(profile.configuration.nodes.count) 节点 · \(profile.configuration.rules.count) 规则").font(.caption)};Spacer();Button(model.currentProfileID==profile.id ? "当前配置":"切换"){Task{await model.changeProfile(profile.id)}};Button("改名"){rename=profile.name;renaming=profile};Button("删除",role:.destructive){Task{await model.deleteProfile(profile.id)}}.disabled(profile.id==model.currentProfileID)}.disabled(model.locked)}.frame(minHeight:160)
            TextField("新配置名称",text:$name);Toggle("复制当前配置",isOn:$copy).toggleStyle(.checkbox)
            if !copy {TextField("办公模板：内网域名，用逗号分隔；留空创建通用模板",text:$office)}
            HStack{Button("新建配置"){Task{await model.createProfile(name:name,copy:copy,officeDomains:office.split(separator:",").map{$0.trimmingCharacters(in:.whitespaces)});if model.errorMessage==nil{name="";office=""}}}.disabled(model.locked || name.isEmpty);Spacer();Button("加密备份 / 恢复"){backup=true}.disabled(model.locked)}
        }.sheet(isPresented:$backup){BackupView(model:model)}.sheet(item:$renaming){profile in VStack(spacing:18){Text("配置改名").font(.headline);TextField("名称",text:$rename);HStack{Button("取消"){renaming=nil};Button("保存"){Task{await model.renameProfile(profile.id,name:rename);if model.errorMessage==nil{renaming=nil}}}}}.padding(26).frame(width:440)}
    }
}
struct BackupView:View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password=""
    @State private var confirm=""
    @State private var snapshot:BackupSnapshot?
    @State private var message=""
    @State private var working=false
    var body:some View {
        VStack(alignment:.leading,spacing:16){Text("本地加密完整备份").font(.title2.bold());Text("备份包含节点密码、订阅地址等凭据。请妥善保存文件与口令，口令不会写入备份。AES-GCM · PBKDF2-SHA256 600,000 次。").font(.caption).foregroundStyle(.secondary);SecureField("备份或恢复口令",text:$password);SecureField("导出时再次输入口令",text:$confirm)
            HStack{Button("导出加密备份"){export()}.disabled(password.isEmpty || password != confirm || working);Button("打开备份并预览"){load()}.disabled(password.isEmpty || working);Button("预览升级前快照"){do{snapshot=try model.migrationSnapshot();message="升级前快照已读取，尚未恢复"}catch{message="升级前快照不存在或无法解密；未修改现有数据"}}.disabled(working)}
            if let snapshot{Text("恢复预览：\(snapshot.catalog.profiles.count) 份配置、\(snapshot.catalog.profiles.reduce(0){$0+$1.configuration.nodes.count}) 个节点；将替换当前配置集合。").font(.headline);Text("只有确认成功后才替换元数据并清理旧凭据，运行配置失败时恢复上一份。").font(.caption);Button("导出 0.2 回退数据并恢复必要旧凭据"){let panel=NSSavePanel();panel.nameFieldStringValue="state-0.2.json";panel.begin{response in if response == .OK,let url=panel.url{do{try BackupService.exportLegacy(snapshot,to:url,credentials:model.credentials);message="回退数据已导出。退出 0.3 并另存当前 state.json，再将导出的文件作为旧版 state.json；没有切换当前配置。"}catch{message=Redactor.redact(error.localizedDescription)}}}}.disabled(model.locked || working);Button("确认恢复全部配置",role:.destructive){Task{working=true;await model.restoreBackup(snapshot);working=false;if model.errorMessage==nil{password="";confirm="";self.snapshot=nil;dismiss()}}}.disabled(model.locked || working)}
            if working{ProgressView()};if !message.isEmpty{Text(message).font(.caption).foregroundStyle(.orange)}
            Button("关闭"){password="";confirm="";snapshot=nil;dismiss()}.disabled(working)
        }.padding(26).frame(width:620)
    }
    private func export(){guard let store=model.store else{return};let panel=NSSavePanel();panel.nameFieldStringValue="轻舟配置.qzb";panel.begin{response in guard response == .OK,let url=panel.url else{return};working=true;Task{do{let value=try BackupService.snapshot(store.catalog,credentials:model.credentials);let secret=password;let data=try await Task.detached{try BackupService.encrypt(value,password:secret)}.value;try SecureFile.write(data,to:url);model.recordBackup(url);message="备份已保存"}catch{message=Redactor.redact(error.localizedDescription)};working=false}}}
    private func load(){let panel=NSOpenPanel();panel.allowsMultipleSelection=false;panel.canChooseDirectories=false;panel.begin{response in guard response == .OK,let url=panel.url else{return};working=true;snapshot=nil;Task{do{let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}};let size=(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.intValue ?? Int.max;guard size<=48*1024*1024 else{throw ProxyError("备份超过大小限制")};let data=try Data(contentsOf:url);let secret=password;snapshot=try await Task.detached{try BackupService.decrypt(data,password:secret)}.value;message="口令及完整性校验通过，尚未恢复"}catch{message="备份无法读取、口令错误或文件损坏；未修改现有配置"};working=false}}}
}
struct DiagnosticsView:View {
    @ObservedObject var model:AppModel
    var body:some View {VStack(alignment:.leading,spacing:14){HStack{Button("一键诊断"){Task{await model.diagnose()}}.disabled(model.locked || model.diagnosing);Button("恢复原网络"){Task{await model.recover()}}.disabled(model.locked);if model.diagnosing{ProgressView().controlSize(.small)}};List(model.diagnosticRows){row in VStack(alignment:.leading,spacing:6){HStack{Text(row.stage).font(.headline);Spacer();Text(row.status).foregroundStyle(row.status=="失败" ? Color.red:row.status=="通过" ? Color.green:Color.secondary)};Text(row.detail).font(.caption).textSelection(.enabled)}};Text("诊断导出只含阶段、结果和脱敏说明，节点、订阅地址及密钥不导出。").font(.caption);Button("导出脱敏诊断"){let panel=NSSavePanel();panel.nameFieldStringValue="轻舟诊断.txt";panel.begin{response in if response == .OK,let url=panel.url{try? SecureFile.write(Data(model.diagnosticRows.map{Redactor.redact($0.stage+" · "+$0.status+"："+$0.detail)}.joined(separator:"\n").utf8),to:url)}}}.disabled(model.diagnosticRows.isEmpty)}}
}
struct RuleExplanationView:View {
    @ObservedObject var model:AppModel
    @State private var input=""
    @State private var explanation:RuleExplanation?
    @State private var message=""
    var body:some View {VStack(alignment:.leading,spacing:14){Text("模拟规则匹配").font(.headline);TextField("输入域名或 IPv4/IPv6 地址",text:$input).onSubmit{evaluate()};Button("解释匹配顺序"){evaluate()};if let explanation{ScrollView{VStack(alignment:.leading,spacing:8){ForEach(Array(explanation.steps.enumerated()),id:\.offset){Text($0.element)};Text("最终策略："+(explanation.target.map{model.state.label($0)} ?? "需要实际 DNS 结果才能确定")).bold();if let limit=explanation.uncertainty{Text(limit).foregroundStyle(.orange)}}.frame(maxWidth:.infinity,alignment:.leading)}};if !message.isEmpty{Text(message).foregroundStyle(.red)};Text("这是模拟结果。真实核心命中只在连接详情中显示，核心未提供时标为未提供。").font(.caption).foregroundStyle(.secondary)}}
    private func evaluate(){do{explanation=try RuleEvaluator.explain(input,state:model.state);message=""}catch{explanation=nil;message=error.localizedDescription}}
}
struct ShareRequest:Identifiable {let id=UUID();let node:Node}
struct ShareView:View {
    @ObservedObject var model:AppModel
    let node:Node
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged=false
    @State private var link=""
    @State private var qr:NSImage?
    var body:some View {VStack(alignment:.leading,spacing:16){Text("分享节点："+node.name).font(.title2.bold());Text("分享链接和二维码包含连接凭据，接收者可使用此节点。请只分享给可信的人。").foregroundStyle(.orange);if !acknowledged{Button("确认生成含凭据的分享内容"){do{link=try NodeShare.link(node,credentials:model.credentials);let filter=CIFilter(name:"CIQRCodeGenerator")!;filter.setValue(Data(link.utf8),forKey:"inputMessage");filter.setValue("M",forKey:"inputCorrectionLevel");if let output=filter.outputImage,let cg=CIContext().createCGImage(output.transformed(by:CGAffineTransform(scaleX:7,y:7)),from:output.extent.applying(CGAffineTransform(scaleX:7,y:7))){qr=NSImage(cgImage:cg,size:NSSize(width:280,height:280))};acknowledged=true}catch{model.errorMessage=error.localizedDescription}}}else{if let qr{Image(nsImage:qr).interpolation(.none).resizable().scaledToFit().frame(width:280,height:280)};Button("复制分享链接"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(link,forType:.string)};Button("保存二维码"){guard let qr,let tiff=qr.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) else{return};let panel=NSSavePanel();panel.nameFieldStringValue="节点二维码.png";panel.begin{response in if response == .OK,let url=panel.url{try? SecureFile.write(png,to:url)}}};Text("关闭窗口后分享内容从界面内存移除；已复制的内容仍在系统剪贴板中。").font(.caption)};Button("关闭"){link="";qr=nil;dismiss()}}.padding(26).frame(width:580)}
}
struct RateChart:View {
    let samples:[RateSample]
    var body:some View {VStack(alignment:.leading){Text("最近 30 分钟速率 · 仅保存在内存").font(.caption);Chart(samples){sample in LineMark(x:.value("时间",sample.time),y:.value("速率",sample.upload)).foregroundStyle(by:.value("方向","上传"));LineMark(x:.value("时间",sample.time),y:.value("速率",sample.download)).foregroundStyle(by:.value("方向","下载"))}.chartYAxis{AxisMarks{value in AxisGridLine();AxisValueLabel{if let n=value.as(Int64.self){Text(bytes(n)+"/s")}}}}.frame(height:150)}}
}
struct RuleDraftView:View {
    @ObservedObject var model:AppModel
    var draft:RoutingRule
    @Environment(\.dismiss) private var dismiss
    @State private var value=""
    @State private var target=PolicyReference.selected
    var body:some View{VStack(alignment:.leading,spacing:18){Text("确认新规则").font(.title2.bold());Text("从连接目标生成，尚未应用；应用归属和真实命中信息不会用于猜测规则。").font(.caption);TextField(draft.kind == .domain ? "域名":"IP/CIDR",text:$value);RuleTargetPicker(state:model.state,target:$target);HStack{Button("取消"){dismiss()};Spacer();Button("确认添加"){var next=draft;next.value=value;next.target=target;next.action=target == .direct ? .direct:target == .reject ? .reject:.proxy;Task{await model.addRule(next);if model.errorMessage==nil{dismiss()}}}.disabled(model.locked)}}.padding(26).frame(width:550).onAppear{value=draft.value}}
}
