import SwiftUI
import AppKit

// 外观偏好独立于代理配置，跟随系统使用空值取消应用自身的覆盖。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "白天"
        case .dark: return "夜间"
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct AppearanceSetting: View {
    @AppStorage("appearancePreference") private var appearance = AppearancePreference.system
    var body: some View {
        LabeledContent("界面外观") {
            HStack(spacing:4) {
                ForEach(AppearancePreference.allCases) { value in
                    Button {appearance=value} label: {
                        Text(value.title).font(.system(size:12,weight:appearance == value ? .semibold : .regular))
                            .foregroundStyle(appearance == value ? Theme.accentBlue : Color.secondary)
                            .fixedSize().padding(.horizontal,12).padding(.vertical,8)
                            .background(appearance == value ? Theme.accentBlue.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).accessibilityValue(appearance == value ? "已选择":"未选择")
                }
            }.padding(4).background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:12))
                .accessibilityIdentifier("appearancePicker")
        }
    }
}

struct AppearanceMenu: View {
    @AppStorage("appearancePreference") private var appearance = AppearancePreference.system
    var body: some View {
        AppearancePopUp(selection: $appearance)
            .frame(width: 132, height: 24)
    }
}

// 原生下拉框只创建一次菜单；遥测重绘不替换菜单标题或改变按钮尺寸。
struct AppearancePopUp: NSViewRepresentable {
    @Binding var selection: AppearancePreference
    private static let choices: [AppearancePreference] = [.light, .dark, .system]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.addItems(withTitles: Self.choices.map(\.title))
        for (index, value) in Self.choices.enumerated() {
            button.item(at: index)?.image = NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil)
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setAccessibilityLabel("界面外观")
        button.setAccessibilityIdentifier("appearanceMenu")
        button.toolTip = "白天、夜间或跟随系统"
        button.selectItem(at: Self.choices.firstIndex(of: selection)!)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let index = Self.choices.firstIndex(of: selection)!
        if button.indexOfSelectedItem != index { button.selectItem(at: index) }
    }
    final class Coordinator: NSObject {
        var selection: Binding<AppearancePreference>
        init(selection: Binding<AppearancePreference>) { self.selection = selection }
        @objc func select(_ button: NSPopUpButton) {
            guard AppearancePopUp.choices.indices.contains(button.indexOfSelectedItem) else { return }
            selection.wrappedValue = AppearancePopUp.choices[button.indexOfSelectedItem]
        }
    }
}
