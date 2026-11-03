import SwiftUI
import AppKit

// 仅拦截编辑弹窗；主窗口关闭仍保留菜单栏驻留行为。
struct EditorCloseGuard:NSViewRepresentable {
    var allowClose:()->Bool
    func makeNSView(context:Context)->GuardView {let view=GuardView();view.allowClose=allowClose;return view}
    func updateNSView(_ view:GuardView,context:Context) {view.allowClose=allowClose;view.attach()}
    static func dismantleNSView(_ view:GuardView,coordinator:()) {view.detach()}
    final class GuardView:NSView,NSWindowDelegate {
        var allowClose:()->Bool={true}
        weak var original:NSWindowDelegate?
        weak var guardedWindow:NSWindow?
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();attach()}
        func attach() {
            guard let window,window.sheetParent != nil,guardedWindow !== window else{return}
            detach();original=window.delegate;guardedWindow=window;window.delegate=self
        }
        func detach() {
            if let guardedWindow,guardedWindow.delegate === self {guardedWindow.delegate=original}
            guardedWindow=nil;original=nil
        }
        func windowShouldClose(_ sender:NSWindow)->Bool {
            guard allowClose() else{return false}
            return original?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector:Selector!)->Bool {super.responds(to:selector) || (original?.responds(to:selector) ?? false)}
        override func forwardingTarget(for selector:Selector!)->Any? {original?.responds(to:selector)==true ? original:super.forwardingTarget(for:selector)}
    }
}

struct DraftEditorSheet<Draft:ObservableObject & SessionDraft,Content:View>:View {
    @ObservedObject var draft:Draft
    let store:SessionDraftStore
    let title:String
    @ViewBuilder var content:()->Content
    @Environment(\.dismiss) private var dismiss
    private func allowClose()->Bool {
        guard !draft.dirty || store.confirm("关闭"+title) else{return false}
        draft.discard();return true
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text(title).font(.headline);Spacer();Button("完成") {if allowClose(){dismiss()}}.keyboardShortcut(.cancelAction)}
            content()
        }
        .interactiveDismissDisabled(draft.dirty)
        .onExitCommand {if allowClose(){dismiss()}}
        .background(EditorCloseGuard(allowClose:allowClose))
    }
}
