import AppKit
import ApplicationServices
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

private final class Calls: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var all: [String] { lock.withLock { v } }
}

/// 真实事件验证（O1-157 F1 / O1-165）：测试点都由「实际 panel frame + 实际形状 + 实际可点控件」算出，并先断言它在 / 不在形状内再投递事件；
/// 面板上的动作有正向计数（点到「允许一次」→ 决定被调用一次），同时断言下层窗口没收到；透明区反过来（下层 +1、面板动作不变），避免双投递。
/// 不做任何全局 mouseDown 重放兜底。CGEvent 投递到其他窗口需要「辅助功能」授权：没有授权时投递类测试 XCTSkip（环境限制，不是通过），
/// 请 Owner 在授权过的机器上跑：xcodebuild test -only-testing:PalmhelmMacTests/NotchRealEventTests。
/// 全局 mouseMoved 监视本身不需要辅助功能权限（只有键盘事件需要）。
@MainActor
final class NotchRealEventTests: XCTestCase {
    private final class Counting: NSView {
        var downs = 0, scrolls = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { downs += 1 }
        override func scrollWheel(with event: NSEvent) { scrolls += 1 }
    }

    private struct Rig {
        let c: NotchController
        let under: Counting
        let screen: NSScreen
        let calls: Calls
    }

    /// 让主 actor 上的任务（控制器的 tick、SwiftUI 回报）继续跑：用 Task.sleep 让出，而不是阻塞主线程的 RunLoop。
    private func spin(_ s: TimeInterval = 0.05) async { try? await Task.sleep(for: .seconds(s)) }
    private func cg(_ p: CGPoint, _ screen: NSScreen) -> CGPoint { CGPoint(x: p.x, y: screen.frame.maxY - p.y) } // AppKit → CG 全局
    private func move(_ p: CGPoint, _ r: Rig) { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cg(p, r.screen), mouseButton: .left)?.post(tap: .cghidEventTap) }
    private func click(_ p: CGPoint, _ r: Rig) {
        for t in [CGEventType.leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: cg(p, r.screen), mouseButton: .left)?.post(tap: .cghidEventTap) }
    }
    private func scroll(_ p: CGPoint, _ r: Rig) {
        move(p, r)
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    /// 展开的刘海（带一条待答，所以有「允许一次」按钮）+ 覆盖其下方的计数窗口。
    private func rig() async throws -> Rig {
        guard let screen = NSScreen.main else { throw XCTSkip("没有屏幕") }
        let s = MacSession()
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b"},"occupancy":"free","targets":[{"projectName":"P","id":"A"}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.link = .connected
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d","name":"mac","paused":false,"permission":"control"}"#.utf8))
        let now = Int(Date().timeIntervalSince1970 * 1000)
        s.approvals["A"] = ApprovalView(id: "A", status: "pending", targetLabel: "P", attribution: "exact", toolName: "Bash", summary: "ls", truncated: false, createdT: now - 1000, expiresT: now + 600_000)
        let calls = Calls()
        s.decideOverride = { a, d in calls.add("\(a.id):\(d)") }
        let bar = NotchMetrics.of(screen).barHeight
        let under = Counting(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let win = NSWindow(contentRect: NSRect(x: screen.frame.midX - 500, y: screen.frame.maxY - bar - 600, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = under
        win.level = .normal
        win.orderFrontRegardless()
        addTeardownBlock { @MainActor in win.orderOut(nil); win.close() }
        let c = NotchController()
        c.attach(session: s)
        addTeardownBlock { @MainActor in c.detach() }
        c.debugSetExpanded(true)
        for _ in 0..<60 { await spin(0.05); c.debugTick(); if c.primaryControlFrame != nil, let f = c.panelFrame, abs(f.width - NotchGeometry.panelSize(shape: c.layout.size).width) < 0.5 { break } } // 展开稳定、按钮位置已回报
        return Rig(c: c, under: under, screen: screen, calls: calls)
    }

    /// 可见、可点击控件的中心（屏幕坐标）：来自视图回报的控件 frame（面板内容坐标，左上原点）。
    private func controlCenter(_ r: Rig) throws -> CGPoint {
        let f = try XCTUnwrap(r.c.primaryControlFrame, "展开卡上的「允许一次」按钮没有回报位置 pin=\(String(describing: r.c.pin.id)) card=\(String(describing: r.c.pinnedApproval?.id)) mode=\(r.c.layout.mode) frame=\(String(describing: r.c.panelFrame)) vis=\(r.c.panelVisible)")
        let p = try XCTUnwrap(r.c.panelFrame)
        return CGPoint(x: p.minX + f.midX, y: p.maxY - f.midY)
    }
    /// 面板内的透明区：形状右下圆角外侧——在实际 panel frame 里、在实际（live）形状外。
    private func transparentPoint(_ r: Rig) throws -> CGPoint {
        let p = try XCTUnwrap(r.c.panelFrame)
        return CGPoint(x: p.maxX - 1, y: p.minY + 1)
    }
    private func inShape(_ pt: CGPoint, _ r: Rig) -> Bool {
        let live = r.c.liveShape ?? (r.c.layout.size, r.c.layout.radius)
        return NotchHit.inside(mouse: pt, screenFrame: r.screen.frame, shape: live.size, radius: live.radius)
    }

    // MARK: 不需要授权：测试点的几何前提自洽

    func testHitPointsAreDerivedFromTheRealPanelAndShape() async throws {
        let r = try await rig()
        let ctl = try controlCenter(r)
        let panel = try XCTUnwrap(r.c.panelFrame)
        XCTAssertTrue(panel.contains(ctl), "控件中心在面板内")
        XCTAssertTrue(inShape(ctl, r), "控件中心在实际形状内（不依赖内容高度，取自视图回报的控件位置）")
        let clear = try transparentPoint(r)
        XCTAssertTrue(panel.contains(clear), "透明点在实际 panel frame 内（不是面板外）")
        XCTAssertFalse(inShape(clear, r), "透明点在实际形状外")
        r.c.updateHitRegion(mouse: ctl)
        XCTAssertEqual(r.c.ignoresMouseEvents, false)
        r.c.updateHitRegion(mouse: clear)
        XCTAssertEqual(r.c.ignoresMouseEvents, true)
    }

    // MARK: 需要辅助功能授权：真实事件

    func testRealEventsThroughTheShapeEdges() async throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("CGEvent 投递需要辅助功能授权，测试环境没有；请 Owner 在授权过的机器上运行本测试") }
        let r = try await rig()
        let button = try controlCenter(r), clear = try transparentPoint(r)
        XCTAssertTrue(inShape(button, r)); XCTAssertFalse(inShape(clear, r))
        func settle() async { await spin(0.25) }
        // 1) 形状内的可见按钮：移动后立即点击——面板动作 +1（正向），下层不收到；滚轮不落到下层
        move(button, r); click(button, r); scroll(button, r); await settle()
        XCTAssertEqual(r.calls.all.count, 1, "面板上的按钮首击生效（正向计数）")
        XCTAssertEqual([r.under.downs, r.under.scrolls], [0, 0], "形状内：下层没收到点击与滚轮")
        // 2) 透明区：下层 +1，面板动作不变（不双投递）
        move(clear, r); click(clear, r); scroll(clear, r); await settle()
        XCTAssertEqual([r.under.downs, r.under.scrolls], [1, 1], "透明区穿透到下层")
        XCTAssertEqual(r.calls.all.count, 1, "面板动作没有被透明区的点击触发")
        // 3) 刚移出：从按钮直接移到透明区并立即点击
        move(button, r); move(clear, r); click(clear, r); await settle()
        XCTAssertEqual(r.under.downs, 2, "刚移出立即点击：穿透")
        XCTAssertEqual(r.calls.all.count, 1)
        // 4) 刚进入：从透明区直接移到按钮并立即点击——面板动作再 +1，下层不变
        move(clear, r); move(button, r); click(button, r); await settle()
        XCTAssertEqual(r.under.downs, 2, "刚进入立即点击：落在面板上，不落到下层")
        XCTAssertEqual(r.calls.all.count, 2)
    }

    /// 过渡中：点取「始终在形状内」（起止形状的交集里）与「始终在形状外但在 panel frame 内」（起止形状之外），两者与动画进度无关。
    func testRealEventsDuringExpandAndCollapseTransitions() async throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("CGEvent 投递需要辅助功能授权，测试环境没有；请 Owner 在授权过的机器上运行本测试") }
        let r = try await rig()
        let button = try controlCenter(r)
        for phase in ["collapsing", "expanding"] {
            let startShape = r.c.liveShape ?? (r.c.layout.size, r.c.layout.radius)
            r.c.debugSetExpanded(phase == "expanding")
            // 过渡刚开始（形状还在途中，面板是起止并集 + 过冲余量）
            let panel = try XCTUnwrap(r.c.panelFrame)
            let endShape = (r.c.layout.size, r.c.layout.radius)
            let always = CGPoint(x: r.screen.frame.midX, y: r.screen.frame.maxY - NotchMetrics.of(r.screen).barHeight / 2) // 起止形状都含的刘海中线
            let never = CGPoint(x: panel.maxX - 1, y: panel.minY + 1) // 并集面板的右下角：起止形状之外
            func inside(_ s: (CGSize, CGFloat), _ p: CGPoint) -> Bool { NotchHit.inside(mouse: p, screenFrame: r.screen.frame, shape: s.0, radius: s.1) }
            XCTAssertTrue(inside(startShape, always) && inside(endShape, always), "\(phase)：always 点在起止形状内")
            XCTAssertTrue(panel.contains(never) && !inside(startShape, never) && !inside(endShape, never), "\(phase)：never 点在 panel frame 内、起止形状外")
            let before = r.under.downs
            move(never, r); click(never, r); await spin(0.1)
            XCTAssertEqual(r.under.downs, before + 1, "\(phase)：动画中形状外的透明区穿透")
            move(always, r); click(always, r); await spin(0.1)
            XCTAssertEqual(r.under.downs, before + 1, "\(phase)：动画中形状内（刘海条）由面板接收")
            for _ in 0..<40 { await spin(0.05) } // 过渡结束
            _ = button
        }
    }
}
