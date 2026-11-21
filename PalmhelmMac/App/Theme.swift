import SwiftUI
import AppKit
import PalmhelmKit

/// 外观偏好（设置 › 外观）：跟随系统 / 浅色 / 深色。按本机保存。
enum PalmhelmAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .system: String(localized: "跟随系统"); case .light: String(localized: "浅色"); case .dark: String(localized: "深色") }
    }
    /// 应用级外观：跟随系统时为 nil（NSApp.appearance = nil）。设在 NSApp 上，主 / 搜索 / 配对 / 设置窗口、弹层和菜单栏都一并生效，不需要重建任何视图。
    var nsAppearance: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}

/// 主题家族与外观的可观察存储：视图读取它们时自动依赖更新，切换即时生效；不重建窗口 / 引擎 / Session，也不重跑 AppBoot。
@MainActor
@Observable
final class PalmhelmThemeStore {
    static let shared = PalmhelmThemeStore()
    static let familyKey = "palmhelm.themeFamily"
    static let appearanceKey = "palmhelm.appearance"
    private let defaults: UserDefaults
    /// 应用外观的落点：生产里是 NSApp.appearance，测试可替换。
    var applyAppearance: (NSAppearance?) -> Void = { NSApp?.appearance = $0 }

    var family: PalmhelmThemeFamily { didSet { defaults.set(family.rawValue, forKey: Self.familyKey) } }
    var appearance: PalmhelmAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            applyAppearance(appearance.nsAppearance)
        }
    }

    init(defaults: UserDefaults = AppDefaults.standard) {
        self.defaults = defaults
        family = defaults.string(forKey: Self.familyKey).flatMap(PalmhelmThemeFamily.init(rawValue:)) ?? .standard
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(PalmhelmAppearance.init(rawValue:)) ?? .system
    }

    var tokens: PalmhelmThemeTokens { PalmhelmThemeTokens.tokens(family) }
}

// 语义 token：accent / 卡片色来自当前主题家族（Kit 的 token 表）；ok / warn / bad 是不随主题变的语义色（Kit PalmhelmSemanticColor）。
// 都是读 PalmhelmThemeStore 的计算属性：视图 body 里读取即建立观察，换主题即时刷新。
enum PalmhelmTheme {
    @MainActor static var accent: Color { PalmhelmThemeStore.shared.tokens.color(\.accent) }
    @MainActor static var accentSoft: Color { PalmhelmThemeStore.shared.tokens.color(\.accentSoft) }
    @MainActor static var emphasis: Color { PalmhelmThemeStore.shared.tokens.color(\.emphasis) }
    @MainActor static var onAccent: Color { PalmhelmThemeStore.shared.tokens.color(\.onAccent) }
    @MainActor static var card: Color { PalmhelmThemeStore.shared.tokens.color(\.card) }
    @MainActor static var card2: Color { PalmhelmThemeStore.shared.tokens.color(\.card2) }
    @MainActor static var ok: Color { PalmhelmSemanticColor.ok.color }
    @MainActor static var warn: Color { PalmhelmSemanticColor.warn.color }
    @MainActor static var bad: Color { PalmhelmSemanticColor.bad.color }
    /// 我的气泡：accentSoft 底 + emphasis 字（与主题同源）。
    @MainActor static var bubbleMe: Color { accentSoft }
    // 下面两个是阅读底色，不随家族变（角色色同理固定）。
    static let bubbleAgent = Color(light: 0xEFEEE9, dark: 0x22252A) // 比窗口底色深一档，浅色模式下也看得出是一块
    static let codeBlock = Color(light: 0xE3E1DA, dark: 0x2C3036)

    /// 刘海固定取深色 token（外壳黑色，不跟系统明暗）。
    @MainActor static var notchTokens: PalmhelmThemeSwatch { PalmhelmThemeTokens.tokens(PalmhelmThemeStore.shared.family).dark }
    // 刘海里的颜色：取当前家族的深色 token（固定，不随系统明暗），ok / warn / bad 取语义色的深色值。
    @MainActor static var notchAccent: Color { Color(hex: notchTokens.accent) }
    @MainActor static var notchOnAccent: Color { Color(hex: notchTokens.onAccent) }
    static var notchBad: Color { Color(hex: PalmhelmSemanticColor.bad.dark) }
    static var notchWarn: Color { Color(hex: PalmhelmSemanticColor.warn.dark) }
}

extension Color {
    init(hex v: UInt32) {
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(
                red: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// 卡片是否撑满所在的高度（#32：用量页右栏末卡与行高对齐）。默认关闭，其他页面不变。
private struct CardFillsHeightKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var cardFillsHeight: Bool { get { self[CardFillsHeightKey.self] } set { self[CardFillsHeightKey.self] = newValue } }
}

/// 卡片内边距（默认 12；用量页通过环境改成 16，其他页面不变）。
private struct CardPaddingKey: EnvironmentKey { static let defaultValue: CGFloat = 12 }
extension EnvironmentValues {
    var cardPadding: CGFloat { get { self[CardPaddingKey.self] } set { self[CardPaddingKey.self] = newValue } }
}

struct CardStyle: ViewModifier {
    @Environment(\.cardFillsHeight) private var fillsHeight
    @Environment(\.cardPadding) private var padding
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .background(PalmhelmTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

extension StatusDot.Kind {
    /// Bridge 的 online：true/false 来自 60 秒内的 Herdr 快照；nil 表示没有新鲜快照，不能当离线。
    static func online(_ v: Bool?) -> Self { v == true ? .ok : v == false ? .off : .warn }
}

struct StatusDot: View {
    enum Kind { case ok, warn, bad, off }
    let kind: Kind
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
    static func onlineLabel(_ v: Bool?) -> String { v == true ? String(localized: "在线") : v == false ? String(localized: "离线") : String(localized: "状态未知") }
    private var color: Color {
        switch kind {
        case .ok: PalmhelmTheme.ok
        case .warn: PalmhelmTheme.warn
        case .bad: PalmhelmTheme.bad
        case .off: Color.secondary.opacity(0.4)
        }
    }
}

/// 应用图标（Assets 里的 AppIcon，与 Dock 同一张）：主窗口品牌位、配对窗口、关于页共用。
struct PalmhelmAppIcon: View {
    var size: CGFloat = 22
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// 主按钮样式：accent 填充 + onAccent 字（不写死白字：深色主题 accent 是浅色，白字对比度不够）。禁用时降低不透明度。
struct PalmhelmProminentButtonStyle: ButtonStyle {
    var fill: Color?
    var label: Color?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @MainActor func makeBody(configuration: Configuration) -> some View {
        let small = size == .small || size == .mini
        configuration.label
            .font(small ? .caption.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(label ?? PalmhelmTheme.onAccent)
            .padding(.horizontal, small ? 10 : 14).padding(.vertical, small ? 3 : 5)
            .background(fill ?? PalmhelmTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PalmhelmProminentButtonStyle {
    static var palmhelmProminent: PalmhelmProminentButtonStyle { PalmhelmProminentButtonStyle() }
}
