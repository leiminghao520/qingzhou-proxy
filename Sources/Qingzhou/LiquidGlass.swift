import SwiftUI
import AppKit

// 玻璃仅用于导航和操作层；正文使用不透明卡片，保持文字清晰。
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
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Theme.subtleBorder, lineWidth: 1).allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.14 : 0.04), radius: 12, x: 0, y: 5)
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

struct LiquidModePicker: View {
    @Binding var selection: InterfaceMode
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 4) {
                mode(.simple, title: "简洁", icon: "sparkles")
                mode(.professional, title: "专业", icon: "slider.horizontal.3")
            }
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("界面模式")
        .accessibilityIdentifier("interfaceModePicker")
    }

    private func mode(_ value: InterfaceMode, title: String, icon: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                selection = value
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
                .foregroundStyle(selection == value ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .modifier(LiquidSelectionSurface(selected: selection == value, namespace: namespace, id: "interface-mode", cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selection == value ? "已选中" : "未选中")
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}

extension View {
    func liquidContentSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(LiquidContentSurface(cornerRadius: cornerRadius))
    }
    func liquidControl<S: InsettableShape>(in shape: S, tint: Color = .clear, interactive: Bool = true) -> some View {
        modifier(LiquidControlSurface(shape: shape, tint: tint, interactive: interactive))
    }
    func liquidAction(prominent: Bool = false, tint: Color = Theme.accentBlue) -> some View {
        modifier(LiquidActionStyle(prominent: prominent, tint: tint))
    }
}
