import SwiftUI
import QingzhouKit

struct BypassDiagnosticView:View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model:AppModel
    @State private var target=""
    @State private var report:BypassPathDiagnostic?
    @State private var error:String?
    @State private var checking=false
    @State private var generation=UUID()
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("目标路径诊断").font(.title2.bold())
            Text("静态规则推演见“规则解释”；这里读取当前系统代理选择、DNS 及路由，不修改网络。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("域名或 IP",text:$target).textFieldStyle(.roundedBorder)
                Button(checking ? "查询中…":"查询实际路径") {inspect()}.disabled(checking || target.isEmpty)
            }
            if let error {Text(error).foregroundStyle(.red)}
            if let report {
                Text(report.hasFailure ? "验证失败：配置与实际路径存在差异":"只读路径查询完成；业务连接未验证").foregroundStyle(report.hasFailure ? .orange:.secondary)
                ScrollView {VStack(alignment:.leading,spacing:8){ForEach(Array(report.rows.enumerated()),id:\.offset){_,row in Text(row).textSelection(.enabled)}}.frame(maxWidth:.infinity,alignment:.leading)}
            } else {Spacer()}
            HStack {Spacer();Button("关闭") {dismiss()}}
        }.padding(24).frame(width:800,height:570)
        .onChange(of:target){_,_ in generation=UUID();report=nil;error=nil;checking=false}
        .onChange(of:model.currentProfileID){_,_ in generation=UUID();report=nil;error="当前配置已切换，请重新查询";checking=false}
        .onDisappear {generation=UUID()}
    }
    private func inspect() {
        let token=UUID();generation=token;checking=true;error=nil;report=nil
        let input=target,state=model.state,active=model.activeBypasses==model.state.effectiveBypasses && model.connection == .connected
        Task {
            do {
                let tunnel=try? await model.capture.helperStatus().tunnelInterface
                let result=try await Task.detached{try BypassDiagnostics.inspect(input,state:state,active:active,ownedTunnel:tunnel)}.value
                guard generation==token else{return}
                report=result
            }catch {guard generation==token else{return};self.error=error.localizedDescription}
            if generation==token {checking=false}
        }
    }
}
