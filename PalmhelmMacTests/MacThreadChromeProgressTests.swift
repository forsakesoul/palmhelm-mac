import AppKit
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// 包装器（受控时钟）：Kit 的 directionalProgress 经 MacThreadChrome 的输入口径、离散输入失败开放、接收者登记。
@MainActor
final class MacThreadChromeProgressTests: XCTestCase {
    private func make(extent: CGFloat = 100) -> MacThreadChrome { let c = MacThreadChrome(); c.setExtent(extent); return c }
    private func drag(_ c: MacThreadChrome, from y: CGFloat, by deltas: [CGFloat], t: inout Double) -> CGFloat {
        var y = y
        c.observeGeometry(offsetY: y, rawAtBottom: false, layoutChanged: false, now: t)
        for d in deltas { y += d; t += 0.016; c.observeGeometry(offsetY: y, rawAtBottom: false, layoutChanged: false, now: t) }
        return y
    }

    func testProgressFollowsReversesAndIdleHolds() {
        let c = make(); var t = 100.0
        c.phaseChanged(to: .interacting, now: t)
        var y = drag(c, from: 500, by: [25, 25], t: &t)
        XCTAssertEqual(c.progress, 0.5, accuracy: 0.001)
        y = drag(c, from: y, by: [20, 80], t: &t)
        XCTAssertEqual(c.progress, 1, accuracy: 0.001)
        y = drag(c, from: y, by: [-20], t: &t)
        XCTAssertEqual(c.progress, 0.8, accuracy: 0.001, "到端点后立刻反向：无欠账")
        c.phaseChanged(to: .idle, now: t); t += 5
        c.observeGeometry(offsetY: y, rawAtBottom: false, layoutChanged: false, now: t)
        XCTAssertEqual(c.progress, 0.8, accuracy: 0.001, "idle 保持")
    }
    func testOnlyUserGestureCountsAndLayoutCorrectionDoesNot() {
        let c = make(); var t = 100.0
        _ = drag(c, from: 500, by: [30, 30], t: &t)
        XCTAssertEqual(c.progress, 0, "没有 interacting：位置变化不产生进度")
        c.phaseChanged(to: .interacting, now: t)
        c.observeGeometry(offsetY: 600, rawAtBottom: false, layoutChanged: true, now: t + 0.1)
        c.observeGeometry(offsetY: 700, rawAtBottom: false, layoutChanged: true, now: t + 0.2)
        XCTAssertEqual(c.progress, 0, "布局变化帧只同步参考点")
    }
    func testExtentChangeResetsAndInvalidExtentFailsOpen() {
        let c = make(); var t = 100.0
        c.phaseChanged(to: .interacting, now: t); _ = drag(c, from: 500, by: [50], t: &t)
        XCTAssertGreaterThan(c.progress, 0)
        c.setExtent(120); XCTAssertEqual(c.progress, 0); XCTAssertEqual(c.topOcclusion, 120, "遮挡高度立即是新 H")
        c.setExtent(0); XCTAssertEqual(c.progress, 0); XCTAssertEqual(c.topOcclusion, 0)
        c.phaseChanged(to: .interacting, now: t); _ = drag(c, from: 500, by: [50, 50], t: &t)
        XCTAssertEqual(c.progress, 0, "H 未测 / 非法：失败开放（显示）")
        c.setExtent(.nan); XCTAssertEqual(c.extent, 0)
    }
    func testNormalizedOffsetClampsRubberBand() {
        XCTAssertEqual(MacThreadChrome.normalizedOffset(contentOffsetY: -30, insetTop: 0, contentHeight: 2000, containerHeight: 500, insetBottom: 50), 0)
        XCTAssertEqual(MacThreadChrome.normalizedOffset(contentOffsetY: 1700, insetTop: 0, contentHeight: 2000, containerHeight: 500, insetBottom: 50), 1550)
        XCTAssertEqual(MacThreadChrome.normalizedOffset(contentOffsetY: 800, insetTop: 0, contentHeight: 2000, containerHeight: 500, insetBottom: 50), 800)
    }
    func testResetThenOrphanMomentumDoesNotRevive() {
        let c = make(); var t = 100.0
        c.phaseChanged(to: .interacting, now: t); var y = drag(c, from: 500, by: [40], t: &t)
        c.reset(); XCTAssertEqual(c.progress, 0)
        c.phaseChanged(to: .decelerating, now: t); y = drag(c, from: y, by: [30, 30], t: &t)
        XCTAssertEqual(c.progress, 0, "reset 后孤立惯性不复活")
    }
    func testDiscreteInputIsFailOpenForTheNextEpisodeOnly() {
        let c = make(); var t = 100.0
        c.phaseChanged(to: .interacting, now: t); var y = drag(c, from: 500, by: [40], t: &t)
        c.discreteInput()
        XCTAssertEqual(c.progress, 0, "离散输入：立即显示")
        c.phaseChanged(to: .idle, now: t) // 上一次手势的结束不影响登记
        c.phaseChanged(to: .interacting, now: t); y = drag(c, from: y, by: [30, 30], t: &t)
        c.phaseChanged(to: .decelerating, now: t); y = drag(c, from: y, by: [20], t: &t)
        XCTAssertEqual(c.progress, 0, "离散输入后的序列（含惯性）不跟手")
        c.phaseChanged(to: .idle, now: t)
        c.phaseChanged(to: .interacting, now: t); y = drag(c, from: y, by: [30], t: &t)
        XCTAssertGreaterThan(c.progress, 0, "idle 之后新的手势跟手")
        // 新滚轮使登记作废
        c.reset(); c.discreteInput(); c.wheelInput()
        c.phaseChanged(to: .interacting, now: t); _ = drag(c, from: y, by: [30], t: &t)
        XCTAssertGreaterThan(c.progress, 0)
    }
    func testPageKeyClassification() {
        let pg = String(UnicodeScalar(NSPageDownFunctionKey)!)
        XCTAssertTrue(MacScrollInputGuard.GuardView.isPageKey(keyCode: 121, chars: pg))
        XCTAssertTrue(MacScrollInputGuard.GuardView.isPageKey(keyCode: 116, chars: pg))
        XCTAssertTrue(MacScrollInputGuard.GuardView.isPageKey(keyCode: 115, chars: pg))
        XCTAssertTrue(MacScrollInputGuard.GuardView.isPageKey(keyCode: 119, chars: pg))
        XCTAssertTrue(MacScrollInputGuard.GuardView.isPageKey(keyCode: 49, chars: " "))
        XCTAssertFalse(MacScrollInputGuard.GuardView.isPageKey(keyCode: 0, chars: "a"), "普通按键不是翻页")
        XCTAssertFalse(MacScrollInputGuard.GuardView.isPageKey(keyCode: 125, chars: String(UnicodeScalar(NSDownArrowFunctionKey)!)), "方向键不是翻页")
        XCTAssertFalse(MacScrollInputGuard.GuardView.isPageKey(keyCode: 49, chars: "x"))
    }
    func testSinkGenerationOnlyClearsItsOwnRegistration() {
        let c = make(); var a: [CGFloat] = [], b: [CGFloat] = []
        let g1 = c.attachProgressSink { a.append($0) }
        let g2 = c.attachProgressSink { b.append($0) }
        c.detachProgressSink(g1) // 旧登记迟到注销：不得清掉新的
        var t = 100.0; c.phaseChanged(to: .interacting, now: t); _ = drag(c, from: 500, by: [30], t: &t)
        XCTAssertEqual(a.count, 1, "旧接收者只收到登记时的初值"); XCTAssertGreaterThan(b.count, 1)
        c.detachProgressSink(g2)
        let n = b.count; _ = drag(c, from: 530, by: [30], t: &t)
        XCTAssertEqual(b.count, n, "注销后不再推送")
    }
}

/// 测试动作捕获了列视图（含 chrome 本身）：离页 / 卸载的 tearDown 必须断开，否则形成引用环（A2-007 R2）。
@MainActor
final class MacThreadChromeLifecycleTests: XCTestCase {
    func testTearDownReleasesTheTestActionAndItsStrongCapture() {
        weak var released: MacThreadChrome?
        do {
            let c = MacThreadChrome()
            released = c
            c.jumpToLatestForTest = { _ = c.progress } // 与 ThreadColumn 的动作同形：强捕获自己
            c.tearDown()
        }
        XCTAssertNil(released, "tearDown 后释放持有者：没有引用环")
    }

    func testControlWithoutTearDownTheStrongCaptureKeepsTheChromeAlive() {
        weak var leaked: MacThreadChrome?
        do {
            let c = MacThreadChrome()
            leaked = c
            c.jumpToLatestForTest = { _ = c.progress }
        }
        XCTAssertNotNil(leaked, "负控：不清动作时引用环确实存在（证明上一用例有区分度）")
        leaked?.jumpToLatestForTest = nil
        XCTAssertNil(leaked, "手动断开后释放")
    }
}

/// 输入监视器的热路径：连续事件只做 O(1) 归属判断，不搜索视图树（A2-017 R1）。无窗口：视图层级挂在一个普通父视图下。
@MainActor
final class MacScrollInputGuardTests: XCTestCase {
    private func make() -> (root: NSView, guardView: MacScrollInputGuard.GuardView, scroll: NSScrollView, chrome: MacThreadChrome) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let sv = NSScrollView(frame: NSRect(x: 100, y: 0, width: 500, height: 400))
        sv.hasVerticalScroller = true
        let noise = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 400))
        let g = MacScrollInputGuard.GuardView(frame: sv.frame)
        root.addSubview(noise); root.addSubview(sv); root.addSubview(g)
        let c = MacThreadChrome(); c.setExtent(100)
        g.chrome = c
        return (root, g, sv, c)
    }

    func testResolvesOnceThenManyEventsDoNoStructuralSearch() {
        let m = make()
        m.guardView.resolveScrollView()
        XCTAssertTrue(m.guardView.scroll === m.scroll)
        let n0 = m.guardView.resolveCount
        for _ in 0..<500 { m.guardView.route(type: .scrollWheel, locationInWindow: NSPoint(x: 300, y: 200), keyCode: 0, chars: nil, editingText: false) }
        for _ in 0..<50 { m.guardView.route(type: .keyDown, locationInWindow: .zero, keyCode: 0, chars: "a", editingText: false) }
        XCTAssertEqual(m.guardView.resolveCount, n0, "连续事件不触发结构搜索")
    }

    func testKeyAndWheelClassificationStillWorkWithTheCachedScrollView() {
        let m = make(); m.guardView.resolveScrollView()
        var t = 100.0
        m.chrome.phaseChanged(to: .interacting, now: t)
        m.chrome.observeGeometry(offsetY: 500, rawAtBottom: false, layoutChanged: false, now: t); t += 0.02
        m.chrome.observeGeometry(offsetY: 540, rawAtBottom: false, layoutChanged: false, now: t)
        XCTAssertGreaterThan(m.chrome.progress, 0)
        m.guardView.route(type: .keyDown, locationInWindow: .zero, keyCode: 121, chars: "", editingText: true)
        XCTAssertTrue(m.chrome.discreteStateForTest.contains("armed=false"), "文本编辑中的翻页键不登记")
        m.guardView.route(type: .keyDown, locationInWindow: .zero, keyCode: 121, chars: "", editingText: false)
        XCTAssertEqual(m.chrome.progress, 0, "翻页键：立即显示")
        XCTAssertTrue(m.chrome.discreteStateForTest.contains("armed=true"))
        m.guardView.route(type: .scrollWheel, locationInWindow: NSPoint(x: 300, y: 200), keyCode: 0, chars: nil, editingText: false)
        XCTAssertTrue(m.chrome.discreteStateForTest.contains("armed=false"), "本滚动区内的滚轮使旧登记作废")
        m.chrome.discreteInput()
        m.guardView.route(type: .scrollWheel, locationInWindow: NSPoint(x: 10, y: 200), keyCode: 0, chars: nil, editingText: false)
        XCTAssertTrue(m.chrome.discreteStateForTest.contains("armed=true"), "区域外（侧栏）的滚轮不清登记")
    }

    func testUnresolvedScrollViewFailsOpenForPressesInsideTheArea() {
        let m = make()
        XCTAssertNil(m.guardView.scroll)
        let n0 = m.guardView.resolveCount
        m.guardView.route(type: .leftMouseDown, locationInWindow: NSPoint(x: 300, y: 200), keyCode: 0, chars: nil, editingText: false)
        XCTAssertTrue(m.chrome.discreteStateForTest.contains("armed=true"), "未解析：区域内按下失败开放")
        m.chrome.reset()
        m.guardView.route(type: .leftMouseDown, locationInWindow: NSPoint(x: 10, y: 200), keyCode: 0, chars: nil, editingText: false)
        XCTAssertTrue(m.chrome.discreteStateForTest.contains("armed=false"), "区域外不登记")
        XCTAssertEqual(m.guardView.resolveCount, n0, "失败开放也不在事件里重搜")
    }

    func testReplacedScrollViewIsNotUsedAfterItLeavesAndReResolveBindsTheNewOne() {
        let m = make(); m.guardView.resolveScrollView()
        let old = m.scroll
        old.removeFromSuperview()
        m.guardView.resolveScrollView() // 低频入口（换 scope / 重新布局）
        XCTAssertNil(m.guardView.scroll, "旧视图已移除：解析不到，不保留旧引用")
        let fresh = NSScrollView(frame: old.frame); m.root.addSubview(fresh)
        m.guardView.resolveScrollView()
        XCTAssertTrue(m.guardView.scroll === fresh); XCTAssertFalse(m.guardView.scroll === old)
    }

    /// 真实 NSEvent → 解码 → route 的共同入口（handle）：鼠标 / 滚轮事件不得读取键盘专用字段（AppKit 会抛 NSInternalInconsistencyException）。
    func testRealNSEventsGoThroughTheSharedDecodeWithoutTouchingKeyboardFields() {
        let m = make(); m.guardView.resolveScrollView()
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 300, y: 200), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        m.guardView.handle(down, editingText: false) // 滚动条外的普通点击：不登记，不崩
        XCTAssertTrue(m.chrome.discreteStateForTest.contains("armed=false"))
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
        let wheel = NSEvent(cgEvent: cg)!
        m.guardView.handle(wheel, editingText: false)
        m.chrome.discreteInput()
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 300, y: 200), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        m.guardView.handle(drag, editingText: false) // 订阅之外的类型也不崩
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: String(UnicodeScalar(NSPageDownFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSPageDownFunctionKey)!), isARepeat: false, keyCode: 121)!
        m.chrome.reset()
        m.guardView.handle(key, editingText: false)
        XCTAssertTrue(m.chrome.discreteStateForTest.contains("armed=true"), "真实 keyDown 经同一入口登记")
        m.chrome.reset()
        m.guardView.handle(key, editingText: true)
        XCTAssertTrue(m.chrome.discreteStateForTest.contains("armed=false"), "文本编辑中不登记")
    }
}
