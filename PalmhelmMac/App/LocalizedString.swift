import Foundation
import PalmhelmKit

// 模块内同签名的 init 优先于 Foundation：全部 `String(localized:)` 调用点零改动，改走 Kit 的当前显示语言（选定 lproj），
// 且在调用处读取 DisplayLanguage，SwiftUI body 里调用会登记 Observation 依赖。locale 参数不能替代 bundle，故被忽略。
extension String {
    init(localized key: String.LocalizationValue, table: String? = nil, bundle: Bundle? = nil, locale: Locale = .current, comment: StaticString? = nil) {
        self = KitL10n.localized(key, table: table, bundle: bundle, comment: comment)
    }
}
