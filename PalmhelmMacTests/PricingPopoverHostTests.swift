import XCTest
import SwiftUI
import PalmhelmKit
@testable import PalmhelmMac

// O1-372 R4a：价格浮层内容在宿主里渲染（非空规则、长值、短链接），内部滚动有上限，打开前后主页面滚动位置不变。
@MainActor
final class PricingPopoverHostTests: XCTestCase {
    private func pricing(rules: Int, longNote: Bool = true) throws -> UsagePricingInfo {
        let rule = #"{"rule":"cache_1h_write","appliesTo":"cache_write_1h","multiplier":2,"source":"platform.claude.com/docs/en/about-claude/pricing","asOf":"2026-10-24"}"#
        let note = longNote ? #""inference_geo_us_x1_1_when_logged","inference_geo_global_assumed_otherwise""# : ""
        return try JSONDecoder().decode(UsagePricingInfo.self, from: Data(#"""
        {"source":"models.dev/api.json","origin":"downloaded","freshness":"current","versionHash":"abc","asOfT":1792771200000,"lastValidatedT":1792771200000,"lastCheckT":1792771200000,"autoUpdate":true,"updatePolicy":"startup_if_older_than_3d","cacheLongRules":[\#(Array(repeating: rule, count: rules).joined(separator: ","))],"notes":[\#(note)]}
        """#.utf8))
    }

    private func host(_ view: some View, height: CGFloat) -> NSHostingView<AnyView> {
        let h = NSHostingView(rootView: AnyView(view))
        h.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        h.layoutSubtreeIfNeeded()
        return h
    }

    func testDetailContentRendersShortLinkAndLongValuesWithoutOverflow() throws {
        let p = try pricing(rules: 1)
        // 短链接：可点击的站点名 + 日期，不出现裸地址
        let url = try XCTUnwrap(PricingDetails.sourceURL("platform.claude.com/docs/en/about-claude/pricing"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(PricingDetails.sourceName(url), "Claude 定价页")
        XCTAssertFalse(PricingDetails.sourceName(url).contains("http"), "显示文字不含裸地址")
        // 内容视图：宽度不超过 420，长值换行，不水平溢出
        let h = host(PricingDetails(p: p).padding(14).frame(width: 420, alignment: .leading), height: 900)
        XCTAssertLessThanOrEqual(h.fittingSize.width, 421, "长值换行，不超出 420 宽")
        XCTAssertGreaterThan(h.fittingSize.height, 60, "内容非空")
        XCTAssertNotNil(ImageRenderer(content: PricingDetails(p: p).frame(width: 420)).nsImage, "内容可以渲染成图像")
    }

    func testPopoverHasAMaximumHeightAndScrollsInside() throws {
        let short = host(PricingPopoverContent(p: try pricing(rules: 1)), height: 900)
        let tall = host(PricingPopoverContent(p: try pricing(rules: 40)), height: 900)
        XCTAssertLessThanOrEqual(tall.fittingSize.height, 361, "浮层最大高 360，超出在内部滚动")
        XCTAssertGreaterThan(short.fittingSize.height, 60)
        XCTAssertLessThan(short.fittingSize.height, tall.fittingSize.height + 1)
        XCTAssertTrue(hasScrollView(tall), "长内容放在可滚动视图里")
    }

    private func hasScrollView(_ v: NSView) -> Bool {
        if v is NSScrollView { return true }
        return v.subviews.contains { hasScrollView($0) }
    }

    /// 在无障碍树里找到标题匹配的按钮（SwiftUI 按钮不是 NSButton）。
    private func findAXButton(_ root: Any, title: String, depth: Int = 0) -> NSAccessibilityProtocol? {
        guard depth < 40, let obj = root as? NSAccessibilityProtocol else { return nil }
        if (obj.accessibilityLabel() ?? "") == title || (obj.accessibilityTitle() ?? "") == title, obj.accessibilityRole() == .button { return obj }
        for child in (obj.accessibilityChildren() ?? []) {
            if let b = findAXButton(child, title: title, depth: depth + 1) { return b }
        }
        return nil
    }
    private func scrollViews(_ v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = v as? NSScrollView { out.append(s) }
        for sub in v.subviews { out += scrollViews(sub) }
        return out
    }

    /// 打开浮层（同一个 showDetails 状态，经测试接缝 pricingInitiallyExpanded 在出现时打开）：与未打开的同样页面相比，
    /// 页面主滚动位置一致，并且多出一个可见的浮层窗口。
    func testOpeningThePopoverKeepsThePageScrollPosition() async throws {
        func page(expanded: Bool) -> (NSHostingView<AnyView>, NSWindow, MacSession) {
            let session = MacSession()
            session.device = UsageShotFixture.decode(#"{"id":"d","name":"mac","paused":false}"#)
            session.state = UsageShotFixture.state()
            session.link = .connected
            session.usageOverride = { w in UsageShotFixture.usage(w, .normal) }
            session.accountsOverride = { _ in UsageShotFixture.accounts() }
            let settings = EngineSettings(defaults: UserDefaults(suiteName: "palmhelm.o372.popover.\(UUID().uuidString)")!)
            let view = NSHostingView(rootView: AnyView(MacStatsView(initialSegment: .today).environment(session)
                .environment(BridgeEngine(settings: settings)).environment(settings).environment(\.usageNow, UsageShotFixture.fixedNow)
                .environment(\.pricingInitiallyExpanded, expanded)))
            view.frame = NSRect(x: 0, y: 0, width: 1260, height: 900)
            let win = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.contentView = view
            win.orderFrontRegardless()
            return (view, win, session)
        }
        let (plainView, plainWin, plainSession) = page(expanded: false)
        let (openView, openWin, openSession) = page(expanded: true)
        defer { plainWin.orderOut(nil); openWin.orderOut(nil) }
        for (view, session) in [(plainView, plainSession), (openView, openSession)] {
            await session.loadUsage(.h24)
            await session.loadAccounts()
            for _ in 0..<6 { try? await Task.sleep(nanoseconds: 150_000_000); view.layoutSubtreeIfNeeded() }
        }
        let plainScroll = try XCTUnwrap(scrollViews(plainView).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        let openScroll = try XCTUnwrap(scrollViews(openView).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        for scroll in [plainScroll, openScroll] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for _ in 0..<4 { try? await Task.sleep(nanoseconds: 150_000_000); plainView.layoutSubtreeIfNeeded(); openView.layoutSubtreeIfNeeded() }
        XCTAssertEqual(openScroll.contentView.bounds.origin, plainScroll.contentView.bounds.origin, "打开浮层的页面与未打开的页面滚动位置一致")
        XCTAssertEqual(openScroll.contentView.bounds.origin.y, 300, accuracy: 0.5, "滚动位置保持在 300")
        // 浮层窗口：打开的页面比未打开的多出可见的窗口
        let popoverWindows = NSApp.windows.filter { $0.isVisible && $0 !== plainWin && $0 !== openWin && $0.className.lowercased().contains("popover") }
        XCTAssertFalse(popoverWindows.isEmpty, "打开的页面出现了价格细节浮层窗口")
        popoverWindows.forEach { $0.orderOut(nil) }
    }
}
