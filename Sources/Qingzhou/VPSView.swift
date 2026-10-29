import SwiftUI
import AppKit
import QingzhouKit

struct VPSView: View {
    @ObservedObject var model:AppModel
    @ObservedObject var center:VPSCenter
    @State private var selection:UUID?
    @State private var code=""
    @State private var recoveryPassword=""
    @State private var diagnosticDate:Date?
    @Environment(\.scenePhase) private var phase
    private func bytes(_ value:VPSValue)->String {guard let n=value.number,n>=0,n<Double(Int64.max) else{return "未知"};return ByteCountFormatter.string(fromByteCount:Int64(n),countStyle:.binary)}
    private func date(_ value:VPSValue)->String {if let n=value.number{return Date(timeIntervalSince1970:n).formatted()};if let text=value.string {
            let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            if let d=parser.date(from:text) ?? ISO8601DateFormatter().date(from:text) {return d.formatted()}
            return text
        };return "未知"}
    private func stateName(_ value:VPSValue)->String {
        let text=value.string ?? "unknown"
        return ["fresh":"最新","stale":"已过期","unconfigured":"未配置","active":"运行中","inactive":"已停止","failed":"异常","unknown":"未知"][text] ?? text
    }
    private func period(_ label:String,_ value:VPSValue)->String {label+"：上传 "+bytes(value["upload"])+" · 下载 "+bytes(value["download"])+(value["complete"].bool==true ? "":"（观测不完整）")}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                HStack {Text("VPS 联动").font(.largeTitle.bold());Spacer();if center.binding != nil {Button("刷新"){Task{await center.refresh()}}.disabled(center.busy)}}
                Text("服务端信息独立查询；查询失败不影响普通代理。").foregroundStyle(.secondary)
                if let error=center.error {Text(error).foregroundStyle(.orange).textSelection(.enabled)}
                ForEach(center.notices,id:\.self){Text($0).foregroundStyle(.orange)}
                if center.binding==nil {pairing} else {
                    HStack {
                        Text((center.binding.flatMap{URL(string:$0.endpoint)?.host}) ?? "已配对")
                        Spacer();Button("解除本机配对"){center.unlink()}
                    }
                    SimpleCard {
                        Text("设备流量").font(.headline)
                        Text(period("今日",center.usage["today"]))
                        Text(period("本月",center.usage["month"]))
                        Text(period("累计归档",center.usage["retained"]))
                        Text("来源：Hysteria 已观测数据 · Asia/Shanghai · 最近采样："+date(center.usage["captured_at"])).font(.caption)
                        if center.usage["fresh"].bool != true {Text("采样已过期或尚无有效数据").foregroundStyle(.orange)}
                    }
                    if center.owner {serverStatus;cloudBilling}
                    deviceList
                    SimpleCard {
                        Text("当前路径带宽").font(.headline)
                        Text(center.speedMessage).textSelection(.enabled)
                        HStack {
                            Button("开始测试（最多 16 MiB）"){center.startSpeed(model:model)}.disabled(center.speedRunning)
                            Button("取消"){center.cancelSpeed()}.disabled(!center.speedRunning)
                        }
                    }
                    if center.owner {backups}
                    diagnostics
                }
            }.padding(24)
        }
        .task {
            while !Task.isCancelled {
                if phase == .active {await CredentialAuthorization.$allowsInteraction.withValue(false) {await center.refresh()}}
                do{try await Task.sleep(for:.seconds(30))}catch{break}
            }
        }
        .onDisappear{center.cancelSpeed()}
        .onChange(of:model.epoch){_,_ in center.cancelSpeed()}
        .onChange(of:model.latencyInvalidatedAt){_,_ in center.cancelSpeed()}
        .onChange(of:model.networkRechecking){_,value in if value{center.cancelSpeed()}}
        .onChange(of:model.connection){_,value in if value != .connected{center.cancelSpeed()}}
    }
    private var pairing:some View {
        SimpleCard {
            Text("配对现有订阅").font(.headline)
            Picker("订阅",selection:$selection) {
                Text("选择订阅").tag(Optional<UUID>.none)
                ForEach(model.state.subscriptions){s in Text(s.name).tag(Optional(s.id))}
            }
            Button("检查联动能力") {if let sub=model.state.subscriptions.first(where:{$0.id==selection}){Task{await center.discover(sub,model:model)}}}.disabled(center.busy || selection==nil)
            if center.endpoint != nil {
                Text("到 VPS 管理后台的设备页生成十分钟有效的配对码。").font(.caption)
                SecureField("完整的 32 位一次性配对码",text:$code)
                Button("配对") {if let id=selection{let value=code;Task{await center.pair(code:value,subscription:id);if center.binding != nil{code=""}}}}.disabled(code.isEmpty || center.busy)
            }
        }.onChange(of:selection){_,_ in center.endpoint=nil;code=""}
    }
    private var deviceList:some View {
        SimpleCard {
            Text("我的设备").font(.headline)
            ForEach(Array(center.devices["devices"].array.enumerated()),id:\.offset){_,d in deviceRow(d)}
            if let url=center.adminURL(){Link("打开管理后台（停用、轮换或添加设备）",destination:url)}
        }
    }
    private func deviceRow(_ d:VPSValue)->some View {
        let name=(d["name"].string ?? "设备")+" · "+(d["platform"].string ?? "")
        let enabled=d["enabled"].number==1 ? "已启用":"已停用"
        return VStack(alignment:.leading) {
            Text(name)
            Text(enabled+" · 最近在线："+date(d["last_online_at"])).font(.caption)
            Text(period("留存用量",d["usage"])).font(.caption)
        }
    }
    private func billRow(_ bill:VPSValue)->some View {
        VStack(alignment:.leading) {
            Text((bill["BusinessCodeName"].string ?? "资源")+" · "+(bill["PayModeName"].string ?? ""))
            ForEach(Array(bill["ComponentSet"].array.enumerated()),id:\.offset){_,item in componentRow(item)}
        }
    }
    private func componentRow(_ item:VPSValue)->some View {
        let name=item["ComponentCodeName"].string ?? "计费项"
        let amount=item["UsedAmount"].string ?? "未知"
        let unit=item["UsedAmountUnit"].string ?? ""
        let cost=item["RealCost"].string ?? "未知"
        return Text(name+"："+amount+" "+unit+" · 实付 "+cost).font(.caption)
    }
    private var serverStatus:some View {
        SimpleCard {
            Text("服务端状态").font(.headline)
            Text("数据状态："+stateName(center.status["state"])+" · 采集："+date(center.status["captured_at"]))
            ForEach([("hysteria","代理"),("auth","认证"),("nginx","HTTPS 入口")],id:\.0){key,label in
                Text(label+"："+stateName(center.status["data"][key]))
            }
            Text("证书到期："+date(center.status["data"]["certificate_expires"]))
            Text("可用内存："+bytes(center.status["data"]["resources"]["memory_available"])+" · 磁盘剩余："+bytes(center.status["data"]["resources"]["disk_free"]))
            Text("进程正常不代表转发正常，请结合联合诊断。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func packageRow(_ p:VPSValue)->some View {
        let unit=p["unit"].string ?? "GB"
        let total=p["total_gb"].number.map{String(format:"%.3f ",$0)+unit} ?? "未知"
        let remaining=p["remaining_gb"].number.map{String(format:"%.3f ",$0)+unit} ?? "未知"
        let label=p["scope"].string=="instance_package" ? "实例套餐" : "共享套餐"
        return Text(label+" · 总量 "+total+" · 剩余 "+remaining)
    }
    private var cloudBilling:some View {
        SimpleCard {
            Text("腾讯云账单与套餐").font(.headline)
            if center.billing["data"]["configured"].bool != true {
                Text("尚未配置腾讯云只读授权，普通代理及设备流量照常可用。")
            } else {
                Text("刷新："+date(center.billing["captured_at"])+" · "+stateName(center.billing["state"]))
                Text("计费："+(center.billing["data"]["charge_type"].string ?? "未知"))
                Text("实例到期："+date(center.billing["data"]["expires"]))
                ForEach(Array(center.billing["data"]["packages"].array.enumerated()),id:\.offset){_,p in
                    packageRow(p)
                }
                ForEach(Array(center.billing["data"]["bills"].array.enumerated()),id:\.offset){_,bill in billRow(bill)}
                if center.billing["data"]["bills"].array.isEmpty {
                    Text("本月暂无该资源账单记录，不代表套餐免费或账户未产生费用。")
                }
                Text("云账单存在结算延迟；套餐流量不等同当前设备用量，共享套餐还可能包括其他资源。80%、90%、100% 仅应用内提醒。").font(.caption)
            }
        }
    }
    private var backups:some View {
        SimpleCard {
            Text("加密备份").font(.headline)
            Text(center.backupMessage)
            if center.binding?.recoveryExported != true {
                SecureField("恢复文件口令（至少十二个字符）",text:$recoveryPassword)
                Button("导入已有恢复密钥") {
                    do{try center.importRecovery(password:recoveryPassword);recoveryPassword=""}catch is CancellationError{}catch{center.error=error.localizedDescription}
                }
                Button("生成并导出恢复密钥") {
                    do{try center.exportRecovery(password:recoveryPassword);recoveryPassword=""}catch is CancellationError{}catch{center.error=error.localizedDescription}
                }
            }
            HStack {
                Button("启用每日备份"){Task{await center.enableBackup()}}.disabled(center.binding?.recoveryExported != true)
                Button("同步到本机"){Task{await center.syncBackup()}}
                Button("打开备份目录"){center.openBackups()}
                Button("隔离验证备份"){Task{await center.verifyBackup()}}
            }
            Text("VPS 保留七份日备份和四份周备份；应用运行时同步加密文件。恢复需管理员操作，请另存恢复密钥及口令。").font(.caption)
        }
    }
    private var jointRows:[DiagnosticResult] {VPSDiagnostics.summarize(local:model.diagnosticRows,server:center.status)}
    private var diagnostics:some View {
        SimpleCard {
            HStack {
                Text("联合诊断").font(.headline);Spacer()
                Button("停止诊断"){model.cancelDiagnostic()}.disabled(!model.diagnosing)
                Button("开始诊断"){Task{await model.diagnose();guard let session=model.diagnosticSession,!session.results.contains(where:{$0.code=="cancelled" || $0.code=="timeout"}) else{return};await center.refresh();guard model.diagnosticSession?.id==session.id else{return};diagnosticDate=Date()}}.disabled(model.diagnosing || center.busy)
            }
            if let diagnosticDate {
                Text("检查时间："+diagnosticDate.formatted()).font(.caption)
                ForEach(model.diagnosticRows){row in Text(row.stage+" · "+row.status+" · "+row.detail).font(.callout)}
                ForEach(jointRows){row in Text(row.stage+" · "+row.status+" · "+row.detail).font(.callout)}
                Button("导出 JSON") {if var session=model.diagnosticSession {session.results += jointRows;saveDiagnosticData(try? session.export(json:true),name:"汐航联合诊断.json")}}
                Text("服务端："+(center.status["state"].string=="fresh" ? "使用上述最新状态":"未知，管理通道不可达不能据此判定代理故障"))
                Button("导出脱敏诊断") {
                    let panel=NSSavePanel();panel.nameFieldStringValue="汐航联合诊断.txt"
                    if panel.runModal() == .OK,let url=panel.url {
                        if var session=model.diagnosticSession {
                            session.results += jointRows
                            try? SecureFile.write(session.export(json:false),to:url)
                        }
                    }
                }
            }else{Text("诊断不会自动连接、修复或重启核心。")}
        }
    }
}
