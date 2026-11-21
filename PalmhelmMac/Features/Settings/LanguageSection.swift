import SwiftUI
import PalmhelmKit

/// 外观页里的“语言”区：三选一，按本机保存、即时生效；不碰引擎设置，不需要重启 Bridge。
/// 选项里“简体中文 / English”用自称，不翻译，切到陌生语言后仍能找回。
struct LanguageSection: View {
    private let language = DisplayLanguage.shared

    var body: some View {
        Section("语言") {
            Picker("App 语言", selection: Binding(get: { language.choice }, set: { language.select($0) })) {
                ForEach(AppLanguageChoice.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
            }
            Text("只影响这台 Mac，不同步到 iPhone 或 Apple Watch。Palmhelm 自有界面即时更新，不需要重启 Bridge；消息、项目和设备名等原文不变。")
                .font(.caption).foregroundStyle(.secondary)
            Text("系统菜单、权限面板和通知外壳仍由 macOS 为 Palmhelm 选择的语言决定；需要一致时请在“系统设置”里设置 Palmhelm 的语言。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func label(_ c: AppLanguageChoice) -> String {
        switch c {
        case .system: String(localized: "跟随系统")
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }
}
