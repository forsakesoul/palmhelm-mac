import XCTest
import SwiftUI
import Vision
import PalmhelmKit
@testable import PalmhelmKit
@testable import PalmhelmMac

// 直达原生插话（Mac 会话接线）：steer 只在目标声明 nativeSteer 时发出；缺能力零请求并保留草稿；确定拒绝不留失败记录。
@MainActor
final class NativeSteerMacTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var failures = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
        func failNext(_ count: Int) { lock.withLock { failures = count } }
        func takeFailure() -> Bool { lock.withLock { if failures > 0 { failures -= 1; return true }; return false } }
    }

    /// 权威快照：指令 key 已 native_delivered（有界确认读取拿到的结果）。
    nonisolated static func deliveredSnapshot(key: String) -> String {
        #"{"occupancy":"busy","targets":[{"id":"t1","projectName":"p","agentName":"design","status":"working","capabilities":{"steer":false,"nativeSteer":true}}],"commands":[{"key":"\#(key)","inboxSeq":1,"text":"插话","truncated":false,"origin":"api","state":"finished","reason":"native_delivered","lane":"use","targetId":"t1","directAgent":"design"}],"history":{"highWater":0,"items":[]}}"#
    }

    private func session(capabilities: String, box: Box, error: (@Sendable () -> Error)? = nil) throws -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.native-steer.mac")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-native","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"busy","targets":[{"id":"t1","projectName":"p","agentName":"design","status":"working","capabilities":\#(capabilities)}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.sendOverride = { _, _ in
            box.bump()
            if box.takeFailure(), let error { throw error() }
            return MessageReceipt.stub("native")
        }
        var d = MacSession.ComposerDraft()
        d.text = "直达的插话"
        s.setDraft(d, for: "t1")
        return s
    }

    func testDirectSteerWithNativeCapabilitySendsSteerMode() async throws {
        let box = Box()
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: box)
        let ok = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        XCTAssertTrue(ok)
        XCTAssertEqual(box.value, 1)
        XCTAssertEqual(s.lastSendMode, .steer)
    }

    func testDirectSteerWithoutNativeCapabilityIsRefusedWithZeroRequestsAndKeepsTheDraft() async throws {
        for caps in [#"{"steer":true}"#, #"{"steer":true,"nativeSteer":false}"#] {
            let box = Box()
            let s = try session(capabilities: caps, box: box)
            let ok = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
            XCTAssertFalse(ok)
            XCTAssertEqual(box.value, 0, "缺 nativeSteer：零请求")
            XCTAssertEqual(s.composerNote("t1")?.text, SendTimingCopy.directSteerUnavailable + "，消息没有发出")
            XCTAssertEqual(s.draft("t1").text, "直达的插话", "草稿保留")
            XCTAssertTrue(s.sent.isEmpty, "没有失败记录")
        }
    }

    func testTypedSteerRefusalLeavesNoRecordAndKeepsDraft() async throws {
        let box = Box()
        box.failNext(1)
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: box) { MessageActionError.steerUnavailable(reason: .noTurn) }
        let ok = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        XCTAssertFalse(ok)
        XCTAssertEqual(s.composerNote("t1")?.text, "没有运行中的回合，未发出")
        XCTAssertEqual(s.draft("t1").text, "直达的插话", "确定拒绝：恢复原草稿")
        XCTAssertTrue(s.sent.isEmpty)
    }

    /// 本机行的状态（界面「我」行）：原生插话的权威快照决定「已送达工作中终端，尚未确认并入本轮」，没有快照前不说已完成。
    func testMineRowStatusFollowsTheAuthoritativeNativeSnapshot() async throws {
        let box = Box()
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: box)
        let ok = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        XCTAssertTrue(ok)
        let sent = try XCTUnwrap(s.sent.last)
        let key = try XCTUnwrap(sent.eventKey)
        s.commands[key] = try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"\#(key)","inboxSeq":1,"text":"插话","truncated":false,"origin":"api","state":"finished","lane":"use","targetId":"t1","directAgent":"design"}"#.utf8))
        XCTAssertEqual(s.outgoingStatus(sent).label, "待确认", "无 reason 的 finished：中性待确认")
        s.commands[key]?.reason = "native_delivered"
        XCTAssertEqual(s.outgoingStatus(sent).label, "已送达工作中终端，尚未确认并入本轮")
    }

    func testFailedDirectSteerRetryKeepsSteerMode() async throws {
        let box = Box()
        box.failNext(1)
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: box) { BridgeError.http(status: 500) }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        let failed = try XCTUnwrap(s.sent.last)
        XCTAssertEqual(failed.mode, .steer)
        XCTAssertNotNil(failed.error)
        let retried = await s.resendFailed(failed, threadId: "t1")
        XCTAssertTrue(retried)
        XCTAssertEqual(box.value, 2)
        XCTAssertEqual(s.sent.last?.mode, .steer, "重试沿用 steer，不降为普通直达")
    }

    private func command(_ key: String, state: String, reason: String? = nil, lane: String = "use") throws -> ApiCommand {
        let r = reason.map { #","reason":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"\#(key)","inboxSeq":1,"text":"keep-this-text","truncated":false,"origin":"api","state":"\#(state)","lane":"\#(lane)","targetId":"t1","directAgent":"design"\#(r)}"#.utf8))
    }

    /// R1：重试遇确定拒绝：原失败记录（正文、草稿、错误）原位保留，并给出固定原因。
    func testRejectedRetryPreservesOriginalFailureOrDraft() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.sendOverride = { _, _ in throw MessageActionError.http(status: 500) }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        let old = try XCTUnwrap(s.sent.last)
        XCTAssertNotNil(old.error)
        s.sendOverride = { _, _ in throw MessageActionError.steerUnavailable(reason: .notWorking) }
        let ok = await s.resendFailed(old, threadId: "t1")
        XCTAssertFalse(ok)
        XCTAssertEqual(s.sent.map(\.id), [old.id], "确定拒绝：原失败记录原位保留")
        XCTAssertEqual(s.sent.first?.text, "直达的插话")
        XCTAssertEqual(s.sent.first?.draft, "直达的插话", "原草稿仍在记录里，可再次重试或恢复")
        XCTAssertNotNil(s.sent.first?.error)
        XCTAssertEqual(s.composerNote("t1")?.text, SendTimingCopy.steerNotWorking)
    }

    /// R4(a)：目标改名后，旧 agent 名的直达不发出。
    func testChangedDirectTargetNameDoesNotSendSteer() async throws {
        let box = Box()
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: box)
        let ok = await s.submitComposer(threadId: "t1", agent: "old-design", mode: .steer)
        XCTAssertFalse(ok)
        XCTAssertEqual(box.value, 0)
        XCTAssertEqual(s.composerNote("t1")?.text, SendTimingCopy.directTargetChanged)
        XCTAssertTrue(s.sent.isEmpty)
        XCTAssertEqual(s.draft("t1").text, "直达的插话", "草稿保留")
    }

    /// R4(b)：原直达消息 promote 时原目标的 nativeSteer 已撤销：零请求，并给出固定原因。
    func testPromoteAfterNativeCapabilityWithdrawalMakesZeroRequests() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.state?.targets[0].capabilities?.nativeSteer = false
        let c = try command("old-key", state: "queued")
        s.commandOverride = { _, _ in XCTFail("native promote reached transport after capability withdrawal") }
        await s.promoteQueued(c)
        XCTAssertTrue(s.commandRequests.isEmpty)
        XCTAssertEqual(s.commandNotes["old-key"]?.text, SendTimingCopy.directSteerUnavailable)
    }

    /// R3(a)：普通直达排队后 promote（本机记录仍是普通），finished 无 reason：按权威直达 + use 车道待确认，不说已完成。
    func testPromotedOrdinaryDirectDoesNotClaimDoneWithoutReason() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.sendOverride = { _, _ in MessageReceipt.stub("p") }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: nil)
        let m = try XCTUnwrap(s.sent.last)
        XCTAssertEqual(m.eventKey, "p")
        s.commands["p"] = try command("p", state: "queued", lane: "ordinary")
        s.commandOverride = { _, _ in }
        await s.promoteQueued(try command("p", state: "queued", lane: "ordinary"))
        s.commands["p"] = try command("p", state: "finished")
        XCTAssertEqual(s.outgoingStatus(m).phase, .nativePending, "promote 后的权威路由进入同一判断")
        XCTAssertNotEqual(s.outgoingStatus(m).label, "已完成")
    }

    /// R2：原生排队只说会写入工作中终端，不承诺并入。
    func testNativeQueuedLabelDoesNotPromiseMerge() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.sendOverride = { _, _ in MessageReceipt.stub("q") }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        let m = try XCTUnwrap(s.sent.last)
        s.commands["q"] = try command("q", state: "queued")
        let label = s.outgoingStatus(m).label
        XCTAssertFalse(label.contains("将并入"), "原生排队仍承诺并入：\(label)")
        XCTAssertEqual(label, SendTimingCopy.queuedNative)
    }

    /// R3(b)：progress 的 finished（无 reason）→ 有界补拉见到权威 native_delivered。
    func testNativeDeliveredArrivesThroughBoundedConfirmation() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.nativeConfirmDelay = { _ in .milliseconds(0) }
        s.sendOverride = { _, _ in MessageReceipt.stub("n") }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        s.commands["n"] = try command("n", state: "queued")
        s.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"busy","targets":[{"id":"t1","projectName":"p","agentName":"design","status":"working","capabilities":{"steer":false,"nativeSteer":true}}],"commands":[{"key":"n","inboxSeq":1,"text":"插话","truncated":false,"origin":"api","state":"finished","reason":"native_delivered","lane":"use","targetId":"t1","directAgent":"design"}],"history":{"highWater":0,"items":[]}}"#.utf8)) }
        s.applyProgressForTest(key: "n", state: "finished", reason: nil)
        for _ in 0..<100 where s.commands["n"]?.reason == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(s.commands["n"]?.reason, "native_delivered")
        let m = try XCTUnwrap(s.sent.last)
        XCTAssertEqual(s.outgoingStatus(m).phase, .nativeDelivered)
    }

    /// H3-2：一次 finished progress 后遇瞬时失败（503）仍按退避重试，拿到权威 native_delivered 即停。
    func testOneFinishedProgressRetriesTransientSnapshotFailure() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        let reads = Box()
        s.commands["confirm"] = try command("confirm", state: "queued")
        s.nativeConfirmDelay = { _ in .milliseconds(1) }
        s.stateOverride = {
            reads.bump()
            if reads.value == 1 { throw BridgeError.http(status: 503) }
            return try JSONDecoder().decode(BridgeState.self, from: Data(Self.deliveredSnapshot(key: "confirm").utf8))
        }
        s.applyProgressForTest(key: "confirm", state: "finished", reason: nil)
        for _ in 0..<100 where s.commands["confirm"]?.reason == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(s.commands["confirm"]?.reason, "native_delivered")
        XCTAssertEqual(reads.value, 2, "503 之后只再读一次就拿到权威结果")
    }

    /// H3-2：读取总次数封顶 3（含失败）；重复 progress 不放大次数。
    func testConfirmationFetchCountIsBoundedAndDuplicateProgressDoesNotAmplify() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        let reads = Box()
        s.commands["confirm"] = try command("confirm", state: "queued")
        s.nativeConfirmDelay = { _ in .milliseconds(1) }
        s.stateOverride = { reads.bump(); throw BridgeError.http(status: 503) }
        for _ in 0..<10 { s.applyProgressForTest(key: "confirm", state: "finished", reason: nil) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(reads.value, 3)
        s.applyProgressForTest(key: "confirm", state: "finished", reason: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(reads.value, 3, "上限用尽后再来的 progress 不再读取")
    }

    /// H3-2：补拉等待期间换了代次（忘记配对 / 换连接）：不再读取，也不把结果写进新一代。
    func testQueuedConfirmationStopsWhenGenerationChanges() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        let reads = Box()
        s.commands["confirm"] = try command("confirm", state: "queued")
        s.nativeConfirmDelay = { _ in .milliseconds(30) }
        s.stateOverride = { reads.bump(); return try JSONDecoder().decode(BridgeState.self, from: Data(Self.deliveredSnapshot(key: "confirm").utf8)) }
        s.applyProgressForTest(key: "confirm", state: "finished", reason: nil)
        s.stopStream()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads.value, 0)
    }

    /// H3-2：读取在途时换了代次：旧读取的结果不写入新一代。
    func testInFlightConfirmationCannotApplyToNextGeneration() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        let reads = Box()
        s.commands["confirm"] = try command("confirm", state: "queued")
        s.nativeConfirmDelay = { _ in .zero }
        s.stateOverride = {
            reads.bump()
            try await Task.sleep(for: .milliseconds(50))
            return try JSONDecoder().decode(BridgeState.self, from: Data(Self.deliveredSnapshot(key: "confirm").utf8))
        }
        s.applyProgressForTest(key: "confirm", state: "finished", reason: nil)
        for _ in 0..<50 where reads.value == 0 { try await Task.sleep(for: .milliseconds(2)) }
        s.stopStream()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads.value, 1)
        XCTAssertNil(s.commands["confirm"]?.reason)
    }

    /// H3-1：重试在传输期间忘记配对 / 换连接，随后被确定拒绝：旧记录不复活，也不写提示进新一代。
    func testRejectedRetryCannotRestoreRecordAfterGenerationReset() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.sendOverride = { _, _ in throw MessageActionError.http(status: 500) }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        let old = try XCTUnwrap(s.sent.last)
        s.sendOverride = { _, _ in
            await MainActor.run { s.stopStream(); s.sent = [] }
            throw MessageActionError.steerUnavailable(reason: .notWorking)
        }
        _ = await s.resendFailed(old, threadId: "t1")
        XCTAssertTrue(s.sent.isEmpty, "旧失败记录不能在新代次复活")
        XCTAssertNil(s.composerNote("t1"), "旧代次的拒绝原因不能写进新代次")
    }

    /// H3-1：代次变化后，旧重试的拒绝不覆盖用户在新代次里输入的内容。
    func testRejectedRetryAfterResetDoesNotOverwriteNewInput() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.sendOverride = { _, _ in throw MessageActionError.http(status: 500) }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        let old = try XCTUnwrap(s.sent.last)
        s.sendOverride = { _, _ in
            await MainActor.run {
                s.stopStream(); s.sent = []
                var d = MacSession.ComposerDraft(); d.text = "新一代的输入"
                s.setDraft(d, for: "t1")
            }
            throw MessageActionError.steerUnavailable(reason: .notWorking)
        }
        _ = await s.resendFailed(old, threadId: "t1")
        XCTAssertEqual(s.draft("t1").text, "新一代的输入")
        XCTAssertNil(s.composerNote("t1"))
    }

    /// H3-1 同代次对照：重试被确定拒绝时，原记录与草稿仍按原样保留，并给出固定原因。
    func testRejectedRetrySameGenerationStillRestoresRecordWithReason() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.sendOverride = { _, _ in throw MessageActionError.http(status: 500) }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        let old = try XCTUnwrap(s.sent.last)
        s.sendOverride = { _, _ in throw MessageActionError.steerUnavailable(reason: .notWorking) }
        _ = await s.resendFailed(old, threadId: "t1")
        XCTAssertTrue(s.sent.contains { $0.id == old.id }, "同代次：原失败记录原位保留")
        XCTAssertNotNil(s.composerNote("t1"))
    }

    /// R3(b)：快照先到（native_delivered），迟到的 queued progress 不把它拉回。
    func testLateQueuedProgressDoesNotRegressNativeDelivered() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.sendOverride = { _, _ in MessageReceipt.stub("late") }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        let m = try XCTUnwrap(s.sent.last)
        s.commands["late"] = try command("late", state: "finished", reason: "native_delivered")
        s.applyProgressForTest(key: "late", state: "queued", reason: nil)
        XCTAssertEqual(s.commands["late"]?.reason, "native_delivered")
        XCTAssertEqual(s.outgoingStatus(m).phase, .nativeDelivered)
    }

    /// 原绑定排队消息，当前视图是直达（绑定已移到 t2，t1 只有 nativeSteer）：promote 按原路由只看 hook steer，零请求；hook steer 可用时才允许。
    func testBoundQueuedMessageIsNotPromotedByDirectNativeCapability() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        func state(steer: Bool) throws -> BridgeState {
            try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"busy","binding":{"targetId":"t2","projectName":"q","agentName":"bound"},"targets":[{"id":"t1","projectName":"p","agentName":"design","status":"working","capabilities":{"steer":\#(steer),"nativeSteer":true}},{"id":"t2","projectName":"q","agentName":"bound","capabilities":{"steer":true}}],"history":{"highWater":0,"items":[]}}"#.utf8))
        }
        s.state = try state(steer: false)
        let bound = try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"bound-1","inboxSeq":1,"text":"补","truncated":false,"origin":"api","state":"queued","lane":"ordinary","targetId":"t1"}"#.utf8))
        s.commandOverride = { _, _ in }
        await s.promoteQueued(bound)
        XCTAssertTrue(s.commandRequests.isEmpty, "原绑定消息不因当前直达的 nativeSteer 被 promote")
        XCTAssertEqual(s.commandNotes["bound-1"]?.text, SendTimingCopy.notPromotable)
        // 正控：同一条原绑定消息，原目标的 hook steer 可用时允许 promote。
        s.state = try state(steer: true)
        await s.promoteQueued(bound)
        XCTAssertEqual(s.commandRequests.count, 1)
    }

    /// Gate3（菜单可读性，Mac）：原生相关菜单项的完整标题（SendControls.title 即菜单按钮的标题与 AX 标签）不截断，并在常规菜单宽度内。
    /// 方法：不靠截图（NSMenu 未展开时不在视图树里）；直接取视图实际使用的标题字符串，并用系统字体 13pt 测量宽度（上限 320pt）。
    func testNativeMenuTitlesFitRegularMenuWidth() throws {
        let font = NSFont.systemFont(ofSize: 13)
        var titles: [String] = []
        for (steer, nativeSteer) in [(SteerAvailability.unavailable, false), (.unavailable, true)] {
            for item in SendTimingRules.menu(steer: steer, direct: true, nativeSteer: nativeSteer, queueDeadline: false) where item.choice == .steerNow {
                titles.append(SendControls.title(item, direct: true))
            }
        }
        titles.append(QueuedAction.promote.title)
        for t in titles {
            let width = (t as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, 320, "菜单项过宽：\(t)")
            XCTAssertFalse(t.contains("…"))
        }
    }

    /// Gate4（transcript）：真实会话记录行在宿主中渲染；原生插话的回执经权威指令叠加为「已送达工作中终端，尚未确认并入本轮」，未关联的原生回执保持「结果未知」。
    func testTranscriptRowRendersNativeDeliveredAndUnknownReceipts() throws {
        let linked = TranscriptItem(id: "n", role: "user", text: "插话正文", t: 1_760_000_000_000, receipt: .init(commandKey: "k", origin: "api", receiptState: "unknown", eventKey: "k"))
        let unlinked = TranscriptItem(id: "u", role: "user", text: "其他设备", t: 1_760_000_000_000, receipt: .init(commandKey: "x", origin: "api", receiptState: "unknown"))
        let cmd = try command("k", state: "finished", reason: "native_delivered")
        for (item, command, expected) in [(linked, cmd, "已送达工作中终端，尚未确认并入本轮"), (unlinked, nil, "结果未知")] {
            let host = NSHostingView(rootView: TranscriptItemRow(item: item, linkedCommand: command).frame(width: 420))
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            XCTAssertTrue(TranscriptCopy.sourceLine(item, command: command, now: Date(timeIntervalSince1970: 1_760_000_000)).contains(expected), "行文案应为 \(expected)")
        }
    }

    /// 渲染检查：把实际视图渲染成位图，再用 Vision 文字识别读回屏幕上可见的文案（不依赖无障碍树）。
    private func renderedTexts<V: View>(_ view: V, width: CGFloat = 460, height: CGFloat = 200) throws -> [String] {
        let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let scale: CGFloat = 3
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: height)
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil
        let cg = try XCTUnwrap(rep.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// OCR 把间隔点 · 识别成 • 或漏空格：比较前去掉这些字符。
    private func normalized(_ s: String) -> String { s.filter { !" ·•.".contains($0) } }
    /// OCR 文本是否含有期望文案：两边都经 `copyKey` 归一后精确子串匹配（不做编辑距离容忍）。
    private func shows(_ texts: [String], _ expected: String) -> Bool { nativeCopyMatches(texts, expected) }

    /// Gate4（mine / command 真实视图）：渲染 RowView(.mine / .command)，经 Vision 识别断言三种原生状态文案；旧的「并入当前回合 / 已完成」不得出现。
    func testRowViewsRenderNativeQueuedPendingAndDeliveredCopy() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSteer":true}"#, box: Box())
        s.sendOverride = { _, _ in MessageReceipt.stub("v") }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .steer)
        let m = try XCTUnwrap(s.sent.last)
        let forbidden = ["并入当前回合", "已完成"]
        let cases: [(state: String, reason: String?, expected: String)] = [
            ("queued", nil, "补充排队中 · 等待写入工作中终端，未验证"),
            ("finished", nil, "待确认"),
            ("finished", "native_delivered", "已送达工作中终端，尚未确认并入本轮"),
        ]
        for c in cases {
            s.commands["v"] = try command("v", state: c.state, reason: c.reason)
            let mine = try renderedTexts(RowView(row: .mine(m)).environment(s))
            XCTAssertTrue(shows(mine, c.expected), "mine 行应渲染「\(c.expected)」，实际 \(mine)")
            XCTAssertFalse(mine.contains { t in forbidden.contains { normalized(t).contains(normalized($0)) } }, "mine 行不得出现旧文案：\(mine)")
            let cmd = try renderedTexts(RowView(row: .command(s.commands["v"]!)).environment(s))
            XCTAssertTrue(shows(cmd, c.expected), "command 行应渲染「\(c.expected)」，实际 \(cmd)")
            XCTAssertFalse(cmd.contains { t in forbidden.contains { normalized(t).contains(normalized($0)) } }, "command 行不得出现旧文案：\(cmd)")
        }
    }
}

/// OCR 归一：去掉空格与 · • . 、 分隔符，并把 CI 实测的两处误读映射回原字（只做这两条词级替换，不做单字替换）。
/// 误读来源：CI 的 Vision 把「确认」识别成「路认」、「并入」识别成「井入」。
private func copyKey(_ s: String) -> String {
    String(s.filter { !" ·•.、".contains($0) })
        .replacingOccurrences(of: "路认", with: "确认")
        .replacingOccurrences(of: "井入", with: "并入")
}

/// 纯函数（不依赖 Vision）：归一后，任一 OCR 文本包含期望文案即匹配。
func nativeCopyMatches(_ texts: [String], _ expected: String) -> Bool {
    let e = copyKey(expected)
    return texts.contains { copyKey($0).contains(e) }
}

/// 纯函数负控与 CI 实测误读的正控（不依赖 Vision，每次运行都执行）。
final class NativeCopyMatcherTests: XCTestCase {
    private let queued = "补充排队中 · 等待写入工作中终端，未验证"
    private let delivered = "已送达工作中终端，尚未确认并入本轮"

    func testMissingPendingWordDoesNotMatch() {
        XCTAssertFalse(nativeCopyMatches(["补充排队中 · 等待写入工作中终端，未验证"], "待确认"))
    }

    func testVerifiedInsteadOfUnverifiedDoesNotMatch() {
        XCTAssertFalse(nativeCopyMatches(["补充排队中 · 等待写入工作中终端，已验证"], queued))
    }

    func testAlreadyConfirmedInsteadOfNotYetConfirmedDoesNotMatch() {
        XCTAssertFalse(nativeCopyMatches(["已送达工作中终端，已经确认并入本轮"], delivered))
    }

    /// CI 实测的 4 条误读文本（mine / command 两行、两个状态）：归一后必须匹配。
    func testObservedCIMisreadsMatch() {
        XCTAssertTrue(nativeCopyMatches(["我•这台 Mac", "直达的插话", "补充排队中、等待写入工作中终端，未验证"], queued))
        XCTAssertTrue(nativeCopyMatches(["补充排队中、等待写入工作中终端，未验证", "我·来自设备", "keep-this-text"], queued))
        XCTAssertTrue(nativeCopyMatches(["我•这台 Mac", "直达的插话", "已送达工作中终端，尚未确认井入本轮"], delivered))
        XCTAssertTrue(nativeCopyMatches(["已送达工作中终端，尚未路认井入本轮", "我•来自设备", "keep-this-text"], delivered))
    }
}

