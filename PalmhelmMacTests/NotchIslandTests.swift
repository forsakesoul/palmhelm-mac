import AppKit
import SwiftUI
import XCTest
@testable import PalmhelmMac

/// 刘海岛：档位判定、几何、弹簧参数、悬停意图、瞬时提示、事件差分、像素角色与角色偏好。
@MainActor
final class NotchIslandTests: XCTestCase {
    private let notch = NotchMetrics(notchWidth: 185, barHeight: 32)
    private let flat = NotchMetrics(notchWidth: 0, barHeight: 34)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: 档位

    func testWaitingBeatsWorkingBeatsIdle() {
        XCTAssertEqual(NotchRules.base(pending: 0, running: 0), .idle)
        XCTAssertEqual(NotchRules.base(pending: 0, running: 2), .working)
        XCTAssertEqual(NotchRules.base(pending: 1, running: 2), .waiting, "待答优先于工作")
    }

    func testModePrecedenceExpandedThenToastThenCompact() {
        XCTAssertEqual(NotchRules.mode(base: .working, hasToast: true, expanded: true), .expanded)
        XCTAssertEqual(NotchRules.mode(base: .working, hasToast: true, expanded: false), .toast)
        XCTAssertEqual(NotchRules.mode(base: .waiting, hasToast: false, expanded: false), .compact(.waiting))
    }

    func testNoNotchScreenHidesWhenIdleButNotchScreenKeepsPanel() {
        XCTAssertTrue(NotchRules.isHidden(hasNotch: false, base: .idle, hasToast: false, expanded: false))
        XCTAssertFalse(NotchRules.isHidden(hasNotch: true, base: .idle, hasToast: false, expanded: false), "有刘海：空闲只剩硬件刘海，面板仍在接收悬停")
        XCTAssertFalse(NotchRules.isHidden(hasNotch: false, base: .idle, hasToast: true, expanded: false), "提示时显示")
        XCTAssertFalse(NotchRules.isHidden(hasNotch: false, base: .working, hasToast: false, expanded: false))
    }

    // MARK: 几何

    func testCompactSizesWithNotchWrapTheHardwareNotch() {
        XCTAssertEqual(NotchGeometry.compactSize(notch, base: .idle), CGSize(width: 185, height: 32), "空闲只剩刘海")
        let w = NotchGeometry.compactSize(notch, base: .working), a = NotchGeometry.compactSize(notch, base: .waiting)
        XCTAssertEqual(w.width, 185 + NotchGeometry.wingLeftWidth + NotchGeometry.wingRightWorking)
        XCTAssertGreaterThan(a.width, w.width, "待答右翼放倒计时更宽")
        XCTAssertEqual(w.height, 32)
    }

    // R2（实机）：紧凑态左翼内边距 ≥ 8pt，角色不被形状裁掉；三段宽度之和恰好等于紧凑宽（超宽会被居中挤出形状）
    func testWingsSumToTheCompactWidthAndKeepTheLeadingInset() {
        XCTAssertGreaterThanOrEqual(NotchGeometry.leadingInset, 8)
        XCTAssertGreaterThanOrEqual(NotchGeometry.wingLeftWidth, NotchGeometry.leadingInset + NotchGeometry.characterWidth, "左翼放得下 8pt 内边距 + 30pt 角色")
        XCTAssertEqual(NotchGeometry.characterWidth, CGFloat(PixelBitmaps.cols) * PixelBitmaps.cell)
        for b: NotchBase in [.idle, .working, .waiting] {
            XCTAssertEqual(NotchGeometry.wingLeft(b) + notch.notchWidth + NotchGeometry.wingRight(b), NotchGeometry.compactSize(notch, base: b).width, "\(b)")
        }
    }

    func testNoCharacterTouchesTheLeftEdgeOrOverflowsItsCanvas() {
        for c in NotchCharacter.allCases {
            for mode in [PixelMode.run, .wait, .done] {
                let xs = (0..<48).flatMap { PixelBitmaps.cells(c, mode: mode, tick: $0, still: false) }.map(\.x)
                XCTAssertGreaterThanOrEqual(xs.min() ?? 0, 0, "\(c) \(mode)")
                XCTAssertLessThan(xs.max() ?? 0, PixelBitmaps.cols, "\(c) \(mode) 不超出画布宽（30pt）")
            }
        }
    }

    func testNoNotchCompactStaysWithin100to160By28to32() {
        for b: NotchBase in [.idle, .working, .waiting] {
            let s = NotchGeometry.compactSize(flat, base: b)
            XCTAssertTrue((100...160).contains(s.width) && (28...32).contains(s.height), "\(b) \(s)")
        }
    }

    func testExpandedSizeIsAtMost40PercentOfScreenAndAvoidsTheNotchBar() {
        let small = NotchGeometry.expandedSize(notch, contentHeight: 100, screenHeight: 900)
        XCTAssertEqual(small.width, 400)
        XCTAssertEqual(small.height, 32 + 8 + 100 + 16, "顶部让出刘海那一条 + 内容 + 底边距")
        let huge = NotchGeometry.expandedSize(notch, contentHeight: 5000, screenHeight: 900)
        XCTAssertEqual(huge.height, 360, "上限约屏高 40%，超出部分内部滚动")
        XCTAssertEqual(NotchGeometry.expandedSize(flat, contentHeight: 100, screenHeight: 900).height, 8 + 100 + 16, "无刘海不用让出刘海条")
    }

    func testPanelAddsOnlyTheEarsAndRadiiGrowWhenExpanded() {
        XCTAssertEqual(NotchGeometry.panelSize(shape: CGSize(width: 262, height: 32)), CGSize(width: 262 + 16, height: 32))
        XCTAssertEqual(NotchGeometry.radius(for: .compact(.idle)), 10)
        XCTAssertEqual(NotchGeometry.radius(for: .expanded), 22)
    }

    func testSpringParametersMatchTheMeasuredFit() {
        XCTAssertEqual(NotchSpring.stiffness, 300)
        XCTAssertEqual(NotchSpring.expandDamping, 29)
        XCTAssertEqual(NotchSpring.collapseDamping, 2 * 300.0.squareRoot(), accuracy: 1e-9, "收起临界阻尼，无回弹")
        let zeta = NotchSpring.expandDamping / (2 * NotchSpring.stiffness.squareRoot())
        let overshoot = exp(-Double.pi * zeta / (1 - zeta * zeta).squareRoot())
        XCTAssertLessThanOrEqual(overshoot, 0.015, "展开过冲 ≤1.5%")
        XCTAssertGreaterThan(overshoot, 0, "展开有轻微过冲")
        XCTAssertTrue(NotchSpring.grows(from: CGSize(width: 262, height: 32), to: CGSize(width: 400, height: 200)))
        XCTAssertFalse(NotchSpring.grows(from: CGSize(width: 400, height: 200), to: CGSize(width: 262, height: 32)))
    }

    // MARK: 悬停意图

    func testCompactAccessibilitySummaryKeepsStatusAndCountdown() {
        XCTAssertEqual(NotchRules.accessibilitySummary(base: .working, pending: 0, running: 2, remaining: nil), "工作中 2 个")
        XCTAssertEqual(NotchRules.accessibilitySummary(base: .waiting, pending: 1, running: 2, remaining: 252), "1 条待答，4 分 12 秒后超时")
        XCTAssertEqual(NotchRules.accessibilitySummary(base: .waiting, pending: 2, running: 0, remaining: 252), "2 条待答，4 分 12 秒后超时，最近一条")
        XCTAssertEqual(NotchRules.accessibilitySummary(base: .idle, pending: 0, running: 0, remaining: nil), "Palmhelm")
    }

    func testClickModeNeverOpensFromHoverAndStaysOpenAfterLeaving() {
        var h = NotchHoverState()
        h.update(inside: true, now: t0, trigger: .click)
        XCTAssertFalse(h.update(inside: true, now: t0.addingTimeInterval(10), trigger: .click))
        h.force(expanded: true)
        XCTAssertTrue(h.update(inside: false, now: t0.addingTimeInterval(11), trigger: .click))
        XCTAssertTrue(h.update(inside: false, now: t0.addingTimeInterval(100), trigger: .click))
        h.dismiss()
        XCTAssertFalse(h.update(inside: true, now: t0.addingTimeInterval(101), trigger: .click))
    }

    func testExplicitDismissCannotImmediatelyReopenUnderThePointer() {
        var h = NotchHoverState()
        h.force(expanded: true)
        h.dismiss()
        XCTAssertFalse(h.update(inside: true, now: t0))
        XCTAssertFalse(h.update(inside: true, now: t0.addingTimeInterval(10)))
        h.update(inside: false, now: t0.addingTimeInterval(11))
        XCTAssertFalse(h.update(inside: true, now: t0.addingTimeInterval(12)))
        XCTAssertTrue(h.update(inside: true, now: t0.addingTimeInterval(12.41)))
    }

    func testChangingTriggerStartsAFreshHoverDwell() {
        var h = NotchHoverState()
        h.update(inside: true, now: t0)
        h.update(inside: true, now: t0.addingTimeInterval(0.3), trigger: .click)
        XCTAssertFalse(h.update(inside: true, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(h.update(inside: true, now: t0.addingTimeInterval(1.39)))
        XCTAssertTrue(h.update(inside: true, now: t0.addingTimeInterval(1.41)))
    }

    func testPinnedClickExpansionHoldsToastAndApprovalUntilDismissed() {
        var h = NotchHoverState()
        var pin = NotchCardPin()
        var toast = NotchToastState()
        toast.post(NotchEvent(kind: .newRequest, target: "sample"), now: t0, held: false)
        h.force(expanded: true)
        pin.sync(expanded: h.expanded, pending: ["a"])
        h.update(inside: false, now: t0.addingTimeInterval(10), trigger: .click)
        pin.sync(expanded: h.expanded, pending: ["b"])
        toast.tick(now: t0.addingTimeInterval(10), held: h.expanded)
        XCTAssertEqual(pin.id, "a", "点击展开期间新卡不替换已钉住的卡")
        XCTAssertNotNil(toast.current, "明确收回前，原提示保持")
        h.dismiss()
        pin.sync(expanded: h.expanded, pending: ["b"])
        XCTAssertNil(pin.id)
    }

    func testInteractionPreferenceDefaultsPersistsAndFallsBackInIsolatedDefaults() {
        let suite = "palmhelm.test.notch.interaction.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = NotchInteractionStore(defaults: d)
        XCTAssertEqual(store.trigger, .hover)
        store.trigger = .click
        XCTAssertEqual(d.string(forKey: NotchInteractionStore.key), "click")
        XCTAssertEqual(NotchInteractionStore(defaults: d).trigger, .click)
        d.set("unknown", forKey: NotchInteractionStore.key)
        XCTAssertEqual(NotchInteractionStore(defaults: d).trigger, .hover)
    }

    func testInteractionStoreDoesNotWriteRealPreferencesInTestHost() {
        let before = UserDefaults.standard.object(forKey: NotchInteractionStore.key) as? NSObject
        let store = NotchInteractionStore()
        store.trigger = .click
        XCTAssertEqual(UserDefaults.standard.object(forKey: NotchInteractionStore.key) as? NSObject, before)
        store.trigger = .hover
    }

    func testNotchPanelOnlyAcceptsKeyboardFocusAfterExplicitRequestAndHandlesEscape() {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey, "悬停和瞬时提示不能取得键盘焦点")
        XCTAssertFalse(panel.canBecomeMain)
        panel.acceptsKeyboardFocus = true
        XCTAssertTrue(panel.canBecomeKey)
        var dismissed = false
        panel.onDismiss = { dismissed = true }
        let other = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
        panel.sendEvent(other)
        XCTAssertFalse(dismissed, "普通窗口事件必须直接交回 AppKit，不读取字符或触发收回")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        panel.sendEvent(escape)
        XCTAssertTrue(dismissed)
        dismissed = false
        let toggle = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
        panel.sendEvent(toggle)
        XCTAssertTrue(dismissed, "面板非激活但持有键盘焦点时快捷键也可收回")
        panel.acceptsKeyboardFocus = false
        XCTAssertFalse(panel.canBecomeKey)
    }

    func testExplicitControllerOpenAndEscapeUseTheSameStateAndReleaseKeyboardEligibility() throws {
        let suite = "palmhelm.test.notch.controller.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let preferences = NotchInteractionStore(defaults: d)
        preferences.trigger = .click
        let controller = NotchController(interaction: preferences)
        controller.attach(session: MacSession())
        defer { controller.detach() }
        let number = try XCTUnwrap(controller.panelWindowNumber)
        let panel = try XCTUnwrap(NSApp.window(withWindowNumber: number) as? NotchPanel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        controller.toggleExpansion()
        XCTAssertTrue(controller.isExpanded)
        XCTAssertTrue(panel.canBecomeKey)
        controller.debugTick()
        XCTAssertTrue(controller.isExpanded, "点击模式不因当前鼠标在别处而收回")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: number, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        panel.sendEvent(escape)
        XCTAssertFalse(controller.isExpanded)
        XCTAssertFalse(panel.canBecomeKey)
        controller.toggleExpansion()
        XCTAssertTrue(controller.isExpanded)
        controller.toggleExpansion()
        XCTAssertFalse(controller.isExpanded, "菜单/原生按钮的相同入口可以收回")
        controller.detach()
        XCTAssertFalse(controller.isExpanded)
        XCTAssertEqual(controller.mouseMonitorCount, 0)
    }

    func testHoverExpandsOnlyAfterContinuousDwellOf0_4s() {
        var h = NotchHoverState()
        XCTAssertFalse(h.update(inside: true, now: t0))
        XCTAssertFalse(h.update(inside: true, now: t0.addingTimeInterval(0.39)))
        XCTAssertTrue(h.update(inside: true, now: t0.addingTimeInterval(0.41)))
    }

    func testQuickInAndOutNeverFlashes() {
        var h = NotchHoverState()
        h.update(inside: true, now: t0)
        h.update(inside: false, now: t0.addingTimeInterval(0.3)) // 0.4s 之前离开：计时重置
        h.update(inside: true, now: t0.addingTimeInterval(0.35))
        XCTAssertFalse(h.update(inside: true, now: t0.addingTimeInterval(0.7)), "重新计时：从 0.35 起只过了 0.35s")
        XCTAssertTrue(h.update(inside: true, now: t0.addingTimeInterval(0.76)))
    }

    func testLeaveHasA0_35sGraceAndReEntryCancelsIt() {
        var h = NotchHoverState()
        h.update(inside: true, now: t0); h.update(inside: true, now: t0.addingTimeInterval(0.5))
        XCTAssertTrue(h.expanded)
        XCTAssertTrue(h.update(inside: false, now: t0.addingTimeInterval(1.0)))
        XCTAssertTrue(h.update(inside: false, now: t0.addingTimeInterval(1.30)), "宽限内仍展开")
        XCTAssertFalse(h.update(inside: false, now: t0.addingTimeInterval(1.40)))
        // 宽限内回来：取消收起
        var g = NotchHoverState()
        g.update(inside: true, now: t0); g.update(inside: true, now: t0.addingTimeInterval(0.5))
        g.update(inside: false, now: t0.addingTimeInterval(1.0))
        g.update(inside: true, now: t0.addingTimeInterval(1.2))
        XCTAssertTrue(g.update(inside: false, now: t0.addingTimeInterval(1.3)))
        XCTAssertTrue(g.update(inside: false, now: t0.addingTimeInterval(1.6)), "离开计时从 1.3 重新算")
        XCTAssertFalse(g.update(inside: false, now: t0.addingTimeInterval(1.7)))
    }

    // MARK: 瞬时提示

    private func ev(_ k: NotchEventKind = .newRequest, _ t: String = "proj") -> NotchEvent { NotchEvent(kind: k, target: t) }

    func testToastRetractsAfterAbout3Seconds() {
        var s = NotchToastState()
        s.post(ev(), now: t0, held: false)
        XCTAssertNotNil(s.current)
        s.tick(now: t0.addingTimeInterval(2.9), held: false)
        XCTAssertNotNil(s.current)
        s.tick(now: t0.addingTimeInterval(3.0), held: false)
        XCTAssertNil(s.current)
    }

    func testSameTargetEventsMergeCountsAndRestartTheTimerWithoutQueueing() {
        var s = NotchToastState()
        s.post(ev(.newRequest, "A"), now: t0, held: false)
        s.post(ev(.newRequest, "A"), now: t0.addingTimeInterval(2), held: false)
        XCTAssertEqual(s.current?.count, 2)
        XCTAssertEqual(s.current?.text, "A · 等你处理（2）")
        s.tick(now: t0.addingTimeInterval(4.9), held: false)
        XCTAssertNotNil(s.current, "合并后重新计时")
        s.post(ev(.done, "B"), now: t0.addingTimeInterval(5), held: false) // 不同事件：替换，不排队
        XCTAssertEqual(s.current?.event.target, "B")
        s.tick(now: t0.addingTimeInterval(8.1), held: false)
        XCTAssertNil(s.current, "没有排队的后续提示")
    }

    func testHoveringOrOperatingNeitherRetractsNorReplacesTheToast() {
        var s = NotchToastState()
        s.post(ev(.newRequest, "A"), now: t0, held: false)
        s.tick(now: t0.addingTimeInterval(10), held: true)
        XCTAssertNotNil(s.current, "悬停 / 操作中不收回")
        s.post(ev(.done, "B"), now: t0.addingTimeInterval(10), held: true)
        XCTAssertEqual(s.current?.event.target, "A", "不替换正在看的卡片")
        s.post(ev(.newRequest, "A"), now: t0.addingTimeInterval(10), held: true)
        XCTAssertEqual(s.current?.count, 2, "同一目标仍可合并计数")
        s.tick(now: t0.addingTimeInterval(10.5), held: false) // 刚松开：合并那一下重新计时 3 秒
        XCTAssertNotNil(s.current)
        s.tick(now: t0.addingTimeInterval(13.1), held: false)
        XCTAssertNil(s.current)
        // 一直悬停后松开：至少再留 1 秒
        var h = NotchToastState()
        h.post(ev(.newRequest, "A"), now: t0, held: false)
        h.tick(now: t0.addingTimeInterval(20), held: true)
        h.tick(now: t0.addingTimeInterval(20.5), held: false)
        XCTAssertNotNil(h.current)
        h.tick(now: t0.addingTimeInterval(21.1), held: false)
        XCTAssertNil(h.current)
    }

    func testToastWhileHeldWithNothingShowingIsDropped() {
        var s = NotchToastState()
        s.post(ev(), now: t0, held: true)
        XCTAssertNil(s.current, "悬停时来的新事件不弹（待答数仍在紧凑档 / 展开卡里）")
    }

    // MARK: 事件差分

    func testOnlyThreeEventKindsAreProducedAndFirstSnapshotIsSilent() {
        var a = NotchSnapshot(); a.link = .connected
        XCTAssertTrue(NotchEvents.diff(old: nil, new: a).isEmpty, "首次观测不弹：启动同步的旧数据不算新事件")
        var b = a; b.pending["p1"] = "proj"
        XCTAssertEqual(NotchEvents.diff(old: a, new: b), [NotchEvent(kind: .newRequest, target: "proj")])
        XCTAssertTrue(NotchEvents.diff(old: b, new: b).isEmpty, "已有的不重复弹")
        var running = a; running.running["c1"] = "proj"
        var done = a; done.finished["c1"] = "proj"
        XCTAssertEqual(NotchEvents.diff(old: running, new: done), [NotchEvent(kind: .done, target: "proj")], "明确完成：之前在途、现在 finished")
        var finishedAtStart = a; finishedAtStart.finished["c9"] = "x"
        XCTAssertTrue(NotchEvents.diff(old: a, new: finishedAtStart).isEmpty, "没见过它在途就不报完成（历史里的旧命令）")
        var off = a; off.link = .offline
        XCTAssertEqual(NotchEvents.diff(old: a, new: off), [NotchEvent(kind: .connectionError, target: "Bridge")])
        var other = a; other.link = .other
        XCTAssertTrue(NotchEvents.diff(old: a, new: other).isEmpty, "只有 connected → offline 才算关键连接错误")
        var progress = a; progress.running["c2"] = "proj" // 在途变化本身（progress）不弹
        XCTAssertTrue(NotchEvents.diff(old: a, new: progress).isEmpty)
    }

    // MARK: 像素角色

    func testEveryFrameFitsTheCanvasForAllCharactersModesAndTicks() {
        for c in NotchCharacter.allCases {
            for mode in [PixelMode.run, .wait, .done] {
                for tick in 0..<48 {
                    for still in [false, true] {
                        let cells = PixelBitmaps.cells(c, mode: mode, tick: tick, still: still)
                        XCTAssertFalse(cells.isEmpty, "\(c) \(mode)")
                        for cell in cells { XCTAssertTrue((0..<PixelBitmaps.cols).contains(cell.x) && (0..<PixelBitmaps.rows).contains(cell.y), "\(c) \(mode) tick \(tick) → \(cell)") }
                    }
                }
            }
        }
    }

    func testReducedMotionStaysOnTheStillFrameAndRunFramesDiffer() {
        for c in [NotchCharacter.horse, .robot, .cat] {
            let still0 = PixelBitmaps.cells(c, mode: .run, tick: 0, still: true).map { "\($0.x),\($0.y)" }
            let still7 = PixelBitmaps.cells(c, mode: .run, tick: 7, still: true).map { "\($0.x),\($0.y)" }
            XCTAssertEqual(still0, still7, "\(c) 减少动态效果：停在静止帧，不随 tick 变")
            let f0 = PixelBitmaps.cells(c, mode: .run, tick: 0, still: false).map { "\($0.x),\($0.y)" }
            let f1 = PixelBitmaps.cells(c, mode: .run, tick: 1, still: false).map { "\($0.x),\($0.y)" }
            XCTAssertNotEqual(f0, f1, "\(c) 工作：相邻帧不同（在动）")
            XCTAssertEqual(PixelBitmaps.cells(c, mode: .run, tick: 0, still: false).map { "\($0.x),\($0.y)" }, PixelBitmaps.cells(c, mode: .run, tick: 4, still: false).map { "\($0.x),\($0.y)" }, "4 帧循环")
        }
    }

    func testWaitingBangBlinksAndStaysVisibleWhenStill() {
        func hasBang(_ tick: Int, still: Bool) -> Bool { PixelBitmaps.cells(.horse, mode: .wait, tick: tick, still: still).contains { $0.x == 18 } }
        XCTAssertTrue(hasBang(0, still: false)); XCTAssertTrue(hasBang(3, still: false))
        XCTAssertFalse(hasBang(4, still: false)); XCTAssertFalse(hasBang(5, still: false)) // 约 0.66s 一闪
        XCTAssertTrue(hasBang(4, still: true), "减少动态效果：「!」常亮，信息不丢")
    }

    func testDoneNodsOnceAndBarsStayInsideTheirRange() {
        let up = PixelBitmaps.cells(.horse, mode: .done, tick: 4, still: false, nod: false).map(\.y).min()!
        let down = PixelBitmaps.cells(.horse, mode: .done, tick: 0, still: false, nod: true).map(\.y).min()!
        XCTAssertEqual(down, up + 1, "完成：点一次头（下沉一格）")
        for tick in 0..<40 { for b in 0..<5 {
            let h = PixelBitmaps.barHeight(index: b, mode: .run, tick: tick, still: false)
            XCTAssertTrue((3...10).contains(h))
        } }
        XCTAssertEqual(PixelBitmaps.barHeight(index: 0, mode: .wait, tick: 3, still: false), 2)
    }

    // MARK: 角色偏好

    func testCharacterDefaultsToHorseAndPersistsInTheGivenDefaults() {
        let suite = "palmhelm.test.notch.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let s = NotchCharacterStore(defaults: d)
        XCTAssertEqual(s.character, .horse)
        s.character = .cat
        XCTAssertEqual(d.string(forKey: NotchCharacterStore.key), "cat")
        XCTAssertEqual(NotchCharacterStore(defaults: d).character, .cat, "重启后保留")
        d.set("dragon", forKey: NotchCharacterStore.key)
        XCTAssertEqual(NotchCharacterStore(defaults: d).character, .horse, "未知值回落默认")
    }

    func testDefaultStoreUsesTheIsolatedSuiteInTestHost() {
        let before = UserDefaults.standard.object(forKey: NotchCharacterStore.key) as? NSObject
        let s = NotchCharacterStore()
        s.character = .robot
        XCTAssertEqual(UserDefaults.standard.object(forKey: NotchCharacterStore.key) as? NSObject, before, "测试宿主不改真实偏好")
        s.character = .horse
    }

    // MARK: 宿主配置

    func testHostingViewAcceptsTheFirstClickAndRestFrameHugsTheShape() {
        let v = FirstMouseHostingView(rootView: EmptyView())
        XCTAssertTrue(v.acceptsFirstMouse(for: nil), "可见卡片上的按钮第一下点击就生效（非激活面板默认不接收第一下）")
        let shape = NotchGeometry.compactSize(notch, base: .working)
        XCTAssertEqual(NotchGeometry.panelSize(shape: shape).height, shape.height, "静止时面板高度恰好贴着形状，不留透明区盖住下方 App")
    }

    /// O1-343 ⑤：外层无障碍标签读出的是读取时刻的真实剩余时间，过期后归零。
    func testCompactAccessibilityTimeTracksTheRealRemainingTime() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let expiresT = 1_000_000 + 252_000  // 252 秒后超时（毫秒）
        XCTAssertEqual(NotchRules.remainingSeconds(expiresT: expiresT, now: t0), 252)
        XCTAssertEqual(NotchRules.accessibilitySummary(base: .waiting, pending: 1, running: 0, remaining: NotchRules.remainingSeconds(expiresT: expiresT, now: t0.addingTimeInterval(1))), "1 条待答，4 分 11 秒后超时")
        XCTAssertEqual(NotchRules.remainingSeconds(expiresT: expiresT, now: t0.addingTimeInterval(400)), 0, "过期不为负")
    }
}
