import Foundation
import Observation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #89 片 B（Mac 父级投影 / 状态值）：与 iOS QueueSemanticsParentTests 同一组场景，沿线上同一入口喂事实。
private final class ParentFlag: @unchecked Sendable { var value = false }
private final class ParentCounter: @unchecked Sendable { var n = 0 }

@MainActor final class QueueSemanticsParentMacTests: XCTestCase {
    private func session() throws -> MacSession {
        let s = MacSession()
        s.stopStream()
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"par-mac","name":"mac","paused":false,"permission":"control"}"#.utf8))
        return s
    }
    private func json(_ key: String, _ state: String, seq: Int = 1, target: String = "t1", extra: String = "") -> String {
        #"{"key":"\#(key)","inboxSeq":\#(seq),"text":"合成 \#(key)","truncated":false,"origin":"api","state":"\#(state)","lane":"ordinary","targetId":"\#(target)"\#(extra)}"#
    }
    private func event(_ name: String, _ data: String) -> BridgeEvent {
        var parser = SSEParser()
        return BridgeEventDecoder.decode(parser.feed(Data("event: \(name)\ndata: \(data)\n\n".utf8))[0])
    }
    private func inbound(_ s: MacSession, _ key: String, _ state: String = "queued", seq: Int = 1, target: String = "t1", extra: String = "") {
        s.applyStreamEventForTest(event("inbound", json(key, state, seq: seq, target: target, extra: extra)))
    }
    private func progress(_ s: MacSession, _ key: String, _ state: String, _ extra: String = "") {
        s.applyStreamEventForTest(event("progress", #"{"eventKey":"\#(key)","state":"\#(state)"\#(extra)}"#))
    }
    private func echo(_ key: String, epoch: String? = nil) -> MacSession.Sent {
        var m = MacSession.Sent(id: UUID(), text: "合成 \(key)", at: Date(), afterSeq: 0, targetId: "t1")
        m.eventKey = key; m.sessionEpoch = epoch
        return m
    }
    private func readable(linked: [String] = []) -> TranscriptThread {
        var t = TranscriptThread(); t.status = .ok; t.sessionEpoch = "e1"
        t.items = linked.map { TranscriptItem(id: "u\($0)", role: "user", text: "合成 \($0)", receipt: .init(commandKey: $0, origin: "api", receiptState: "accepted", eventKey: $0)) }
        return t
    }
    private let deadline = #","queueDeadlineT":1790000000000,"queueReason":"wait_turn","queuePosition":1,"observedAt":null,"phase":null"#
    private let awaiting = #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"awaiting""#

    func testTheTailShowsEachActualRowOnceAcrossRestartOtherDeviceAndPausedCases() throws {
        let s = try session()
        s.transcripts["t1"] = readable()
        inbound(s, "other", "queued", seq: 1)
        inbound(s, "dl", "queued", seq: 2, extra: deadline)
        inbound(s, "stop", "queued", seq: 3); progress(s, "stop", "paused", #","stopDisposition":"not_dispatched""#)
        inbound(s, "unc", "queued", seq: 4); progress(s, "unc", "started"); progress(s, "unc", "paused")
        inbound(s, "mine", "queued", seq: 5)
        s.sent = [echo("mine")]
        inbound(s, "same-text-a", "queued", seq: 6); inbound(s, "same-text-b", "queued", seq: 7)
        let tail = s.threadTail(threadId: "t1")
        XCTAssertEqual(tail.deadline.map(\.key), ["dl"])
        XCTAssertEqual(tail.supplement.map(\.key), ["other", "stop", "unc", "same-text-a", "same-text-b"], "回显 mine 与期限行 dl 不重复；相同正文不同 key 各一份")
        XCTAssertEqual(tail.echoes.map(\.eventKey), ["mine"])
        let all = tail.commandRows.map(\.key) + tail.echoes.compactMap(\.eventKey)
        XCTAssertEqual(all.count, Set(all).count, "任一 key 只出现一次")
    }

    func testLinkedKeysAreNotAppendedAndHistoryOrPinnedWindowsHaveNoTail() throws {
        let s = try session()
        inbound(s, "k1", "queued", seq: 1, extra: deadline); inbound(s, "k2", "queued", seq: 2)
        s.transcripts["t1"] = readable(linked: ["k1"])
        let tail = s.threadTail(threadId: "t1")
        XCTAssertTrue(tail.deadline.isEmpty, "有记录行承载同 key：不再追加期限行")
        XCTAssertEqual(tail.supplement.map(\.key), ["k2"])
        var loading = TranscriptThread(); loading.status = .loading
        s.transcripts["t1"] = loading
        XCTAssertTrue(s.threadTail(threadId: "t1").commandRows.isEmpty && s.threadTail(threadId: "t1").echoes.isEmpty, "无可读记录零补")
        var pinned = readable()
        _ = pinned.applyLocated(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: ["x1", "x2"].map { TranscriptItem(id: $0, role: "user", text: $0) }, nextBefore: "c", hasMore: true), itemId: "x1")
        s.transcripts["t1"] = pinned
        s.sent = [echo("k2")]
        XCTAssertNotNil(pinned.pinnedHit)
        XCTAssertTrue(s.threadTail(threadId: "t1").commandRows.isEmpty && s.threadTail(threadId: "t1").echoes.isEmpty, "定位窗不追加当前指令 / 期限 / 回显")
        XCTAssertTrue(s.commands["k1"] != nil && s.commands["k2"] != nil && s.sent.count == 1, "数据保留")
        s.transcripts["t1"] = readable()
        let back = s.threadTail(threadId: "t1")
        XCTAssertEqual(back.commandRows.map(\.key), ["k1"])
        XCTAssertEqual(back.echoes.compactMap(\.eventKey), ["k2"], "回到最新恢复：k1 期限行；k2 由本机回显承载")
    }

    func testForeignEpochEchoKeysAreExcludedFromTheTail() throws {
        let s = try session()
        s.transcripts["t1"] = readable()
        inbound(s, "f", "queued", seq: 1, extra: deadline); inbound(s, "g", "queued", seq: 2)
        s.sent = [echo("f", epoch: "other"), echo("g", epoch: "other")]
        let tail = s.threadTail(threadId: "t1")
        XCTAssertTrue(tail.commandRows.isEmpty && tail.echoes.isEmpty, "不同会话代次的 key：command 与普通回显都不冒称属于当前原生会话（B-F2）")
    }

    func testAPlainEchoFromAnOlderEpochIsFilteredButSameNoEpochAndFailuresStay() throws {
        let s = try session()
        s.transcripts["t1"] = readable()
        for (i, k) in ["F", "SAME", "NONE", "FAIL"].enumerated() { inbound(s, k, "queued", seq: i + 1) }
        var failed = echo("FAIL", epoch: "e-old"); failed.error = "网络失败"
        s.sent = [echo("F", epoch: "e-old"), echo("SAME", epoch: "e1"), echo("NONE"), failed]
        let tail = s.threadTail(threadId: "t1")
        XCTAssertEqual(Set(tail.echoes.compactMap(\.eventKey)), ["SAME", "NONE", "FAIL"], "F 被过滤；同 epoch、无 epoch、失败行保留")
        XCTAssertEqual(s.sent.count, 4, "数据保留")
    }

    func testTheFallbackDoesNotResurrectAnEvictedStopAndKeepsRealHistory() throws {
        let s = try session()
        var unavailable = TranscriptThread(); unavailable.status = .unavailable
        s.transcripts["t1"] = unavailable
        inbound(s, "P", "queued", seq: 1); progress(s, "P", "paused", #","stopDisposition":"not_dispatched""#)
        for i in 0..<201 { inbound(s, "N\(i)", "queued", seq: 10 + i) }
        XCTAssertFalse(s.commandWindow.contains("P"))
        XCTAssertNotNil(s.commands["P"], "前置：P 已出窗口，但仍在关联缓存里")
        s.history = [HistoryItem(seq: 1, uuid: "u1", text: "真实历史回执", kind: "text", replyTo: nil, target: TargetRef(id: "t1", projectName: "p", agentName: "a"))]
        var failed = echo("nocmd"); failed.error = "发送失败"
        s.sent = [failed, echo("P")]
        let rows = s.rows(for: "t1")
        let commandKeys = rows.compactMap { r -> String? in if case .command(let c) = r { return c.key } else { return nil } }
        XCTAssertFalse(commandKeys.contains("P"), "已淘汰的停止行不复活")
        XCTAssertTrue(commandKeys.contains("N200") && commandKeys.contains("N1"), "当前窗口成员仍可见")
        XCTAssertTrue(rows.contains { if case .receipt(let h) = $0 { h.text == "真实历史回执" } else { false } }, "真实历史不丢")
        XCTAssertTrue(rows.contains { if case .mine(let m) = $0 { m.eventKey == "nocmd" } else { false } }, "无权威命令的失败回显保留")
        XCTAssertFalse(rows.contains { if case .mine(let m) = $0 { m.eventKey == "P" } else { false } }, "被淘汰命令的回显不复活")
        XCTAssertNotNil(s.commands["P"])
    }

    func testCommandOnlyStatusCarriesDeliveryEvidenceRegardlessOfFirstRead() throws {
        let s = try session()
        inbound(s, "early", "started", extra: awaiting); inbound(s, "late", "started", extra: awaiting)
        XCTAssertEqual(s.messageStatus(for: s.commands["early"]!).phase, .awaiting, "前置：early 在 started 时被读取过")
        for k in ["early", "late"] { progress(s, k, "paused", #","stopDisposition":"not_dispatched""#) }
        for k in ["early", "late"] {
            let ms = s.messageStatus(for: s.commands[k]!)
            XCTAssertEqual(ms.phase, .stoppedUncertain, k)
            XCTAssertEqual(ms.label, "已停止跟踪，可能已执行")
            XCTAssertNil(ms.card)
        }
        inbound(s, "plain"); progress(s, "plain", "paused", #","stopDisposition":"not_dispatched""#)
        XCTAssertEqual(s.messageStatus(for: s.commands["plain"]!).phase, .stopped, "正控：无送达证据的全新 not_dispatched")
        inbound(s, "legacy"); progress(s, "legacy", "paused")
        XCTAssertEqual(s.messageStatus(for: s.commands["legacy"]!).label, "已停止跟踪，可能已执行", "旧 Bridge 缺键保守")
    }

    func testATrackerThatAlreadyDegradedRemovesTheStaleRawCard() throws {
        let s = try session()
        inbound(s, "k", "started", extra: awaiting)
        XCTAssertEqual(s.messageStatus(for: s.commands["k"]!).card?.title, "已送达 · 等待回合开始")
        inbound(s, "u", "started", extra: awaiting)
        progress(s, "u", "unknown")
        let ms = s.messageStatus(for: s.commands["u"]!)
        XCTAssertEqual(ms.phase, .unknown)
        XCTAssertNil(ms.card)
        XCTAssertEqual(ms.label, "结果未知")
    }

    func testReceiptStrongFactsAreNotOverriddenByAnOldTrackerTerminal() throws {
        let s = try session()
        inbound(s, "K", "queued"); progress(s, "K", "started"); progress(s, "K", "paused", #","stopDisposition":"not_dispatched""#)
        XCTAssertEqual(s.messageStatus(for: s.commands["K"]!).phase, .stoppedUncertain)
        inbound(s, "K", "finished", extra: #","reason":"merged""#)
        let r = TranscriptReceipt(commandKey: "x", origin: "api", receiptState: "done", reason: "merged", eventKey: "K")
        XCTAssertEqual(s.recordStatus(r)?.phase, .merged)
        XCTAssertNil(s.recordStatus(TranscriptReceipt(commandKey: "x", origin: "api", receiptState: "sent", eventKey: "nope")))
        XCTAssertNil(s.recordStatus(TranscriptReceipt(commandKey: "x", origin: "api", receiptState: "sent")))
    }

    func testAMismatchedExternalCommandNeverPollutesAnExactReceipt() throws {
        let s = try session()
        inbound(s, "A", "paused", seq: 1); inbound(s, "B", "queued", seq: 2)
        XCTAssertEqual(s.recordStatus(TranscriptReceipt(commandKey: "x", origin: "api", receiptState: "accepted", eventKey: "B"))?.phase, .queued)
    }

    private func fires(_ read: @escaping @MainActor () -> Void, during op: () -> Void) async -> Bool {
        let f = ParentFlag()
        withObservationTracking { read() } onChange: { f.value = true }
        op()
        await Task.yield()
        return f.value
    }

    func testTheTailPublishesOnRealChangesOnly() async throws {
        let s = try session()
        s.transcripts["t1"] = readable()
        inbound(s, "k", "started", extra: awaiting)
        let quiet = await fires({ _ = s.threadTail(threadId: "t1") }) {
            s.state = try? JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[{"id":"t1","projectName":"p","agentName":"a","status":"working"}],"history":{"highWater":0,"items":[]}}"#.utf8))
            _ = s.outgoingStatus(self.echo("k"))
            _ = s.messageStatus(for: s.commands["k"]!)
        }
        XCTAssertFalse(quiet, "无关 targets 活动与视图读取不使尾部发布")
        let positive = await fires({ _ = s.threadTail(threadId: "t1") }) { self.progress(s, "k", "paused", #","stopDisposition":"execution_uncertain""#) }
        XCTAssertTrue(positive, "同 K 真实 phase / stop 变化：正控触发")
        XCTAssertEqual(s.messageStatus(for: s.commands["k"]!).phase, .stoppedUncertain)
    }

    func testReadingStatusDoesNotWriteObservableState() async throws {
        let s = try session()
        inbound(s, "k", "started", extra: awaiting)
        let wrote = await fires({ _ = s.commands; _ = s.commandWindow; _ = s.sent }) {
            for _ in 0..<5 { _ = s.messageStatus(for: s.commands["k"]!); _ = s.recordStatus(.init(commandKey: "x", origin: "api", receiptState: "sent", eventKey: "k")) }
        }
        XCTAssertFalse(wrote)
    }

    func testLedgerScopeChangesInvalidateAnOldPageBeforeAnyRequest() async throws {
        let s = try session()
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","bridge":{"id":"B1"},"targets":[{"id":"t1","projectName":"p","agentName":"a"}],"history":{"highWater":0,"items":[]}}"#.utf8))
        let scope = try XCTUnwrap(s.ledgerScope("t1"))
        let calls = ParentCounter()
        s.archiveClientOverride = { calls.n += 1; return nil }
        await s.loadArchivedHistory("t1", older: false, scope: scope)
        XCTAssertEqual(calls.n, 1, "scope 有效：走到取客户端（正控）")
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","bridge":{"id":"B2"},"targets":[],"history":{"highWater":0,"items":[]}}"#.utf8))
        await s.loadArchivedHistory("t1", older: false, scope: scope)
        XCTAssertEqual(calls.n, 1, "Bridge 变化：旧页面零请求")
    }
}
