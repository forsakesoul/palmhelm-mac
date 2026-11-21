import AppKit
import Foundation
import PalmhelmKit
import XCTest
@testable import PalmhelmMac

// #57：发送失败后清空输入框（已入账），失败气泡可重试；输入框上限 14 行。
@MainActor
final class ComposerResendTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Bool
        init(_ v: Bool) { self.v = v }
        var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    private func session(fail: Box? = nil) -> MacSession {
        let s = bindingSession(binding: "A") // 绑定到 A：普通发送与重试都投到 A
        s.device = try? JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d","name":"mac","paused":false}"#.utf8))
        s.sendOverride = { _, id in
            if let fail, fail.value { throw URLError(.timedOut) }
            return MessageReceipt.stub("ek-\(id.uuidString.prefix(6))")
        }
        s.stateOverride = { [unowned s] in await MainActor.run { s.state ?? BridgeState.empty } }
        s.selectTarget("A")
        return s
    }

    private func failedRecord(text: String = "原文", draft: String = "原文", paths: [String] = [], agent: String? = nil) -> MacSession.Sent {
        var m = MacSession.Sent(id: UUID(), text: text, at: Date(), afterSeq: 0, targetId: "A", error: "发送失败", draft: draft, attachmentPaths: paths)
        m.agent = agent
        return m
    }

    // MARK: settle（纯逻辑）

    func testSettleClearsSnapshotWhenRecordedEvenIfFailed() {
        var draft = "在发的话"
        var atts: [ComposerAttachment] = []
        ComposerRules.settle(recorded: true, draftSnap: "在发的话", attachSnap: [], draft: &draft, attachments: &atts)
        XCTAssertEqual(draft, "", "已入账（失败也有记录）：与成功一致清掉本次草稿")
    }

    func testSettleKeepsDraftWhenNothingRecorded() {
        var draft = "在发的话"
        var atts: [ComposerAttachment] = []
        ComposerRules.settle(recorded: false, draftSnap: "在发的话", attachSnap: [], draft: &draft, attachments: &atts)
        XCTAssertEqual(draft, "在发的话", "守卫拦下、没有记录：草稿原样保留")
    }

    func testSettleDoesNotEraseTextTypedAfterSnapshot() {
        var draft = "发送期间新输入"
        var atts: [ComposerAttachment] = []
        ComposerRules.settle(recorded: true, draftSnap: "旧快照", attachSnap: [], draft: &draft, attachments: &atts)
        XCTAssertEqual(draft, "发送期间新输入", "草稿已不同于快照：不清掉用户新写的内容")
    }

    func testInputMaxLinesIsFourteen() {
        XCTAssertEqual(ComposerRules.inputMaxLines, 14)
    }

    // MARK: 提交后的输入框

    func testFailedSubmitClearsDraftAndKeepsFailedRecord() async {
        let fail = Box(true)
        let s = session(fail: fail)
        var d = MacSession.ComposerDraft(); d.text = "你好"
        s.setDraft(d, for: "A")
        let ok = await s.submitComposer(threadId: "A", agent: nil)
        XCTAssertFalse(ok)
        XCTAssertEqual(s.draft("A").text, "", "失败已入账：输入框清空，重试走气泡")
        XCTAssertEqual(s.sent.count, 1)
        XCTAssertNotNil(s.sent.first?.error)
        XCTAssertEqual(s.sent.first?.draft, "你好", "失败记录保留原草稿，供重试")
    }

    func testGuardBlockedSubmitKeepsDraftWithoutRecord() async {
        let s = session()
        s.sendOverride = nil // 没有传输：守卫拦下，不产生记录
        var d = MacSession.ComposerDraft(); d.text = "别丢"
        s.setDraft(d, for: "A")
        let ok = await s.submitComposer(threadId: "A", agent: nil)
        XCTAssertFalse(ok)
        XCTAssertEqual(s.draft("A").text, "别丢")
        XCTAssertTrue(s.sent.isEmpty)
    }

    // MARK: 重试

    func testResendWithMissingAttachmentDoesNotSendAndKeepsRecord() async {
        let s = session()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("o420-missing-\(UUID().uuidString).png").path
        let m = failedRecord(paths: [missing])
        s.sent = [m]
        let ok = await s.resendFailed(m, threadId: "A")
        XCTAssertFalse(ok)
        XCTAssertEqual(s.sent.map(\.id), [m.id], "附件缺失：不发送，失败记录保留")
        XCTAssertNotNil(s.composerNotes[s.draftKey("A")], "说明缺哪个附件")
    }

    func testResendSuccessRemovesOldFailedRecordAndCreatesNewOne() async {
        let s = session()
        let m = failedRecord(text: "再发一次", draft: "再发一次")
        s.sent = [m]
        let ok = await s.resendFailed(m, threadId: "A")
        XCTAssertTrue(ok)
        XCTAssertFalse(s.sent.contains { $0.id == m.id }, "成功后移除旧失败记录")
        XCTAssertEqual(s.sent.count, 1)
        XCTAssertEqual(s.sent.first?.text, "再发一次")
        XCTAssertNil(s.sent.first?.error, "新记录按成功推进")
    }

    func testResendDirectKeepsAgentFromOriginalRecord() async throws {
        let s = session()
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","binding":{"targetId":"A","projectName":"P","agentName":"claude"},"targets":[{"id":"A","projectName":"P","agentName":"codex","online":true,"capabilities":{"steer":true,"queueDeadline":true}}],"history":{"highWater":0,"items":[]}}"#.utf8))
        let m = failedRecord(text: "直达的话", draft: "直达的话", agent: "codex")
        s.sent = [m]
        let ok = await s.resendFailed(m, threadId: "A")
        XCTAssertTrue(ok)
        XCTAssertEqual(s.sent.first?.agent, "codex", "直达与否沿用原记录")
    }

    /// 目标改名后重试：原记录的 agent 与目标不一致，零请求，失败记录保留（R4）。
    func testResendDirectRefusesWhenTargetAgentChanged() async {
        let s = session()
        let m = failedRecord(text: "直达的话", draft: "直达的话", agent: "codex")
        s.sent = [m]
        let ok = await s.resendFailed(m, threadId: "A")
        XCTAssertFalse(ok)
        XCTAssertEqual(s.sent.map(\.id), [m.id], "失败记录保留")
        XCTAssertEqual(s.composerNotes[s.draftKey("A")]?.text, SendTimingCopy.directTargetChanged)
    }

    func testResendFailingAgainLeavesOnlyOneFailedRecord() async {
        let fail = Box(true)
        let s = session(fail: fail)
        let m = failedRecord(text: "一直失败", draft: "一直失败")
        s.sent = [m]
        let ok = await s.resendFailed(m, threadId: "A")
        XCTAssertFalse(ok)
        XCTAssertEqual(s.sent.count, 1, "新记录入账即移除旧记录：同一条内容只剩一条气泡")
        XCTAssertNotEqual(s.sent.first?.id, m.id)
        XCTAssertNotNil(s.sent.first?.error, "剩下的是这次的失败记录")
    }

    func testResendKeepsOriginalModeAndQueueTTL() async {
        let fail = Box(true)
        let s = session(fail: fail)
        // 目标带排队期限与立即插入能力，并被绑定：普通发送才会带 mode 与 TTL
        s.state = try? JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","binding":{"targetId":"A","projectName":"P","agentName":"claude"},"targets":[{"id":"A","projectName":"P","agentName":"claude","online":true,"capabilities":{"steer":true,"queueDeadline":true}}],"history":{"highWater":0,"items":[]}}"#.utf8))
        var d = MacSession.ComposerDraft(); d.text = "排队的话"
        s.setDraft(d, for: "A")
        let first = await s.submitComposer(threadId: "A", agent: nil, mode: .queue, queueTTLSeconds: 3600)
        XCTAssertFalse(first)
        let failed = s.sent.last!
        XCTAssertEqual(failed.mode, .queue, "入账时记录原模式")
        XCTAssertEqual(failed.queueTTLSeconds, 3600, "入账时记录原排队期限")
        fail.value = false
        let ok = await s.resendFailed(failed, threadId: "A")
        XCTAssertTrue(ok)
        XCTAssertEqual(s.lastSendMode, .queue, "重试沿用原模式")
        XCTAssertEqual(s.lastQueueTTLSeconds, 3600, "重试沿用原排队期限")
        XCTAssertEqual(s.sent.count, 1)
    }

    // MARK: A1-219 反例（R1 传输期间只有一条气泡；R2 绑定变化后不改投）

    private actor Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func started() -> Bool { entered }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func bindingSession(binding: String = "A") -> MacSession {
        let s = MacSession()
        s.state = try! JSONDecoder().decode(BridgeState.self, from: Data("{\"occupancy\":\"free\",\"binding\":{\"targetId\":\"\(binding)\",\"projectName\":\"P\",\"agentName\":\"claude\"},\"targets\":[{\"id\":\"A\",\"projectName\":\"A\",\"online\":true},{\"id\":\"B\",\"projectName\":\"B\",\"online\":true}],\"history\":{\"highWater\":0,\"items\":[]}}".utf8))
        s.link = .connected
        return s
    }

    private func failedOnA() -> MacSession.Sent {
        MacSession.Sent(id: UUID(), text: "原文", at: Date(), afterSeq: 0, targetId: "A", error: "失败", draft: "原文")
    }

    func testRetryHasOneVisibleRowDuringTransport() async throws {
        XCTAssertTrue(RuntimeEnvironment.isTestHost)
        let s = bindingSession(); let m = failedOnA(); s.sent = [m]
        let gate = Gate()
        s.sendOverride = { _, _ in await gate.wait(); return MessageReceipt.stub("new") }
        let task = Task { await s.resendFailed(m, threadId: "A") }
        for _ in 0..<100 { if await gate.started() { break }; try await Task.sleep(for: .milliseconds(5)) }
        let rows = ThreadRow.merge(history: [], commands: [], sent: s.sent)
        XCTAssertEqual(rows.count, 1, "旧失败行和新发送行不应同时出现")
        await gate.release(); _ = await task.value
        XCTAssertEqual(s.sent.count, 1)
    }

    func testRetryDoesNotMoveOriginalAToCurrentBindingB() async {
        let s = bindingSession(binding: "B"); let m = failedOnA(); s.sent = [m]
        s.sendOverride = { _, _ in MessageReceipt.stub("new") }
        let ok = await s.resendFailed(m, threadId: "A")
        XCTAssertFalse(ok, "绑定已变：不发送")
        XCTAssertEqual(s.sent.map(\.id), [m.id], "原失败记录保留")
        XCTAssertEqual(s.sent.last?.targetId, "A", "重试A不能按当前绑定发往B")
        XCTAssertNotNil(s.composerNotes[s.draftKey("A")], "说明原目标与绑定变化")
    }
}
