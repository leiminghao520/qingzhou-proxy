import Flutter
import NetworkExtension
import Mobile
import UIKit

final class QingzhouRuntime: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
    private var manager: NETunnelProviderManager?
    private var exportResult: FlutterResult?
    private var exportURL: URL?
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = QingzhouRuntime()
        registrar.addMethodCallDelegate(instance,channel:FlutterMethodChannel(name:"cn.qingzhou/runtime",binaryMessenger:registrar.messenger()))
    }
    private func json(_ value: Any) -> String {String(data:try! JSONSerialization.data(withJSONObject:value),encoding:.utf8)!}
    private func load(_ completion: @escaping (NETunnelProviderManager?,Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers,error in
            if let error {completion(nil,error);return}
            let manager = managers?.first {($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == "cn.qingzhou.qingzhou.PacketTunnel"} ?? NETunnelProviderManager()
            self.manager = manager;completion(manager,nil)
        }
    }
    func handle(_ call: FlutterMethodCall,result: @escaping FlutterResult) {
        if call.method == "capabilities" {result(json(["captureModes":["tun"],"coreVersion":QZMobileVersion(),"httpCompatibility":true,"fallback":true]));return}
        if call.method == "validate" {
            DispatchQueue.global(qos:.userInitiated).async {
                do {try TunnelSecrets.validate(call.arguments as? String);DispatchQueue.main.async {result(nil)}}
                catch {DispatchQueue.main.async {result(FlutterError(code:"validation",message:"核心配置校验失败",details:nil))}}
            };return
        }
        if call.method == "probe" {
            DispatchQueue.global(qos:.userInitiated).async {
                do {guard let raw=call.arguments as? String,let data=raw.data(using:.utf8),let request=try JSONSerialization.jsonObject(with:data) as? [String:Any],let selected=request["selected"] as? [String:String],let id=selected["id"] else {throw NSError(domain:"Qingzhou",code:41)}
                    var error:NSError?;let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Probe")
                    guard let core=QZMobileNewSession(root.path,ProbeHost(),&error) else {throw error ?? NSError(domain:"Qingzhou",code:42)}
                    defer{try? core.stop()};try core.startProbe(raw);var ms:Int64=0;try core.delay("node-"+id.lowercased(),ret0_:&ms);let value=self.json(["milliseconds":ms]);DispatchQueue.main.async{result(value)}
                }catch{DispatchQueue.main.async{result(FlutterError(code:"probe",message:"节点 HTTPS 测速失败",details:nil))}}
            };return
        }
        if call.method == "export" {export(call,result:result);return}
        load { manager,error in
            guard error == nil, let manager else {result(FlutterError(code:"preferences",message:"VPN 配置读取失败",details:nil));return}
            switch call.method {
            case "status":
                let state: String
                switch manager.connection.status {case .connected:state="connected";case .connecting,.reasserting:state="connecting";case .disconnecting:state="disconnecting";default:state="disconnected"}
                result(self.json(["state":state]))
            case "start":self.start(manager,request:call.arguments as? String,result:result)
            case "stop","recover":manager.connection.stopVPNTunnel();self.wait(manager,connected:false,attempt:0,result:result)
            case "query","select","delay":
                guard manager.connection.status == .connected,let connection=manager.connection as? NETunnelProviderSession else {result(FlutterError(code:"disconnected",message:"代理未连接",details:nil));return}
                let payload=self.json(["method":call.method,"arguments":call.arguments as? String ?? ""])
                do {try connection.sendProviderMessage(Data(payload.utf8)) { data in
                    guard let data,let response=try? JSONSerialization.jsonObject(with:data) as? [String:Any],response["error"] == nil else {result(FlutterError(code:"runtime",message:"扩展操作失败",details:nil));return}
                    result(call.method == "select" ? nil : response["value"])
                }} catch {result(FlutterError(code:"runtime",message:"扩展通信失败",details:nil))}
            default:result(FlutterMethodNotImplemented)
            }
        }
    }
    private func start(_ manager: NETunnelProviderManager,request: String?,result: @escaping FlutterResult) {
        guard let request,request.utf8.count<=4*1024*1024,manager.connection.status == .disconnected || manager.connection.status == .invalid else {result(FlutterError(code:"request",message:"运行请求无效或代理已连接",details:nil));return}
        let account=UUID().uuidString
        do {try TunnelSecrets.validate(request);try TunnelSecrets.save(Data(request.utf8),account:account)} catch {result(FlutterError(code:"validation",message:"配置或共享凭据保存失败",details:nil));return}
        let proto=NETunnelProviderProtocol();proto.providerBundleIdentifier="cn.qingzhou.qingzhou.PacketTunnel";proto.serverAddress="轻舟代理";proto.disconnectOnSleep=false
        manager.protocolConfiguration=proto;manager.localizedDescription="轻舟代理";manager.isEnabled=true
        manager.saveToPreferences { error in
            guard error == nil else {TunnelSecrets.remove(account);result(FlutterError(code:"permission",message:"VPN 授权或保存失败",details:nil));return}
            manager.loadFromPreferences {error in
                do {if let error {throw error};try manager.connection.startVPNTunnel(options:["requestAccount":account as NSString]);self.wait(manager,connected:true,attempt:0,result:result)}
                catch {TunnelSecrets.remove(account);result(FlutterError(code:"start",message:"VPN 启动失败",details:nil))}
            }
        }
    }
    private func wait(_ manager: NETunnelProviderManager,connected: Bool,attempt: Int,result: @escaping FlutterResult) {
        let state=manager.connection.status
        if (connected && state == .connected) || (!connected && (state == .disconnected || state == .invalid)) {result(nil);return}
        if attempt>=150 || (connected && attempt>5 && state == .disconnected) {result(FlutterError(code:"timeout",message:"VPN 连接或恢复未完成",details:nil));return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){self.wait(manager,connected:connected,attempt:attempt+1,result:result)}
    }
    private func export(_ call: FlutterMethodCall,result: @escaping FlutterResult) {
        guard exportResult == nil,let args=call.arguments as? [String:Any],let bytes=args["bytes"] as? FlutterStandardTypedData,bytes.data.count<=48*1024*1024 else {result(FlutterError(code:"export",message:"导出请求无效",details:nil));return}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);let url=directory.appendingPathComponent("qingzhou.qzb");try bytes.data.write(to:url,options:.completeFileProtection);exportURL=url;exportResult=result
            let picker=UIDocumentPickerViewController(forExporting:[url],asCopy:true);picker.delegate=self
            guard let scene=UIApplication.shared.connectedScenes.first as? UIWindowScene,let controller=scene.windows.first(where:{$0.isKeyWindow})?.rootViewController else {throw NSError(domain:"Qingzhou",code:1)}
            controller.present(picker,animated:true)
        } catch {finishExport(FlutterError(code:"export",message:"文件导出失败",details:nil))}
    }
    private func finishExport(_ error: FlutterError? = nil) {if let url=exportURL {try? FileManager.default.removeItem(at:url.deletingLastPathComponent())};exportURL=nil;exportResult?(error);exportResult=nil}
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {finishExport()}
    func documentPicker(_ controller: UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {finishExport()}
}
