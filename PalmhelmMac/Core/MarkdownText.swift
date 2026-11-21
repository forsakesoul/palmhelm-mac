import SwiftUI
import PalmhelmKit

// 回执正文：共用 Kit 的块级 Markdown 视图，代码块底色用 Mac 主题。
struct MarkdownText: View {
    let text: String
    var highlight: String? = nil
    var body: some View {
        let _ = MacRenderCounter.bump("rowBody") // 测试：消息行里的正文 body 求值次数（发布版为空操作）
        #if DEBUG
        if MacDiagnostics.enabled { // 测试显式打开才装：普通 Debug 不给每行装 geometry 回调
            let key = String(text.prefix(24))
            PalmhelmMarkdownText(text: text, codeBackground: PalmhelmTheme.codeBlock, highlight: highlight)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { MacRowFrames.set(key, $0) } // 测试：行的窗口坐标
                .onDisappear { MacRowFrames.remove(key) }
        } else {
            PalmhelmMarkdownText(text: text, codeBackground: PalmhelmTheme.codeBlock, highlight: highlight)
        }
        #else
        PalmhelmMarkdownText(text: text, codeBackground: PalmhelmTheme.codeBlock, highlight: highlight)
        #endif
    }
}
