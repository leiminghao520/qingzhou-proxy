import SwiftUI
import AppKit

// 玻璃仅用于操作控件；正文使用系统底色卡片，保持文字清晰。
struct LiquidCanvas: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Theme.secondaryBackground

        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LiquidContentSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(Theme.cardBackground))
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Theme.subtleBorder, lineWidth: contrast == .increased ? 1 : 0.5).allowsHitTesting(false)
            }
    }
}

struct LiquidControlSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Theme.subtleBorder, lineWidth: 1).allowsHitTesting(false))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 1).allowsHitTesting(false))
        }
    }
}

struct LiquidActionStyle: ViewModifier {
    var prominent: Bool
    var tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            if prominent { content.buttonStyle(.glassProminent).tint(tint) }
            else { content.buttonStyle(.glass(.regular.tint(.clear))).foregroundStyle(.primary) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent).tint(tint) }
            else { content.buttonStyle(.bordered).tint(tint) }
        }
    }
}

struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

struct LiquidSelectionSurface: ViewModifier {
    var selected: Bool
    var namespace: Namespace.ID?
    var id: String
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if !selected {
            content
        } else if reduceTransparency || contrast == .increased {
            content.background(Theme.accentBlue.opacity(0.2), in: shape)
        } else if #available(macOS 26.0, *), let namespace {
            // 将文字与材质作为同一个玻璃元素合成，避免背景玻璃折射到前景文字。
            content.glassEffect(.regular.tint(Theme.accentBlue.opacity(0.12)), in: shape)
                .glassEffectID(id, in: namespace)
        } else {
            content.background(Theme.accentBlue.opacity(0.14), in: shape)
        }
    }
}

extension View {
    func liquidContentSurface(cornerRadius: CGFloat = Theme.cardCornerRadius) -> some View {
        modifier(LiquidContentSurface(cornerRadius: cornerRadius))
    }
    func liquidControl<S: InsettableShape>(in shape: S, tint: Color = .clear, interactive: Bool = true) -> some View {
        modifier(LiquidControlSurface(shape: shape, tint: tint, interactive: interactive))
    }
    func liquidAction(prominent: Bool = false, tint: Color = Theme.accentBlue) -> some View {
        modifier(LiquidActionStyle(prominent: prominent, tint: tint))
    }
}
