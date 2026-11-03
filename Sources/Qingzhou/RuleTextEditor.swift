import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QingzhouKit

@MainActor final class RuleTextEditorModel:ObservableObject {
    @Published var text:String
    @Published private(set) var result=RuleTextResult(rules:[],issues:[])
    @Published private(set) var validating=true
    @Published private(set) var validatedText=""
    private let state:AppState
    private let previous:[RoutingRule]
    private var task:Task<Void,Never>?
    init(text:String,state:AppState,previous:[RoutingRule]){self.text=text;self.state=state;self.previous=previous;validate()}
    func validate() {
        task?.cancel();validating=true
        let text=text,state=state,previous=previous
        task=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:300_000_000)}catch{return}
            let parsed=await Task.detached(priority:.userInitiated){RuleTextCodec.parse(text,state:state,previous:previous)}.value
            guard !Task.isCancelled else{return}
            self?.result=parsed;self?.validatedText=text;self?.validating=false
        }
    }
    deinit{task?.cancel()}
}

struct RuleTextEditor:View {
    @ObservedObject var app:AppModel
    @StateObject private var editor:RuleTextEditorModel
    let accept:([RoutingRule])->Void
    let final:PolicyReference?
    let initialText:String
    let onTextChange:(String)->Void
    let onDiscard:()->Void
    private func cancel() {
        guard editor.text==initialText || app.drafts.confirm("关闭规则文本编辑器") else{return}
        onDiscard();dismiss()
    }
    @Environment(\.dismiss) private var dismiss
    @State private var fileError:String?
    @State private var selectedLine:Int?
    @State private var simulationInput=""
    @State private var simulationResult:String?
    init(app:AppModel,text:String,rules:[RoutingRule],final:PolicyReference?=nil,baselineText:String?=nil,onTextChange:@escaping (String)->Void={_ in},onDiscard:@escaping ()->Void={},accept:@escaping ([RoutingRule])->Void){self.app=app;self.accept=accept;self.final=final;self.initialText=baselineText ?? text;self.onTextChange=onTextChange;self.onDiscard=onDiscard;_editor=StateObject(wrappedValue:RuleTextEditorModel(text:text,state:app.state,previous:rules))}
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{Text("批量规则草稿").font(.title2.bold());Spacer();Button("取消"){cancel()}}
            Text("类型,匹配内容,目标；MATCH,目标。支持 # 注释。补全使用 PROXY / DIRECT / REJECT / AUTO 或节点、组的唯一标识。")
                .font(.caption).foregroundStyle(.secondary)
            codeEditor
                .frame(minHeight:300)
            if editor.validating {Text("正在检查…").font(.caption)}
            else {Text("\(editor.result.rules.count) 条规则 · \(editor.result.issues.count) 个错误").font(.caption)}
            HStack {
                TextField("用域名或 IP 模拟草稿，不发起 DNS 请求",text:$simulationInput)
                Button("模拟匹配"){simulate()}.disabled(editor.validating || !editor.result.issues.isEmpty)
            }
            if let simulationResult {Text(simulationResult).font(.caption).foregroundStyle(.secondary).lineLimit(3)}
            if let error=fileError {Text(error).foregroundStyle(Theme.dangerRed)}
            if !editor.result.issues.isEmpty {
                ScrollView {VStack(alignment:.leading){ForEach(editor.result.issues){issue in Button("第\(issue.line)行：\(issue.message)"){selectedLine=issue.line}.buttonStyle(.plain).foregroundStyle(Theme.dangerRed)}}}.frame(maxHeight:100)
            }
            HStack{
                Button("导入文本…"){load()};Button("导出文本…"){save()};Spacer()
                Button("更新规则草稿") {accept(editor.result.rules);dismiss()}
                    .buttonStyle(.borderedProminent).disabled(editor.validating || !editor.result.issues.isEmpty || app.locked)
            }
            Text("此处只更新草稿；返回后点击应用才会保存，连接中最多重连一次。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth:760,minHeight:560).onChange(of:editor.text){_,value in onTextChange(value);editor.validate()}
        .interactiveDismissDisabled(editor.text != initialText)
        .onExitCommand {cancel()}
        .background(EditorCloseGuard {
            guard editor.text==initialText || app.drafts.confirm("关闭规则文本编辑器") else{return false}
            onDiscard();return true
        })
    }
    private var completions:[String] {
        var values=RuleTextCodec.kinds+["PROXY","DIRECT","REJECT","AUTO","no-resolve"]
        values.append(contentsOf:app.state.nodes.map{PolicyReference.node($0.id).tag})
        values.append(contentsOf:app.state.groups.map{PolicyReference.group($0.id).tag})
        return values
    }
    private var codeEditor:some View {
        RuleCodeText(text:$editor.text,issues:editor.result.issues,highlightText:editor.validatedText,selectedLine:selectedLine,completions:completions)
    }
    private func simulate() {
        do {
            var state=app.state;state.rules=editor.result.rules;if let final {state.ruleFinal=final}
            let result=try RuleEvaluator.explain(simulationInput,state:state)
            simulationResult=result.steps.suffix(2).joined(separator:"；")+" → "+state.label(result.target)+(result.uncertainty.map{"；"+$0} ?? "")
        } catch {simulationResult=error.localizedDescription}
    }
    private func load(){let panel=NSOpenPanel();panel.allowedContentTypes=[.plainText];guard panel.runModal() == .OK,let url=panel.url else{return};do{let granted=url.startAccessingSecurityScopedResource();defer{if granted{url.stopAccessingSecurityScopedResource()}};let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max;guard size<=2*1024*1024 else{throw ProxyError("规则文本超过2 MiB")};editor.text=try String(contentsOf:url,encoding:.utf8);fileError=nil}catch{fileError=error.localizedDescription}}
    private func save(){let panel=NSSavePanel();panel.nameFieldStringValue="qingzhou-rules.txt";guard panel.runModal() == .OK,let url=panel.url else{return};do{guard editor.text.utf8.count<=2*1024*1024 else{throw ProxyError("规则文本超过2 MiB")};try SecureFile.write(Data(editor.text.utf8),to:url);fileError=nil}catch{fileError=error.localizedDescription}}
}

private struct RuleCodeText:NSViewRepresentable {
    @Binding var text:String
    var issues:[RuleTextIssue]
    var highlightText:String
    var selectedLine:Int?
    var completions:[String]
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        let view=NSTextView();view.isRichText=false;view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false
        view.isAutomaticSpellingCorrectionEnabled=false;view.isAutomaticTextCompletionEnabled=true
        view.font = .monospacedSystemFont(ofSize:12,weight:.regular);view.textColor = .labelColor;view.backgroundColor = .textBackgroundColor
        view.autoresizingMask=[.width];view.isVerticallyResizable=true;view.textContainer?.widthTracksTextView=true
        view.textContainerInset=NSSize(width:12,height:12);view.delegate=context.coordinator;scroll.documentView=view;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? NSTextView else{return}
        context.coordinator.parent=self
        if view.string != text {view.string=text}
        let signature=highlightText+issues.map{"\($0.line)"}.joined(separator:",")
        if highlightText==text,context.coordinator.highlight != signature {
            context.coordinator.highlight=signature
            let all=NSRange(location:0,length:(text as NSString).length)
            view.textStorage?.beginEditing();view.textStorage?.addAttribute(.foregroundColor,value:NSColor.labelColor,range:all)
            let regex=try? NSRegularExpression(pattern:"(?m)^(?:DOMAIN(?:-SUFFIX|-KEYWORD)?|IP-CIDR6?|MATCH)|(?:PROXY|DIRECT|REJECT|AUTO|no-resolve)$|(?m)^#.*$")
            for match in regex?.matches(in:text,range:all) ?? [] {view.textStorage?.addAttribute(.foregroundColor,value:NSColor.systemBlue,range:match.range)}
            view.textStorage?.endEditing()
        }
        if selectedLine != context.coordinator.selectedLine,let selectedLine {
            context.coordinator.selectedLine=selectedLine
            let lines=text.components(separatedBy:"\n");let index=min(max(0,selectedLine-1),max(0,lines.count-1))
            let offset=lines.prefix(index).reduce(0){$0+($1 as NSString).length+1}
            let range=NSRange(location:offset,length:(lines[index] as NSString).length)
            view.setSelectedRange(range);view.scrollRangeToVisible(range)
        }
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:RuleCodeText
        var highlight=""
        var selectedLine:Int?
        init(_ parent:RuleCodeText){self.parent=parent}
        func textDidChange(_ notification:Notification){guard let view=notification.object as? NSTextView else{return};parent.text=view.string}
        func textView(_ textView:NSTextView,completions words:[String],forPartialWordRange range:NSRange,indexOfSelectedItem index:UnsafeMutablePointer<Int>?)->[String] {
            let prefix=(textView.string as NSString).substring(with:range)
            return parent.completions.filter{$0.lowercased().hasPrefix(prefix.lowercased())}
        }
    }
}
