import XCTest
import PalmhelmKit
@testable import PalmhelmMac

private final class Sink: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var all: [String] { lock.withLock { v } }
}

/// O1-148：过期状态不冒充当前（Mac 端：当前活动、提醒当前性、条件重置、快照式已读）。
@MainActor
final class StaleStateTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    private func state(bridge: String = "b1", targets: String = #"[{"projectName":"P","id":"A"}]"#, blocked: String? = nil, history: String = "[]", truncated: Bool = false) -> BridgeState {
        let b = blocked.map { #","currentBlocked":\#($0),"currentBlockedFresh":true"# } ?? ""
        return decode(#"{"bridge":{"id":"\#(bridge)"},"occupancy":"free","targets":\#(targets),"history":{"highWater":0,"items":\#(history)},"commandsTruncated":\#(truncated)\#(b)}"#)
    }
    private func session(_ st: BridgeState? = nil, connected: Bool = true) -> MacSession {
        let s = MacSession()
        s.streamDisabled = true
        s.applyStateSnapshot(st ?? state())
        s.link = connected ? .connected : .offline("x")
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        s.stateOverride = { [unowned s] in await MainActor.run { s.state ?? BridgeState.empty } }
        return s
    }
    private func cmd(_ key: String, _ state: String, target: String? = "A") -> ApiCommand { ApiCommand(key: key, inboxSeq: 1, text: "x", origin: "api", targetId: target, state: state) }
    private func reminder(_ seq: Int, key: String = "evA", target: String = "A") -> HistoryItem {
        HistoryItem(seq: seq, uuid: "nblocked2:c\(seq)", text: "[P] 等待已超过 10 分钟", kind: "text", replyTo: key, target: TargetRef(id: target, projectName: "P"), t: nowMs)
    }
    /// 72 小时窗口按真实时钟计：测试数据用当前时间，过期场景单独写旧时间。
    private var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }

    // D2
    func testOnlyKnownQueuedStartedWithTargetPresentCountAsRunning() {
        let s = session()
        for c in [cmd("a", "started"), cmd("b", "queued"), cmd("c", "unknown"), cmd("d", "mystery"), cmd("e", "started", target: "gone"), cmd("f", "paused")] { s.commands[c.key] = c }
        XCTAssertEqual(Set(s.runningCommands.map(\.key)), ["a", "b"])
        XCTAssertEqual(s.unresolvedCommandCount, 2, "未知 / 不识别单独说明，不计在途")
        XCTAssertEqual(s.commandLabel(cmd("d", "mystery")), "暂不支持此状态")
        XCTAssertEqual(s.commandLabel(cmd("c", "unknown")), "结果未知")
    }

    func testOfflineShowsPendingSyncNotWorking() {
        let s = session(connected: false)
        s.commands["a"] = cmd("a", "started")
        XCTAssertTrue(s.runningCommands.isEmpty)
        XCTAssertTrue(s.activityPendingSync)
        XCTAssertEqual(s.commandLabel(cmd("a", "started")), "状态待同步")
    }

    // D4 / D5
    func testReminderIsCurrentOnlyForTheActiveBlockedCommandAndOldOneNeverReturns() {
        let s = session(state(blocked: #"[{"targetId":"A","eventKey":"evA","blockedSince":1}]"#))
        let a = reminder(1)
        XCTAssertEqual(s.reminderStatus(a), .current(eventKey: "evA"))
        s.applyTargetsFrame(s.state!.targets, spaces: nil, currentBlocked: [CurrentBlocked(targetId: "A", eventKey: "evB", blockedSince: 2)], currentBlockedFresh: true) // A 完成 → B 阻塞
        XCTAssertEqual(s.reminderStatus(a), .history)
        s.applyTargetsFrame(s.state!.targets, spaces: nil, currentBlocked: [CurrentBlocked(targetId: "A", eventKey: "evA", blockedSince: 3)], currentBlockedFresh: true) // 不会因 eventKey 复用以外的原因回到当前
        XCTAssertTrue(s.reminderStatus(a).allowsReset)
        s.applyTargetsFrame(s.state!.targets, spaces: nil, currentBlocked: nil) // 旧 Bridge 帧：证据缺口
        XCTAssertEqual(s.reminderStatus(a), .unverified)
        s.link = .offline("x")
        s.applyTargetsFrame(s.state!.targets, spaces: nil, currentBlocked: [], currentBlockedFresh: true)
        XCTAssertEqual(s.reminderStatus(a), .unverified, "离线：待核")
    }

    func testResetSendsConditionalTextAndConfirmDialogRaceHasZeroEffect() async {
        let s = session(state(blocked: #"[{"targetId":"A","eventKey":"evA","blockedSince":1}]"#))
        let sink = Sink()
        s.sendOverride = { text, _ in sink.add(text); return MessageReceipt.stub("k") }
        s.device = decode(#"{"id":"d","name":"mac","paused":false,"permission":"control"}"#)
        await s.resetOccupancy(for: reminder(1), name: "P")
        XCTAssertEqual(sink.all, ["重置占用 P #evA"])
        // 确认框打开期间 A 被换成 B：零发送
        s.applyTargetsFrame(s.state!.targets, spaces: nil, currentBlocked: [CurrentBlocked(targetId: "A", eventKey: "evB", blockedSince: 2)], currentBlockedFresh: true)
        let r2 = reminder(2, key: "evA")
        await s.resetOccupancy(for: r2, name: "P")
        XCTAssertEqual(sink.all.count, 1)
        XCTAssertEqual(s.reminderSend(r2).blocked, "这条提醒已不是当前状态，没有重置")
    }

    // D3
    func testFirstSyncBaselinesOldRemindersAndOpeningSnapshotsSeen() async {
        let hist = (1...3).map { #"{"seq":\#($0),"uuid":"nblocked2:c\#($0)","text":"[P] x","kind":"text","replyTo":"e\#($0)","target":{"id":"A","projectName":"P"},"t":\#(nowMs)}"# }.joined(separator: ",")
        let s = session(state(history: "[\(hist)]")) // 无当前阻塞证据：状态待核
        s.reminderLedger = ReminderLedger()
        try? await s.pullState()
        XCTAssertEqual(s.unreadReminderCount, 0, "升级后首次同步：旧提醒进历史")
        XCTAssertTrue(s.blockedReminders.isEmpty, "已读的旧提醒不显示")
        // 新提醒到达 → 未读；打开 = 快照标已读；打开期间再来的仍未读
        s.history.append(reminder(4, key: "e4"))
        XCTAssertEqual(s.unreadReminderCount, 1)
        s.openReminders()
        XCTAssertEqual(s.unreadReminderCount, 0)
        s.history.append(reminder(5, key: "e5"))
        XCTAssertEqual(s.unreadReminderCount, 1)
        XCTAssertEqual(s.blockedReminders.first?.seq, 5)
    }

    func testReadingKeepsEntryAndDifferentBridgesAreIsolated() {
        let s = session()
        s.reminderLedger = ReminderLedger()
        s.history = [reminder(1)]
        s.openReminders()
        XCTAssertEqual(s.blockedReminders.count, 1, "读过仍可达")
        s.applyStateSnapshot(state(bridge: "b2"))
        XCTAssertEqual(s.unreadReminderCount, 1, "另一台 Bridge 的同 uuid 提醒不继承已读")
    }

    // R3：支持但证据过期（Herdr 快照过期）≠ 可靠的空数组 / 当前阻塞
    func testStaleBlockedEvidenceDisablesResetAndIsNotAReliableEmpty() async {
        let s = session(state(blocked: #"[{"targetId":"A","eventKey":"evA","blockedSince":1}]"#))
        let sink = Sink()
        s.sendOverride = { text, _ in sink.add(text); return MessageReceipt.stub("k") }
        s.device = decode(#"{"id":"d","name":"mac","paused":false,"permission":"control"}"#)
        let a = reminder(1)
        XCTAssertEqual(s.reminderStatus(a), .current(eventKey: "evA"))
        s.applyTargetsFrame(s.state!.targets, spaces: nil, currentBlocked: [CurrentBlocked(targetId: "A", eventKey: "evA", blockedSince: 1)], currentBlockedFresh: false) // SSE 保持，但 Herdr 刷新失败
        XCTAssertEqual(s.reminderStatus(a), .unverified, "证据过期：不能再当作当前")
        await s.resetOccupancy(for: a, name: "P")
        XCTAssertTrue(sink.all.isEmpty, "证据过期时零发送")
        s.applyTargetsFrame(s.state!.targets, spaces: nil, currentBlocked: [], currentBlockedFresh: false)
        XCTAssertEqual(s.reminderStatus(a), .unverified, "过期的空数组不是「没有阻塞」")
    }

    // R7：首次连接顺序——pullState 跑在 link 变成 connected 之前，当前阻塞的提醒不能被基线标成已读
    func testFirstConnectionBaselineUsesTheSyncEvidenceNotTheLinkState() async {
        let hist = [1, 2].map { #"{"seq":\#($0),"uuid":"nblocked2:c\#($0)","text":"[P] x","kind":"text","replyTo":"e\#($0)","target":{"id":"A","projectName":"P"},"t":\#(nowMs)}"# }.joined(separator: ",")
        let s = session(state(blocked: #"[{"targetId":"A","eventKey":"e2","blockedSince":\#(nowMs)}]"#, history: "[\(hist)]"))
        s.reminderLedger = ReminderLedger()
        s.link = .connecting // 真实首次连接：refresh 先置 connecting，pullState 成功后才 connected
        try? await s.pullState()
        XCTAssertEqual(s.unreadReminderCount, 1, "仍在阻塞的 e2 保持未读；e1 是旧历史")
        s.link = .connected
        XCTAssertEqual(s.reminderStatus(s.blockedReminders.first { $0.replyTo == "e2" }!), .current(eventKey: "e2"))
    }

    // R1：普通 rejected 回执与发送失败走同一个账本；上限只裁已读的普通历史，可恢复项全部保留
    func testPlainReceiptsAndSendFailuresShareTheLedgerAndNoCapCutsUnread() async {
        func rej(_ n: Int) -> String { #"{"seq":\#(n),"uuid":"rj-\#(n)","text":"rejected:x\#(n)","kind":"text","replyTo":"k\#(n)","t":\#(nowMs)}"# }
        let old = (1...3).map(rej).joined(separator: ",")
        let s = session(state(history: "[\(old)]"))
        s.reminderLedger = ReminderLedger()
        try? await s.pullState()
        XCTAssertTrue(s.inboxAlerts.isEmpty, "升级后首次同步：旧的普通回执进历史，已读即隐藏")
        XCTAssertEqual(s.unreadReminderCount, 0)
        // 新的普通回执与一条带草稿的发送失败：都是未读
        var h = s.history
        h.append(HistoryItem(seq: 4, uuid: "rj-4", text: "rejected:x4", kind: "text", replyTo: "k4", t: nowMs))
        s.history = h
        s.sent.append(MacSession.Sent(id: UUID(), text: "x", at: Date(), afterSeq: 0, targetId: nil, error: "无法连接", draft: "草稿", attachmentPaths: []))
        XCTAssertEqual(s.unreadReminderCount, 2)
        s.openReminders()
        XCTAssertEqual(s.unreadReminderCount, 0, "打开 = 快照标已读（回执与发送失败同时）")
        // 页内新到的未读：可见、计数；关闭再开后已读的旧项不再补位，没有展示上限
        s.closeReminders()
        for n in 5...30 { s.history.append(HistoryItem(seq: n, uuid: "rj-\(n)", text: "rejected:x\(n)", kind: "text", replyTo: "k\(n)", t: nowMs)) }
        s.openReminders()
        for n in 31...33 { s.history.append(HistoryItem(seq: n, uuid: "rj-\(n)", text: "rejected:x\(n)", kind: "text", replyTo: "k\(n)", t: nowMs)) }
        let ids = s.inboxAlerts.map(\.id)
        XCTAssertTrue((31...33).allSatisfy { ids.contains("rj:rj-\($0)") }, "页内新到的全部可见")
        XCTAssertEqual(s.unreadReminderCount, 3, "只计可见未读：批次里的 5…30 已标读")
        s.closeReminders()
        s.openReminders()
        XCTAssertEqual(s.unreadReminderCount, 0)
        XCTAssertEqual(s.inboxAlerts.filter { $0.restoreSendId == nil }.count, 3, "重开后仅本次批次（31…33）可见，已读项不补位")
    }

    func testRemindersOlderThanSeventyTwoHoursNeverShowOrCount() {
        let s = session(state(blocked: "[]"))
        s.reminderLedger = ReminderLedger()
        // 会话与边界事件共用一个固定时刻（见 iOS 同名用例与 #93）。
        let clock = nowMs
        s.now = Date(timeIntervalSince1970: Double(clock) / 1000)
        let edge = clock - ReminderRules.maxAgeMs
        s.history = [
            HistoryItem(seq: 1, uuid: "rj-old", text: "rejected:x", kind: "text", replyTo: "k1", t: edge - 1),
            HistoryItem(seq: 2, uuid: "rj-edge", text: "rejected:y", kind: "text", replyTo: "k2", t: edge),
        ]
        XCTAssertEqual(s.inboxAlerts.map(\.id), ["rj:rj-edge"], "恰好 72 小时保留，之前的隐藏")
        XCTAssertEqual(s.unreadReminderCount, 1, "超过窗口的未读不计数")
    }

    /// 恢复成功：同一发送的 sent: 与 rj: 别名一起标已读、立即移出（即使本次批次保留着它们）。
    func testRestoreSuccessRemovesAllAliasesEvenWhileThePageIsOpen() {
        let s = session(state(blocked: "[]"))
        s.reminderLedger = ReminderLedger()
        let sent = MacSession.Sent(id: UUID(), text: "x", at: Date(), afterSeq: 0, targetId: nil, eventKey: "k2", error: "无法连接", draft: "草稿", attachmentPaths: [])
        s.sent = [sent]
        s.history = [HistoryItem(seq: 2, uuid: "rj-2", text: "rejected:x", kind: "text", replyTo: "k2", t: nowMs)]
        s.openReminders()
        XCTAssertFalse(s.inboxAlerts.isEmpty, "打开后：恢复入口可见")
        s.markRestored(sent.id)
        XCTAssertTrue(s.inboxAlerts.isEmpty, "恢复成功：立即移出，不等下一次打开")
        XCTAssertEqual(s.unreadReminderCount, 0)
        XCTAssertNotNil(s.sent.first { $0.id == sent.id }, "快照本身不删")
    }

    // F2：本机 Sent 一直追加；一条已读的旧失败项之后，同一 Bridge 又读过超过容量的新提醒——它的已读标记不能被挤掉，恢复入口仍可达
    func testOldReadSendFailureSurvivesLaterReadsBeyondCapacityAndStaysRecoverable() {
        let s = session(state(blocked: "[]"))
        s.reminderLedger = ReminderLedger()
        let old = MacSession.Sent(id: UUID(), text: "旧", at: Date(), afterSeq: 0, targetId: nil, error: "无法连接", draft: "旧草稿", attachmentPaths: [])
        s.sent.append(old)
        s.openReminders()
        XCTAssertEqual(s.unreadReminderCount, 0)
        var window: [HistoryItem] = []
        for n in 1...(ReminderLedger.perBridgeLimit + 300) {
            window.append(HistoryItem(seq: n, uuid: "rj-\(n)", text: "rejected:x\(n)", kind: "text", replyTo: "k\(n)"))
            if window.count > 500 { window.removeFirst() } // 历史保留窗口
            s.history = window
            s.closeReminders(); s.openReminders()
            // 每一步都断言（尤其是账本第一次越界的那一步）：S 仍是已读、未读数为 0、恢复入口仍可达
            if n % 50 == 0 || n > ReminderLedger.perBridgeLimit - 5 {
                XCTAssertTrue(s.reminderLedger.isSeen(bridgeId: s.reminderIdentity.id, id: ReminderLedger.sentId(old.id)), "n=\(n)：S 仍是已读")
                XCTAssertEqual(s.unreadReminderCount, 0, "n=\(n)：未读数为 0")
                XCTAssertTrue(s.inboxAlerts.contains { $0.restoreSendId == old.id }, "n=\(n)：恢复入口可达")
            }
        }
        XCTAssertEqual(s.unreadReminderCount, 0, "旧的已读失败项没有因为后来的已读而重新变成未读")
        XCTAssertTrue(s.inboxAlerts.contains { $0.restoreSendId == old.id }, "可恢复项仍可达（草稿没被删）")
        XCTAssertLessThanOrEqual(s.reminderLedger.seenByBridge[s.reminderIdentity.id]?.count ?? 0, ReminderLedger.perBridgeLimit + 600, "有界")
    }

    // F3：旧 Bridge 没有 id 时不共用 "local" 账本
    func testBridgesWithoutIdUseTheirOwnPairingKeyAndNeverShareALedger() {
        func noId(_ device: String?) -> MacSession {
            let s = MacSession()
            s.streamDisabled = true
            s.applyStateSnapshot(decode(#"{"occupancy":"free","targets":[{"projectName":"P","id":"A"}],"history":{"highWater":0,"items":[]}}"#))
            s.link = .connected
            if let device { s.device = decode(#"{"id":"\#(device)","name":"mac","paused":false}"#) }
            s.reminderLedger = ReminderLedger()
            return s
        }
        let a = noId("dev-a"), b = noId("dev-b"), none = noId(nil)
        XCTAssertNotEqual(a.reminderIdentity.id, b.reminderIdentity.id)
        XCTAssertNotEqual(a.reminderIdentity.id, "local")
        XCTAssertTrue(a.reminderIdentity.persistent)
        XCTAssertFalse(none.reminderIdentity.persistent, "没有任何稳定身份：不持久化")
        let item = HistoryItem(seq: 1, uuid: "rj-1", text: "rejected:x", kind: "text", replyTo: "k")
        a.history = [item]
        a.openReminders()
        XCTAssertEqual(a.unreadReminderCount, 0)
        b.history = [item]
        XCTAssertEqual(b.unreadReminderCount, 1, "另一个没有 id 的账号不继承已读")
        none.history = [item]
        XCTAssertEqual(none.unreadReminderCount, 1)
    }
}
