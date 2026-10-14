import SwiftUI
import AppKit
import QingzhouKit

// MARK: - Qingzhou UI Theme & Styles
enum Theme {
    static let cornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 14
    static let controlRadius: CGFloat = 8
    
    // Status Colors
    static let connectedGreen = Color(red: 0.18, green: 0.78, blue: 0.44)
    static let connectingYellow = Color(red: 0.95, green: 0.65, blue: 0.12)
    static let disconnectedGray = Color.secondary
    static let dangerRed = Color(red: 0.92, green: 0.28, blue: 0.28)
    static let accentBlue = Color(red: 0.12, green: 0.52, blue: 0.96)
    static let purpleAccent = Color(red: 0.58, green: 0.35, blue: 0.92)
    static let cyanAccent = Color(red: 0.08, green: 0.72, blue: 0.82)
    static let amberAccent = Color(red: 0.95, green: 0.55, blue: 0.15)
    
    // Background Tints
    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }
    
    static var secondaryBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
    
    static var subtleBorder: Color {
        Color.primary.opacity(0.07)
    }
}

// MARK: - Protocol Tag Badge
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

// MARK: - Latency Pill Badge
struct LatencyBadge: View {
    let delayText: String
    
    private var color: Color {
        if delayText.contains("ms") {
            let num = Int(delayText.replacingOccurrences(of: " ms", with: "").trimmingCharacters(in: .whitespaces)) ?? 999
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
            Text(delayText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Modern Stat Card
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
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(Theme.subtleBorder, lineWidth: 1)
        )
    }
}

// MARK: - Modern Section Header
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
                    .font(.headline.weight(.semibold))
                
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

// MARK: - Modern Help / Info Tooltip Indicator (Interactive Hover + Click Pill)
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
                        .fixedSize(horizontal: true, vertical: false)
                }
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

// MARK: - Usage Progress Bar
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

// MARK: - Sidebar Navigation Item Row (Full-Width Hit Testing & Hover)
struct SidebarNavItemRow: View {
    let name: String
    let icon: String
    let isSelected: Bool
    var badgeText: String? = nil
    var badgeColor: Color? = nil
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(isSelected ? Theme.accentBlue : (isHovered ? Color.primary : .secondary))
                
                Text(name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : (isHovered ? Color.primary : .secondary))
                
                Spacer(minLength: 8)
                
                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(badgeColor ?? .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background((badgeColor ?? Color.secondary).opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(isSelected ? Theme.accentBlue.opacity(0.14) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
