import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// O1-336：对话区的内容高度必须与各行真实高度之和一致，否则底部的行计不进滚动范围（最新回复滚不到、过度滚动后回弹）。
// 用长 Markdown 的会话记录（末尾一条长回复）宿主真实 MainWindow，比较滚动视图声明的高度与逐行渲染之和。
@MainActor
final class TranscriptContentHeightTests: XCTestCase {
    static func markdown(_ i: Int, long: Bool) -> String {
        var parts = ["## 第 \(i) 条回复", "这是第 \(i) 条的说明段落，包含 **加粗**、`行内代码` 与一个 [链接](https://example.com)。"]
        let items = long ? 24 : 3
        parts.append((1...items).map { "- 要点 \($0)：这一条是为了让回复变长，内容可以换行，也要有一定宽度。" }.joined(separator: "\n"))
        if long {
            parts.append("```swift\n" + (1...18).map { "let value\($0) = compute(\($0), seed: \(i))  // 第 \($0) 行" }.joined(separator: "\n") + "\n```")
            parts.append("### 小结\n" + (1...6).map { "段落 \($0)：总结内容，与前面的要点相关，保证段落有足够的行数。" }.joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n")
    }
    static func items(_ n: Int) -> [TranscriptItem] {
        (1...n).map { i in TranscriptItem(id: "tr-\(i)", role: i % 2 == 0 ? "user" : "assistant", text: markdown(i, long: i % 3 == 0)) }
    }
    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    private func scrollViews(_ v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = v as? NSScrollView { out.append(s) }
        for sub in v.subviews { out += scrollViews(sub) }
        return out
    }
    private func rowHeight(_ item: TranscriptItem, width: CGFloat, folding: TranscriptRowFolding?) -> CGFloat {
        let host = NSHostingView(rootView: TranscriptItemRow(item: item, folding: folding).frame(width: width, alignment: .leading))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
    private func rowHeight(_ item: TranscriptItem, width: CGFloat) -> CGFloat {
        // 与对话区的渲染一致（#88 S4）：可折叠的助手回复按折叠态测量；不可折叠的行不带折叠状态。
        let folding: TranscriptRowFolding? = TranscriptFolding.isFoldable(item, isLatestStreaming: false)
            ? TranscriptRowFolding(folded: true, expansion: nil, expand: {}, collapse: {}, loadMore: {}) : nil
        return rowHeight(item, width: width, folding: folding)
    }

    // A1-281 R2：无换行的长段落折叠态须明显矮于展开态（预览取前几行并有字数上限，视图按显示行收口）。
    func testUnbrokenLongParagraphFoldsShorterThanOpen() {
        let item = TranscriptItem(id: "long", role: "assistant", text: String(repeating: "这是没有换行的长回复正文。", count: 80))
        let folded = rowHeight(item, width: 390, folding: TranscriptRowFolding(folded: true, expansion: nil, expand: {}, collapse: {}, loadMore: {}))
        let open = rowHeight(item, width: 390, folding: TranscriptRowFolding(folded: false, expansion: nil, expand: {}, collapse: {}, loadMore: {}))
        XCTAssertLessThan(folded, open * 0.7, "折叠态应只露前几行，不能与展开态等高")
    }

    func testDeclaredContentHeightMatchesRowsIncludingTheLatestReply() async throws {
        // 主窗口的页面由 @AppStorage 读写 UserDefaults.standard（测试宿主下不清空），上次停在统计页时会话记录不渲染，
        // 下面的 max 会选中统计页的滚动视图（#95）。这里固定回到对话页，结束后还原原值。
        let pageKey = "palmhelm.mainPage"
        let previousPage = UserDefaults.standard.object(forKey: pageKey)
        UserDefaults.standard.set(0, forKey: pageKey)
        defer {
            if let previousPage { UserDefaults.standard.set(previousPage, forKey: pageKey) } else { UserDefaults.standard.removeObject(forKey: pageKey) }
        }
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.o336.test")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-o336t","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let json = #"{"occupancy":"free","targets":[{"id":"t1","projectName":"p","agentName":"p","status":"idle"}],"history":{"highWater":0,"items":[]}}"#
        s.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8)) }
        s.selectedTarget = "t1"; s.selectedThread = "t1"
        await s.refresh()
        var t = TranscriptThread(); t.status = .ok
        t.items = Self.items(40) + [TranscriptItem(id: "tr-last", role: "assistant", text: Self.markdown(999, long: true))]
        s.transcripts["t1"] = t
        let settings = EngineSettings(defaults: UserDefaults(suiteName: "palmhelm.o337.settings")!)
        let hv = NSHostingView(rootView: MainWindow().environment(s).environment(BridgeEngine(settings: settings)).environment(settings).frame(width: 900, height: 620))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hv
        win.orderBack(nil)
        defer { win.orderOut(nil) }
        spin(1.5)
        let sv = try XCTUnwrap(scrollViews(hv).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        let width = sv.contentView.bounds.width - 32
        // 窗口只渲染最近 renderLimit 行（O1-341）：声明高度要与窗口内的行一致
        let rows = s.transcripts["t1"]!.visibleItems.map { rowHeight($0, width: width) }
        let trueHeight = rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * 10 + 32
        let declared = sv.documentView?.frame.height ?? 0
        XCTAssertEqual(declared, trueHeight, accuracy: trueHeight * 0.02, "声明的内容高度应与各行真实高度之和一致（底部的行要计入滚动范围）")
        // 滚到底部后高度不再变化（懒加载时会随滚动被修正，内容像橡皮筋一样回弹）
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, declared - sv.contentView.bounds.height)))
        sv.reflectScrolledClipView(sv.contentView)
        spin(0.6)
        XCTAssertEqual(sv.documentView?.frame.height ?? 0, declared, accuracy: 1, "滚到底部后内容高度保持稳定")
    }
}
