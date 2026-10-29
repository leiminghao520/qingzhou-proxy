import SwiftUI

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
        Menu {
            Picker("界面外观", selection: $appearance) {
                Text("白天").tag(AppearancePreference.light)
                Text("夜间").tag(AppearancePreference.dark)
                Text("跟随系统").tag(AppearancePreference.system)
            }
        } label: {
            Label(appearance.title, systemImage: appearance.symbol)
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("界面外观")
        .accessibilityValue(appearance.title)
        .help("白天、夜间或跟随系统")
    }
}
