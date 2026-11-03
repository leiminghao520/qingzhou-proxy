import SwiftUI
import AppKit
import QingzhouKit

// 日志使用独立发布对象，避免每条核心输出刷新整个应用。
@MainActor final class RuntimeLogBuffer: ObservableObject {
    @Published private(set) var text = ""
    private var lines: [String] = []
    private var pending: [String] = []
    private var flushTask: Task<Void, Never>?
    private var writer: RuntimeLogWriter?
    private var dropped=0
    private let formatter: DateFormatter = {let value=DateFormatter();value.dateFormat="HH:mm:ss";return value}()
    private static let ansi = try! NSRegularExpression(pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]")

    func configure(url: URL) { writer = RuntimeLogWriter(url: url) }
    func append(_ input: String, secrets: [String]) {
        let range=NSRange(input.startIndex..<input.endIndex,in:input)
        let plain=Self.ansi.stringByReplacingMatches(in:input,range:range,withTemplate:"")
        let timestamp=formatter.string(from:Date())
        let bounded=String(Redactor.redact(plain,secrets:secrets).prefix(65536))
        for line in bounded.components(separatedBy:.newlines) where !line.isEmpty {
            pending.append(timestamp+"  "+String(Redactor.redact(line,secrets:secrets).prefix(2048)))
        }
        // 高流量时限定单批容量，避免后台磁盘任务无限积压。
        if pending.count > 1000 {dropped+=pending.count-1000;pending.removeFirst(pending.count-1000)}
        guard flushTask == nil else {return}
        flushTask=Task { [weak self] in
            try? await Task.sleep(nanoseconds:500_000_000)
            guard !Task.isCancelled,let self else {return}
            self.flushTask=nil
            var batch=self.pending;self.pending=[]
            if self.dropped>0 {batch.append("高流量期间丢弃 \(self.dropped) 条日志");self.dropped=0}
            self.lines.append(contentsOf:batch)
            if self.lines.count>500 {self.lines.removeFirst(self.lines.count-500)}
            self.text=self.lines.joined(separator:"\n")
            self.writer?.append(batch) { [weak self] in
                Task { @MainActor in self?.append("诊断日志保存失败，请检查用户目录权限",secrets:[]) }
            }
        }
    }
    func clear() {flushTask?.cancel();flushTask=nil;pending=[];dropped=0;lines=[];text=""}
}

// 文件仅在后台串行追加，队列只保留一个工作项和有界待写批次。
private final class RuntimeLogWriter: @unchecked Sendable {
    private let queue=DispatchQueue(label:"cn.qingzhou.log-writer",qos:.utility)
    private let log: DiagnosticLog
    private var reported=false
    private let lock=NSLock()
    private var pending:[String]=[]
    private var scheduled=false
    private var dropped=0
    init(url:URL) {log=DiagnosticLog(url:url)}
    func append(_ lines:[String],failure:@escaping @Sendable ()->Void) {
        lock.lock();pending.append(contentsOf:lines)
        if pending.count>1000 {dropped+=pending.count-1000;pending.removeFirst(pending.count-1000)}
        let start = !scheduled;scheduled=true;lock.unlock()
        guard start else{return}
        queue.async { [self] in
            while true {
                lock.lock();var batch=pending;pending=[]
                if dropped>0 {batch.append("磁盘日志队列丢弃 \(dropped) 条");dropped=0}
                if batch.isEmpty {scheduled=false;lock.unlock();return};lock.unlock()
                do {try log.appendBatch(batch)} catch {if !reported {reported=true;failure()}}
            }
        }
    }
}

struct RuntimeLogView: View {
    @ObservedObject var buffer: RuntimeLogBuffer
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("最近 500 行 · 每秒最多刷新两次 · 敏感链接与凭据已脱敏")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空日志") {buffer.clear()}.buttonStyle(.bordered).controlSize(.small)
            }
            RuntimeLogText(text:buffer.text).equatable()
                .clipShape(RoundedRectangle(cornerRadius:Theme.cornerRadius))
        }
    }
}

// 原生文本视图保留选择、复制与滚动位置；无变化时不重新排版。
private struct RuntimeLogText: NSViewRepresentable, Equatable {
    let text:String
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        let view=NSTextView();view.isEditable=false;view.isSelectable=true;view.isRichText=false
        view.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        view.textColor = .labelColor;view.backgroundColor = .textBackgroundColor
        view.textContainerInset=NSSize(width:14,height:14)
        view.isVerticallyResizable=true;view.isHorizontallyResizable=false
        view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true
        view.textContainer?.containerSize=NSSize(width:scroll.contentSize.width,height:CGFloat.greatestFiniteMagnitude)
        view.minSize=NSSize(width:0,height:0);view.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        scroll.documentView=view
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? NSTextView,view.string != text else {return}
        let origin=scroll.contentView.bounds.origin
        view.string=text
        scroll.contentView.scroll(to:origin);scroll.reflectScrolledClipView(scroll.contentView)
    }
}
