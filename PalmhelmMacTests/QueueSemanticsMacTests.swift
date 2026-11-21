import Foundation
import Observation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #89 语义片 A（Mac 会话层）：与 iOS QueueSemanticsSessionTests 同一组场景，沿线上同一入口（SSE 帧解码 → 分发、挂起的 HTTP 快照）。
private final class FiredFlag: @unchecked Sendable { var value = false }
private final class MacGate: @unchecked Sendable { var resume: CheckedContinuation<Void, Never>? }

private func semState(_ commands: [String]?, working: Bool = false) throws -> BridgeState {
    let list = commands.map { #","commands":[\#($0.joined(separator: ","))]"# } ?? ""
    let status = working ? #","status":"working""# : ""
    return try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[{"id":"t1","projectName":"p","agentName":"a"\#(status)}],"history":{"highWater":0,"items":[]}\#(list)}"#.utf8))
}

@MainActor final class QueueSemanticsMacTests: XCTestCase {
    private func session(permission: String = "control") throws -> MacSession {
        let s = MacSession()
        s.stopStream()
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"sem-mac","name":"mac","paused":false,"permission":"\#(permission)"}"#.utf8))
        return s
    }
    private func json(_ key: String, _ state: String, seq: Int = 1, target: String = "t1", extra: String = "") -> String {
        #"{"key":"\#(key)","inboxSeq":\#(seq),"text":"合成","truncated":false,"origin":"api","state":"\#(state)","lane":"ordinary","targetId":"\#(target)"\#(extra)}"#
    }
    private func event(_ name: String, _ data: String) -> BridgeEvent { {
        var parser = SSEParser()
        let frames = parser.feed(Data("event: \(name)\ndata: \(data)\n\n".utf8))
        return BridgeEventDecoder.decode(frames[0])
    }() }
    private func inbound(_ s: MacSession, _ key: String, _ state: String = "queued", seq: Int = 1, target: String = "t1", extra: String = "") {
        s.applyStreamEventForTest(event("inbound", json(key, state, seq: seq, target: target, extra: extra)))
    }
    private func progress(_ s: MacSession, _ key: String, _ state: String, _ extra: String = "") {
        s.applyStreamEventForTest(event("progress", #"{"eventKey":"\#(key)","state":"\#(state)"\#(extra)}"#))
    }
    private func echo(_ key: String, target: String = "t1", epoch: String? = nil) -> MacSession.Sent {
        var m = MacSession.Sent(id: UUID(), text: "合成", at: Date(), afterSeq: 0, targetId: target)
        m.eventKey = key; m.sessionEpoch = epoch
        return m
    }

    func testStopDispositionFlowsFromSseFramesToTheSharedStatus() throws {
        let s = try session()
        inbound(s, "k1"); progress(s, "k1", "paused", #","stopDisposition":"not_dispatched""#)
        XCTAssertEqual(s.outgoingStatus(echo("k1")).phase, .stopped)
        XCTAssertEqual(s.outgoingStatus(echo("k1")).label, "已停止，未发出")
        inbound(s, "k2"); progress(s, "k2", "started"); progress(s, "k2", "paused")
        XCTAssertEqual(s.outgoingStatus(echo("k2")).phase, .stoppedUncertain, "缺键保守")
        inbound(s, "k3"); progress(s, "k3", "paused", #","stopDisposition":"not_dispatched""#); progress(s, "k3", "paused", #","stopDisposition":null"#)
        XCTAssertEqual(s.commands["k3"]?.stopDisposition, .uncertain)
        progress(s, "k3", "paused")
        XCTAssertEqual(s.commands["k3"]?.stopDisposition, .uncertain, "之后的缺键帧不恢复")
        progress(s, "early", "paused", #","stopDisposition":"not_dispatched""#)
        inbound(s, "early")
        XCTAssertEqual(s.commands["early"]?.stopDisposition, .notDispatched)
        XCTAssertEqual(s.commands["early"]?.state, "paused")
        inbound(s, "legacy"); progress(s, "legacy", "paused")
        let legacy = s.outgoingStatus(echo("legacy")).label
        XCTAssertFalse(legacy.contains("被拒绝") || legacy.contains("未发出"))
        inbound(s, "np"); progress(s, "np", "finished", #","stopDisposition":"not_dispatched""#)
        XCTAssertNil(s.commands["np"]?.stopDisposition)
    }

    func testBusyOrIdleTargetGivesTheSamePhaseText() throws {
        var labels: [String: [String]] = [:]
        for working in [false, true] {
            let s = try session()
            s.state = try semState(nil, working: working)
            XCTAssertEqual(s.targetWorking("t1"), working)
            for (key, phase) in [("d", "dispatch"), ("a", "awaiting"), ("r", "running")] {
                inbound(s, key, "started", extra: #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"\#(phase)""#)
                labels[phase, default: []].append(s.outgoingStatus(echo(key)).label)
            }
            inbound(s, "legacy", "started")
            labels["legacy", default: []].append(s.outgoingStatus(echo("legacy")).label)
        }
        XCTAssertEqual(labels["dispatch"], ["正在发送", "正在发送"])
        XCTAssertEqual(labels["awaiting"], ["已送达 · 等待回合开始", "已送达 · 等待回合开始"])
        XCTAssertEqual(labels["running"], ["已送达 · 回合进行中", "已送达 · 回合进行中"])
        XCTAssertEqual(labels["legacy"], ["已送达", "已送达"], "缺 phase：不据目标忙推断处理中")
    }

    func testDispatchAfterQueuedIsNotHeldBackByTheTracker() throws {
        let s = try session()
        let g = #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"#
        inbound(s, "k", "queued", extra: #","queueReason":null,"queuePosition":1,"observedAt":null,"phase":null"#)
        XCTAssertEqual(s.outgoingStatus(echo("k")).phase, .queued)
        progress(s, "k", "started", g + #""dispatch""#)
        XCTAssertEqual(s.outgoingStatus(echo("k")).phase, .dispatching)
        progress(s, "k", "started", g + #""awaiting""#)
        progress(s, "k", "started", g + #""running""#)
        XCTAssertEqual(s.outgoingStatus(echo("k")).phase, .processing)
        XCTAssertEqual(s.outgoingStatus(echo("k")).phase, .processing, "重复读取一致")
    }

    func testSuspendedHttpNeverOverwritesANewerSseStop() async throws {
        let s = try session()
        let gate = MacGate()
        let snapshot = json("k", "paused", extra: #","stopDisposition":"not_dispatched""#)
        s.stateOverride = { @Sendable in await withCheckedContinuation { gate.resume = $0 }; return try semState([snapshot]) }
        inbound(s, "k")
        let pull = Task { try await s.pullState() }
        while gate.resume == nil { await Task.yield() }
        progress(s, "k", "paused", #","stopDisposition":"execution_uncertain""#)
        gate.resume?.resume()
        try await pull.value
        XCTAssertEqual(s.commands["k"]?.stopDisposition, .uncertain, "HTTP 晚到的显式值不盖新 SSE")
        XCTAssertTrue(s.commandWindow.contains("k"))
    }

    func testCommandsKeyAbsentKeepsTheWindowAndEmptyListDropsNonPaused() async throws {
        let s = try session()
        inbound(s, "q", "queued", seq: 1); inbound(s, "p", "queued", seq: 2); progress(s, "p", "paused", #","stopDisposition":"execution_uncertain""#)
        s.stateOverride = { @Sendable in try semState(nil) }
        try await s.pullState()
        XCTAssertTrue(s.commandWindow.contains("q"), "缺键 ≠ 空列表")
        s.stateOverride = { @Sendable in try semState([]) }
        try await s.pullState()
        XCTAssertFalse(s.commandWindow.contains("q"))
        XCTAssertTrue(s.commandWindow.contains("p"))
        XCTAssertNotNil(s.commands["q"]); XCTAssertNotNil(s.commands["p"], "commands 字典不因窗口清理")
    }

    func testWindowBoundaryEvictionAndUnchangedReplayDoNotResurrect() throws {
        let s = try session()
        inbound(s, "p0", "queued", seq: 0); progress(s, "p0", "paused", #","stopDisposition":"execution_uncertain""#)
        for i in 1...CommandWindow.capacity { inbound(s, "q\(i)", seq: i) }
        XCTAssertEqual(s.commandWindow.count, CommandWindow.capacity)
        XCTAssertTrue(s.commandWindow.truncated)
        XCTAssertFalse(s.commandWindow.contains("p0"))
        XCTAssertTrue(s.commandWindow.contains("q1"))
        inbound(s, "p0", "paused", seq: 0, extra: #","stopDisposition":"execution_uncertain""#)
        XCTAssertFalse(s.commandWindow.contains("p0"))
        XCTAssertEqual(s.commands["p0"]?.state, "paused")
        progress(s, "p0", "queued")
        XCTAssertFalse(s.commandWindow.contains("p0"))
        inbound(s, "fresh", seq: 999)
        XCTAssertTrue(s.commandWindow.contains("fresh"))
        XCTAssertEqual(s.commandWindow.count, CommandWindow.capacity)
    }

    private func readableThread(epoch: String = "e1") -> TranscriptThread {
        var t = TranscriptThread(); t.status = .ok; t.sessionEpoch = epoch
        return t
    }

    func testSupplementShowsServerOnlyMessagesAndDedupsAgainstEchoesAndRecord() throws {
        let s = try session()
        s.transcripts["t1"] = readableThread()
        inbound(s, "other", "queued", seq: 1)
        inbound(s, "mine", "queued", seq: 2)
        inbound(s, "stop", "queued", seq: 3); progress(s, "stop", "paused", #","stopDisposition":"not_dispatched""#)
        inbound(s, "run", "started", seq: 4)
        inbound(s, "done", "finished", seq: 5)
        s.sent = [echo("mine"), echo("stop")]
        let keys = s.supplementCommands(threadId: "t1").map(\.key)
        XCTAssertEqual(keys, ["other", "stop", "run"])
        XCTAssertFalse(keys.contains("mine") || keys.contains("done"))
        var t = readableThread()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: [TranscriptItem(id: "u1", role: "user", text: "合成", receipt: .init(commandKey: "x", origin: "api", receiptState: "sent", eventKey: "other"))], nextBefore: nil, hasMore: false))
        s.transcripts["t1"] = t
        XCTAssertFalse(s.supplementCommands(threadId: "t1").map(\.key).contains("other"))
        inbound(s, "same-text-other-key", "queued", seq: 6)
        XCTAssertTrue(s.supplementCommands(threadId: "t1").map(\.key).contains("same-text-other-key"))
    }

    func testSupplementIsEmptyOutsideTheLatestReadingWindowAndForForeignEpoch() throws {
        let s = try session()
        inbound(s, "k", "queued", seq: 1)
        XCTAssertTrue(s.supplementCommands(threadId: "t1").isEmpty)
        var loading = TranscriptThread(); loading.status = .loading
        s.transcripts["t1"] = loading
        XCTAssertTrue(s.supplementCommands(threadId: "t1").isEmpty)
        var located = readableThread()
        _ = located.applyLocated(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: ["x1", "x2"].map { TranscriptItem(id: $0, role: "user", text: $0) }, nextBefore: "c", hasMore: true), itemId: "x1")
        s.transcripts["t1"] = located
        XCTAssertNotNil(located.pinnedHit)
        XCTAssertTrue(s.supplementCommands(threadId: "t1").isEmpty, "定位窗零强插")
        s.transcripts["t1"] = readableThread()
        XCTAssertEqual(s.supplementCommands(threadId: "t1").map(\.key), ["k"])
        s.sent = [echo("k", epoch: "other-epoch")]
        XCTAssertFalse(s.supplementCommands(threadId: "t1").map(\.key).contains("k"))
        inbound(s, "k2", "queued", seq: 2, target: "t2")
        XCTAssertFalse(s.supplementCommands(threadId: "t1").map(\.key).contains("k2"))
    }

    func testScopeResetClearsStopCachePendingFramesWindowAndTracker() throws {
        let s = try session()
        inbound(s, "k", "queued"); progress(s, "k", "paused", #","stopDisposition":"not_dispatched""#)
        XCTAssertEqual(s.outgoingStatus(echo("k")).phase, .stopped)
        progress(s, "pending-only", "paused", #","stopDisposition":"not_dispatched""#)
        s.forget()
        XCTAssertTrue(s.commands.isEmpty); XCTAssertEqual(s.commandWindow.count, 0)
        inbound(s, "pending-only")
        XCTAssertEqual(s.commands["pending-only"]?.state, "queued")
        XCTAssertNil(s.commands["pending-only"]?.stopDisposition, "换 scope 后旧待物化帧不复活")
        inbound(s, "k"); progress(s, "k", "paused")
        XCTAssertEqual(s.outgoingStatus(echo("k")).phase, .stoppedUncertain, "tracker 随 scope 清空")
    }

    func testVisibleStopFactsGrantNoWritePower() async throws {
        let s = try session(permission: "readonly")
        inbound(s, "k", "queued"); progress(s, "k", "paused", #","stopDisposition":"not_dispatched""#)
        let c = try XCTUnwrap(s.commands["k"])
        XCTAssertTrue(SendTimingRules.queuedActions(state: c.state, reason: c.reason, steer: .available).isEmpty, "暂停行没有任何排队操作")
        s.commandOverride = { _, _ in XCTFail("只读设备不得发请求") }
        inbound(s, "q2", "queued", seq: 2)
        let q = try XCTUnwrap(s.commands["q2"])
        await s.withdrawQueued(q)
        await s.promoteQueued(q)
        XCTAssertTrue(s.commandRequests.isEmpty, "只读 / 他设备：零请求")
    }

    func testWithdrawStaysAvailableWhileDoNotDisturbOrDevicePausedButPromoteDoesNot() async throws {
        let s = try session()
        s.device?.paused = true
        s.commandOverride = { _, _ in }
        inbound(s, "q", "queued", extra: #","queueReason":"paused","queuePosition":1,"observedAt":null,"phase":null"#)
        let c = try XCTUnwrap(s.commands["q"])
        await s.promoteQueued(c)
        XCTAssertTrue(s.commandRequests.isEmpty, "promote 沿自己的发送守卫")
        await s.withdrawQueued(c)
        XCTAssertEqual(s.commandRequests, [.withdraw], "撤回不被新增字段变成发送守卫")
    }

    private func fires(_ read: @escaping @MainActor () -> Void, during op: () -> Void) async -> Bool {
        let flag = FiredFlag()
        withObservationTracking { read() } onChange: { flag.value = true }
        op()
        await Task.yield()
        return flag.value
    }

    func testWindowPublishesOnlyOnRealMembershipChange() async throws {
        let s = try session()
        let g = #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"#
        inbound(s, "k", "started", seq: 1, extra: g + #""dispatch""#)
        let quiet = await fires({ _ = s.commandWindow }) {
            self.progress(s, "k", "started", g + #""awaiting""#)
            self.inbound(s, "k", "started", seq: 1, extra: g + #""awaiting""#)
            s.state = try? semState(nil, working: true)
        }
        XCTAssertFalse(quiet, "同 K 阶段推进 / 重复帧 / 无关 targets 不使窗口重新发布")
        let positive = await fires({ _ = s.commandWindow }) { self.progress(s, "k", "paused", #","stopDisposition":"execution_uncertain""#) }
        XCTAssertTrue(positive, "同 K 变为暂停：正控触发")
        let commandsObserved = await fires({ _ = s.commands["k2"] }) { self.inbound(s, "k2", "queued", seq: 2) }
        XCTAssertTrue(commandsObserved)
    }

    // MARK: 复审补修（A1-004）：A-F1 送达证据 / A-F2 同活动 inbound / A-F3 容量一致

    func testDeliveryEvidenceDoesNotDependOnWhenTheViewFirstReads() async throws {
        let s = try session()
        let awaiting = #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"awaiting""#
        for k in ["early", "late"] { inbound(s, k, "started", extra: awaiting) }
        XCTAssertTrue(s.outgoingStatus(echo("early")).phase == .awaiting, "前置：early 在 started 时被读取过")
        for k in ["early", "late"] { progress(s, k, "paused", #","stopDisposition":"not_dispatched""#) }
        for k in ["early", "late"] {
            XCTAssertTrue(s.outgoingStatus(echo(k)).phase == .stoppedUncertain, "\(k)：见过送达证据后暂停，不论何时首次读取都保守")
            XCTAssertTrue(s.outgoingStatus(echo(k)).label == "已停止跟踪，可能已执行", "文案保守")
        }
        inbound(s, "plain"); progress(s, "plain", "paused", #","stopDisposition":"not_dispatched""#)
        XCTAssertTrue(s.outgoingStatus(echo("plain")).phase == .stopped, "正控：只见过 queued 的无冲突首次 not_dispatched 仍是未发出")
        // HTTP 快照采纳的 started 同样记证据；之后 SSE 暂停，首次读取在暂停之后。
        let snapJson = json("h", "started", extra: awaiting)
        s.stateOverride = { @Sendable in try semState([snapJson]) }
        try await s.pullState()
        progress(s, "h", "paused", #","stopDisposition":"not_dispatched""#)
        XCTAssertTrue(s.outgoingStatus(echo("h")).phase == .stoppedUncertain, "HTTP 采纳的送达证据同样保守")
    }

    func testSameActiveInboundReentersTheWindowAfterAnEmptyHttpList() async throws {
        let s = try session()
        inbound(s, "k", "started"); inbound(s, "done", "finished")
        XCTAssertTrue(s.commandWindow.contains("k"), "前置")
        s.stateOverride = { @Sendable in try semState([]) }
        try await s.pullState()
        XCTAssertTrue(!s.commandWindow.contains("k"), "空列表移除非暂停成员")
        inbound(s, "k", "started") // 完全相同的活动内容
        XCTAssertTrue(s.commandWindow.contains("k"), "同内容活动 inbound 重新准入")
        inbound(s, "done", "finished")
        XCTAssertTrue(!s.commandWindow.contains("done"), "已淘汰的未变终态不复活")
        let again = s.commandWindow
        inbound(s, "k", "started")
        XCTAssertTrue(s.commandWindow == again, "已在窗的同内容活动不重复发布")
    }

    func testSameActiveInboundDuringASuspendedHttpSurvivesALateEmptyList() async throws {
        let s = try session()
        let gate = MacGate()
        s.stateOverride = { @Sendable in await withCheckedContinuation { gate.resume = $0 }; return try semState([]) }
        inbound(s, "kept", "started"); inbound(s, "dropped", "started")
        let pull = Task { try await s.pullState() }
        while gate.resume == nil { await Task.yield() }
        inbound(s, "kept", "started") // 请求期间同内容再次到来：这是比快照更新的存在事实
        gate.resume?.resume()
        try await pull.value
        XCTAssertTrue(s.commandWindow.contains("kept"), "晚到的空列表不得丢掉请求期间重新确认的活动")
        XCTAssertTrue(!s.commandWindow.contains("dropped"), "负控：请求期间没有新事实的成员照常被空列表移除")
    }

    func testWindowCapacityRuleIsTheSameForSseAndHttpAndOldStopsDoNotOutliveNewerActivity() async throws {
        let s = try session()
        let cap = CommandWindow.capacity
        for i in 0..<cap { inbound(s, "k\(1000 + i)", seq: 1000 + i) }
        inbound(s, "ancient", "paused", seq: 1, extra: #","stopDisposition":"not_dispatched""#)
        XCTAssertTrue(!s.commandWindow.contains("ancient") && s.commandWindow.contains("k1000") && s.commandWindow.count == cap, "SSE：比所有活动都旧的停止不被强留，更新的活动保留")
        XCTAssertTrue(s.commandWindow.truncated && s.commands["ancient"] != nil, "truncated 按真实值发布；commands 缓存仍在")
        let viaSse = s.commandWindow
        // 同一事实集合经 HTTP 重建：结果一致。
        var listed = (0..<cap).map { json("k\(1000 + $0)", "queued", seq: 1000 + $0) }
        listed.append(json("ancient", "paused", seq: 1, extra: #","stopDisposition":"not_dispatched""#))
        let listedJson = listed
        s.stateOverride = { @Sendable in try semState(listedJson) }
        try await s.pullState()
        XCTAssertTrue(s.commandWindow == viaSse, "HTTP 重建与 SSE 准入同一容量规则")
        inbound(s, "fresh", seq: 5000)
        XCTAssertTrue(s.commandWindow.contains("fresh") && !s.commandWindow.contains("k1000") && s.commandWindow.count == cap, "新 seq 活动正控：挤掉最旧成员")
    }

    // MARK: 复审补修 v3（A1-006）：待物化 progress 的送达证据 / paused 终态重放不复活

    func testProgressBeforeInboundKeepsDeliveryEvidenceThroughMaterialization() async throws {
        let s = try session()
        let awaiting = #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"awaiting""#
        progress(s, "k", "started", awaiting); progress(s, "k", "paused", #","stopDisposition":"not_dispatched""#)
        inbound(s, "k") // 物化有序两帧：最终只剩 paused + not_dispatched
        XCTAssertTrue(s.commands["k"]?.state == "paused" && s.commands["k"]?.stopDisposition == .notDispatched, "前置：物化后只剩 paused")
        XCTAssertTrue(s.outgoingStatus(echo("k")).phase == .stoppedUncertain, "待物化阶段的 started 已记证据：首次读取也保守")
        // 待物化帧有界淘汰：k 的 started 帧被挤掉，证据仍在。
        progress(s, "e", "started")
        for i in 0..<(PendingProgress.capacity + 5) { progress(s, "flood\(i)", "queued") }
        progress(s, "e", "paused", #","stopDisposition":"not_dispatched""#)
        inbound(s, "e")
        XCTAssertTrue(s.outgoingStatus(echo("e")).phase == .stoppedUncertain, "started 帧即使被有界淘汰，证据也不丢")
        // 正控：只见 queued / 首个 paused 的有效 not_dispatched 仍是“未发出”。
        progress(s, "c", "paused", #","stopDisposition":"not_dispatched""#)
        inbound(s, "c")
        XCTAssertTrue(s.outgoingStatus(echo("c")).phase == .stopped, "正控：无送达证据时仍显示未发出")
    }

    func testHttpMaterializedProgressKeepsDeliveryEvidence() async throws {
        let s = try session()
        let gate = MacGate()
                let snapJson = json("h", "queued")
        s.stateOverride = { @Sendable in await withCheckedContinuation { gate.resume = $0 }; return try semState([snapJson]) }
        let pull = Task { try await s.pullState() }
        while gate.resume == nil { await Task.yield() }
        progress(s, "h", "started"); progress(s, "h", "paused", #","stopDisposition":"not_dispatched""#) // 请求期间到达、命令尚未存在
        gate.resume?.resume()
        try await pull.value
        XCTAssertTrue(s.commands["h"]?.state == "paused", "前置：HTTP 物化后只剩 paused")
        XCTAssertTrue(s.outgoingStatus(echo("h")).phase == .stoppedUncertain, "HTTP 物化路径同样保守")
    }

    func testAnEvictedPausedCommandIsNotResurrectedByASameContentReplay() async throws {
        let s = try session()
        let stop = #","stopDisposition":"not_dispatched""#
        inbound(s, "P", "paused", seq: 1, extra: stop)
        XCTAssertTrue(s.commandWindow.contains("P"), "前置：新的 paused 准入")
        for i in 0..<CommandWindow.capacity { inbound(s, "k\(1000 + i)", seq: 1000 + i) } // 更新的活动把旧停止挤出窗口
        XCTAssertTrue(!s.commandWindow.contains("P") && s.commands["P"] != nil, "前置：P 被淘汰，commands 缓存仍在")
        s.stateOverride = { @Sendable in try semState([]) }
        try await s.pullState() // 明确空列表：窗口腾空
        XCTAssertTrue(s.commandWindow.count == 0, "前置：窗口已腾空")
        inbound(s, "P", "paused", seq: 1, extra: stop) // 与缓存完全相同的重放
        XCTAssertTrue(!s.commandWindow.contains("P"), "已淘汰的 paused 同内容重放不复活")
        // 正控：全新的 paused、以及显式 stop 分类真实改变的 paused 仍准入。
        inbound(s, "Q", "paused", seq: 2, extra: stop)
        XCTAssertTrue(s.commandWindow.contains("Q"), "正控：全新 paused 准入")
        inbound(s, "P", "paused", seq: 1, extra: #","stopDisposition":"execution_uncertain""#)
        XCTAssertTrue(s.commands["P"]?.stopDisposition == .uncertain && s.commandWindow.contains("P"), "正控：stop 分类真实改变（若被合并规则接受）按 changed 准入")
        // 活动成员同内容重新确认仍然开放。
        inbound(s, "A", "started")
        s.stateOverride = { @Sendable in try semState([]) }
        try await s.pullState()
        inbound(s, "A", "started")
        XCTAssertTrue(s.commandWindow.contains("A"), "正控：started 同内容重新确认")
    }
}
