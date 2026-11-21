import AppKit
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}
private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }

private func questions() -> [ProjectedQuestion] {
    decode(#"[{"header":"h","question":"选哪个？","multiSelect":false,"options":[{"label":"甲","description":"","selectable":true}]}]"#)
}
private func detail(_ a: ApprovalView) -> ApprovalDetail {
    let v = String(data: try! JSONEncoder().encode(a), encoding: .utf8)!
    let q = String(data: try! JSONEncoder().encode(questions()), encoding: .utf8)!
    return decode(#"{"view":\#(v),"body":{"questions":\#(q)}}"#)
}
/// h10c 终审（A1-055）修复：F2 附件缺失、F3 提醒发送中断连、F5 复核、F6 窄窗规则、提醒区呈现。
@MainActor
final class ReviewFixTests: XCTestCase {
    private func state(bridge: String = "b1") -> BridgeState {
        decode(#"{"bridge":{"id":"\#(bridge)"},"occupancy":"free","targets":[{"projectName":"P","id":"A","online":true,"status":"working"}],"history":{"highWater":0,"items":[]},"binding":{"targetId":"A","projectName":"P"}}"#)
    }
    private func session() -> MacSession {
        let s = MacSession()
        s.state = state()
        s.link = .connected
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        s.sendOverride = { _, id in MessageReceipt.stub("ek-\(id.uuidString.prefix(6))") }
        s.stateOverride = { [unowned s] in await MainActor.run { s.state ?? BridgeState.empty } }
        s.selectTarget("A")
        return s
    }
    private func pngFile(_ name: String = "a") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rf-\(UUID().uuidString)-\(name).png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
    private func attachment(_ url: URL) -> ComposerAttachment { ComposerAttachment(path: url.path, thumbnail: NSImage(contentsOf: url) ?? NSImage(size: NSSize(width: 1, height: 1))) }

    // MARK: F2

    func testSendWithAnAttachmentDeletedAfterAddingSendsNothingAndKeepsTheDraft() async throws {
        let s = session()
        let url = try pngFile("shot")
        var d = MacSession.ComposerDraft(); d.text = "看这张图"; d.attachments = [attachment(url)]
        s.setDraft(d, for: "A")
        try FileManager.default.removeItem(at: url) // 加入后被删
        let calls = Box(0)
        s.sendOverride = { _, _ in calls.value += 1; return MessageReceipt.stub("k") }
        let ok = await s.submitComposer(threadId: "A", agent: nil)
        XCTAssertFalse(ok)
        XCTAssertEqual(calls.value, 0, "零发送")
        XCTAssertTrue(s.sent.isEmpty)
        XCTAssertEqual(s.draft("A").text, "看这张图")
        XCTAssertEqual(s.draft("A").attachments.count, 1, "草稿与附件都保留")
        XCTAssertTrue(s.composerNote("A")?.text.contains(url.lastPathComponent) == true, "显示缺失文件名")
        XCTAssertFalse(s.isComposerBusy("A"))
    }

    func testRestoreWithAMissingAttachmentDoesNothingAndKeepsSnapshotAndEntry() async throws {
        let s = session()
        let url = try pngFile()
        let m = MacSession.Sent(id: UUID(), text: "x", at: Date(), afterSeq: 0, targetId: "A", eventKey: "k", draft: "被拒的话", attachmentPaths: [url.path], attachmentSources: [.userReference])
        s.sent = [m]
        try FileManager.default.removeItem(at: url)
        var existing = MacSession.ComposerDraft(); existing.text = "已有"
        s.setDraft(existing, for: "A")
        XCTAssertFalse(s.restoreRejected(m, threadId: "A"))
        XCTAssertEqual(s.draft("A").text, "已有", "整个恢复不做，不恢复一半")
        XCTAssertFalse(s.sent[0].restored, "不标已恢复：入口与快照保留")
        XCTAssertTrue(s.composerNote("A")?.text.contains(url.lastPathComponent) == true)
        // 文件回来后同一入口仍可恢复
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let back = try pngFile()
        try FileManager.default.moveItem(at: back, to: url)
        s.setDraft(MacSession.ComposerDraft(), for: "A")
        XCTAssertTrue(s.restoreRejected(m, threadId: "A"))
        XCTAssertEqual(s.draft("A").text, "被拒的话")
        try? FileManager.default.removeItem(at: url)
    }

    func testUnattributedRestoreWithMissingAttachmentKeepsEntry() async throws {
        let s = session()
        let url = try pngFile()
        s.sent.append(MacSession.Sent(id: UUID(), text: "x", at: Date(), afterSeq: 0, targetId: nil, error: "无法连接", draft: "旧快照", attachmentPaths: [url.path]))
        try FileManager.default.removeItem(at: url)
        let id = s.inboxAlerts[0].restoreSendId!
        let msg = s.restoreUnattributed(id)
        XCTAssertTrue(msg?.text.contains(url.lastPathComponent) == true)
        XCTAssertNotNil(s.inboxAlerts[0].restoreSendId, "入口保留")
        XCTAssertTrue(s.draft("A").isEmpty)
    }

    func testComposerRulesRestoreIsAllOrNothing() throws {
        let ok = try pngFile(), gone = try pngFile()
        try FileManager.default.removeItem(at: gone)
        let m = MacSession.Sent(id: UUID(), text: "x", at: Date(), afterSeq: 0, targetId: "A", draft: "d", attachmentPaths: [ok.path, gone.path])
        var draft = "原来的", atts: [ComposerAttachment] = []
        XCTAssertFalse(ComposerRules.restore(m, canEdit: true, draft: &draft, attachments: &atts))
        XCTAssertEqual(draft, "原来的")
        XCTAssertTrue(atts.isEmpty)
        try? FileManager.default.removeItem(at: ok)
    }

    // MARK: F3

    private var reminder: HistoryItem { HistoryItem(seq: 7, uuid: "nblocked2:r1", text: "[P] 等待已超过 10 分钟", kind: "text", replyTo: "evA", target: TargetRef(id: "A", projectName: "P"), t: Int(Date().timeIntervalSince1970 * 1000)) }
    /// 提醒要「当前」才能重置：新 Bridge 的投影里该目标正阻塞在这条 eventKey 上。
    private func blockedSession() -> MacSession {
        let s = session()
        s.applyStateSnapshot({ var st = state(); st.currentBlocked = [CurrentBlocked(targetId: "A", eventKey: "evA", blockedSince: 1)]; st.currentBlockedFresh = true; return st }())
        return s
    }

    func testDisconnectDuringResetReleasesBusyMarksInterruptedAndStaleTaskDoesNotOverwrite() async {
        let gate = Gate()
        let calls = Box(0)
        let s = blockedSession()
        s.sendOverride = { _, id in calls.value += 1; if calls.value == 1 { await gate.wait() }; return MessageReceipt.stub("ek-\(id.uuidString.prefix(6))") }
        let card = reminder
        let task = Task { @MainActor in await s.resetOccupancy(for: card, name: "P") }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(s.reminderSend(card).busy)
        s.disconnect(reason: "断开")
        let st = s.reminderSend(card)
        XCTAssertFalse(st.busy, "旧代次的 busy 随连接失效释放")
        XCTAssertTrue(st.interrupted, "说明「连接中断，结果未知」")
        // 重连后用户再次操作
        s.link = .connected
        await s.resetOccupancy(for: card, name: "P")
        let second = s.reminderSend(card)
        XCTAssertNotNil(second.sendId)
        XCTAssertFalse(second.interrupted)
        // 旧任务此时才返回：不覆盖重连后的新结果，也不自动重放
        await gate.release()
        await task.value
        XCTAssertEqual(s.reminderSend(card), second, "旧任务返回不覆盖")
        XCTAssertEqual(calls.value, 2, "只有旧的那一次与用户重连后主动的那一次，没有自动重放")
    }

    func testInterruptedStateIsShownOnTheCardAndClearedByTheNextOperation() async {
        let s = blockedSession()
        let gate = Gate()
        s.sendOverride = { _, id in await gate.wait(); return MessageReceipt.stub("k") }
        let card = reminder
        let t = Task { @MainActor in await s.resetOccupancy(for: card, name: "P") }
        for _ in 0..<30 { await Task.yield() }
        s.disconnect(reason: "x")
        XCTAssertTrue(s.reminderSend(card).interrupted)
        await gate.release(); await t.value
        s.forget()
        XCTAssertFalse(s.reminderSend(card).interrupted, "forget 清空")
    }

    // MARK: F5

    private func approval(_ id: String) -> ApprovalView {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var a = ApprovalView(id: id, status: "pending", targetLabel: "P", attribution: "exact", toolName: "Bash", summary: "x", createdT: now, expiresT: now + 600_000)
        a.kind = "question"
        return a
    }
    private func answeredDraft(_ s: MacSession, _ a: ApprovalView) -> QuestionDraft {
        var d = QuestionDraft(questions()); d.toggle(question: 0, option: 0)
        s.setQuestionDraft(d, for: a)
        return d
    }

    func testStateRefreshFailureKeepsTheDraftEvenWhenDetailWouldSucceed() async {
        let s = session()
        let a = approval("q1"); s.approvals["q1"] = a
        let calls = Box(0)
        s.pendingCallOverride = { _ in calls.value += 1; return decode(#"{"status":"decided"}"#) }
        s.approvalDetailOverride = { _ in detail(a) }
        s.stateOverride = { throw URLError(.timedOut) } // 权限刷新失败：不吞
        let d = answeredDraft(s, a)
        let r = await s.submitQuestion(a, d)
        if case .kept = r {} else { XCTFail("应保留：\(r)") }
        XCTAssertEqual(calls.value, 0, "零提交")
        XCTAssertNotNil(s.questionDraft(a))
    }

    func testDisconnectWhileDetailIsPendingSubmitsNothing() async {
        let s = session()
        let a = approval("q1"); s.approvals["q1"] = a
        let gate = Gate()
        let calls = Box(0)
        s.pendingCallOverride = { _ in calls.value += 1; return decode(#"{"status":"decided"}"#) }
        s.approvalDetailOverride = { _ in await gate.wait(); return detail(a) }
        let d = answeredDraft(s, a)
        let task = Task { @MainActor in await s.submitQuestion(a, d) }
        for _ in 0..<30 { await Task.yield() }
        s.disconnect(reason: "断开")
        await gate.release()
        let r = await task.value
        if case .kept = r {} else { XCTFail("应保留：\(r)") }
        XCTAssertEqual(calls.value, 0)
    }

    func testPermissionDroppingWhileDetailIsPendingSubmitsNothing() async {
        let s = session()
        let a = approval("q1"); s.approvals["q1"] = a
        let gate = Gate()
        let calls = Box(0)
        s.pendingCallOverride = { _ in calls.value += 1; return decode(#"{"status":"decided"}"#) }
        s.approvalDetailOverride = { _ in await gate.wait(); return detail(a) }
        let d = answeredDraft(s, a)
        let task = Task { @MainActor in await s.submitQuestion(a, d) }
        for _ in 0..<30 { await Task.yield() }
        s.device = decode(#"{"id":"d","name":"mac","paused":false,"permission":"readonly"}"#) // 等详情期间被降为只读
        await gate.release()
        let r = await task.value
        if case .kept = r {} else { XCTFail("应保留：\(r)") }
        XCTAssertEqual(calls.value, 0, "最后一个 await 之后再核权限")
    }

    // MARK: F6 窄窗规则

    func testSidebarWideNarrowExpandBackToWide() {
        var st = SidebarState()
        XCTAssertTrue(st.shown(narrow: false))
        XCTAssertFalse(st.shown(narrow: true), "窄窗默认收起")
        st.toggle(narrow: true) // 窄窗里点展开
        XCTAssertTrue(st.shown(narrow: true), "可临时展开，不会永远打不开")
        XCTAssertTrue(st.userWants, "不改写用户意图")
        st.widthChanged(narrow: false)
        XCTAssertTrue(st.shown(narrow: false), "回宽窗恢复用户意图")
        XCTAssertFalse(st.tempOpen)
        st.toggle(narrow: true)
        XCTAssertTrue(st.shown(narrow: true))
        st.toggle(narrow: true)
        XCTAssertFalse(st.shown(narrow: true), "再点收起")
    }

    func testSidebarUserCollapsedStaysCollapsedAfterNarrowTempOpen() {
        var st = SidebarState()
        st.toggle(narrow: false) // 宽窗里用户主动收起
        XCTAssertFalse(st.shown(narrow: false))
        st.reveal(narrow: true) // 窄窗里铃铛 / 导航临时展开
        XCTAssertTrue(st.shown(narrow: true))
        st.widthChanged(narrow: false)
        XCTAssertFalse(st.shown(narrow: false), "宽窗仍是用户收起的意图")
        st.reveal(narrow: false) // 宽窗里导航到收件箱：保证看得见
        XCTAssertTrue(st.shown(narrow: false))
        XCTAssertTrue(SidebarState.isNarrow(899))
        XCTAssertFalse(SidebarState.isNarrow(900))
    }

    // MARK: 侧栏分区 / 提醒入口（O1-113）

    func testSidebarInboxHidesNeedsYouWhenEmptyAndNeverContainsAlerts() {
        let working: [TargetSummary] = [TargetSummary(projectName: "A", online: true, targetId: "a", status: "working")]
        let m = InboxModel.build(approvals: [], targets: working, pinned: { _ in false }, lastActivity: { _ in 0 })
        XCTAssertFalse(m.showsNeedsYou, "没有请求卡和无卡 blocked：整个「需要你处理」区不显示")
        XCTAssertTrue(m.showsWorking)
        XCTAssertFalse(m.showsEmptyState, "有工作中就没有空态")
        let empty = InboxModel.build(approvals: [], targets: [], pinned: { _ in false }, lastActivity: { _ in 0 })
        XCTAssertTrue(empty.showsEmptyState, "三区都空才显示一行空态")
        XCTAssertFalse(empty.showsNeedsYou || empty.showsWorking)
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var a = ApprovalView(id: "r", status: "pending", targetLabel: "P", attribution: "exact", toolName: "Bash", summary: "x", createdT: now, expiresT: now + 60_000)
        a.kind = nil
        let withReq = InboxModel.build(approvals: [a], targets: [], pinned: { _ in false }, lastActivity: { _ in 0 })
        XCTAssertTrue(withReq.showsNeedsYou)
        XCTAssertFalse(withReq.showsEmptyState)
    }

    func testAlertsDoNotAffectTheInboxModelButShowTheMarker() {
        let s = session()
        s.history = (1...20).map { HistoryItem(seq: $0, uuid: "u\($0)", text: "rejected:target_not_verified 旧\($0)", kind: "text", replyTo: "x\($0)", target: nil, t: Int(Date().timeIntervalSince1970 * 1000) + $0) }
        let m = s.inboxModel
        XCTAssertFalse(m.showsNeedsYou, "一长串拒绝不进收件箱")
        XCTAssertFalse(s.inboxAlerts.isEmpty, "提醒数据与逻辑保留")
        XCTAssertTrue(AlertsPresentation.showsMarker(reminders: s.blockedReminders.count, alerts: s.inboxAlerts.count))
        XCTAssertFalse(AlertsPresentation.showsMarker(reminders: 0, alerts: 0), "没有提醒不显示标记")
        s.history = []
        XCTAssertFalse(AlertsPresentation.showsMarker(reminders: s.blockedReminders.count, alerts: s.inboxAlerts.count))
    }

    func testPopoverOrderPutsRecoverableFailuresBeforeHistoryRejections() {
        let s = session()
        s.history = [HistoryItem(seq: 1, uuid: "u1", text: "rejected:target_not_verified 历史", kind: "text", replyTo: "x", target: nil, t: 9_000_000_000_000)] // 比失败新
        s.sent.append(MacSession.Sent(id: UUID(), text: "a", at: Date(), afterSeq: 0, targetId: nil, error: "无法连接", draft: "可恢复的话"))
        let ordered = AlertsPresentation.ordered(s.inboxAlerts)
        XCTAssertEqual(ordered.count, 2)
        XCTAssertNotNil(ordered[0].restoreSendId, "可恢复失败排前，即使历史拒绝更新")
        XCTAssertNil(ordered[1].restoreSendId)
    }

    // MARK: 提醒区呈现

    func testAlertsSplitRecoverableStaysVisibleAndNoRecoveryGoesToHistory() {
        let s = session()
        s.sent.append(MacSession.Sent(id: UUID(), text: "a", at: Date(), afterSeq: 0, targetId: nil, error: "无法连接", draft: "可恢复的话"))
        let at = Int(Date().timeIntervalSince1970 * 1000)
        s.history = [HistoryItem(seq: 1, uuid: "u1", text: "rejected:target_not_verified 旧拒绝", kind: "text", replyTo: "x", target: nil, t: at)]
        let (live, history) = AlertsPresentation.split(s.inboxAlerts)
        XCTAssertEqual(live.count, 1)
        XCTAssertNotNil(live[0].restoreSendId)
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history[0].restoreSendId)
        XCTAssertEqual(history[0].t, at, "每条带时间，视图显示相对时间")
        XCTAssertEqual(s.history.count, 1, "不删原始数据")
    }
}
