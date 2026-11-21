import AppKit
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
private final class Calls: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var all: [String] { lock.withLock { v } }
}
private func approval(_ id: String, createdAgo: Int = 1000) -> ApprovalView {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    return ApprovalView(id: id, status: "pending", targetLabel: "P", attribution: "exact", toolName: "Bash", summary: "ls", truncated: false, createdT: now - createdAgo, expiresT: now + 600_000)
}

/// O1-149 / A1-071：命中区跟随形状、完成点头只一次、提示文字不进刘海、展开卡固定当次 id。
@MainActor
final class NotchHitTests: XCTestCase {
    // MARK: F1 命中区（纯规则）

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private func pt(_ dx: CGFloat, _ dyFromTop: CGFloat) -> CGPoint { CGPoint(x: screen.midX + dx, y: screen.maxY - dyFromTop) }

    func testHitFollowsShapeIncludingEarsAndRoundedCorners() {
        let shape = CGSize(width: 300, height: 100), r: CGFloat = 22
        func inside(_ p: CGPoint, tol: CGFloat = 0) -> Bool { NotchHit.inside(mouse: p, screenFrame: screen, shape: shape, radius: r, tolerance: tol) }
        XCTAssertTrue(inside(pt(0, 50)), "形状中央")
        XCTAssertTrue(inside(pt(0, 1)), "上沿")
        XCTAssertFalse(inside(pt(0, 130)), "形状下方的透明区")
        XCTAssertFalse(inside(pt(200, 50)), "形状右侧的透明区")
        XCTAssertFalse(inside(pt(-148, 99)), "左下圆角外的透明角")
        XCTAssertFalse(inside(pt(150 + NotchGeometry.ear - 1, 99)), "右下圆角 / 耳朵外缘下方的透明角")
        XCTAssertFalse(inside(pt(150 + NotchGeometry.ear - 0.5, 40)), "耳朵以下的外侧贴边：形状主体之外")
        XCTAssertTrue(inside(pt(0, 101), tol: 2), "容差内仍算形状（边缘不闪烁）")
    }

    // MARK: F1 命中区（控制器 + 真实面板）

    private func session() -> MacSession {
        let s = MacSession()
        s.state = decode(#"{"bridge":{"id":"b"},"occupancy":"free","targets":[{"projectName":"P","id":"A"}],"history":{"highWater":0,"items":[]}}"#)
        s.link = .connected
        s.commands["k1"] = ApiCommand(key: "k1", inboxSeq: 1, text: "x", origin: "api", targetId: "A", state: "started")
        return s
    }
    private func controller(_ s: MacSession? = nil) throws -> NotchController {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let c = NotchController()
        c.attach(session: s ?? session())
        addTeardownBlock { @MainActor in c.detach() }
        return c
    }

    func testIgnoresMouseTracksTheLiveShapeThroughExpandCollapseAndReversal() throws {
        let c = try controller()
        let scr = NSScreen.main!.frame
        func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: scr.midX + dx, y: scr.maxY - dy) }
        let r = NotchGeometry.expandedRadius
        // 并集放大期间：面板是旧 / 新形状并集，形状只长到一半
        c.debugSetExpanded(true)
        c.reportShape(CGSize(width: 200, height: 60), r)
        c.updateHitRegion(mouse: at(0, 30))
        XCTAssertEqual(c.ignoresMouseEvents, false, "形状内：接收")
        c.updateHitRegion(mouse: at(180, 30))
        XCTAssertEqual(c.ignoresMouseEvents, true, "并集面板内、形状外：穿透")
        c.updateHitRegion(mouse: at(0, 90))
        XCTAssertEqual(c.ignoresMouseEvents, true, "形状下方的透明区：穿透")
        // 圆角和耳朵的透明区
        c.updateHitRegion(mouse: at(-100 - 1, 59))
        XCTAssertEqual(c.ignoresMouseEvents, true, "圆角外的透明角：穿透")
        // 收起中：形状还大，鼠标在里面
        c.reportShape(CGSize(width: 380, height: 120), r)
        c.updateHitRegion(mouse: at(150, 100))
        XCTAssertEqual(c.ignoresMouseEvents, false, "收起中仍在形状里：接收")
        // 刚收起：面板还没来得及缩回（0.9s 宽限），形状已是紧凑
        c.reportShape(CGSize(width: 200, height: 32), NotchGeometry.compactRadius)
        c.updateHitRegion(mouse: at(150, 100))
        XCTAssertEqual(c.ignoresMouseEvents, true, "刚收起：旧展开区域的透明部分穿透")
        // 快速反向：立刻又长大，鼠标应随形状在两种状态间正确切换
        for (w, expect) in [(CGFloat(200), true), (380, false), (200, true), (380, false)] {
            c.reportShape(CGSize(width: w, height: w > 300 ? 120 : 32), r)
            c.updateHitRegion(mouse: at(150, 100))
            XCTAssertEqual(c.ignoresMouseEvents, expect, "反向 w=\(w)")
        }
    }

    /// 命中开关与 acceptsFirstMouse 属性测试：只证明「形状外 → WindowServer 不把该点交给面板」和「宿主接受首击」两个属性，不是真实点击的端到端验证（见 testRealEventsThroughTheShapeEdges）。
    func testHitSwitchAndAcceptsFirstMouseProperties() throws {
        let c = try controller()
        guard let panelNo = c.panelWindowNumber else { throw XCTSkip("无面板") }
        let scr = NSScreen.main!.frame
        c.debugSetExpanded(true)
        let r = NotchGeometry.expandedRadius
        c.reportShape(CGSize(width: 200, height: 60), r)
        let outside = CGPoint(x: scr.midX + 180, y: scr.maxY - 30) // 并集面板内、形状外
        let inside = CGPoint(x: scr.midX, y: scr.maxY - 30)
        c.updateHitRegion(mouse: outside)
        XCTAssertEqual(c.panelFrame?.contains(outside), true, "探针点在面板内")
        let atOutside = NSWindow.windowNumber(at: outside, belowWindowWithWindowNumber: 0)
        XCTAssertNotEqual(atOutside, panelNo, "形状外：WindowServer 把这一点交给下方窗口（点击 / 滚轮穿透）")
        c.updateHitRegion(mouse: inside)
        XCTAssertEqual(c.ignoresMouseEvents, false)
        // 可见按钮的首击：非激活面板必须接收「第一下」
        XCTAssertEqual(c.hostingAcceptsFirstMouse, true)
    }

    // MARK: F2 完成点头只一次 / F4 合并不重播

    func testDoneNodHappensOnceFromToastCreationNotTheGlobalLoop() {
        var edges = 0, last = false
        var t = 0.0
        while t <= 3.0 { // 3 秒内按 0.11s 帧采样（从 toast 创建时刻起算）
            let n = PixelBitmaps.nodding(elapsed: t)
            if n && !last { edges += 1 }
            last = n; t += PixelBitmaps.frameInterval / 2
        }
        XCTAssertEqual(edges, 1, "3 秒内只点一次头")
        XCTAssertFalse(PixelBitmaps.nodding(elapsed: 0.25), "点完停在静帧")
        XCTAssertFalse(PixelBitmaps.nodding(elapsed: 2.9))
        let still = PixelBitmaps.cells(.horse, mode: .done, tick: 0, still: false, nod: false).map(\.y)
        XCTAssertEqual(PixelBitmaps.cells(.horse, mode: .done, tick: 5, still: false, nod: false).map(\.y), still, "静帧与全局 tick 无关")
    }

    func testMergingTheSameEventExtendsTextOnlyAndKeepsTheNodOrigin() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var s = NotchToastState()
        let e = NotchEvent(kind: .done, target: "P")
        s.post(e, now: t0, held: false)
        let born = s.current!.born
        s.post(e, now: t0.addingTimeInterval(2), held: false)
        XCTAssertEqual(s.current?.count, 2)
        XCTAssertEqual(s.current?.born, born, "合并只延长文字与计时，不重置点头起点")
        XCTAssertFalse(PixelBitmaps.nodding(elapsed: t0.addingTimeInterval(2.1).timeIntervalSince(born)), "合并后不会再点头")
        s.tick(now: t0.addingTimeInterval(4.9), held: false)
        XCTAssertNotNil(s.current, "计时已被延长")
    }

    // MARK: 提示文字不进刘海

    func testToastTextAndIconsNeverIntersectTheNotch() {
        var cases: [NotchMetrics] = [185, 200, 224, 250].flatMap { w in [32.0, 38.0].map { NotchMetrics(notchWidth: CGFloat(w), barHeight: CGFloat($0)) } }
        if let s = NSScreen.main { let m = NotchMetrics.of(s); if m.hasNotch { cases.append(m) } } // 本机真实刘海
        for m in cases {
            let size = NotchGeometry.toastSize(m)
            let notch = NotchGeometry.notchRect(m, shapeWidth: size.width)
            let g = NotchGeometry.toastLayout(m)
            for (name, r) in [("文字", g.text), ("图标", g.icon), ("倒计时", g.countdown)] {
                XCTAssertFalse(r.intersects(notch), "\(name) \(r) 与刘海 \(notch) 相交（notchWidth \(m.notchWidth)）")
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(r), "\(name) 超出形状")
            }
            XCTAssertEqual(size.height, m.barHeight + NotchGeometry.toastTextRow, "文字行在刘海下缘新增")
            XCTAssertGreaterThanOrEqual(g.text.minY, notch.maxY)
        }
        let noNotch = NotchMetrics(notchWidth: 0, barHeight: 34)
        XCTAssertEqual(NotchGeometry.toastSize(noNotch).height, 32, "无刘海保持单行")
    }

    // MARK: F3 展开卡固定当次 id

    func testPinModelHoldsTheCardAgainstReorderAndLateArrivals() {
        var p = NotchCardPin()
        p.sync(expanded: true, pending: ["A", "C"])
        XCTAssertEqual(p.id, "A")
        p.sync(expanded: true, pending: ["B", "C"]) // A 失效，更早创建的 B 迟到进入列表并排在最前
        XCTAssertEqual(p.id, "A", "B 不会顶到同一个位置")
        XCTAssertFalse(p.isLive(pending: ["B", "C"]))
        XCTAssertEqual(p.others(pending: ["B", "C"]), 2, "新来的只更新「另 N 条」")
        p.advance(pending: ["B", "C"])
        XCTAssertEqual(p.id, "B", "明确点「下一条」才切")
        p.sync(expanded: false, pending: ["B"])
        XCTAssertNil(p.id, "收起清空，重开取当时的第一条")
        p.sync(expanded: true, pending: ["C", "B"])
        XCTAssertEqual(p.id, "C")
    }

    func testDecisionNeverLandsOnBWhenAExpiresBetweenPressAndRelease() async throws {
        let s = session()
        let calls = Calls()
        s.decideOverride = { a, d in calls.add("\(a.id):\(d)") }
        s.approvals["A"] = approval("A")
        let c = try controller(s)
        c.debugSetExpanded(true)
        c.debugTick()
        XCTAssertEqual(c.pin.id, "A")
        XCTAssertTrue(c.pinnedIsLive)
        // 按下时 A 仍有效；抬起前 A 过期，且一条更早创建的 B 迟到进入列表
        var expired = approval("A"); expired.status = "expired"
        s.approvals["A"] = expired
        s.approvals["B"] = approval("B", createdAgo: 9000)
        c.debugTick()
        XCTAssertEqual(c.pin.id, "A", "展开期间固定当次 id")
        XCTAssertFalse(c.pinnedIsLive)
        XCTAssertEqual(c.pinnedGoneNote, "已过期")
        await c.decidePinned(.allowOnce, expectedId: "A") // 抬起：零决策，B 也不会被决策
        XCTAssertTrue(calls.all.isEmpty, "A 失效后零决策；B 没被碰：\(calls.all)")
        c.advancePin()
        XCTAssertEqual(c.pin.id, "B", "切到 B 需要明确操作")
        await c.decidePinned(.deny, expectedId: "B")
        await c.decidePinned(.deny, expectedId: "A") // 过期的 id：执行时复核，不落到当前固定的 B
        XCTAssertEqual(calls.all, ["B:deny"])
    }

    // MARK: R1 混合进度 / R2 公共尾部 / F1 监视器

    func testBlendIsDrivenByRevealNotShapeHeight() {
        let tm = NotchMetrics(notchWidth: 200, barHeight: 32)
        let toastH = NotchGeometry.toastSize(tm).height, compactH = NotchGeometry.compactSize(tm, base: .idle).height
        XCTAssertGreaterThan(toastH, compactH, "toast 比紧凑高（刘海下新增文字行）")
        for mode in [NotchMode.compact(.idle), .compact(.working), .toast] {
            let reveal = NotchBlend.reveal(for: mode)
            XCTAssertEqual(reveal, 0, "\(mode)：不是展开")
            // 非减少动态效果：稳态下 toast / 紧凑层全显，展开内容隐藏——不管形状高度是多少
            let p = NotchBlend.progress(reveal: reveal)
            XCTAssertEqual(NotchBlend.compactOpacity(progress: p, reduceMotion: false, expanded: false), 1, "\(mode)")
            XCTAssertEqual(NotchBlend.expandedOpacity(progress: p, reduceMotion: false, expanded: false), 0, "\(mode)")
        }
        XCTAssertEqual(NotchBlend.reveal(for: .expanded), 1)
        let pe = NotchBlend.progress(reveal: NotchBlend.reveal(for: .expanded))
        XCTAssertEqual(NotchBlend.compactOpacity(progress: pe, reduceMotion: false, expanded: true), 0, "展开稳态：紧凑 / 提示层隐藏")
        XCTAssertEqual(NotchBlend.expandedOpacity(progress: pe, reduceMotion: false, expanded: true), 1, "展开稳态：展开内容全显")
        // 过渡采样：compact→toast→compact 全程 reveal = 0（弹簧过冲也被夹在 [0,1]）
        for r in stride(from: -0.1, through: 0.0, by: 0.05) {
            let p = NotchBlend.progress(reveal: CGFloat(r))
            XCTAssertEqual(NotchBlend.compactOpacity(progress: p, reduceMotion: false, expanded: false), 1)
            XCTAssertEqual(NotchBlend.expandedOpacity(progress: p, reduceMotion: false, expanded: false), 0)
        }
        // toast ↔ expanded：reveal 从 0 单调升到 1，两层交叉淡入淡出，两端稳态正确
        var lastC: CGFloat = 1, lastE: CGFloat = 0
        for r in stride(from: 0.0, through: 1.0, by: 0.1) {
            let p = NotchBlend.progress(reveal: CGFloat(r))
            let c = NotchBlend.compactOpacity(progress: p, reduceMotion: false, expanded: false), e = NotchBlend.expandedOpacity(progress: p, reduceMotion: false, expanded: false)
            XCTAssertLessThanOrEqual(c, lastC + 1e-9); XCTAssertGreaterThanOrEqual(e, lastE - 1e-9)
            lastC = c; lastE = e
        }
        XCTAssertEqual(lastC, 0); XCTAssertEqual(lastE, 1)
        // 减少动态效果：按目标二选一
        XCTAssertEqual(NotchBlend.compactOpacity(progress: 0.5, reduceMotion: true, expanded: true), 0)
        XCTAssertEqual(NotchBlend.expandedOpacity(progress: 0.5, reduceMotion: true, expanded: true), 1)
    }

    func testRevealIsPartOfTheLayoutAndTracksModeOnly() async throws {
        let c = try controller()
        c.debugTick()
        XCTAssertEqual(c.layout.reveal, 0)
        c.debugSetExpanded(true)
        c.debugTick()
        XCTAssertEqual(c.layout.reveal, 1)
        c.debugSetExpanded(false)
        c.debugTick()
        XCTAssertEqual(c.layout.reveal, 0)
    }

    private func pendingKindFlow(_ kind: String?) async throws {
        let s = session()
        let calls = Calls()
        s.decideOverride = { a, d in calls.add("\(a.id):\(d)") }
        var a = approval("A"); a.kind = kind
        s.approvals["A"] = a
        let c = try controller(s)
        c.debugSetExpanded(true)
        c.debugTick()
        XCTAssertEqual(c.pin.id, "A")
        var gone = a; gone.status = "expired"
        s.approvals["A"] = gone // A 失效
        var b = approval("B", createdAgo: 9000); b.kind = kind
        s.approvals["B"] = b // 更早创建的 B 到来
        c.debugTick()
        XCTAssertEqual(c.pin.id, "A", "\(kind ?? "approval")：固定卡不被 B 顶掉")
        let f = NotchCardFooter.make(pinId: c.pin.id, pending: ["B"], live: c.pinnedIsLive, goneNote: c.pinnedGoneNote)
        XCTAssertEqual(f, NotchCardFooter(note: "已过期", others: 1, action: .next), "公共尾部：失效说明 + 另 1 条 + 下一条")
        c.advancePin() // 用户点「下一条」
        XCTAssertEqual(c.pin.id, "B")
        XCTAssertEqual(c.pinnedApproval?.id, "B")
        XCTAssertTrue(calls.all.isEmpty)
    }
    func testQuestionCardFollowsThePinAndFooterFlow() async throws { try await pendingKindFlow("question") }
    func testPlanCardFollowsThePinAndFooterFlow() async throws { try await pendingKindFlow("plan") }
    func testApprovalCardFollowsThePinAndFooterFlow() async throws { try await pendingKindFlow(nil) }

    func testFooterVariants() {
        XCTAssertEqual(NotchCardFooter.make(pinId: "A", pending: ["A"], live: true, goneNote: "x"), NotchCardFooter(note: nil, others: 0, action: nil))
        XCTAssertTrue(NotchCardFooter.make(pinId: "A", pending: ["A"], live: true, goneNote: "x").isEmpty)
        XCTAssertEqual(NotchCardFooter.make(pinId: "A", pending: [], live: false, goneNote: "已撤回"), NotchCardFooter(note: "已撤回", others: 0, action: .dismiss), "没有别的待答：知道了")
    }

    func testMouseMonitorsAreInstalledAndRemoved() throws {
        let c = try controller()
        XCTAssertEqual(c.mouseMonitorCount, 2, "全局 + 本地 mouseMoved / dragged")
        c.detach()
        XCTAssertEqual(c.mouseMonitorCount, 0)
    }

    func testShapeChangeRecomputesHitRegionImmediately() throws {
        let c = try controller()
        let scr = NSScreen.main!.frame
        // 鼠标静止在 (midX+150, 顶部下 50)：形状从窄长到宽——动画中形状扫过静止的鼠标，不等 tick
        let still = CGPoint(x: scr.midX + 150, y: scr.maxY - 50)
        c.debugSetExpanded(true)
        c.reportShape(CGSize(width: 200, height: 60), NotchGeometry.expandedRadius)
        c.updateHitRegion(mouse: still)
        XCTAssertEqual(c.ignoresMouseEvents, true)
        c.testMouseLocation = still
        c.reportShape(CGSize(width: 380, height: 120), NotchGeometry.expandedRadius) // 形状长到盖住鼠标：回调里立即切换
        XCTAssertEqual(c.ignoresMouseEvents, false, "形状尺寸变化的回调里立即重算")
    }
}
