import XCTest
import Foundation
import PalmhelmKit
@testable import PalmhelmMac

// 本机回显（真实 MacSession + TranscriptThread，与 iOS 的 PendingEchoSessionTests 同一规则）：普通消息终态即隐藏；原生直达插话在记录里还没关联前保留（每线程最多 20 条，同一原生会话代次），关联后不复活。
@MainActor final class PendingEchoSessionTests: XCTestCase {
    private func echo(_ key: String?, _ text: String = "插话", thread: String = "t1", native: Bool = false, epoch: String? = nil) -> MacSession.Sent {
        var m = MacSession.Sent(id: UUID(), text: text, at: Date(timeIntervalSince1970: 1000), afterSeq: 0, targetId: thread, eventKey: key)
        if native { m.mode = .steer; m.agent = "claude" }
        m.sessionEpoch = epoch
        return m
    }
    private func command(_ key: String, state: String, reason: String? = nil, direct: Bool = false, queueDeadline: Int? = nil) -> ApiCommand {
        var c = ApiCommand(key: key, inboxSeq: 1, text: "x", origin: "api", targetId: "t1", state: state, reason: reason, lane: direct ? "use" : nil)
        if direct { c.directAgent = "claude" }
        c.queueDeadlineT = queueDeadline
        return c
    }
    private func receipt(_ key: String) -> TranscriptItem {
        .init(id: "r-\(key)", role: "user", text: "x", t: 1000, receipt: .init(commandKey: key, origin: "api", receiptState: "done", eventKey: key))
    }
    private func thread(_ items: [TranscriptItem] = [], epoch: String = "e1") -> TranscriptThread {
        var t = TranscriptThread()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: epoch, revision: "r", items: items))
        return t
    }
    private func session(_ sent: [MacSession.Sent], commands: [ApiCommand] = [], transcript: TranscriptThread? = nil) -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.t15.pending-echo.tests")!
        s.sent = sent
        for c in commands { s.commands[c.key] = c }
        if let transcript { s.transcripts["t1"] = transcript }
        return s
    }
    private func ids(_ s: MacSession) -> [UUID] { s.pendingEchoes(threadId: "t1").map(\.id) }

    func testNativeFinishedWithoutReceiptStaysVisible() {
        let a = echo("k1", native: true, epoch: "e1")
        let s = session([a], commands: [command("k1", state: "finished", direct: true)], transcript: thread())
        XCTAssertEqual(ids(s), [a.id], "命令已完成但记录里还没有回执：原生插话的回显仍显示")
    }

    func testConsecutiveNativeSendsKeepOrderWhenFirstIsFinished() {
        let a = echo("k1", "第一句", native: true, epoch: "e1"), b = echo("k2", "第二句", native: true, epoch: "e1")
        let s = session([a, b], commands: [command("k1", state: "finished", direct: true), command("k2", state: "queued", direct: true)], transcript: thread())
        XCTAssertEqual(ids(s), [a.id, b.id])
    }

    func testLinkedReceiptHidesEchoAndNeverRevivesAcrossWindowAndPageReplacement() {
        let a = echo("k1", native: true, epoch: "e1")
        let s = session([a], commands: [command("k1", state: "finished", direct: true)], transcript: thread([receipt("k1")]))
        XCTAssertTrue(ids(s).isEmpty, "回执已进记录：回显隐藏")
        XCTAssertEqual(s.transcripts["t1"]?.linkedEventKeys, ["k1"])

        let replies = (1...40).map { TranscriptItem(id: "a\($0)", role: "assistant", text: "reply") }
        s.transcripts["t1"]?.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r2", items: [receipt("k1")] + replies))
        XCTAssertFalse(s.transcripts["t1"]?.visibleItems.contains { $0.receipt?.eventKey == "k1" } ?? true, "回执已滚出 40 行渲染窗口")
        XCTAssertTrue(ids(s).isEmpty, "窗口外的已关联回显不复活")

        s.transcripts["t1"]?.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r3", items: [.init(id: "new-tail", role: "assistant", text: "new")]))
        XCTAssertFalse(s.transcripts["t1"]?.items.contains { $0.receipt?.eventKey == "k1" } ?? true, "最新页整体替换后回执已不在 items 里")
        XCTAssertTrue(ids(s).isEmpty, "整体替换后已关联回显不复活")
    }

    func testNewNativeSessionDoesNotShowOldEcho() {
        let a = echo("k1", native: true, epoch: "e1")
        let s = session([a], commands: [command("k1", state: "queued", direct: true)], transcript: thread([], epoch: "e2"))
        XCTAssertTrue(ids(s).isEmpty, "发送于 e1 的插话回显不串到 e2 的原生会话")
    }

    func testOrdinaryMessageHidesOnTerminalAndStaysWhileInFlight() {
        let done = echo("k1", "普通完成"), running = echo("k2", "普通在途")
        let s = session([done, running], commands: [command("k1", state: "finished"), command("k2", state: "queued")], transcript: thread())
        XCTAssertEqual(ids(s), [running.id], "普通消息终态即隐藏，在途仍显示（旧规则）")
    }

    func testWithdrawnNativeInsertIsHidden() {
        let a = echo("k1", native: true, epoch: "e1")
        let s = session([a], commands: [command("k1", state: "rejected", reason: "withdrawn", direct: true)], transcript: thread())
        XCTAssertTrue(ids(s).isEmpty, "撤回后不按原生插话保留")
    }

    func testFailedSendKeepsItsError() {
        var a = echo(nil, "失败")
        a.error = "发送失败"
        let s = session([a], transcript: thread())
        XCTAssertEqual(s.pendingEchoes(threadId: "t1").first?.error, "发送失败")
    }

    func testDeadlineRowIsNotDuplicatedAsEcho() {
        let a = echo("k1")
        let s = session([a], commands: [command("k1", state: "queued", queueDeadline: 9999)], transcript: thread())
        XCTAssertTrue(ids(s).isEmpty, "排队期限行已单独显示，回显不重复")
    }

    func testOnlyTheLatestTwentyUnlinkedNativeEchoesAreKept() {
        let all = (0..<21).map { echo("k\($0)", "第\($0)句", native: true, epoch: "e1") }
        let cmds = (0..<21).map { command("k\($0)", state: "finished", direct: true) }
        let s = session(all, commands: cmds, transcript: thread())
        let shown = ids(s)
        XCTAssertEqual(shown.count, 20)
        XCTAssertFalse(shown.contains(all[0].id), "最早的一条超出上限，按普通规则隐藏")
        XCTAssertEqual(shown.last, all[20].id)
    }

    func testEchoesOfAnotherThreadAreNotBackfilled() {
        let other = echo("k9", thread: "t2", native: true, epoch: "e1")
        let s = session([other], commands: [command("k9", state: "queued", direct: true)], transcript: thread())
        XCTAssertTrue(ids(s).isEmpty)
    }

    func testUnboundNativeEchoFollowsOrdinaryRuleUntilFirstEpochIsBound() {
        let a = echo("k1", native: true, epoch: nil)
        let s = session([a], commands: [command("k1", state: "finished", direct: true)])
        XCTAssertTrue(ids(s).isEmpty, "发送时代次未知：不做通配保留，按普通终态规则隐藏")
        s.transcripts["t1"] = thread([], epoch: "e1")
        XCTAssertEqual(s.sent.first?.sessionEpoch, "e1", "线程第一次取得原生代次即绑定")
        XCTAssertEqual(ids(s), [a.id], "同代次的原生回显保留")
        s.transcripts["t1"] = thread([], epoch: "e2")
        XCTAssertTrue(ids(s).isEmpty, "绑定后的回显不随之后的会话 e2 复现")
    }

    func testRejectedNativeTerminalFollowsOrdinaryRule() {
        let a = echo("k1", native: true, epoch: "e1")
        let s = session([a], commands: [command("k1", state: "rejected", direct: true)], transcript: thread())
        XCTAssertTrue(ids(s).isEmpty, "rejected 不是等待处理的暂停：按普通终态隐藏")
    }

    // O1-068：原生插话被暂停（未送达、不自动重发）时保留为本机失败行；关联或换代后不复活；普通消息的 paused 不变。
    func testPausedNativeEchoStaysWithItsFailureLabel() {
        let a = echo("k1", native: true, epoch: "e1")
        var proven = command("k1", state: "paused", direct: true)
        proven.stopDisposition = .notDispatched // Bridge 证明从未派发，才断言“未发送”
        let s = session([a], commands: [proven], transcript: thread())
        XCTAssertEqual(ids(s), [a.id], "原生未送达的 paused 保留为本机失败行")
        XCTAssertEqual(s.outgoingStatus(a).label, "未发送 · 已暂停，不会自动重发")
        let unproven = session([a], commands: [command("k1", state: "paused", direct: true)], transcript: thread())
        XCTAssertEqual(unproven.outgoingStatus(a).label, "已停止跟踪，可能已执行", "缺键的 generic paused 不由路由类型推断未发送")
    }

    func testPausedNativeEchoIsNotResurrectedWhenLinkedOrWhenTheSessionChanges() {
        let a = echo("k1", native: true, epoch: "e1")
        let linked = session([a], commands: [command("k1", state: "paused", direct: true)], transcript: thread([receipt("k1")]))
        XCTAssertTrue(ids(linked).isEmpty, "记录已关联：不复活")
        let moved = session([a], commands: [command("k1", state: "paused", direct: true)], transcript: thread([], epoch: "e2"))
        XCTAssertTrue(ids(moved).isEmpty, "会话已换：不属于当前线程")
    }

    func testPausedOrdinaryMessageStillFollowsTheOrdinaryRule() {
        let a = echo("k1", native: false, epoch: nil)
        let s = session([a], commands: [command("k1", state: "paused")], transcript: thread())
        XCTAssertTrue(ids(s).isEmpty, "普通消息的 paused 仍按终态隐藏")
    }

    // O1-068：暂停通知挂在原消息下，且不被排队卡覆盖。
    func testPausedNativeNoticeAttributesBackToItsMessage() {
        let a = echo("k1", native: true, epoch: "e1")
        let s = session([a], commands: [command("k1", state: "paused", direct: true)], transcript: thread())
        s.history = [HistoryItem(seq: 5, uuid: "nsteer-paused:in-1", text: "[alpha] 直达插话未发送（目标已暂停），已暂停，不会自动重发。", kind: "text", replyTo: "k1", t: 1000)]
        XCTAssertEqual(s.outcome(of: a.id)?.reply?.contains("不会自动重发"), true, "暂停通知挂在原消息下")
        XCTAssertFalse(QueueStatusPresentation.receiptCovered(uuid: "nsteer-paused:in-1", replyTo: "k1", coveredKeys: ["k1"]), "不被排队卡覆盖")
    }

    // H3-1：同代次暂不可读后恢复不是换代，已关联的原生回显不复活。
    func testTransientUnavailableMustNotReviveMatchedNativeEcho() {
        let a = echo("k1", native: true, epoch: "e1")
        let s = session([a], commands: [command("k1", state: "finished", direct: true)], transcript: thread([receipt("k1")]))
        XCTAssertTrue(ids(s).isEmpty)
        s.transcripts["t1"]?.applyLatest(TranscriptPage(status: "unavailable"))
        s.transcripts["t1"]?.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: [.init(id: "newtail", role: "assistant", text: "reply")]))
        XCTAssertTrue(ids(s).isEmpty, "同代次恢复后已匹配的原生回显不复活")
    }
}
