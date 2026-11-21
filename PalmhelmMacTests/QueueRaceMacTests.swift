import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #89 S2 审查 F1–F3（Mac 会话层）：挂起的 HTTP 快照与 SSE 更新竞态；倒退帧不改 commands 与 inflight；
// 完整重建到旧 Bridge 时清除组，增量旧帧不清除。与 iOS 的 QueueRaceSessionTests 同一组场景。

/// 不依赖主 actor 的状态构造（供 @Sendable 闭包使用）。
private func bridgeState(_ command: String?) throws -> BridgeState {
    let commands = command.map { "[\($0)]" } ?? "[]"
    return try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]},"commands":\#(commands)}"#.utf8))
}

/// 挂起 stateOverride 用的盒子：测试在 await 期间插入 SSE 更新，再放行快照。
private final class MacSuspension: @unchecked Sendable {
    var resume: CheckedContinuation<Void, Never>?
}

@MainActor final class QueueRaceMacTests: XCTestCase {
    private let key = "api:d:1"

    private func session() throws -> MacSession {
        let s = MacSession()
        s.stopStream()
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"race-device","name":"test","paused":false,"permission":"control"}"#.utf8))
        return s
    }

    private func command(_ group: String, state: String = "queued", lane: String = "ordinary") throws -> ApiCommand {
        try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"\#(key)","inboxSeq":1,"text":"合成","truncated":false,"origin":"api","state":"\#(state)","lane":"\#(lane)"\#(group)}"#.utf8))
    }

    private func commandJSON(_ group: String, state: String = "queued") -> String {
        #"{"key":"\#(key)","inboxSeq":1,"text":"合成","truncated":false,"origin":"api","state":"\#(state)","lane":"ordinary"\#(group)}"#
    }

    func testHTTPSnapshotRacingAnSSEUpdateKeepsTheNewerGroup() async throws {
        let s = try session()
        let box = MacSuspension()
        let snapshot = commandJSON(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#)
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { box.resume = $0 }
            return try bridgeState(snapshot)
        }
        s.applyInboundForTest(try command(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#))
        let pull = Task { try await s.pullState() }
        while box.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta(reason: "unconfirmed", position: 1, observedAt: 2000))
        box.resume?.resume()
        try await pull.value
        XCTAssertEqual(s.commands[key]?.queue?.reason, "unconfirmed")
        XCTAssertEqual(s.commands[key]?.queue?.observedAt, 2000)
    }

    func testHTTPSnapshotRacingAnExplicitClearKeepsTheClear() async throws {
        let s = try session()
        let box = MacSuspension()
        let snapshot = commandJSON(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#)
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { box.resume = $0 }
            return try bridgeState(snapshot)
        }
        s.applyInboundForTest(try command(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#))
        let pull = Task { try await s.pullState() }
        while box.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta())
        box.resume?.resume()
        try await pull.value
        XCTAssertEqual(s.commands[key]?.queue, QueueMeta())
    }

    func testRepeatedQueuedInboundCannotRegressStartedNorChangeInflight() throws {
        let s = try session()
        s.applyInboundForTest(try command(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"running""#, state: "started"))
        s.applyProgressForTest(key: key, state: "started", reason: nil, queue: QueueMeta(phase: "running"))
        XCTAssertEqual(s.inflight[key], "started")
        s.applyInboundForTest(try command(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#))
        XCTAssertEqual(s.commands[key]?.state, "started")
        XCTAssertNil(s.commands[key]?.queue?.reason)
        XCTAssertEqual(s.inflight[key], "started")
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta(reason: "draft", position: 1))
        XCTAssertEqual(s.commands[key]?.state, "started")
        XCTAssertEqual(s.inflight[key], "started")
    }

    func testFullRebuildToALegacyBridgeClearsTheGroupButIncrementalLegacyKeepsIt() async throws {
        let s = try session()
        s.applyInboundForTest(try command(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#))
        s.applyInboundForTest(try command(""))
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft")
        let legacy = commandJSON("")
        s.stateOverride = { @Sendable in try bridgeState(legacy) }
        try await s.pullState()
        XCTAssertNil(s.commands[key]?.queue)
    }

    // #89 S2 复审 R1：HTTP 快照读到 started 挂起 → SSE 推到 finished → HTTP 返回：旧快照不得把已终态命令重新标为在途。
    func testOldSnapshotDoesNotResurrectAFinishedInflight() async throws {
        let s = try session()
        let box = MacSuspension()
        let snapshot = #"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]},"inflight":[{"eventKey":"\#(key)","state":"started"}],"commands":[{"key":"\#(key)","inboxSeq":1,"text":"合成","truncated":false,"origin":"api","state":"started","lane":"ordinary","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"dispatch"}]}"#
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { box.resume = $0 }
            return try JSONDecoder().decode(BridgeState.self, from: Data(snapshot.utf8))
        }
        s.applyInboundForTest(try command(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"running""#, state: "started"))
        s.applyProgressForTest(key: key, state: "started", reason: nil, queue: QueueMeta(phase: "running"))
        let pull = Task { try await s.pullState() }
        while box.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "finished", reason: nil, queue: QueueMeta())
        box.resume?.resume()
        try await pull.value
        XCTAssertEqual(s.commands[key]?.state, "finished")
        XCTAssertNil(s.inflight[key], "a stale snapshot must not mark a finished command in flight again")
    }

    // #89 S2 复审 R1（规则 C，A1-046 反例）：途中新出现、旧快照没有的 key 保留本地在途；新快照确认的终态清除旧在途。
    func testNewSSEKeyDuringRequestSurvivesAnOlderSnapshotThatOmitsIt() async throws {
        let s = try session()
        let box = MacSuspension()
        let empty = #"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]},"inflight":[],"commands":[]}"#
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { box.resume = $0 }
            return try JSONDecoder().decode(BridgeState.self, from: Data(empty.utf8))
        }
        let pull = Task { try await s.pullState() }
        while box.resume == nil { await Task.yield() }
        s.applyInboundForTest(try command(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"running""#, state: "started"))
        s.applyProgressForTest(key: key, state: "started", reason: nil, queue: QueueMeta(phase: "running"))
        box.resume?.resume()
        try await pull.value
        XCTAssertEqual(s.commands[key]?.state, "started")
        XCTAssertEqual(s.inflight[key], "started", "new SSE key omitted from older snapshot must retain local inflight")
    }

    func testNewTerminalSnapshotClearsOldLocalInflight() async throws {
        let s = try session()
        s.applyInboundForTest(try command(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"running""#, state: "started"))
        s.applyProgressForTest(key: key, state: "started", reason: nil, queue: QueueMeta(phase: "running"))
        let finished = #"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]},"inflight":[],"commands":[{"key":"\#(key)","inboxSeq":1,"text":"合成","truncated":false,"origin":"api","state":"finished","lane":"ordinary"}]}"#
        s.stateOverride = { @Sendable in try JSONDecoder().decode(BridgeState.self, from: Data(finished.utf8)) }
        try await s.pullState()
        XCTAssertEqual(s.commands[key]?.state, "finished")
        XCTAssertNil(s.inflight[key], "terminal accepted from the new snapshot must clear the old local inflight")
    }

    // #89 裁定 O1-048（会话层）：SSE inbound 的 started→queued+use 被接受，在途表项随之删除。
    func testOrderedInboundRecoveryClearsInflight() throws {
        let s = try session()
        s.applyInboundForTest(try command(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"running""#, state: "started"))
        s.applyProgressForTest(key: key, state: "started", reason: nil, queue: QueueMeta(phase: "running"))
        XCTAssertEqual(s.inflight[key], "started")
        s.applyInboundForTest(try command(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":null"#, state: "queued", lane: "use"))
        XCTAssertEqual(s.commands[key]?.state, "queued")
        XCTAssertNil(s.inflight[key])
    }

    // #89 复审4 F1–F2（会话层）：未触及的快照可跳过 started 直达 unknown，在途表随之为 unknown；有序 progress 的恢复清除在途。
    func testUntouchedSnapshotMaySkipStartedAndLandsInflightOnUnknown() async throws {
        let s = try session()
        s.applyInboundForTest(try command(""))
        let unknown = commandJSON("", state: "unknown")
        s.stateOverride = { @Sendable in try bridgeState(unknown) }
        try await s.pullState()
        XCTAssertEqual(s.commands[key]?.state, "unknown")
        XCTAssertEqual(s.inflight[key], "unknown", "in-flight must follow the final command, not a stale started")
    }

    func testOrderedProgressRecoveryToQueuedUseClearsInflight() throws {
        let s = try session()
        s.applyInboundForTest(try command(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"running""#, state: "started", lane: "use"))
        s.applyProgressForTest(key: key, state: "started", reason: nil, queue: QueueMeta(phase: "running"))
        XCTAssertEqual(s.inflight[key], "started")
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta())
        XCTAssertEqual(s.commands[key]?.state, "queued")
        XCTAssertNil(s.inflight[key], "a recovered queued_use is not in flight")
    }

    // #89 O1-052 N1：命令尚不存在时到达的 progress 事实不得被较早的快照覆盖（finished 与 unknown 两分支）。
    func testProgressForAnUnknownKeyWinsOverAnOlderFirstSnapshot() async throws {
        for pushed in ["finished", "unknown"] {
            let s = try session()
            let box = MacSuspension()
            let snapshot = #"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]},"inflight":[{"eventKey":"\#(key)","state":"started"}],"commands":[{"key":"\#(key)","inboxSeq":1,"text":"合成","truncated":false,"origin":"api","state":"started","lane":"ordinary","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"dispatch"}]}"#
            s.stateOverride = { @Sendable in
                await withCheckedContinuation { box.resume = $0 }
                return try JSONDecoder().decode(BridgeState.self, from: Data(snapshot.utf8))
            }
            let pull = Task { try await s.pullState() }
            while box.resume == nil { await Task.yield() }
            s.applyProgressForTest(key: key, state: pushed, reason: nil, queue: QueueMeta())
            box.resume?.resume()
            try await pull.value
            XCTAssertEqual(s.commands[key]?.state, pushed, "progress-only fact must not be undone by an older snapshot: \(pushed)")
            XCTAssertEqual(s.inflight[key], pushed == "unknown" ? "unknown" : nil)
        }
    }

    // #89 O1-052 边界 1：无效或无变化的帧不计为 touch，因此随后的快照采用自己的组。
    func testUnchangedProgressFrameDoesNotMakeALaterSnapshotKeepTheOldGroup() async throws {
        let s = try session()
        s.applyInboundForTest(try command(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#))
        let box = MacSuspension()
        let snapshot = commandJSON(#","queueReason":"wait_turn","queuePosition":2,"observedAt":3000,"phase":null"#)
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { box.resume = $0 }
            return try bridgeState(snapshot)
        }
        let pull = Task { try await s.pullState() }
        while box.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta(reason: "draft", position: 1, observedAt: 1000))
        box.resume?.resume()
        try await pull.value
        XCTAssertEqual(s.commands[key]?.queue?.position, 2)
        XCTAssertEqual(s.commands[key]?.queue?.reason, "wait_turn")
    }

    // #89 O1-054（A1-053 F1、F2）：待物化事实的顺序契约。
    private func pendingBase(_ state: String, lane: String = "use", phase: String? = nil) -> String {
        let ph = phase.map { "\"\($0)\"" } ?? "null"
        return #"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]},"inflight":[{"eventKey":"\#(key)","state":"started"}],"commands":[{"key":"\#(key)","inboxSeq":1,"text":"合成","truncated":false,"origin":"api","state":"\#(state)","lane":"\#(lane)","queueReason":null,"queuePosition":null,"observedAt":null,"phase":\#(ph)}]}"#
    }

    // F2A：请求发起前已到达的 queued 事实，不得把较新的 HTTP started 退回排队。
    func testPendingFrameBeforeFreshSnapshotCannotRollBackStarted() async throws {
        let s = try session()
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta())
        let fresh = try JSONDecoder().decode(BridgeState.self, from: Data(pendingBase("started", phase: "dispatch").utf8))
        s.stateOverride = { @Sendable in fresh }
        try await s.pullState()
        XCTAssertEqual(s.commands[key]?.state, "started", "a frame received before this request must not roll back the fresh snapshot")
        XCTAssertEqual(s.inflight[key], "started")
    }

    // F2A 正向：请求期间到达的 queued/use 恢复事实仍然生效。
    func testPendingFrameDuringSnapshotMayStillRecoverToQueuedUse() async throws {
        let s = try session()
        let box = MacSuspension()
        let snapshot = try JSONDecoder().decode(BridgeState.self, from: Data(pendingBase("started", phase: "dispatch").utf8))
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { box.resume = $0 }
            return snapshot
        }
        let pull = Task { try await s.pullState() }
        while box.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta())
        box.resume?.resume()
        try await pull.value
        XCTAssertEqual(s.commands[key]?.state, "queued")
        XCTAssertNil(s.inflight[key])
    }

    // F1：同一 key 的多帧按序重放，等价于逐帧处理，已并入的原因不丢。
    func testMultiplePendingFramesKeepTheMergedExplanation() async throws {
        let s = try session()
        let box = MacSuspension()
        let snapshot = try JSONDecoder().decode(BridgeState.self, from: Data(pendingBase("started", phase: "dispatch").utf8))
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { box.resume = $0 }
            return snapshot
        }
        let pull = Task { try await s.pullState() }
        while box.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "started", reason: "merged")
        s.applyProgressForTest(key: key, state: "finished", reason: nil)
        box.resume?.resume()
        try await pull.value
        XCTAssertEqual(s.commands[key]?.state, "finished")
        XCTAssertEqual(s.commands[key]?.reason, "merged", "the merged explanation must survive the later finished frame")
    }

    // F2B：待物化事实应用后，另一个仍在途的旧快照不得清掉这份新事实。
    func testMaterializedPendingFactProtectsAgainstAnotherInflightSnapshot() async throws {
        let s = try session()
        let a = MacSuspension(), b = MacSuspension()
        let snapshot = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]},"commands":[{"key":"\#(key)","inboxSeq":1,"text":"合成","truncated":false,"origin":"api","state":"queued","lane":"ordinary","queueReason":null,"queuePosition":null,"observedAt":null,"phase":null}]}"#.utf8))
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { a.resume = $0 }
            return snapshot
        }
        let first = Task { try await s.pullState() }
        while a.resume == nil { await Task.yield() }
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { b.resume = $0 }
            return snapshot
        }
        let second = Task { try await s.pullState() }
        while b.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta(reason: "draft", position: 1, observedAt: 1000))
        a.resume?.resume()
        try await first.value
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft")
        b.resume?.resume()
        try await second.value
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft", "the accepted pending fact must stay visible to the other in-flight snapshot")
    }

    // #89 O1-056（A1-055 R1A）：较新的快照已吸收待物化的 SSE 事实，较早的在途快照仍须看到该事实的新鲜度。
    func testCoveredPendingProtectsAnOlderSnapshot() async throws {
        let s = try session()
        let a = MacSuspension()
        let stale = try bridgeState(commandJSON(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":null"#))
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { a.resume = $0 }
            return stale
        }
        let first = Task { try await s.pullState() }
        while a.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta(reason: "draft", position: 1, observedAt: 1000))
        let fresh = try bridgeState(commandJSON(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#))
        s.stateOverride = { @Sendable in fresh }
        try await s.pullState()
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft")
        a.resume?.resume()
        try await first.value
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft", "SSE covered by a fresh snapshot is still newer than the earlier request")
    }

    // #89 O1-056（A1-055 R1B）：等值重放的事实对更早的在途快照仍然新鲜。
    func testEqualReplayProtectsAnOlderSnapshot() async throws {
        let s = try session()
        let a = MacSuspension(), b = MacSuspension()
        let stale = try bridgeState(commandJSON(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":null"#))
        let fresh = try bridgeState(commandJSON(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#))
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { a.resume = $0 }
            return stale
        }
        let first = Task { try await s.pullState() }
        while a.resume == nil { await Task.yield() }
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { b.resume = $0 }
            return fresh
        }
        let second = Task { try await s.pullState() }
        while b.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta(reason: "draft", position: 1, observedAt: 1000))
        b.resume?.resume()
        try await second.value
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft")
        a.resume?.resume()
        try await first.value
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft", "equal replay must still protect a fact newer than another request")
    }

    // #89 O1-059（A1-058 R1 边界）：已有命令不占用无命令 key 的淘汰预算；199 条已知命令时未知 key 的事实仍须受保护。
    func testAdvisorCoveredPendingWith199KnownCommands() async throws {
        let s = try session()
        for i in 0..<199 {
            s.applyInboundForTest(ApiCommand(key: "known-\(i)", inboxSeq: i + 2, text: "synthetic", origin: "api", state: "finished", lane: "ordinary"))
        }
        let a = MacSuspension()
        let stale = try bridgeState(commandJSON(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":null"#))
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { a.resume = $0 }
            return stale
        }
        let first = Task { try await s.pullState() }
        while a.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta(reason: "draft", position: 1, observedAt: 1000))
        let fresh = try bridgeState(commandJSON(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#))
        s.stateOverride = { @Sendable in fresh }
        try await s.pullState()
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft")
        a.resume?.resume()
        try await first.value
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft", "SSE covered by a fresh snapshot is still newer than the earlier request")
    }

    // #89 O1-059（A1-058 R1 边界）：已有命令不占用无命令 key 的淘汰预算；200 条已知命令时未知 key 的事实仍须受保护。
    func testAdvisorCoveredPendingWith200KnownCommands() async throws {
        let s = try session()
        for i in 0..<200 {
            s.applyInboundForTest(ApiCommand(key: "known-\(i)", inboxSeq: i + 2, text: "synthetic", origin: "api", state: "finished", lane: "ordinary"))
        }
        let a = MacSuspension()
        let stale = try bridgeState(commandJSON(#","queueReason":null,"queuePosition":null,"observedAt":null,"phase":null"#))
        s.stateOverride = { @Sendable in
            await withCheckedContinuation { a.resume = $0 }
            return stale
        }
        let first = Task { try await s.pullState() }
        while a.resume == nil { await Task.yield() }
        s.applyProgressForTest(key: key, state: "queued", reason: nil, queue: QueueMeta(reason: "draft", position: 1, observedAt: 1000))
        let fresh = try bridgeState(commandJSON(#","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#))
        s.stateOverride = { @Sendable in fresh }
        try await s.pullState()
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft")
        a.resume?.resume()
        try await first.value
        XCTAssertEqual(s.commands[key]?.queue?.reason, "draft", "SSE covered by a fresh snapshot is still newer than the earlier request")
    }
}
