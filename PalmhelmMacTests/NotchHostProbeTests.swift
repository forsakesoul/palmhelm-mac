import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// 宿主命中的最小 AppKit 探针：固定最大尺寸的透明面板，透明像素上 WindowServer 会不会把它当作「该点的窗口」。
/// 结论（决定宿主方案）：透明但不忽略鼠标的面板在透明像素上仍被 WindowServer 当作该点的窗口，会吞掉下方 App 的点击与滚轮；
/// 只有 ignoresMouseEvents = true 才穿透。所以「固定最大透明面板」必须靠整窗开关穿透（轮询切换有吞首击风险），这里采用「面板跟随形状调 frame」，
/// 静止时面板恰好贴着形状。下面的断言把这个系统行为固定成证据：哪天系统行为变了，这里会提示重新评估宿主方案。
@MainActor
final class NotchHostProbeTests: XCTestCase {
    func testProbeTransparentPanelWindowAtPoint() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("没有屏幕（无窗口服务器会话）") }
        func make(at origin: NSPoint, ignores: Bool) -> NSPanel {
            let p = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 200, height: 120)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.level = .statusBar
            p.ignoresMouseEvents = ignores
            p.contentView = NSHostingViewForProbe()
            p.orderFrontRegardless()
            return p
        }
        // 候选位置：屏幕四个角附近（Dock / 别的更高层窗口可能占着其中一两处，探针换一处再试）
        let spots = [NSPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 40), NSPoint(x: screen.frame.maxX - 260, y: screen.frame.minY + 40),
                     NSPoint(x: screen.frame.minX + 40, y: screen.frame.midY), NSPoint(x: screen.frame.maxX - 260, y: screen.frame.midY)]
        for origin in spots {
            let probe = NSPoint(x: origin.x + 100, y: origin.y + 60) // 面板中央（透明区）
            let capturing = make(at: origin, ignores: false)
            let atCapturing = NSWindow.windowNumber(at: probe, belowWindowWithWindowNumber: 0)
            capturing.orderOut(nil)
            guard atCapturing == capturing.windowNumber else { continue } // 这一处被别的窗口盖着：换一处
            let passing = make(at: origin, ignores: true)
            let atPassing = NSWindow.windowNumber(at: probe, belowWindowWithWindowNumber: 0)
            let passingNumber = passing.windowNumber
            passing.orderOut(nil)
            print("NOTCH_PROBE capturing: panel=\(capturing.windowNumber) atPoint=\(atCapturing) | ignoresMouseEvents: panel=\(passingNumber) atPoint=\(atPassing)")
            XCTAssertNotEqual(atPassing, passingNumber, "ignoresMouseEvents = true 时穿透到下方窗口")
            return // 透明像素上，不忽略鼠标的面板仍是该点的窗口（会吞点击 / 滚轮）——已由上面的 guard 取得证据
        }
        throw XCTSkip("四个候选位置都被别的窗口盖着，探针不适用")
    }
}

/// R1 端到端（O1-142 实机）：真实控制器 + 真实宿主视图，静止后面板必须收回到「形状 + 两侧耳朵」，并且保持。
/// 根因：宿主视图直接当 contentView 时，窗口会被它的理想尺寸（展开层 400×N，透明也算）在收回几毫秒后又拉回去；改为普通 NSView 容器 + autoresizing。
extension NotchHostProbeTests {
    /// 当前工作态需要证据：已连通 + 目标在快照里 + 已知 started。
    @MainActor func workingSession() -> MacSession {
        let s = MacSession()
        s.state = try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b"},"occupancy":"free","targets":[{"projectName":"P","id":"A"}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.link = .connected
        s.commands["k1"] = ApiCommand(key: "k1", inboxSeq: 1, text: "x", origin: "api", targetId: "A", state: "started")
        return s
    }

    func testControllerRestPanelEqualsShapePlusEarsAfterSettling() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let session = workingSession() // 在途 → 工作态
        let c = NotchController()
        c.attach(session: session)
        addTeardownBlock { @MainActor in c.detach() } // 结束时拆除并关闭窗口，不影响后续用例
        var rest: NSRect?
        for _ in 0..<60 { // 最多等 3 秒：形状到位后约 0.9s 收回面板
            try await Task.sleep(for: .milliseconds(50))
            let want = NotchGeometry.panelSize(shape: c.layout.size)
            if let f = c.panelFrame, abs(f.width - want.width) < 0.5, abs(f.height - want.height) < 0.5, c.layout.mode == .compact(.working) { rest = f; break }
        }
        let want = NotchGeometry.panelSize(shape: c.layout.size)
        print("NOTCH_PROBE controller rest: frame=\(String(describing: c.panelFrame)) want=\(want) layout=\(c.layout.mode)")
        XCTAssertEqual(c.layout.mode, .compact(.working))
        XCTAssertNotNil(rest, "静止后面板尺寸 = 形状 + 两侧耳朵（\(want)），实际 \(String(describing: c.panelFrame?.size))")
        XCTAssertEqual(c.panelFrame?.width ?? 0, c.layout.size.width + 2 * NotchGeometry.ear, accuracy: 0.5)
        // 收回后不能再被撑回去（实机：收回 5ms 后窗口又被拉回内容的理想尺寸 400×90）
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(c.panelFrame?.size.width ?? 0, want.width, accuracy: 0.5, "收回后保持：\(String(describing: c.panelFrame?.size))")
        XCTAssertEqual(c.panelFrame?.size.height ?? 0, want.height, accuracy: 0.5)
        // 面板顶边贴屏幕上沿、水平居中
        if let f = c.panelFrame, let screen = NSScreen.main { XCTAssertEqual(f.maxY, screen.frame.maxY, accuracy: 0.5); XCTAssertEqual(f.midX, screen.frame.midX, accuracy: 0.5) }
    }
}

/// R4（实机）：收回到 279×32 以后宿主视图必须仍铺满容器（否则它保持 400×90、按左下角对齐，上半部分被裁掉，只剩下缘一条黑线）。
extension NotchHostProbeTests {
    private func waitRest(_ c: NotchController, mode: NotchMode) async -> Bool {
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(50))
            let want = NotchGeometry.panelSize(shape: c.layout.size)
            if c.layout.mode == mode, let f = c.panelFrame, abs(f.width - want.width) < 0.5, abs(f.height - want.height) < 0.5 { return true }
        }
        return false
    }

    /// 窗口位图里「亮的、不透明的」像素数（角色橙色 / 数字灰白；外壳是纯黑，不算）。
    private func litPixels(_ rep: NSBitmapImageRep, xRange: Range<Int>, yRange: Range<Int>) -> Int {
        var n = 0
        for y in yRange where y >= 0 && y < rep.pixelsHigh {
            for x in xRange where x >= 0 && x < rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.alphaComponent > 0.5, (c.redComponent + c.greenComponent + c.blueComponent) / 3 > 0.25 { n += 1 }
            }
        }
        return n
    }

    private func assertVisible(_ c: NotchController, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let frames = c.hostingFrames, let panel = c.panelFrame else { return XCTFail("\(label) 没有宿主", file: file, line: line) }
        XCTAssertEqual(frames.hosting.origin.x, frames.container.origin.x, accuracy: 0.5, "\(label) 宿主视图 frame \(frames.hosting) ≠ 容器 bounds \(frames.container)", file: file, line: line)
        XCTAssertEqual(frames.hosting.origin.y, frames.container.origin.y, accuracy: 0.5, "\(label) 宿主视图 frame \(frames.hosting) ≠ 容器 bounds \(frames.container)", file: file, line: line)
        XCTAssertEqual(frames.hosting.size.width, frames.container.size.width, accuracy: 0.5, "\(label) 宽", file: file, line: line)
        XCTAssertEqual(frames.hosting.size.height, frames.container.size.height, accuracy: 0.5, "\(label) 高", file: file, line: line)
        XCTAssertEqual(frames.container.size.width, panel.width, accuracy: 0.5, "\(label) 容器 = 面板", file: file, line: line)
    }

    func testHostingViewFillsTheContainerAndTheIslandIsVisibleAtRestAndAfterARoundTrip() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let session = workingSession() // 工作态：左翼角色 + 右翼数量
        let c = NotchController()
        c.attach(session: session)
        addTeardownBlock { @MainActor in c.detach() } // 结束时拆除并关闭窗口，不影响后续用例
        let restOK1 = await waitRest(c, mode: .compact(.working))
        XCTAssertTrue(restOK1)
        try await Task.sleep(for: .milliseconds(400)) // 让 SwiftUI 把内容画出来
        assertVisible(c, "启动静止")
        try checkPixels(c, "启动静止")
        // 展开再收回一个来回之后再断言一次
        c.debugSetExpanded(true)
        let expandedOK = await waitRest(c, mode: .expanded)
        XCTAssertTrue(expandedOK)
        assertVisible(c, "展开")
        c.debugSetExpanded(false)
        let restOK2 = await waitRest(c, mode: .compact(.working))
        XCTAssertTrue(restOK2)
        try await Task.sleep(for: .milliseconds(400))
        assertVisible(c, "来回之后")
        try checkPixels(c, "来回之后")
    }

    private func checkPixels(_ c: NotchController, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let rep = c.renderPanel(), let panel = c.panelFrame else { return XCTFail("\(label) 渲染失败", file: file, line: line) }
        let scale = Double(rep.pixelsWide) / panel.width
        func px(_ v: CGFloat) -> Int { Int(Double(v) * scale) }
        let ear = NotchGeometry.ear
        // 左翼角色区：形状左缘（耳朵内侧）往右 8…40pt、上下留边
        let left = litPixels(rep, xRange: px(ear + 8)..<px(ear + 40), yRange: px(3)..<px(panel.height - 2))
        // 其余区域（右翼数量）：左翼之右的所有像素里要有亮像素
        let right = litPixels(rep, xRange: px(ear + 40)..<px(panel.width - ear), yRange: px(3)..<px(panel.height - 2))
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "notch-probe-\(label.hasPrefix("启动") ? "rest" : "roundtrip").png")) }
        print("NOTCH_PROBE pixels \(label): left=\(left) right=\(right) bitmap=\(rep.pixelsWide)x\(rep.pixelsHigh) panel=\(panel.size)")
        XCTAssertGreaterThan(left, 8, "\(label) 左翼角色区应有亮像素（小马可见）", file: file, line: line)
        XCTAssertGreaterThan(right, 4, "\(label) 右翼数量区应有亮像素", file: file, line: line)
    }
}

/// O1-143（实机逐帧）：每一帧——并集放大期间、弹簧过程中、收回之后——形状都要贴着窗口上沿（顶边像素在第 0 行）、水平居中。
extension NotchHostProbeTests {
    /// 位图里不透明像素的外接范围。
    private func extent(_ rep: NSBitmapImageRep) -> (top: Int?, minX: Int, maxX: Int) {
        var top: Int?, minX = Int.max, maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                if top == nil { top = y }
                minX = min(minX, x); maxX = max(maxX, x)
            }
        }
        return (top, minX, maxX)
    }

    private func assertTopAndCentered(_ c: NotchController, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let rep = c.renderPanel() else { return XCTFail("\(label) 渲染失败", file: file, line: line) }
        let e = extent(rep)
        XCTAssertEqual(e.top, 0, "\(label) 形状顶边必须在窗口第 0 行（实际 \(String(describing: e.top))）", file: file, line: line)
        let leftMargin = e.minX, rightMargin = rep.pixelsWide - 1 - e.maxX
        XCTAssertLessThanOrEqual(abs(leftMargin - rightMargin), 4, "\(label) 水平居中：左边距 \(leftMargin)px / 右边距 \(rightMargin)px", file: file, line: line)
    }

    func testShapeStaysTopAlignedAndCenteredInEveryFrame() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let session = workingSession()
        let c = NotchController()
        c.attach(session: session)
        addTeardownBlock { @MainActor in c.detach() } // 结束时拆除并关闭窗口，不影响后续用例
        let rest1 = await waitRest(c, mode: .compact(.working)); XCTAssertTrue(rest1)
        try await Task.sleep(for: .milliseconds(300))
        assertTopAndCentered(c, "静止")
        // 展开：并集放大 + 弹簧过程中逐帧采样
        c.debugSetExpanded(true)
        for i in 0..<30 { try await Task.sleep(for: .milliseconds(30)); assertTopAndCentered(c, "展开过程 #\(i)") }
        let exp = await waitRest(c, mode: .expanded); XCTAssertTrue(exp)
        try await Task.sleep(for: .milliseconds(300))
        assertTopAndCentered(c, "展开稳定")
        // 收起：弹簧收回 + 面板收回过程中逐帧采样
        c.debugSetExpanded(false)
        for i in 0..<40 { try await Task.sleep(for: .milliseconds(30)); assertTopAndCentered(c, "收起过程 #\(i)") }
        let rest2 = await waitRest(c, mode: .compact(.working)); XCTAssertTrue(rest2)
        try await Task.sleep(for: .milliseconds(300))
        assertTopAndCentered(c, "来回之后")
    }
}

private final class NSHostingViewForProbe: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // 透明区不接收
}

/// #12「在刘海显示 Palmhelm」开关：关 = 整个拆掉（不留看不见的面板、鼠标监视和快捷展开）；开 = 从当前状态重新挂上，不补播关掉期间的提示。
extension NotchHostProbeTests {
    func testDisablingTheNotchTearsItDownAndReenablingDoesNotReplayMissedToasts() throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let suite = "palmhelm.test.notch.enabled.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = NotchInteractionStore(defaults: d)
        XCTAssertTrue(store.enabled) // 默认开
        let session = workingSession() // k1 在途
        let c = NotchController(interaction: store)
        addTeardownBlock { @MainActor in c.detach() }
        c.attach(session: session)
        c.debugTick() // 建立事件基线：k1 在途
        XCTAssertTrue(c.panelVisible)
        XCTAssertEqual(c.mouseMonitorCount, 2)

        store.enabled = false
        XCTAssertEqual(d.object(forKey: NotchInteractionStore.enabledKey) as? Bool, false)
        XCTAssertNil(c.panelFrame)
        XCTAssertEqual(c.mouseMonitorCount, 0)
        c.toggleExpansion() // ⌘⌥N 之类的显式展开也叫不出来
        XCTAssertFalse(c.isExpanded)
        XCTAssertNil(c.panelFrame)

        session.commands["k1"]?.state = "finished" // 关掉期间完成了：重新打开后不能再弹「完成」
        store.enabled = true
        // 显隐按规则（NotchRules.isHidden：无刘海 + 空闲 + 无提示 + 未展开 → 隐藏）；不假定主屏一定有刘海（O1-344）
        XCTAssertEqual(c.panelVisible, c.metrics.hasNotch)
        XCTAssertNotNil(c.panelFrame, "面板已重新建立")
        XCTAssertEqual(c.mouseMonitorCount, 2, "鼠标监视已恢复")
        c.debugTick(); c.debugTick()
        XCTAssertNil(c.toast.current)
    }

    /// h29c：层级开关立即修改同一个面板；关掉刘海时不建窗；重新开启用已存的层级。
    func testLevelSwitchChangesTheExistingPanelWithoutRebuildingIt() throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let suite = "palmhelm.test.notch.level.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = NotchInteractionStore(defaults: d)
        let c = NotchController(interaction: store)
        addTeardownBlock { @MainActor in c.detach() }
        c.attach(session: workingSession())
        let number = try XCTUnwrap(c.panelWindowNumber)
        let panel = try XCTUnwrap(NSApp.window(withWindowNumber: number) as? NotchPanel)
        XCTAssertEqual(panel.level, NotchController.panelLevel(aboveOthers: true), "默认开：新建面板用抬高后的层级")

        store.aboveOthers = false
        XCTAssertEqual(panel.level, .statusBar, "关闭时立即改同一个面板")
        XCTAssertEqual(c.panelWindowNumber, number, "不重建窗口")
        store.aboveOthers = true
        XCTAssertEqual(panel.level, NotchController.panelLevel(aboveOthers: true))
        XCTAssertEqual(c.panelWindowNumber, number)
    }

    func testLevelSwitchWhileNotchIsDisabledCreatesNoWindowAndReenableUsesStoredLevel() throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let suite = "palmhelm.test.notch.level.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = NotchInteractionStore(defaults: d)
        store.enabled = false
        let c = NotchController(interaction: store)
        addTeardownBlock { @MainActor in c.detach() }
        let session = workingSession() // 控制器只弱引用会话，测试期间由本地持有
        c.attach(session: session)
        store.aboveOthers = false
        store.aboveOthers = true
        XCTAssertNil(c.panelFrame, "刘海关闭时层级开关不建窗")
        store.aboveOthers = false
        store.enabled = true
        let number = try XCTUnwrap(c.panelWindowNumber)
        let panel = try XCTUnwrap(NSApp.window(withWindowNumber: number) as? NotchPanel)
        XCTAssertEqual(panel.level, .statusBar, "重新开启用已存的层级")
    }

    func testAttachWhileDisabledWaitsForTheSwitch() throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let suite = "palmhelm.test.notch.enabled.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(false, forKey: NotchInteractionStore.enabledKey)
        let store = NotchInteractionStore(defaults: d)
        let c = NotchController(interaction: store)
        addTeardownBlock { @MainActor in c.detach() }
        let session = workingSession() // 控制器只弱引用会话（App 里由 AppDelegate 持有）
        c.attach(session: session)
        XCTAssertNil(c.panelFrame)
        XCTAssertEqual(c.mouseMonitorCount, 0)
        store.enabled = true
        XCTAssertNotNil(c.panelFrame)
    }
}
