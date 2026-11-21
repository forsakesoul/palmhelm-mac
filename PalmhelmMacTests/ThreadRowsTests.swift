import XCTest
import PalmhelmKit
@testable import PalmhelmMac

final class ThreadRowsTests: XCTestCase {
    @MainActor
    func testMineRowsPlacedAfterTheirSeq() {
        let mine = MacSession.Sent(id: UUID(), text: "hi", at: Date(), afterSeq: 1, targetId: nil, eventKey: nil, error: nil)
        let rows = ThreadRow.merge(history: [], commands: [], sent: [mine])
        XCTAssertEqual(rows.count, 1)
        if case .mine(let m) = rows[0] { XCTAssertEqual(m.text, "hi") } else { XCTFail("expected mine row") }
    }

    // 直达被拒：回执 rejected: 经 replyTo 关联到本机发送的 eventKey；拒绝回执归“系统”线程，所以关联必须用全量 history（I2）
    @MainActor
    func testRejectedDirectMarksSentFailedInEitherOrder() {
        let rejected = HistoryItem(seq: 5, uuid: "u5", text: "rejected:dispatch_disabled（派发未开启）", kind: "text", replyTo: "k1")
        let mine = MacSession.Sent(id: UUID(), text: "hi", at: Date(), afterSeq: 4, targetId: "t", eventKey: "k1", error: nil)
        // 回执先到、eventKey 已回填
        let after = ThreadRow.withRejections([mine], history: [rejected])
        XCTAssertEqual(after.first?.error?.text, ReceiptText.summary("rejected:dispatch_disabled（派发未开启）"))
        // eventKey 后回填：发送时还没有 eventKey，之后每次按当前历史求值都能关联
        let noKey = MacSession.Sent(id: UUID(), text: "hi", at: Date(), afterSeq: 4, targetId: "t", eventKey: nil, error: nil)
        XCTAssertNil(ThreadRow.withRejections([noKey], history: [rejected]).first?.error)
        var later = noKey
        later.eventKey = "k1"
        XCTAssertNotNil(ThreadRow.withRejections([later], history: [rejected]).first?.error)
    }

    @MainActor
    func testAckDoesNotMarkSentFailed() {
        let ack = HistoryItem(seq: 5, uuid: "u5", text: "ack:已受理", kind: "ack", replyTo: "k3")
        let mine = MacSession.Sent(id: UUID(), text: "hi", at: Date(), afterSeq: 4, targetId: "t", eventKey: "k3", error: nil)
        XCTAssertNil(ThreadRow.withRejections([mine], history: [ack]).first?.error)
    }

    // 业务拒绝后的恢复条件（F2）：HTTP 已受理 + 回执 rejected + 有草稿/附件 + 未恢复过；两种到达顺序都成立
    @MainActor
    func testRestorableOnlyForRejectedSendWithSnapshot() {
        let rejected = HistoryItem(seq: 5, uuid: "u5", text: "rejected:dispatch_disabled（派发未开启）", kind: "text", replyTo: "k1")
        var sent = MacSession.Sent(id: UUID(), text: "hi", at: Date(), afterSeq: 4, targetId: "t", eventKey: nil, error: nil, draft: "hi", attachmentPaths: ["/p/a.png"])
        // 回执先到、eventKey 尚未回填：不恢复
        XCTAssertNil(MacSession.restorableSend(in: [sent], history: [rejected], threadId: "t"))
        // eventKey 后回填：恢复
        sent.eventKey = "k1"
        XCTAssertEqual(MacSession.restorableSend(in: [sent], history: [rejected], threadId: "t")?.id, sent.id)
        // 已恢复过：不再恢复
        sent.restored = true
        XCTAssertNil(MacSession.restorableSend(in: [sent], history: [rejected], threadId: "t"))
    }

    @MainActor
    func testNotRestorableForHTTPFailureAckOtherThreadOrEmptySnapshot() {
        let rejected = HistoryItem(seq: 5, uuid: "u5", text: "rejected:dispatch_disabled（派发未开启）", kind: "text", replyTo: "k1")
        let ack = HistoryItem(seq: 6, uuid: "u6", text: "ack:已受理", kind: "ack", replyTo: "k2")
        // HTTP 失败：原始 error 已有，草稿本来就还在输入框
        let failed = MacSession.Sent(id: UUID(), text: "hi", at: Date(), afterSeq: 4, targetId: "t", eventKey: nil, error: "网络错误", draft: "hi")
        XCTAssertNil(MacSession.restorableSend(in: [failed], history: [rejected], threadId: "t"))
        // 普通受理
        let accepted = MacSession.Sent(id: UUID(), text: "hi", at: Date(), afterSeq: 4, targetId: "t", eventKey: "k2", error: nil, draft: "hi")
        XCTAssertNil(MacSession.restorableSend(in: [accepted], history: [ack], threadId: "t"))
        // 其他线程
        let other = MacSession.Sent(id: UUID(), text: "hi", at: Date(), afterSeq: 4, targetId: "x", eventKey: "k1", error: nil, draft: "hi")
        XCTAssertNil(MacSession.restorableSend(in: [other], history: [rejected], threadId: "t"))
        // 没有草稿与附件
        let empty = MacSession.Sent(id: UUID(), text: "", at: Date(), afterSeq: 4, targetId: "t", eventKey: "k1", error: nil)
        XCTAssertNil(MacSession.restorableSend(in: [empty], history: [rejected], threadId: "t"))
    }

    // O1-364 R2 / R3（Mac）：稳定锚、跨线程 seq、未知时间退回回执锚定排序，与 iOS 同一负例。
    private func timed(_ seq: Int, t: Int) -> HistoryItem { HistoryItem(seq: seq, uuid: "u\(seq)", text: "r\(seq)", kind: "text", replyTo: nil, t: t) }
    private func cmdAt(_ key: String, _ inboxSeq: Int, t: Int?) -> ApiCommand {
        var c = ApiCommand(key: key, inboxSeq: inboxSeq, text: key, origin: "api", state: "queued")
        c.createdT = t
        return c
    }

    @MainActor
    func testLocalEchoKeepsItsSendTimeAnchorAndUnknownTimesFallBack() {
        var echo = MacSession.Sent(id: UUID(), text: "m", at: Date(timeIntervalSince1970: 0.1), afterSeq: 2, targetId: nil, eventKey: nil, error: nil)
        echo.anchorT = 100
        let h = [timed(1, t: 100), timed(3, t: 300), timed(4, t: 900)]
        let rows = ThreadRow.merge(history: h, commands: [], sent: [echo])
        XCTAssertEqual(rows.map(\.id), ["r1", "m\(echo.id.uuidString)", "r3", "r4"], "之后的回执不把回显挪到末尾")
        let legacy = cmdAt("old", 1, t: nil)
        let zero = cmdAt("zero", 2, t: 0)
        for cmds in [[legacy], [zero], [cmdAt("new", 3, t: 300), legacy]] {
            XCTAssertEqual(ThreadRow.merge(history: [timed(1, t: 100), timed(3, t: 400)], commands: cmds, sent: []).map(\.id),
                           ThreadRow.mergeAnchored(history: [timed(1, t: 100), timed(3, t: 400)], commands: cmds, sent: []).map(\.id),
                           "0 或缺失的时间是未知，整段回退原排序")
        }
    }

    // O1-365：会话记录已有的本机发送不再重复显示。
    @MainActor
    func testRecordedSendIsHiddenFromPendingEchoes() {
        let a = MacSession.Sent(id: UUID(), text: "a", at: Date(), afterSeq: 0, targetId: "t1", eventKey: "api:mine:1")
        let b = MacSession.Sent(id: UUID(), text: "b", at: Date(), afterSeq: 0, targetId: "t1", eventKey: "api:mine:2")
        let c = MacSession.Sent(id: UUID(), text: "c", at: Date(), afterSeq: 0, targetId: "t1", eventKey: nil)
        let left = ThreadRow.withoutRecorded([a, b, c], recorded: ["api:mine:1"])
        XCTAssertEqual(left.map(\.id), [b.id, c.id])
    }

    // #89 S3：回执只在实际渲染出卡的指令行覆盖时隐藏（与 iOS rendersCard 同一规则）；无扩展组的旧 Bridge 指令不覆盖。
    @MainActor
    func testReceiptHiddenOnlyWhenItsQueueCardRenders() throws {
        func command(_ key: String, _ inboxSeq: Int, _ queueJSON: String) throws -> ApiCommand {
            try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"\#(key)","inboxSeq":\#(inboxSeq),"text":"x","truncated":false,"origin":"api","state":"queued","lane":"ordinary","targetId":"t1","createdT":\#(inboxSeq)\#(queueJSON)}"#.utf8))
        }
        let carded = try command("k1", 1, #","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#)
        let legacy = try command("k2", 2, "")
        XCTAssertNotNil(QueueStatusPresentation.card(for: carded))
        XCTAssertNil(QueueStatusPresentation.card(for: legacy))
        let history = [
            HistoryItem(seq: 1, uuid: "dirty:target:t1:1", text: "[t1] 输入框有草稿", kind: "text", replyTo: "k1", t: 10),
            HistoryItem(seq: 2, uuid: "dirty:target:t1:2", text: "[t1] 输入框有草稿", kind: "text", replyTo: "k2", t: 20),
            HistoryItem(seq: 3, uuid: "busy:k1", text: "[t1] 目标忙", kind: "text", replyTo: nil, t: 30),
            HistoryItem(seq: 4, uuid: "task-reply:k1", text: "done", kind: "text", replyTo: "k1", t: 40),
        ]
        let rows = QueueCardCoverage.visible(ThreadRow.merge(history: history, commands: [carded, legacy], sent: []))
        XCTAssertEqual(rows.map(\.id), ["ck1", "ck2", "r2", "r4"], "dirty:k1 与 busy:k1 被卡覆盖；旧指令的回执与任务回执保留")
    }
}
