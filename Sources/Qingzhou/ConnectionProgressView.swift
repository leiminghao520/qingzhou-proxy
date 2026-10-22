import SwiftUI
import QingzhouKit

// 只刷新进度文字，避免每秒更新整个应用模型和其他页面。
struct ConnectionProgressView:View {
    let stage:String
    let startedAt:TimeInterval?
    var body:some View {
        TimelineView(.periodic(from:.now,by:1)) { _ in
            Text(stage+" · 已等待 "+String(HelperProgress.elapsed(start:startedAt,now:ProcessInfo.processInfo.systemUptime))+" 秒")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("connectionStage")
        }
    }
}
