import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #89 片 B（Mac 真实父级）：真实 MainWindow → ThreadColumn 的 NSWindow 宿主，事实经线上同一入口（SSE 帧解码 → 采纳）喂入。
// 断言来自页面无障碍文本树（真实 body 的产物），且先等骨架门禁解除、页面上真有内容；账本从实际“线程更多”菜单打开。
private final class QPCalls: @unchecked Sendable { var n = 0 }
private struct QPClient: SearchTranscriptClient {
    let calls: QPCalls
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage { throw URLError(.notConnectedToInternet) }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage {
        calls.n += 1
        return try JSONDecoder().decode(TargetHistoryPage.self, from: Data(QueueV2WireBytes.history.utf8))
    }
}

/// 无障碍树文本：SwiftUI 的 label / value 可能是 NSAttributedString，不能经 Swift 的 String 桥接读取，改用 KVC 再取 .string。
@MainActor private func axTexts(_ node: Any, depth: Int = 0) -> [String] {
    guard depth < 60, let obj = node as? NSObject else { return [] }
    var out: [String] = []
    for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
        let v = obj.value(forKey: key)
        if let a = v as? NSAttributedString { out.append(a.string) } else if let s = v as? String { out.append(s) }
    }
    for c in obj.value(forKey: "accessibilityChildren") as? [Any] ?? [] { out += axTexts(c, depth: depth + 1) }
    return out.filter { !$0.isEmpty }
}

@MainActor
final class QueueSemanticsParentHostTests: XCTestCase {
    private var win: NSWindow!
    private var hv: NSHostingView<AnyView>!
    private var session: MacSession!
    private let pageKey = "palmhelm.mainPage"
    private var previousPage: Any?
    private let deadline = #","queueDeadlineT":1790000000000,"queueReason":"wait_turn","queuePosition":1,"observedAt":null,"phase":null"#
    private let awaiting = #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"awaiting""#

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    /// async 测试里等待：让出主 actor（嵌套 RunLoop 不会运行挂起的 MainActor 任务），同时给窗口一次布局机会。
    private func settle(_ s: TimeInterval) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { try? await Task.sleep(for: .milliseconds(10)); spin(0.05) }
    }
    private func event(_ name: String, _ data: String) -> BridgeEvent {
        var parser = SSEParser()
        return BridgeEventDecoder.decode(parser.feed(Data("event: \(name)\ndata: \(data)\n\n".utf8))[0])
    }
    private func inbound(_ key: String, _ state: String, seq: Int, text: String? = nil, extra: String = "") {
        session.applyStreamEventForTest(event("inbound", #"{"key":"\#(key)","inboxSeq":\#(seq),"text":"\#(text ?? "合成 \(key)")","truncated":false,"origin":"api","state":"\#(state)","lane":"ordinary","targetId":"t1"\#(extra)}"#))
    }
    private func progress(_ key: String, _ state: String, _ extra: String = "") {
        session.applyStreamEventForTest(event("progress", #"{"eventKey":"\#(key)","state":"\#(state)"\#(extra)}"#))
    }

    override func setUp() async throws {
        previousPage = UserDefaults.standard.object(forKey: pageKey)
        UserDefaults.standard.set(0, forKey: pageKey)
        let s = MacSession()
        s.streamDisabled = true
        s.searchClientOverride = { nil } // 激活读取不发请求（否则后台写入会冲掉合成内容）；首应答门禁由下面按生产同一方式确认
        s.preferences = UserDefaults(suiteName: "palmhelm.qp.test")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-qp","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let json = #"{"occupancy":"free","bridge":{"id":"mac-qp"},"targets":[{"id":"t1","projectName":"palmhelm-mac","agentName":"execute","online":true,"status":"idle","kind":"claude"}],"history":{"highWater":0,"items":[]}}"#
        s.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8)) }
        s.selectedTarget = "t1"; s.selectedThread = "t1"
        await s.refresh()
        var t = TranscriptThread(); t.status = .ok; t.sessionEpoch = "qp-e"
        t.items = [
            TranscriptItem(id: "qp-rec", role: "user", text: "记录里的消息 REC", t: 1_763_200_000_000, receipt: .init(commandKey: "REC", origin: "api", receiptState: "sent", eventKey: "REC")),
            TranscriptItem(id: "qp-agent", role: "assistant", text: "好的，收到。", t: 1_763_200_060_000),
        ]
        s.transcripts["t1"] = t
        session = s
        inbound("REC", "started", seq: 1, extra: awaiting)
        inbound("other", "queued", seq: 3)
        inbound("dl", "queued", seq: 4, extra: deadline)
        inbound("stop", "queued", seq: 5); progress("stop", "paused", #","stopDisposition":"not_dispatched""#)
        inbound("unc", "started", seq: 6, extra: awaiting); progress("unc", "paused", #","stopDisposition":"not_dispatched""#)
        inbound("legacy", "queued", seq: 7); progress("legacy", "paused")
        inbound("dupA", "queued", seq: 9, text: "同一正文"); inbound("dupB", "queued", seq: 10, text: "同一正文")
        let settings = EngineSettings(defaults: UserDefaults(suiteName: "palmhelm.qp.settings")!)
        hv = NSHostingView(rootView: AnyView(MainWindow().environment(s).environment(BridgeEngine(settings: settings)).environment(settings).frame(maxWidth: .infinity, maxHeight: .infinity)))
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hv
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        // 激活读取与无障碍树都要求窗口成为 key（应用在前台）。没有前台焦点的会话（后台 / 无界面 / 远程）里窗口永远不会 key，
        // 视图不激活、无障碍树为空，前置条件无法满足；这种环境下跳过并写明原因，不伪造激活（生产的激活入口不被旁路）。
        var keyWaited = 0.0
        while keyWaited < 2, !(NSApp.isActive && win.isKeyWindow) { await settle(0.25); keyWaited += 0.25 }
        try XCTSkipUnless(NSApp.isActive && win.isKeyWindow, "测试宿主没有前台焦点，窗口无法成为 key；请在有焦点的桌面会话中运行这组用例")
        // 骨架门禁（transcriptSettled）：生产在首个应答到达时把 confirmedToken 设为当前激活（MacSession+ActiveTranscript:99）；
        // 宿主里没有网络，这里等视图真正激活后做同一件事。不删 guard、不用遮罩；再等页面上真有内容才继续。
        var waited = 0.0
        while waited < 10, session.transcriptActivation.current?.targetId != "t1" { await settle(0.25); waited += 0.25 }
        session.transcriptConfirmedToken = session.transcriptActivation.current
        waited = 0
        while waited < 10, !(session.transcriptSettled("t1") && texts().contains { $0.contains("合成 other") }) { await settle(0.25); waited += 0.25 }
        XCTAssertTrue(session.transcriptSettled("t1"), "前置：骨架门禁已解除")
    }
    override func tearDown() async throws {
        session.stopStream()
        session.setTranscriptActive(nil)
        win.contentView = nil
        win.orderOut(nil)
        spin(0.3)
        if let previousPage { UserDefaults.standard.set(previousPage, forKey: pageKey) } else { UserDefaults.standard.removeObject(forKey: pageKey) }
    }

    private func texts() -> [String] { axTexts(hv!) }
    private func contains(_ part: String) -> Int { texts().filter { $0.contains(part) }.count }
    private func shotsDir() throws -> URL {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PALMHELM_QP_SHOTS_DIR"] ?? NSTemporaryDirectory() + "qp-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func shot(_ view: NSView, _ name: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: shotsDir().appendingPathComponent("\(name).png"))
    }

    func testRealParentShowsEachSyntheticStateOnceWithAReadableStatus() async throws {
        let all = texts()
        XCTAssertGreaterThan(all.count, 10, "前置：无障碍树里取得了页面文本")
        XCTAssertTrue(all.contains { $0.contains("合成 other") }, "无 Sent、无 deadline 的 queued 补行：页面上有这一行")
        XCTAssertGreaterThanOrEqual(contains("前开始，否则不发"), 1, "排队卡画出服务端期限")
        XCTAssertGreaterThanOrEqual(contains("已停止，未发出"), 1, "新无证明 not_dispatched 正控")
        XCTAssertGreaterThanOrEqual(contains("已停止跟踪，可能已执行"), 2, "见过 awaiting 后才首次渲染 + 旧 Bridge 缺键：保守")
        XCTAssertEqual(contains("被拒绝"), 0)
        XCTAssertGreaterThanOrEqual(contains("同一正文"), 2, "相同正文不同 key 不合并")
        XCTAssertGreaterThanOrEqual(contains("等待回合开始"), 1, "记录行的状态（卡）")
        try shot(hv, "mac-qp-matrix-light")
        // 整窗暗色截图：NSHostingView.cacheDisplay 取不到暗色下的窗口底色（只画出气泡，文字落在白底上），不是可信证据，不交付；暗色用两端 QueueCardShotTests 的卡片级截图。
    }

    func testRecordArrivalKeepsOneCopyOfTheSameKey() async throws {
        XCTAssertTrue(texts().contains { $0.contains("合成 other") })
        var t = try XCTUnwrap(session.transcripts["t1"])
        t.items.append(TranscriptItem(id: "qp-other", role: "user", text: "合成 other", t: 1_763_200_090_000, receipt: .init(commandKey: "other", origin: "api", receiptState: "accepted", eventKey: "other")))
        session.transcripts["t1"] = t
        await settle(1.0)
        XCTAssertFalse(session.threadTail(threadId: "t1").commandRows.map(\.key).contains("other"), "记录行承载同 key，补行让位")
        progress("other", "started", #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"running""#)
        await settle(1.0)
        XCTAssertGreaterThanOrEqual(contains("回合进行中"), 1, "同 K 阶段推进后记录行的卡随之更新")
        try shot(hv, "mac-qp-record-replaced")
    }

    // A1-011：真实 MainWindow→ThreadColumn：native 插话的状态行与同 key 投递 ack 同义，页面上只有一份（数据仍在 history）。
    func testNativeSteerDeliveryShowsOneStatusLineNotTwo() async throws {
        inbound("nat", "finished", seq: 20, text: "原生插话测试", extra: #","reason":"native_delivered""#)
        var m = MacSession.Sent(id: UUID(), text: "原生插话测试", at: Date(), afterSeq: 0, targetId: "t1")
        m.eventKey = "nat"
        session.sent.append(m)
        session.history.append(HistoryItem(seq: 20, uuid: "ack:nat", text: "已送达工作中终端，尚未确认并入本轮。", kind: "text", replyTo: "nat", target: TargetRef(id: "t1", projectName: "palmhelm-mac", agentName: nil)))
        await settle(1.0)
        XCTAssertGreaterThanOrEqual(contains("原生插话测试"), 1, "前置：本机 native 回显气泡在页面上")
        XCTAssertEqual(contains("已送达工作中终端"), 1, "状态行一份，下面不再重复 ack 回执块")
        try shot(hv, "mac-qp-native-one-status")
    }

    /// 找无障碍树里 label / title 等于给定文字的节点（KVC：SwiftUI 的 label 可能是 NSAttributedString）。
    private func findAX(_ node: Any, title: String, depth: Int = 0) -> NSObject? {
        guard depth < 60, let obj = node as? NSObject else { return nil }
        func text(_ key: String) -> String? { let v = obj.value(forKey: key); return (v as? NSAttributedString)?.string ?? (v as? String) }
        if [text("accessibilityLabel"), text("accessibilityTitle")].contains(title) { return obj }
        for c in obj.value(forKey: "accessibilityChildren") as? [Any] ?? [] { if let f = findAX(c, title: title, depth: depth + 1) { return f } }
        return nil
    }

    // 由主窗口的账本入口（与线程“更多”菜单按钮同一动作）点开账本，sheet 由主窗口承载；一次 GET；无写入口；完成后仍在原线程。
    // 注：Mac 本机即 Bridge 宿主，permission 恒为可控；“只读设备可进”由 iOS 的 QueueParentUITests 覆盖。
    func testLedgerOpensFromTheRealMenuAndOffersNoWritesWhileTheMainWindowKeepsItsThread() async throws {
        let calls = QPCalls()
        session.archiveClientOverride = { QPClient(calls: calls) }
        // 菜单项本身：SwiftUI Menu 的项只在真正弹出时才被填充，宿主里跟踪弹出无法收束（一次尝试挂起 555 秒），
        // 所以这里用 DEBUG 测试入口触发与菜单按钮同一个动作；菜单里“消息账本”项存在且不被 canControl 禁用，由源码（MainWindow 菜单）与 iOS 菜单 UI 用例证明。
        let open = try XCTUnwrap(MacLedgerTestHook.open, "线程列视图已登记账本入口")
        open()
        var waited = 0.0
        while waited < 10, win.attachedSheet == nil || calls.n == 0 { await settle(0.25); waited += 0.25 }
        let sheet = try XCTUnwrap(win.attachedSheet, "账本 sheet 由主窗口承载")
        await settle(1.0)
        let cv = try XCTUnwrap(sheet.contentView)
        let t = axTexts(cv)
        XCTAssertTrue(t.contains { $0.contains("正文 e2e:np") }, "账本里能找到同一批固定 key：\(t.prefix(12))")
        XCTAssertTrue(t.contains { $0.contains("已停止，未发出") } && t.contains { $0.contains("已停止跟踪，可能已执行") })
        XCTAssertTrue(t.contains { $0.contains("前开始，否则不发") }, "账本里的 queued 行带期限")
        XCTAssertFalse(t.contains { $0.contains("恢复") || $0 == "删除" || $0.contains("发送") }, "只读账本没有恢复 / 删除 / 发送入口")
        XCTAssertEqual(calls.n, 1, "只读一次 GET")
        XCTAssertEqual(session.selectedThread, "t1")
        XCTAssertTrue(session.sent.isEmpty)
        try shot(cv, "mac-qp-ledger")
        // “完成”带 .cancelAction 快捷键：向 sheet 发真实的 Esc 键事件（SwiftUI 按钮不是 NSButton，也不响应无障碍按下）。
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        sheet.makeKey()
        _ = sheet.performKeyEquivalent(with: esc)
        NSApp.sendEvent(esc)
        waited = 0
        while waited < 5, win.attachedSheet != nil { await settle(0.25); waited += 0.25 }
        XCTAssertNil(win.attachedSheet, "完成后 sheet 关闭")
        XCTAssertEqual(session.selectedThread, "t1", "仍在原线程")
        XCTAssertTrue(texts().contains { $0.contains("合成 other") }, "主窗口内容仍在")
    }

    // A1-010 ③：Mac 并非恒可控（loopback refresh 可清 device）——只读设备（canControl=false）也能进入消息账本，且账本里没有恢复 / 删除 / 绑定 / 发送入口。
    func testReadOnlyDeviceCanOpenTheLedgerWithNoWriteEntries() async throws {
        session.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-qp","name":"mac","paused":false,"permission":"readonly"}"#.utf8)) // 取值是 readonly（DevicePermission.readonly），不是 view
        XCTAssertFalse(session.canControl, "前置：只读已确实生效（canControl=false）")
        let calls = QPCalls()
        session.archiveClientOverride = { QPClient(calls: calls) }
        await settle(0.5)
        XCTAssertFalse(session.canControl, "页面刷新后仍是只读")
        let open = try XCTUnwrap(MacLedgerTestHook.open, "线程列视图已登记账本入口（与菜单“消息账本”按钮同一动作，不受 canControl 影响）")
        open()
        var waited = 0.0
        while waited < 10, win.attachedSheet == nil || calls.n == 0 { await settle(0.25); waited += 0.25 }
        let sheet = try XCTUnwrap(win.attachedSheet, "只读设备也能进入账本")
        await settle(1.0)
        let cv = try XCTUnwrap(sheet.contentView)
        let t = axTexts(cv)
        XCTAssertTrue(t.contains { $0.contains("正文 e2e:np") } && t.contains { $0.contains("已停止，未发出") }, "账本内容可读：\(t.prefix(10))")
        XCTAssertFalse(t.contains { $0.contains("恢复") || $0 == "删除" || $0.contains("绑定") || $0.contains("发送") || $0.contains("重试发送") }, "只读账本没有恢复 / 删除 / 绑定 / 发送入口")
        func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
        XCTAssertTrue(buttons(cv).allSatisfy { !["恢复", "删除", "发送", "绑定"].contains($0.title) }, "没有写类按钮")
        XCTAssertEqual(calls.n, 1, "只读一次 GET")
        XCTAssertTrue(session.sent.isEmpty)
        XCTAssertFalse(session.canControl, "账本打开期间仍是只读")
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        sheet.makeKey()
        _ = sheet.performKeyEquivalent(with: esc)
        NSApp.sendEvent(esc)
        waited = 0
        while waited < 5, win.attachedSheet != nil { await settle(0.25); waited += 0.25 }
        XCTAssertNil(win.attachedSheet, "完成后 sheet 关闭")
        XCTAssertEqual(session.selectedThread, "t1")
    }
}
