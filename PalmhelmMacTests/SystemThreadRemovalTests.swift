import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// 系统线程撤掉后的去向、线程内操作归属、目标切换、会话持有的草稿与未归属恢复：都走真实的 MacSession 调用（传输与 state 用测试接缝）。
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

@MainActor
final class SystemThreadRemovalTests: XCTestCase {
    // MARK: 构造

    private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }

    private func state(binding: (id: String, project: String, agent: String?)? = nil, bridge: String = "b1") -> BridgeState {
        let b = binding.map { #","binding":{"targetId":"\#($0.id)","projectName":"\#($0.project)"\#($0.agent.map { #","agentName":"\#($0)""# } ?? "")}"# } ?? ""
        return decode(#"""
        {"bridge":{"id":"\#(bridge)"},"occupancy":"free","targets":[
          {"projectName":"P","id":"A","agentName":"claude","online":true},
          {"projectName":"P","id":"B","agentName":"codex","online":true},
          {"projectName":"Q","id":"C","agentName":"claude","online":true}],
         "history":{"highWater":0,"items":[]}\#(b)}
        """#)
    }

    private func receipt(_ key: String?) -> MessageReceipt { decode(#"{"received":true\#(key.map { #","eventKey":"\#($0)""# } ?? "")}"#) }

    private func session(binding: (id: String, project: String, agent: String?)? = ("A", "P", "claude"),
                         send: (@Sendable (String, UUID) async throws -> MessageReceipt)? = nil) -> MacSession {
        let s = MacSession()
        s.reminderLedger = ReminderLedger() // 不继承上次运行留下的已读
        var st = state(binding: binding)
        st.currentBlocked = [CurrentBlocked(targetId: "A", eventKey: "evA", blockedSince: 1)]; st.currentBlockedFresh = true // 提醒是该目标当前正阻塞的那条
        s.applyStateSnapshot(st)
        s.link = .connected
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        s.sendOverride = send ?? { _, id in MessageReceipt.stub("ek-\(id.uuidString.prefix(6))") }
        s.stateOverride = { [unowned s] in await MainActor.run { s.state ?? BridgeState.empty } }
        s.selectTarget("A")
        return s
    }

    /// 提醒的 72 小时窗口按真实时钟计：测试时间轴以当前时间为基准（相对先后不变）。
    private var T0: Int { Int(Date().timeIntervalSince1970 * 1000) - 10_000 }
    private func item(_ seq: Int, _ text: String, replyTo: String? = nil, target: String? = nil, uuid: String? = nil, t: Int? = nil) -> HistoryItem {
        HistoryItem(seq: seq, uuid: uuid ?? "u\(seq)", text: text, kind: "text", replyTo: replyTo,
                    target: target.map { TargetRef(id: $0, projectName: "P") }, t: t)
    }

    // MARK: 无目标条目的去向

    func testNoTargetReceiptsGoToThreeDestinations() {
        let s = session()
        s.history = [
            item(1, "ack:已收到"), item(2, "switched:P"), item(3, "queued:1"),                  // 纯回执：不展示
            item(4, "rejected:target_not_verified 未找到目标"),                                  // 失败：提醒区
            item(5, "[P] 等待已超过 10 分钟", uuid: "nblocked2:x", t: T0 + 5),                              // 超时提醒：带重置操作
        ]
        XCTAssertEqual(s.inboxAlerts.count, 1)
        XCTAssertTrue(s.inboxAlerts[0].text.contains("未找到目标"))
        XCTAssertEqual(s.blockedReminders.map(\.seq), [5])
        XCTAssertTrue(s.threads.isEmpty, "无目标回执不再产生任何线程")
        XCTAssertEqual(s.history.count, 5, "原始 history 保留")
    }

    func testThreadListHasNoSystemThread() {
        let s = session()
        s.history = [item(1, "ack:已收到"), item(2, "来自 A 的回执", target: "A")]
        XCTAssertEqual(s.threads.map(\.id), ["A"])
        XCTAssertEqual(s.threads(for: "A").map(\.id), ["A"])
        XCTAssertTrue(s.threads(for: nil).isEmpty)
    }

    func testLegacySystemSelectionFallsBackWithoutBlank() {
        let s = session()
        s.selectedThread = MacSession.legacySystemThread
        XCTAssertEqual(s.selectedThread, "A")
        s.selectedTarget = nil
        s.selectedThread = MacSession.legacySystemThread
        XCTAssertNil(s.selectedThread, "没有目标时回到空态而不是留着旧编号")
    }

    func testRejectionAfterAcceptGoesToAlertsWhenNoThreadHostsIt() async {
        let s = session()
        let id = await s.sendTracked("面板")
        XCTAssertNotNil(id)
        let key = s.sent.last?.eventKey
        XCTAssertNotNil(key)
        XCTAssertTrue(s.inboxAlerts.isEmpty)
        s.history = [item(1, "rejected:target_not_verified x", replyTo: key)]
        XCTAssertEqual(s.inboxAlerts.count, 1, "受理之后才被拒：进提醒区")
    }

    func testRejectionWithoutSentAlsoGoesToAlerts() {
        let s = session()
        s.history = [item(1, "rejected:target_not_verified 没有对应的发送", replyTo: "other")]
        XCTAssertEqual(s.inboxAlerts.count, 1)
    }

    func testThreadHostedRejectionIsNotDuplicatedInAlerts() async {
        let s = session()
        await s.send("面板", inThread: "A")
        let key = s.sent.last?.eventKey
        s.history = [item(1, "rejected:target_not_verified x", replyTo: key)]
        XCTAssertTrue(s.inboxAlerts.isEmpty, "已在线程里可见，不重复进提醒")
        XCTAssertEqual(ThreadRow.withRejections(s.sent, history: s.history).filter { $0.targetId == "A" }.compactMap(\.error).count, 1)
    }

    func testNoTargetNetworkFailureGoesToAlertsWithRestoreEntry() async {
        let s = session { _, _ in throw URLError(.notConnectedToInternet) }
        let id = await s.sendTracked("重置占用 P")
        XCTAssertNotNil(id)
        XCTAssertEqual(s.inboxAlerts.count, 1)
        XCTAssertNil(s.inboxAlerts[0].restoreSendId, "没有输入快照就没有恢复入口")
        XCTAssertNotNil(s.outcome(of: id!)?.error)
    }

    // MARK: 回执收集 / 归属

    func testOutcomeCollectsShardsAndIsolatesByReplyTo() async {
        let s = session()
        let a = await s.send("面板", inThread: "A")!
        let b = await s.send("任务", inThread: "A")!
        let ka = s.sent.first { $0.id == a }!.eventKey!, kb = s.sent.first { $0.id == b }!.eventKey!
        s.history = [item(3, "面板 第二片", replyTo: ka), item(1, "面板 第一片", replyTo: ka), item(2, "任务 全文", replyTo: kb), item(4, "无关", replyTo: "zzz")]
        XCTAssertEqual(s.outcome(of: a)?.reply, "面板 第一片\n面板 第二片")
        XCTAssertEqual(s.outcome(of: b)?.reply, "任务 全文")
        s.history.append(item(5, "面板 迟到的第三片", replyTo: ka))
        XCTAssertEqual(s.outcome(of: a)?.reply, "面板 第一片\n面板 第二片\n面板 迟到的第三片", "迟到的分片补上")
    }

    // A1-011：native 投递 ack 与气泡状态行同义，按精确 key 身份过滤；有效状态不覆盖时仍显示，面板 / 任务分片按 seq 保留。
    func testNativeDeliveryAckIsHiddenOnlyWhenTheStatusLineCoversIt() async {
        let s = session()
        let a = await s.send("插话", inThread: "A")!
        let k = s.sent.first { $0.id == a }!.eventKey!
        s.history = [item(1, "已送达工作中终端，尚未确认并入本轮。", replyTo: k, uuid: "ack:" + k), item(2, "面板片一", replyTo: k), item(3, "别的回执", replyTo: "zzz", uuid: "ack:zzz")]
        XCTAssertEqual(s.outcome(of: a)?.reply, "已送达工作中终端，尚未确认并入本轮。\n面板片一", "默认语义不变")
        XCTAssertEqual(s.outcome(of: a, statusPhase: .nativeDelivered)?.reply, "面板片一")
        XCTAssertEqual(s.outcome(of: a, statusPhase: .queued)?.reply, "已送达工作中终端，尚未确认并入本轮。\n面板片一")
        s.history.removeAll { $0.seq == 2 }
        XCTAssertNil(s.outcome(of: a, statusPhase: .nativeDelivered)?.reply)
    }

    func testThreadOperationAttributedToOriginatingThread() async {
        let s = session()
        let id = await s.send("面板", inThread: "B")!
        XCTAssertEqual(s.sent.first { $0.id == id }?.targetId, "B")
        let key = s.sent.first { $0.id == id }!.eventKey!
        s.history = [item(1, "面板正文", replyTo: key)]                                          // 回执不带目标
        XCTAssertEqual(s.threadHistory("B").map(\.seq), [1])
        XCTAssertTrue(s.threadHistory("A").isEmpty)
        XCTAssertFalse(s.threads.contains { $0.id == "A" && $0.count > 0 })
    }

    func testSendBoolSemanticsKeepFailedDraft() async {
        let fail = Box(true)
        let s = session { _, _ in if fail.value { throw URLError(.timedOut) }; return MessageReceipt.stub("ok") }
        var d = MacSession.ComposerDraft(); d.text = "你好"
        s.setDraft(d, for: "A")
        let ok1 = await s.submitComposer(threadId: "A", agent: nil)
        XCTAssertFalse(ok1)
        XCTAssertEqual(s.draft("A").text, "", "失败已入账：输入框清空，草稿留在失败记录里供重试")
        XCTAssertEqual(s.sent.last?.draft, "你好")
        XCTAssertFalse(s.isComposerBusy("A"))
        fail.value = false
        let ok2 = await s.resendFailed(s.sent.last!, threadId: "A")
        XCTAssertTrue(ok2)
        XCTAssertTrue(s.draft("A").isEmpty)
        let okSend = await s.send("x")
        XCTAssertTrue(okSend, "Mac send 仍返回 Bool 成功")
    }

    // MARK: 目标切换

    func testSwitchConfirmsByExplicitIdentityNotProjectName() async {
        // 绑定在同项目的另一个 agent（B / codex）：想切到 A（claude）不能算成功
        let s = session(binding: ("B", "P", "codex"))
        await s.switchTo(project: "P", agent: "claude", targetId: "A", inThread: "A")
        if case .failed = s.switchState {} else { XCTFail("同项目另一个 agent 不应被当成功：\(s.switchState)") }
    }

    func testBindingConfirmsRules() {
        let b: PalmhelmKit.Binding = decode(#"{"targetId":"B","projectName":"P","agentName":"codex"}"#)
        XCTAssertTrue(MacSession.bindingConfirms(b, project: "P", agent: nil, targetId: "B"))
        XCTAssertFalse(MacSession.bindingConfirms(b, project: "P", agent: nil, targetId: "A"), "明确身份只比身份")
        XCTAssertFalse(MacSession.bindingConfirms(b, project: "P", agent: "claude", targetId: nil))
        XCTAssertTrue(MacSession.bindingConfirms(b, project: "P", agent: "codex", targetId: nil))
        XCTAssertTrue(MacSession.bindingConfirms(b, project: "P", agent: nil, targetId: nil))
        XCTAssertFalse(MacSession.bindingConfirms(nil, project: "P", agent: nil, targetId: "B"))
    }

    func testSwitchSuccessWhenBindingMatchesTarget() async {
        let s = session(binding: ("B", "P", "codex"))
        let target = Box<BridgeState?>(nil)
        target.value = state(binding: ("A", "P", "claude"))
        s.stateOverride = { target.value ?? BridgeState.empty }
        await s.switchTo(project: "P", agent: "claude", targetId: "A", inThread: "A")
        XCTAssertEqual(s.switchState, .idle)
        XCTAssertEqual(s.state?.binding?.targetId, "A")
    }

    func testMultiCandidatesLateAndSelectableAndNewOperationInvalidatesOld() async {
        let s = session(binding: ("B", "P", "codex"))
        // 受理但绑定没变；候选回执（多匹配）在发送之后才到
        let sw = Task { @MainActor in await s.switchTo(project: "P", agent: nil, targetId: nil, inThread: "A") }
        for _ in 0..<500 where s.switchTrack == nil { try? await Task.sleep(for: .milliseconds(2)) }
        let tr = s.switchTrack
        XCTAssertNotNil(tr)
        XCTAssertTrue(s.switchCandidates.isEmpty)
        let key = s.sent.first { $0.id == tr!.id }!.eventKey!
        s.history = [item(1, "\(OwnerCommand.rejectedNotVerified)：项目 P 匹配到 2 \(OwnerCommand.multiMatchMarker)claude、codex。", replyTo: key)]
        XCTAssertEqual(s.switchCandidates, ["claude", "codex"], "迟到的候选也能选")
        XCTAssertNotNil(s.switchOutcome(for: "A"))
        XCTAssertNil(s.switchOutcome(for: "B"), "结果只给发起线程")
        await sw.value
        XCTAssertEqual(s.switchState, .idle, "被拒回到 idle，原因与候选留着")
        // 新的操作作废旧候选
        let again = Task { @MainActor in await s.switchTo(project: "Q", agent: "claude", targetId: "C", inThread: "A") }
        for _ in 0..<500 where s.switchState != .pending { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(s.switchCandidates.isEmpty, "新操作开始即作废旧候选")
        again.cancel()
        await again.value
    }

    func testSwitchSingleFlightAndGuards() async {
        let s = session(binding: ("B", "P", "codex"))
        s.link = .offline("x")
        await s.switchTo(project: "P", agent: "claude", targetId: "A", inThread: "A")
        if case .failed = s.switchState {} else { XCTFail("离线应被守卫拦下") }
        XCTAssertTrue(s.sent.isEmpty, "被拦下不发送")
        s.link = .connected
        s.switchState = .idle
        s.device = decode(#"{"id":"d","name":"mac","paused":false,"permission":"readonly"}"#)
        await s.switchTo(project: "P", agent: "claude", targetId: "A", inThread: "A")
        XCTAssertTrue(s.sent.isEmpty, "只读设备被拦下")
        s.device = decode(#"{"id":"d","name":"mac","paused":true}"#)
        s.switchState = .idle
        await s.switchTo(project: "P", agent: "claude", targetId: "A", inThread: "A")
        XCTAssertTrue(s.sent.isEmpty, "暂停设备被拦下")
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        s.switchState = .pending
        await s.switchTo(project: "P", agent: "claude", targetId: "A", inThread: "A")
        XCTAssertTrue(s.sent.isEmpty, "单飞：进行中不再发第二条")
    }

    // MARK: 草稿

    func testDraftsSurviveThreadSwitchAndDoNotMixAcrossTargets() {
        let s = session()
        var d = MacSession.ComposerDraft(); d.text = "A 的草稿"
        s.setDraft(d, for: "A")
        s.selectTarget("B")
        XCTAssertTrue(s.draft("B").isEmpty, "不串目标")
        d.text = "B 的草稿"; s.setDraft(d, for: "B")
        s.selectTarget("A")
        XCTAssertEqual(s.draft("A").text, "A 的草稿", "切线程后草稿还在")
        XCTAssertEqual(s.draft("B").text, "B 的草稿")
    }

    func testDraftsKeyedByBridgeIdentity() {
        let s = session()
        var d = MacSession.ComposerDraft(); d.text = "x"
        s.setDraft(d, for: "A")
        s.state = state(binding: ("A", "P", "claude"), bridge: "other")
        XCTAssertTrue(s.draft("A").isEmpty, "别的 Bridge 的同名目标不共用草稿")
        s.state = state(binding: ("A", "P", "claude"), bridge: "b1")
        XCTAssertEqual(s.draft("A").text, "x")
    }

    func testForgetClearsDrafts() {
        let s = session()
        var d = MacSession.ComposerDraft(); d.text = "x"
        s.setDraft(d, for: "A")
        s.forget()
        XCTAssertTrue(s.composerDrafts.isEmpty)
    }

    func testRejectedRestoreAfterSettleAndBusyNotRestored() async {
        let s = session()
        var d = MacSession.ComposerDraft(); d.text = "要发的话"
        s.setDraft(d, for: "A")
        await s.submitComposer(threadId: "A", agent: nil)
        XCTAssertTrue(s.draft("A").isEmpty)
        let key = s.sent.last!.eventKey!
        XCTAssertNil(s.restorableSend(threadId: "A"), "还没被拒")
        s.history = [item(1, "rejected:target_not_verified x", replyTo: key, target: "A")]
        let m = s.restorableSend(threadId: "A")
        XCTAssertNotNil(m, "被拒后（收尾之后）可恢复")
        XCTAssertTrue(s.restoreRejected(m!, threadId: "A"))
        XCTAssertEqual(s.draft("A").text, "要发的话")
        XCTAssertNil(s.restorableSend(threadId: "A"), "恢复过不再重复")
    }

    // MARK: 未归属恢复

    private func legacyFailed(_ s: MacSession, draft: String = "旧系统线程里失败的话") {
        s.sent.append(MacSession.Sent(id: UUID(), text: draft, at: Date(), afterSeq: 0, targetId: nil, error: "无法连接", draft: draft))
    }

    func testUnattributedFailedSendHasExplicitRestoreAndNeverAutoInjected() {
        let s = session()
        legacyFailed(s)
        XCTAssertEqual(s.inboxAlerts.count, 1)
        let id = s.inboxAlerts[0].restoreSendId
        XCTAssertNotNil(id, "提醒上有显式的“恢复到输入框”入口")
        XCTAssertTrue(s.draft("A").isEmpty, "不会自动投进当前线程")
        XCTAssertNil(s.restoreUnattributed(id!))
        XCTAssertEqual(s.draft("A").text, "旧系统线程里失败的话", "只在点击后恢复到当时所选线程")
        XCTAssertTrue(s.inboxAlerts.isEmpty, "恢复成功：提醒立即移出（不等下次打开）")
        XCTAssertEqual(s.sent.count, 1, "快照（Sent）本身不删")
    }

    func testUnattributedRestoreDoesNotOverwriteExistingDraftOrBusy() {
        let s = session()
        legacyFailed(s)
        var d = MacSession.ComposerDraft(); d.text = "正在写"
        s.setDraft(d, for: "A")
        let id = s.inboxAlerts[0].restoreSendId!
        XCTAssertNotNil(s.restoreUnattributed(id), "有内容不覆盖，给出原因")
        XCTAssertEqual(s.draft("A").text, "正在写")
        XCTAssertNotNil(s.inboxAlerts[0].restoreSendId, "没恢复就不丢")
        s.selectedThread = nil; s.selectedTarget = nil
        XCTAssertNotNil(s.restoreUnattributed(id), "没有选中线程时不乱放")
    }
}

/// 挂起 sendOverride 用的闸门：release 之前发送停在传输里（真正的 busy / 在途窗口）。
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

@MainActor
extension SystemThreadRemovalTests {
    private func settleTurns() async { for _ in 0..<30 { await Task.yield() } }

    // MARK: F1 提醒按事件时间合并后取最近 8 条

    func testNewNetworkFailureSurvivesEightOlderRejections() {
        let s = session()
        s.history = (1...8).map { item($0, "rejected:target_not_verified 旧\($0)", replyTo: "old\($0)", t: T0 + $0) }
        legacyFailedAt(s, draft: "新失败里的话", ms: T0 + 5_000)
        let alerts = s.inboxAlerts
        XCTAssertEqual(alerts.count, 9, "可恢复项不占历史上限：8 条历史 + 1 条可恢复")
        XCTAssertTrue(alerts[0].text.hasPrefix("发送失败"), "最新的在最前")
        XCTAssertNotNil(alerts[0].restoreSendId, "恢复到输入框入口仍可见")
    }

    // A1-057 R1：上限只作用于历史项；可恢复的发送快照全部保留
    func testOldRecoverableFailureSurvivesEightNewerHistoryRejections() {
        let s = session()
        legacyFailedAt(s, draft: "很早、带草稿的失败", ms: T0 + 500)
        s.history = (1...8).map { item($0, "rejected:target_not_verified 新\($0)", replyTo: "r\($0)", t: T0 + 1_000 + $0) }
        let alerts = s.inboxAlerts
        XCTAssertEqual(alerts.filter { $0.restoreSendId != nil }.count, 1, "可恢复项仍在")
        XCTAssertEqual(alerts.filter { $0.restoreSendId == nil }.count, 8, "历史项仍只取最近 8 条")
        let id = alerts.first { $0.restoreSendId != nil }!.restoreSendId!
        XCTAssertNil(s.restoreUnattributed(id), "仍然能恢复到输入框")
        XCTAssertEqual(s.draft("A").text, "很早、带草稿的失败")
    }

    func testMoreThanEightRecoverableSnapshotsAreAllReachable() {
        let s = session()
        for i in 1...11 { legacyFailedAt(s, draft: "草稿\(i)", ms: T0 + i) }
        s.history = (1...3).map { item($0, "rejected:target_not_verified 历史\($0)", replyTo: "r\($0)", t: T0 + 2_000 + $0) }
        let alerts = s.inboxAlerts
        XCTAssertEqual(Set(alerts.compactMap(\.restoreSendId)).count, 11, "可恢复项自身超过 8 条也全部可达")
        XCTAssertEqual(alerts.count, 14)
        XCTAssertEqual(alerts.filter { $0.restoreSendId == nil }.count, 3)
    }

    func testSameSendIsListedOnceByItsSendId() async {
        let s = session()
        // 一次无目标发送：HTTP 受理后又被拒绝 → 同一 sendId 不重复
        s.sent.append(MacSession.Sent(id: UUID(), text: "x", at: Date(timeIntervalSince1970: TimeInterval(T0 + 1_000) / 1000), afterSeq: 0, targetId: nil, eventKey: "k1", error: "无法连接", draft: "草稿"))
        s.history = [item(1, "rejected:target_not_verified 同一次发送被拒", replyTo: "k1", t: T0 + 3_000)]
        let rec = s.inboxAlerts.filter { $0.restoreSendId != nil }
        XCTAssertEqual(rec.count, 1, "按 sendId 去重，取最新那条")
        XCTAssertTrue(rec[0].id.hasPrefix("rj:"))
    }

    func testHistoryRejectionsHaveNoCapAndHideOnceReadWithoutBackfill() {
        let s = session()
        s.history = (1...10).map { item($0, "rejected:target_not_verified 拒绝\($0)", replyTo: "r\($0)", t: T0 + 1_000 + $0) }
        s.reminderLedger = ReminderLedger()
        s.openReminders()
        XCTAssertEqual(s.inboxAlerts.count, 10, "没有展示上限：本次批次全部可见")
        XCTAssertTrue(s.inboxAlerts[0].text.contains("拒绝10"), "新 → 旧")
        s.closeReminders()
        XCTAssertTrue(s.inboxAlerts.isEmpty, "已读即隐藏，不按上限补位到 8 条")
        XCTAssertEqual(s.history.count, 10, "原始数据不删")
    }

    func testRejectionWithoutTimestampBorrowsItsSendTimeOrSortsOldest() async {
        let s = session()
        await s.sendTracked("面板")
        let key = s.sent.last!.eventKey!
        s.history = [item(1, "rejected:target_not_verified 有对应发送", replyTo: key), item(2, "rejected:target_not_verified 没有任何时间", replyTo: "x")]
        legacyFailedAt(s, draft: "失败", ms: T0 - 5_000) // 比谁都早，但有时间
        let texts = s.inboxAlerts.map(\.text)
        XCTAssertEqual(texts.count, 3)
        XCTAssertTrue(texts[0].contains("有对应发送"), "借发送时间：比 1ms 的失败新")
        XCTAssertTrue(texts.last!.contains("没有任何时间") || texts[1].hasPrefix("发送失败"))
    }

    private func legacyFailedAt(_ s: MacSession, draft: String, ms: Int) {
        s.sent.append(MacSession.Sent(id: UUID(), text: draft, at: Date(timeIntervalSince1970: Double(ms) / 1000), afterSeq: 0, targetId: nil, error: "无法连接", draft: draft))
    }

    // MARK: F2 提醒卡的本次发送放在 Session

    private var reminder: HistoryItem { item(7, "[P] 等待已超过 10 分钟", replyTo: "evA", target: "A", uuid: "nblocked2:r1") }

    func testReminderSendSurvivesCardRebuildAndLateShardsAttachToIt() async {
        let gate = Gate()
        let s = session { _, id in await gate.wait(); return MessageReceipt.stub("ek-\(id.uuidString.prefix(6))") }
        let card = reminder
        s.history = [card]
        let task = Task { @MainActor in await s.resetOccupancy(for: card, name: "P") }
        await settleTurns()
        XCTAssertTrue(s.reminderSend(card).busy, "发送挂起：在途状态在 Session")
        XCTAssertNil(s.reminderSend(card).sendId)
        // 卡重建（弹层 / 侧栏关闭重开）= 重新读 Session：状态仍在，且第二次点击不会重复发送
        XCTAssertTrue(s.reminderSend(card).busy)
        await s.resetOccupancy(for: card, name: "P")
        XCTAssertEqual(s.sent.count, 1, "同一张卡同时只发一次")
        await gate.release()
        await task.value
        let st = s.reminderSend(card)
        XCTAssertFalse(st.busy)
        let id = try! XCTUnwrap(st.sendId)
        XCTAssertNil(s.outcome(of: id)?.reply)
        let key = s.sent.first { $0.id == id }!.eventKey!
        s.history = [card, item(8, "已重置 P（第一片）", replyTo: key), item(9, "第二片", replyTo: key)]
        XCTAssertEqual(s.outcome(of: id)?.reply, "已重置 P（第一片）\n第二片", "迟到分片仍归原提醒")
        XCTAssertEqual(s.reminderSend(card).sendId, id)
    }

    func testReminderSendsAreIsolatedPerReminder() async {
        let s = session()
        let a = item(7, "[P] 超时", replyTo: "evA", target: "A", uuid: "nblocked2:a"), b = item(8, "[Q] 超时", uuid: "nblocked2:b")
        s.history = [a, b]
        await s.resetOccupancy(for: a, name: "P")
        XCTAssertNotNil(s.reminderSend(a).sendId)
        XCTAssertNil(s.reminderSend(b).sendId)
    }

    // MARK: F3 离线 / 暂停 / 变化：零发送 + 可见原因

    func testResetBlockedWhenOfflineOrPausedGivesReasonAndSendsNothing() async {
        let s = session()
        let card = reminder
        s.history = [card]
        s.link = .offline("x")
        XCTAssertNotNil(s.resetOccupancyBlocker(), "入口同步给原因")
        await s.resetOccupancy(for: card, name: "P")
        XCTAssertTrue(s.sent.isEmpty)
        XCTAssertNotNil(s.reminderSend(card).blocked)
        s.link = .connected
        s.device = decode(#"{"id":"d","name":"mac","paused":true}"#)
        XCTAssertNotNil(s.resetOccupancyBlocker())
        await s.resetOccupancy(for: card, name: "P")
        XCTAssertTrue(s.sent.isEmpty)
        XCTAssertTrue(s.reminderSend(card).blocked?.text.contains("暂停") == true)
    }

    func testConnectionOrPermissionChangingAfterConfirmationStillBlocksWithVisibleReason() async {
        let s = session()
        let card = reminder
        s.history = [card]
        XCTAssertNil(s.resetOccupancyBlocker(), "弹确认框时还是可发")
        s.device = decode(#"{"id":"d","name":"mac","paused":false,"permission":"readonly"}"#) // 确认框打开期间变只读
        await s.resetOccupancy(for: card, name: "P")
        XCTAssertTrue(s.sent.isEmpty)
        XCTAssertNotNil(s.reminderSend(card).blocked)
        // 成功后再次被拦：原因不残留成功结果之上的误导（新的拦截覆盖 blocked，但保留已有发送编号）
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        await s.resetOccupancy(for: card, name: "P")
        XCTAssertEqual(s.sent.count, 1)
        XCTAssertNil(s.reminderSend(card).blocked)
    }

    // MARK: busy 窗口（真的挂起发送）

    func testBusyWindowFreezesComposerAndBlocksRestoresUntilSettle() async {
        let gate = Gate()
        let s = session { _, id in await gate.wait(); return MessageReceipt.stub("ek-\(id.uuidString.prefix(6))") }
        var d = MacSession.ComposerDraft(); d.text = "在发的话"
        s.setDraft(d, for: "A")
        legacyFailedAt(s, draft: "旧快照", ms: T0 + 10)
        let task = Task { @MainActor in await s.submitComposer(threadId: "A", agent: nil) }
        await settleTurns()
        XCTAssertTrue(s.isComposerBusy("A"), "发送挂起：busy 真的成立")
        let second = await s.submitComposer(threadId: "A", agent: nil)
        XCTAssertFalse(second, "busy 时不重复发送")
        XCTAssertEqual(s.sent.count, 2, "只有旧快照 + 这一条在途")
        let id = s.inboxAlerts[0].restoreSendId!
        XCTAssertNotNil(s.restoreUnattributed(id), "busy 的输入框不恢复")
        let m = MacSession.Sent(id: UUID(), text: "r", at: Date(), afterSeq: 0, targetId: "A", eventKey: "k", draft: "被拒的话")
        XCTAssertFalse(s.restoreRejected(m, threadId: "A"), "busy 时恢复被拒发送是 no-op")
        XCTAssertEqual(s.draft("A").text, "在发的话")
        await gate.release()
        let ok = await task.value
        XCTAssertTrue(ok)
        XCTAssertFalse(s.isComposerBusy("A"))
        XCTAssertTrue(s.draft("A").isEmpty)
        XCTAssertNil(s.restoreUnattributed(id), "收尾后同一入口可恢复")
    }
}

extension MessageReceipt {
    static func stub(_ key: String?) -> MessageReceipt {
        try! JSONDecoder().decode(MessageReceipt.self, from: Data(#"{"received":true\#(key.map { #","eventKey":"\#($0)""# } ?? "")}"#.utf8))
    }
}

extension BridgeState {
    static var empty: BridgeState {
        try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#.utf8))
    }
}
