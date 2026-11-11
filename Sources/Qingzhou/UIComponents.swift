import SwiftUI
import AppKit
import QingzhouKit

// MARK: - 汐航主题与基础样式
// 以 macOS 系统语义色为底，仅保留品牌青色作为强调色，深浅色与高对比度由系统自动适配。
enum Theme {
    static let cornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8

    // 状态色与品牌色
    static let connectedGreen = Color(nsColor: .systemGreen)
    static let connectingYellow = Color(nsColor: .systemOrange)
    static let disconnectedGray = Color.secondary
    static let dangerRed = Color(nsColor: .systemRed)
    static let accentBlue = Color(nsColor: NSColor(name:nil) { $0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(red:0.20,green:0.80,blue:0.84,alpha:1) : NSColor(red:0.02,green:0.48,blue:0.53,alpha:1) })
    static let brand = Color(red:22/255,green:184/255,blue:197/255)
    static let purpleAccent = Color(nsColor: .systemIndigo)
    static let cyanAccent = accentBlue
    static let amberAccent = Color(nsColor: .systemOrange)

    static let trafficUpload = purpleAccent
    static let trafficDownload = accentBlue

    // 背景颜色：参照系统设置，浅色为灰底白卡，深色为深底浅一级灰卡
    static var cardBackground: Color {
        Color(nsColor: NSColor(name:nil) { $0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:0.17,alpha:1) : NSColor.white })
    }
    static var secondaryBackground: Color {
        Color(nsColor: NSColor(name:nil) { $0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:0.115,alpha:1) : NSColor(white:0.955,alpha:1) })
    }
    static var subtleBorder: Color { Color(nsColor: .separatorColor) }
}

// MARK: - 协议标签
struct ProtocolBadge: View {
    let kind: ProxyKind
    
    var color: Color {
        switch kind {
        case .hysteria2: return Theme.cyanAccent
        case .vless: return Theme.purpleAccent
        case .shadowsocks: return Theme.accentBlue
        case .trojan: return Theme.amberAccent
        }
    }
    
    var body: some View {
        Text(kind.rawValue.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(color.opacity(0.25), lineWidth: 0.6)
            )
    }
}

// MARK: - 延迟标签
struct LatencyBadge: View {
    let delayText: String
    
    private var color: Color {
        if delayText.contains("历史结果") {return Color.secondary}
        if delayText.contains("ms") {
            let num = Int(delayText.split(separator:" ").first.map(String.init) ?? "") ?? 999
            if num <= 100 { return Theme.connectedGreen }
            if num <= 250 { return Theme.accentBlue }
            if num <= 500 { return Theme.amberAccent }
            return Theme.dangerRed
        } else if delayText.contains("失败") || delayText.contains("超时") {
            return Theme.dangerRed
        }
        return Color.secondary
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text((delayText.contains("历史结果") ? "历史 · " : "") + (delayText.components(separatedBy:" · ").first ?? delayText))
                .lineLimit(1)
                .help(delayText)
                .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
        .fixedSize(horizontal:true,vertical:false)
        .help(delayText)
        .accessibilityLabel(delayText)
    }
}

// MARK: - 统计卡片
struct ModernStatCard: View {
    let title: String
    let value: String
    let icon: String
    var iconColor: Color = Theme.accentBlue
    var subtitle: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconColor.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .leading)
        .liquidContentSurface(cornerRadius: Theme.cardCornerRadius)
    }
}

// MARK: - 页面标题
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil
    
    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size:20,weight:.bold,design:.rounded))
                
                if let subtitle, !subtitle.isEmpty {
                    HelpTip(text: subtitle)
                }
            }
            
            Spacer()
            
            if let actionTitle, let action {
                Button(action: action) {
                    if let actionIcon {
                        Label(actionTitle, systemImage: actionIcon)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// 信息提示支持悬停查看和点击固定，长说明自动换行。
struct HelpTip: View {
    let text: String
    @State private var isHovered = false
    @State private var isClicked = false
    
    var body: some View {
        Button {
            isClicked.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle((isHovered || isClicked) ? Theme.accentBlue : Color.secondary.opacity(0.75))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .overlay(alignment: .leading) {
            if isHovered || isClicked {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentBlue)
                        .padding(.top, 1.5)
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 340, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.subtleBorder, lineWidth: 1)
                )
                .fixedSize()
                .offset(x: 26)
                .zIndex(999)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }
}

// MARK: - 订阅用量进度
struct UsageProgressBar: View {
    let usedBytes: Int64?
    let totalBytes: Int64?
    
    private var percentage: Double {
        guard let used = usedBytes, let total = totalBytes, total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(used) / Double(total)))
    }
    
    private var barColor: Color {
        if percentage >= 0.9 { return Theme.dangerRed }
        if percentage >= 0.75 { return Theme.amberAccent }
        return Theme.accentBlue
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 6)
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(6, geo.size.width * CGFloat(percentage)), height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}
