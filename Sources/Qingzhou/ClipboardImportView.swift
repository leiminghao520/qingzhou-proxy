import SwiftUI
import AppKit
import QingzhouKit

struct ClipboardImportView: ViewModifier {
    @ObservedObject var model:AppModel
    @AppStorage("clipboardRecognitionEnabled") private var enabled=false
    @State private var input:String?
    func body(content:Content)->some View {
        content.background(ClipboardActivationObserver(enabled:enabled){value in
            guard !model.locked,model.preview==nil else{return}
            input=value
        }.frame(width:0,height:0))
        .onChange(of:enabled){_,value in if !value{input=nil}}
        .confirmationDialog("剪贴板中发现可导入的节点或订阅",isPresented:Binding(get:{input != nil},set:{if !$0{input=nil}}),titleVisibility:.visible) {
            Button("解析并预览") {let value=input;input=nil;if let value{Task{await model.importPreview(value)}}}
            Button("忽略",role:.cancel){input=nil}
        } message: {Text("只有确认导入订阅后才会请求其地址，剪贴板原文不会写入日志。")}
    }
}

private struct ClipboardActivationObserver:NSViewRepresentable {
    var enabled:Bool
    var offer:(String)->Void
    func makeNSView(context:Context)->ActivationView {ActivationView()}
    func updateNSView(_ view:ActivationView,context:Context){view.offer=offer;view.enabled=enabled}
    final class ActivationView:NSView {
        var enabled=false {didSet{if enabled != oldValue {inspect()}}}
        var offer:((String)->Void)?
        private var policy=ClipboardImportPolicy()
        private var observers:[NSObjectProtocol]=[]
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers{NotificationCenter.default.removeObserver(observer)};observers=[]
            guard window != nil else{return}
            for name in [NSWindow.didBecomeKeyNotification,NSApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in self?.inspect()})
            }
        }
        private func inspect() {
            let foreground=NSApp.isActive && window?.isKeyWindow==true && window?.attachedSheet==nil
            if let value=policy.inspect(enabled:enabled,foreground:foreground,change:NSPasteboard.general.changeCount,read:{NSPasteboard.general.string(forType:.string)}){offer?(value)}
        }
        deinit {for observer in observers{NotificationCenter.default.removeObserver(observer)}}
    }
}
