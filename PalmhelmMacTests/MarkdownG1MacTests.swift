import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// G1（A1-013 §4）Mac：真实 MainWindow 宿主里的 Markdown 选择与复制（中文 / 加粗 / emoji / 代码）、同 ID 增长后的内容更新。
/// SwiftUI 的可选文字在 AppKit 里是 AppKitTextInteractionView：这里直接对它调用 selectAll: / copy:，读系统剪贴板与它的无障碍字符串；
/// 合成鼠标事件不能触发 SwiftUI 的选择手势，所以选择动作不经鼠标。真实 VoiceOver 朗读留装机验收。
@MainActor
final class MarkdownG1MacTests: XCTestCase {
    private func mount(_ s: MacSession) -> (NSWindow, NSHostingView<some View>) {
        let settings = EngineSettings(defaults: UserDefaults(suiteName: "palmhelm.g1.mac.settings.\(UUID().uuidString)")!)
        let hv = NSHostingView(rootView: MainWindow().environment(s).environment(BridgeEngine(settings: settings)).environment(settings).frame(width: 1000, height: 700))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hv
        win.orderBack(nil)
        return (win, hv)
    }

    private func interactions(_ v: NSView) -> [NSView] {
        (String(describing: type(of: v)) == "AppKitTextInteractionView" ? [v] : []) + v.subviews.flatMap(interactions)
    }

    private func content(_ v: NSView) -> String { v.accessibilityString(for: NSRange(location: 0, length: v.accessibilityNumberOfCharacters())) ?? "" }

    private func copyAll(_ v: NSView, in win: NSWindow) -> String {
        NSPasteboard.general.clearContents()
        _ = win.makeFirstResponder(v)
        v.perform(NSSelectorFromString("selectAll:"), with: nil)
        v.perform(NSSelectorFromString("copy:"), with: nil)
        return NSPasteboard.general.string(forType: .string) ?? ""
    }

    private func session(items: [TranscriptItem]) async throws -> MacSession {
        let s = MacSession()
        s.streamDisabled = true
        s.preferences = UserDefaults(suiteName: "palmhelm.g1.mac.\(UUID().uuidString)")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-g1","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let json = #"{"occupancy":"free","targets":[{"id":"t1","projectName":"p","agentName":"p","status":"idle"}],"history":{"highWater":0,"items":[]}}"#
        s.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8)) }
        s.selectedTarget = "t1"; s.selectedThread = "t1"
        await s.refresh()
        var t = TranscriptThread(); t.status = .ok
        t.items = items
        s.transcripts["t1"] = t
        return s
    }

    func testSelectAndCopyChineseBoldEmojiAndCodeInTheRealWindow() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let ud = UserDefaults.standard
        let pageKey = "palmhelm.mainPage"
        let prev = ud.object(forKey: pageKey); ud.set(0, forKey: pageKey)
        defer { if let prev { ud.set(prev, forKey: pageKey) } else { ud.removeObject(forKey: pageKey) } }
        let s = try await session(items: [TranscriptItem(id: "a", role: "assistant", text: "你好 **加粗中文词** 😀👍🏽\n\n```\nvalue42\n```")])
        let (win, hv) = mount(s)
        defer { win.orderOut(nil); win.contentView = nil; win.close() }
        try? await Task.sleep(for: .seconds(2))
        let views = interactions(hv)
        XCTAssertEqual(views.count, 2, "段落与代码块各一个可选文字视图")
        XCTAssertEqual(content(views[0]), "你好 加粗中文词 😀👍🏽", "读屏文本：显示文字，不带 Markdown 标记，emoji 完整")
        XCTAssertEqual(content(views[1]), "value42", "代码块正文")
        XCTAssertEqual(copyAll(views[0], in: win), "你好 加粗中文词 😀👍🏽", "复制到的富文本与显示文字一致")
        XCTAssertEqual(copyAll(views[1], in: win), "value42", "代码原样复制")
        // 顺序：段落在代码块之前（自上而下）
        let order = views.map { $0.convert($0.bounds, to: nil).minY }
        XCTAssertGreaterThan(order[0], order[1], "AppKit 坐标系里上方的 y 更大：段落在上、代码在下")
    }

    func testSameIdGrowthUpdatesTheSelectableContent() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let ud = UserDefaults.standard
        let pageKey = "palmhelm.mainPage"
        let prev = ud.object(forKey: pageKey); ud.set(0, forKey: pageKey)
        defer { if let prev { ud.set(prev, forKey: pageKey) } else { ud.removeObject(forKey: pageKey) } }
        let base = "流式起点：中文 **加粗**"
        let s = try await session(items: [TranscriptItem(id: "stream", role: "assistant", text: base)])
        let (win, hv) = mount(s)
        defer { win.orderOut(nil); win.contentView = nil; win.close() }
        try? await Task.sleep(for: .seconds(2))
        XCTAssertEqual(interactions(hv).map(content), ["流式起点：中文 加粗"])
        for n in 1...3 {
            let grown = base + (1...n).map { "\n\n追加第 \($0) 段 😀" }.joined()
            s.transcripts["t1"]?.items[0] = TranscriptItem(id: "stream", role: "assistant", text: grown)
            try? await Task.sleep(for: .milliseconds(700))
            hv.needsLayout = true; hv.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            let texts = interactions(hv).map(content)
            XCTAssertEqual(texts.count, n + 1, "同一个 id 增长到 \(n + 1) 段：\(texts)")
            XCTAssertEqual(texts.last, "追加第 \(n) 段 😀", "最新一段正文更新：\(texts)")
        }
        let views = interactions(hv)
        XCTAssertEqual(copyAll(views.last!, in: win), "追加第 3 段 😀", "增长后新段仍可选择复制")
    }
}
