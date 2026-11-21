import XCTest
@testable import PalmhelmMac

/// #29 侧栏宽度：夹取、拖动结果、持久化（隔离的 defaults suite），以及窄窗收起逻辑不回归。
final class SidebarWidthTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "SidebarWidthTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return d
    }

    func testClampKeepsWidthWithinMinimumAndMaximum() {
        XCTAssertEqual(SidebarWidth.clamp(100, available: 2000), SidebarWidth.minimum, "低于最小 → 最小")
        XCTAssertEqual(SidebarWidth.clamp(900, available: 2000), SidebarWidth.maximum, "高于最大 → 最大")
        XCTAssertEqual(SidebarWidth.clamp(360, available: 2000), 360, "范围内不动")
    }

    func testClampReservesWorkspaceWhenWindowIsNarrow() {
        // 可用宽度不够时工作区至少留 workspaceMinimum（分隔条也要扣掉）；但侧栏不会低于 minimum（那时由窄窗规则收起）
        XCTAssertEqual(SidebarWidth.clamp(480, available: 700), 700 - SidebarWidth.dividerWidth - SidebarWidth.workspaceMinimum)
        XCTAssertEqual(SidebarWidth.clamp(480, available: 500), SidebarWidth.minimum)
    }

    /// R1：侧栏 + 分隔条 + 工作区 = 可用宽度（只要可用宽度够放下最小侧栏与工作区保留）。
    func testBudgetSumsToAvailableWidth() {
        for available in stride(from: CGFloat(900), through: 1800, by: 37) {
            for stored in [CGFloat(100), 340, 520, 900] {
                let l = SidebarWidth.layout(stored: stored, available: available)
                XCTAssertEqual(l.sidebar + l.divider + l.workspace, available, accuracy: 0.0001, "available \(available) stored \(stored)")
                XCTAssertGreaterThanOrEqual(l.workspace, SidebarWidth.workspaceMinimum, "工作区保留 \(available)")
                XCTAssertGreaterThanOrEqual(l.sidebar, SidebarWidth.minimum)
                XCTAssertLessThanOrEqual(l.sidebar, SidebarWidth.maximum)
            }
        }
    }

    /// R1 场景：保存 520，窗口收窄到 820 → 显示的侧栏不超过预算（452），工作区不低于 360。
    func testSavedWideSidebarIsShownWithinBudgetOnNarrowerWindow() {
        let l = SidebarWidth.layout(stored: 520, available: 820)
        XCTAssertEqual(l.sidebar, 820 - SidebarWidth.dividerWidth - SidebarWidth.workspaceMinimum)
        XCTAssertEqual(l.workspace, SidebarWidth.workspaceMinimum)
    }

    /// R1 场景：临时展开后小幅左拖，以「显示宽度」为起点，而不是保存的 520。
    func testDragStartsFromDisplayedWidthNotStoredIntent() {
        let shown = SidebarWidth.clamp(520, available: 820) // 452
        XCTAssertEqual(SidebarWidth.drag(from: shown, by: -1, available: 820), shown - 1, "左拖 1 立刻生效")
        XCTAssertEqual(SidebarWidth.drag(from: shown, by: -60, available: 820), shown - 60)
        XCTAssertEqual(SidebarWidth.drag(from: shown, by: -shown, available: 820), SidebarWidth.minimum, "拖到最左也只停在最小，不收起")
    }

    /// 自动夹取只改显示，不改保存的意图宽度（clamp / layout 都是纯函数，不写回）。
    func testAutoClampDoesNotRewriteStoredIntent() {
        let d = isolatedDefaults()
        SidebarWidth.save(520, to: d)
        _ = SidebarWidth.layout(stored: SidebarWidth.load(d), available: 820)
        XCTAssertEqual(SidebarWidth.load(d), 520, "窗口收窄不改保存值")
        XCTAssertEqual(SidebarWidth.layout(stored: SidebarWidth.load(d), available: 1600).sidebar, 520, "回到宽窗口恢复原设置")
    }

    /// AX 增减与拖动同一套规则：夹取，不收起。
    func testAccessibilityAdjustUsesSameRules() {
        XCTAssertEqual(SidebarWidth.adjust(from: 340, increment: true, available: 2000), 340 + SidebarWidth.step)
        XCTAssertEqual(SidebarWidth.adjust(from: 340, increment: false, available: 2000), 340 - SidebarWidth.step)
        XCTAssertEqual(SidebarWidth.adjust(from: 520, increment: true, available: 2000), SidebarWidth.maximum, "到最大夹住")
        XCTAssertEqual(SidebarWidth.adjust(from: 280, increment: false, available: 2000), SidebarWidth.minimum, "到最小夹住，不收起")
    }

    func testDragOutcomes() {
        XCTAssertEqual(SidebarWidth.drag(from: 340, by: 50, available: 2000), 390)
        XCTAssertEqual(SidebarWidth.drag(from: 340, by: 500, available: 2000), SidebarWidth.maximum, "拖过最大 → 夹在最大")
        XCTAssertEqual(SidebarWidth.drag(from: 340, by: -70, available: 2000), SidebarWidth.minimum, "拖过最小 → 停在最小")
        XCTAssertEqual(SidebarWidth.drag(from: 340, by: -1000, available: 2000), SidebarWidth.minimum, "#29 验收：拖不动时松手也不收起侧栏")
    }

    func testWidthPersistsAndRestoresInIsolatedDefaults() {
        let d = isolatedDefaults()
        XCTAssertEqual(SidebarWidth.load(d), SidebarWidth.ideal, "没有保存过 → 默认宽度")
        SidebarWidth.save(410, to: d)
        XCTAssertEqual(SidebarWidth.load(d), 410, "重启后恢复上次的宽度")
        // 测试只写隔离的 suite：真实偏好里的同名 key 前后保持不变（不假设它是否存在）
        let before = UserDefaults.standard.object(forKey: SidebarWidth.key) as? Double
        SidebarWidth.save(300, to: d)
        XCTAssertEqual(UserDefaults.standard.object(forKey: SidebarWidth.key) as? Double, before, "测试没有写进真实偏好")
    }

    func testStoredValuesAreClampedOnLoadAndSave() {
        let d = isolatedDefaults()
        d.set(9999.0, forKey: SidebarWidth.key)
        XCTAssertEqual(SidebarWidth.load(d), SidebarWidth.maximum, "保存的越界值读出时夹取")
        d.set(12.0, forKey: SidebarWidth.key)
        XCTAssertEqual(SidebarWidth.load(d), SidebarWidth.minimum)
        d.set(-5.0, forKey: SidebarWidth.key)
        XCTAssertEqual(SidebarWidth.load(d), SidebarWidth.ideal, "非法值退回默认")
        SidebarWidth.save(5000, to: d)
        XCTAssertEqual(d.double(forKey: SidebarWidth.key), Double(SidebarWidth.maximum), "保存时也夹取")
    }

    /// 窄窗收起逻辑不回归（宽度改动不影响 SidebarState 的规则）。
    func testNarrowCollapseRulesAreUnchanged() {
        XCTAssertTrue(SidebarState.isNarrow(899))
        XCTAssertFalse(SidebarState.isNarrow(900))
        var narrow = SidebarState()
        XCTAssertFalse(narrow.shown(narrow: true), "窄窗默认收起")
        narrow.reveal(narrow: true)
        XCTAssertTrue(narrow.shown(narrow: true))
        narrow.widthChanged(narrow: false)
        XCTAssertFalse(narrow.tempOpen, "回宽窗即清临时展开")
    }

}

/// 拖动状态机：起点是显示宽度；取消 / 重复收尾 / 视图消失都只生效一次，不留下错误的起点。
final class SidebarDragTests: XCTestCase {
    func testDragFromDisplayedWidthAndFinishOnce() {
        var d = SidebarWidth.Drag()
        XCTAssertEqual(d.changed(shown: 452, delta: -1, available: 820), 451)
        XCTAssertEqual(d.changed(shown: 452, delta: -60, available: 820), 392, "累计位移，起点不随界面重算")
        XCTAssertEqual(d.finish(delta: -60, shown: 392, available: 820), 392)
        XCTAssertNil(d.finish(delta: -60, shown: 392, available: 820), "第二次收尾不生效")
        XCTAssertFalse(d.active)
    }

    func testCancelFinishesWithLastPreviewNotStart() {
        var d = SidebarWidth.Drag()
        _ = d.changed(shown: 340, delta: 50, available: 2000)
        XCTAssertEqual(d.finish(delta: nil, shown: 340, available: 2000), 390, "切走 App / 失焦：以最后预览收尾")
        XCTAssertNil(d.finish(delta: nil, shown: 340, available: 2000))
    }

    func testDraggingFarLeftPreviewsAndFinishesAtMinimum() {
        var d = SidebarWidth.Drag()
        XCTAssertEqual(d.changed(shown: 340, delta: -150, available: 2000), SidebarWidth.minimum, "拖到最左：预览停在最小")
        XCTAssertEqual(d.finish(delta: -400, shown: 340, available: 2000), SidebarWidth.minimum, "松手：保存最小宽度，不收起")
    }

    func testNoDragMeansNothingToFinish() {
        var d = SidebarWidth.Drag()
        XCTAssertNil(d.finish(delta: nil, shown: 340, available: 2000), "没有拖动过：不保存、不收起")
    }

    func testNextDragStartsFreshAfterFinish() {
        var d = SidebarWidth.Drag()
        _ = d.changed(shown: 452, delta: -100, available: 820)
        _ = d.finish(delta: -100, shown: 352, available: 820)
        // 下一次拖动以新的显示宽度为起点（不是上一次的起点 452）
        XCTAssertEqual(d.changed(shown: 352, delta: -1, available: 820), 351)
    }
}
