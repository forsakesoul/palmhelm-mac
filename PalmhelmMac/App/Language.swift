import SwiftUI
import PalmhelmKit

/// 每个自有 scene 根 / NSHostingView 根的语言环境：body 里读 DisplayLanguage 才有 Observation 依赖，
/// 语言改变时只重算这一层 modifier（不 .id 重建、不碰 Session/Engine），子视图里读过垫片的叶子各自失效。
private struct DisplayLanguageEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.locale, DisplayLanguage.shared.context.formattingLocale)
    }
}

extension View {
    func displayLanguage() -> some View { modifier(DisplayLanguageEnvironment()) }
}

/// 语言偏好的外部触发：回前台与系统 locale 变化时重新解析；context 不变不发布（DisplayLanguage 内部判等）。
@MainActor
final class LanguageRefresher {
    private var tokens: [NSObjectProtocol] = [] // 随 AppDelegate 同生命周期，不拆除
    init() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSLocale.currentLocaleDidChangeNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in DisplayLanguage.shared.refresh() })
        }
    }
}

/// 缓存在状态里的 App 自产文案：存“怎么生成”（key + 参数在闭包里），显示时再按当前语言取，
/// 这样语言切换后仍在展示的提示/失败原因不会停在旧语言。服务器原文、用户正文不要放进来（它们不翻译）。
/// 相等按当前显示文本比较（语义等价，不是同一次构造）。
struct LText: Equatable, ExpressibleByStringLiteral, CustomStringConvertible, @unchecked Sendable { // 闭包只捕获值类型参数并读取语言快照，不改共享状态
    private let make: () -> String
    init(_ make: @autoclosure @escaping () -> String) { self.make = make }
    /// 字面量按原样（不查 Catalog）：用于测试与已是最终显示形式的文本。
    init(stringLiteral value: String) { make = { value } }
    /// 读取时在调用处触发 DisplayLanguage 的 Observation 依赖。
    var text: String { make() }
    var description: String { text } // 误用字符串插值时也得到文案而不是类型名
    static func == (a: LText, b: LText) -> Bool { a.text == b.text }
}


// 展示用日期/数字：语言文字用选定语言，地区/日历/时区/12-24h 取系统（Kit 的 formattingLocale）。协议格式（ISO、en_US_POSIX）不要用这些。
extension Date {
    func shown(date: Date.FormatStyle.DateStyle = .omitted, time: Date.FormatStyle.TimeStyle = .omitted) -> String { KitL10n.formatted(self, date: date, time: time) }
    /// 相对时间（“3 分钟前”）。
    static func relativeStyle(_ presentation: Date.RelativeFormatStyle.Presentation) -> Date.RelativeFormatStyle {
        Date.RelativeFormatStyle(presentation: presentation, unitsStyle: .wide, locale: KitL10n.formattingLocale, calendar: KitL10n.formattingLocale.calendar)
    }
}
extension BinaryInteger {
    var shown: String { KitL10n.number(self) }
}
extension Double {
    var shown: String { KitL10n.number(self) }
}

/// 朗读/摘要里的列表分隔符：由代码按所选资源语言给出，不经 Catalog（译文的首尾空白不可靠）。
enum DisplayList {
    static var separator: String { DisplayLanguage.shared.context.resourceLanguage == "zh-Hans" ? "，" : ", " }
    static func join(_ parts: [String]) -> String { parts.joined(separator: separator) }
}
