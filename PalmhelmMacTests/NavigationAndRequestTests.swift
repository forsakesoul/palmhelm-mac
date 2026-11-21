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

private func approval(_ id: String, kind: String? = nil, label: String = "P", summary: String = "ls", attribution: String? = "exact", expiresInMs: Int = 600_000, truncated: Bool = false) -> ApprovalView {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    var a = ApprovalView(id: id, status: "pending", targetLabel: label, attribution: attribution, toolName: "Bash", summary: summary, truncated: truncated, createdT: now - 1000, expiresT: now + expiresInMs)
    a.kind = kind
    return a
}

private func questions(_ text: String = "选哪个？") -> [ProjectedQuestion] {
    decode(#"[{"header":"h","question":"\#(text)","multiSelect":false,"options":[{"label":"甲","description":"","selectable":true},{"label":"乙","description":"","selectable":true}]}]"#)
}

private func detail(_ a: ApprovalView, status: String = "pending", expiresInMs: Int = 600_000, qs: [ProjectedQuestion]? = nil) -> ApprovalDetail {
    var v = a; v.status = status; v.expiresT = Int(Date().timeIntervalSince1970 * 1000) + expiresInMs
    let viewData = try! JSONEncoder().encode(v)
    let body = qs.map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! }.map { #"{"questions":\#($0)}"# } ?? "null"
    return decode(#"{"view":\#(String(data: viewData, encoding: .utf8)!),"body":\#(body)}"#)
}

/// 导航意图（D6）、请求草稿与提交前复核（D4）、收件箱数据与自绘分段规则：走真实 MacSession 调用。
@MainActor
final class NavigationAndRequestTests: XCTestCase {
    // MARK: 构造

    private func state(bridge: String = "b1", binding: String? = "A") -> BridgeState {
        let b = binding.map { #","binding":{"targetId":"\#($0)","projectName":"P","agentName":"claude"}"# } ?? ""
        return decode(#"""
        {"bridge":{"id":"\#(bridge)"},"occupancy":"free","targets":[
          {"projectName":"P","id":"A","agentName":"claude","online":true,"status":"working"},
          {"projectName":"Q","id":"B","agentName":"codex","online":true,"status":"blocked"},
          {"projectName":"R","id":"C","agentName":"claude","online":true,"status":"idle"}],
         "history":{"highWater":0,"items":[]}\#(b)}
        """#)
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

    private func answered(_ s: MacSession, _ a: ApprovalView) -> QuestionDraft {
        var d = QuestionDraft(questions())
        d.toggle(question: 0, option: 0)
        s.setQuestionDraft(d, for: a)
        return d
    }

    // MARK: D6 导航意图

    func testAToBToAEachNewIntentSupersedesThePendingOne() {
        let s = session()
        s.openThread("B")
        let first = s.pendingNav
        XCTAssertEqual(first?.destination, .thread("B"))
        s.openThread("C")
        XCTAssertEqual(s.pendingNav?.destination, .thread("C"), "后来的意图使旧的作废")
        XCTAssertGreaterThan(s.pendingNav!.serial, first!.serial)
        s.openThread("A")
        XCTAssertEqual(s.selectedTarget, "A")
        XCTAssertEqual(s.consumeNav()?.destination, .thread("A"))
        XCTAssertNil(s.consumeNav(), "只消费一次")
    }

    func testOfflineDoesNotOpenThreadButExplainsAndGoesToInbox() {
        let s = session()
        s.link = .offline("x")
        s.openThread("B")
        XCTAssertEqual(s.selectedTarget, "A", "不直接打开线程")
        XCTAssertEqual(s.pendingNav?.destination, .inbox)
        XCTAssertNotNil(s.navNotice)
        XCTAssertEqual(s.lens, .inbox)
    }

    func testRemovedTargetExplainsInsteadOfStayingOnTheOldThread() {
        let s = session()
        s.openThread("ZZ")
        XCTAssertEqual(s.pendingNav?.destination, .inbox)
        XCTAssertTrue(s.navNotice?.text.contains("不在") == true)
        XCTAssertNil(s.selectedRequest)
    }

    func testRequestIntentSelectsCardAndSurvivesUntilTheWindowAppears() async {
        let s = session()
        let a = approval("r1", kind: "question")
        s.approvals["r1"] = a
        await s.openRequest("r1")
        XCTAssertEqual(s.selectedRequest, "r1")
        XCTAssertEqual(s.lens, .inbox)
        XCTAssertEqual(s.pendingNav?.destination, .request("r1"), "主窗口还没出现：意图留在 Session（冷启动 / 关闭后重开都能消费）")
        // 窗口重开前又来了新意图：旧的待消费 card 被清掉
        s.openThread("B")
        XCTAssertNil(s.selectedRequest)
        XCTAssertEqual(s.consumeNav()?.destination, .thread("B"))
    }

    func testExpiredOrGoneRequestGivesNoticeNotAStaleThread() async {
        let s = session()
        s.approvals["old"] = approval("old", expiresInMs: -1000)
        await s.openRequest("old")
        XCTAssertNil(s.selectedRequest)
        XCTAssertEqual(s.pendingNav?.destination, .inbox)
        XCTAssertNotNil(s.navNotice)
        await s.openRequest("never-existed")
        XCTAssertNil(s.selectedRequest)
    }

    func testOfflineRequestIntentGoesToInboxWithNotice() async {
        let s = session()
        s.approvals["r1"] = approval("r1")
        s.link = .offline("x")
        await s.openRequest("r1")
        XCTAssertNil(s.selectedRequest)
        XCTAssertEqual(s.pendingNav?.destination, .inbox)
        XCTAssertNotNil(s.navNotice)
    }

    func testLateRequestIntentIsDroppedWhenANewerIntentArrivedDuringTheRefresh() async {
        let s = session()
        let gate = Gate()
        let fresh = approval("late", kind: "plan")
        s.approvalsListOverride = { await gate.wait(); return [fresh] }
        let opening = Task { @MainActor in await s.openRequest("late") } // 卡还没在本地：先补拉权威列表，挂起
        for _ in 0..<50 { await Task.yield() }
        s.openThread("B") // 期间用户点了别的目标
        await gate.release()
        await opening.value
        XCTAssertNil(s.selectedRequest, "旧意图作废：不再改导航")
        XCTAssertEqual(s.pendingNav?.destination, .thread("B"))
        XCTAssertEqual(s.selectedTarget, "B")
    }

    func testRequestIntentIsDroppedWhenTheConnectionGenerationChanges() async {
        let s = session()
        let gate = Gate()
        s.approvalsListOverride = { await gate.wait(); return [approval("late")] }
        let opening = Task { @MainActor in await s.openRequest("late") }
        for _ in 0..<50 { await Task.yield() }
        s.disconnect(reason: "断开") // 连接代次变化
        await gate.release()
        await opening.value
        XCTAssertNil(s.selectedRequest)
    }

    func testSelectTargetFromTheUserIsANewIntentAndLeavesRequestDetail() async {
        let s = session()
        s.approvals["r1"] = approval("r1", kind: "plan")
        await s.openRequest("r1")
        s.selectTarget("C")
        XCTAssertNil(s.selectedRequest)
        XCTAssertNil(s.pendingNav, "用户自己点选：旧的待消费意图作废")
    }

    func testActiveRequestBecomesNilWhenTheCardIsGone() async {
        let s = session()
        let a = approval("r1", kind: "question")
        s.approvals["r1"] = a
        await s.openRequest("r1")
        XCTAssertEqual(s.activeRequest?.id, "r1")
        s.approvals["r1"]?.status = "decided"
        XCTAssertNil(s.activeRequest, "卡没了：详情改显示卡外反馈，不再显示旧卡")
    }

    // MARK: B-01 铃铛定位（侧栏已开时点铃铛必须有可观察的定位 / 高亮）

    func testBellWithPendingLocatesTheFirstRequestAndPulsesEveryClick() async {
        let s = session()
        s.approvals["late"] = approval("late", kind: "question", expiresInMs: 900_000)
        s.approvals["soon"] = approval("soon", kind: "plan", expiresInMs: 100_000) // 到期最紧 = 第一条
        XCTAssertNil(s.inboxFocus)
        await s.bellTapped()
        XCTAssertEqual(s.selectedRequest, "soon", "走现有 openRequest 意图定位到第一条待处理卡")
        XCTAssertEqual(s.inboxFocus?.target, .request("soon"))
        let first = s.inboxFocus!.serial
        await s.bellTapped() // 目标没变（selectedRequest 仍是 soon）：再点也要有新的脉冲，否则侧栏已开时「什么都不发生」
        XCTAssertEqual(s.inboxFocus?.target, .request("soon"))
        XCTAssertGreaterThan(s.inboxFocus!.serial, first)
    }

    func testBellWithoutPendingGoesToInboxTopAndHighlightsIt() async {
        let s = session()
        s.selectedRequest = nil
        let said = Box<[String]>([])
        s.announcer = { said.value.append($0) }
        await s.bellTapped()
        XCTAssertEqual(said.value, ["没有需要你处理的请求"], "没有待答：明确的一句提示，VoiceOver 播报同一句话")
        XCTAssertEqual(MacSession.noPendingText, "没有需要你处理的请求")
        XCTAssertEqual(MacSession.flashSeconds.top, 2.0, "约 2 秒后淡出")
        XCTAssertEqual(s.pendingNav?.destination, .inbox)
        XCTAssertEqual(s.lens, .inbox)
        XCTAssertEqual(s.inboxFocus?.target, .top)
        let first = s.inboxFocus!.serial
        await s.bellTapped()
        XCTAssertGreaterThan(s.inboxFocus!.serial, first, "没有待答时每次点击也有可观察的高亮")
    }

    func testBellFallsBackToTopWhenTheRequestCannotBeOpened() async {
        let s = session()
        s.approvals["r1"] = approval("r1", kind: "question")
        s.link = .offline("x") // openRequest 离线：给说明、转收件箱，不选中请求
        let said = Box<[String]>([])
        s.announcer = { said.value.append($0) }
        await s.bellTapped()
        XCTAssertNil(s.selectedRequest)
        XCTAssertEqual(s.inboxFocus?.target, .top)
        XCTAssertNotNil(s.navNotice)
        XCTAssertTrue(said.value.isEmpty, "其实有待答（只是没能打开）：不能播报「没有需要你处理的请求」")
    }

    func testBellRevealsACollapsedSidebarButLeavesAnOpenOneOpen() {
        var st = SidebarState()
        st.reveal(narrow: false) // 已开：保持开着（真正的反应由定位脉冲给出）
        XCTAssertTrue(st.shown(narrow: false))
        var narrow = SidebarState()
        XCTAssertFalse(narrow.shown(narrow: true))
        narrow.reveal(narrow: true) // 窄窗收起：先展开
        XCTAssertTrue(narrow.shown(narrow: true))
        var collapsed = SidebarState(); collapsed.toggle(narrow: false)
        collapsed.reveal(narrow: false)
        XCTAssertTrue(collapsed.shown(narrow: false), "宽窗用户收起了：铃铛先展开再定位")
    }

    // MARK: 收件箱数据

    func testInboxModelOrdersRequestsAndKeepsBlockedWithoutReliableCardVisible() {
        let targets = state().targets
        let r1 = approval("r1", label: "Q", expiresInMs: 900_000) // Q 项目 exact → B 有可靠卡
        let r2 = approval("r2", label: "P", expiresInMs: 100_000)
        let m = InboxModel.build(approvals: [r1, r2], targets: targets, pinned: { _ in false }, lastActivity: { _ in 0 })
        XCTAssertEqual(m.requests.map(\.id), ["r2", "r1"], "按到期时间，最紧的在前")
        XCTAssertTrue(m.blockedWithoutCard.isEmpty, "B 是 blocked 但有 exact 归属的卡")
        XCTAssertEqual(m.working, ["A"])
        // 候选归属不算「有卡」：B 仍标需到终端处理
        let cand = approval("r3", label: "候选：Q", attribution: "candidate")
        let m2 = InboxModel.build(approvals: [cand], targets: targets, pinned: { _ in false }, lastActivity: { _ in 0 })
        XCTAssertEqual(m2.blockedWithoutCard, ["B"])
        XCTAssertEqual(m2.needsYouCount, 2)
    }

    func testInboxModelSameNameProjectsDoNotCountAsAReliableCard() {
        var ts = state().targets
        ts.append(TargetSummary(projectName: "Q", online: true, targetId: "B2", agentName: "claude", status: "blocked"))
        let r = approval("r1", label: "Q")
        let m = InboxModel.build(approvals: [r], targets: ts, pinned: { _ in false }, lastActivity: { _ in 0 })
        XCTAssertEqual(Set(m.blockedWithoutCard), ["B", "B2"], "项目名不唯一：不能把这张卡算给其中一个")
    }

    func testInboxModelWorkingPinnedFirstThenRecent() {
        let ts: [TargetSummary] = [
            TargetSummary(projectName: "P1", online: true, targetId: "a", status: "working"),
            TargetSummary(projectName: "P2", online: true, targetId: "b", status: "working"),
            TargetSummary(projectName: "P3", online: true, targetId: "c", status: "working"),
        ]
        let m = InboxModel.build(approvals: [], targets: ts, pinned: { $0 == "c" }, lastActivity: { ["a": 1, "b": 9, "c": 0][$0] ?? 0 })
        XCTAssertEqual(m.working, ["c", "b", "a"])
        XCTAssertFalse(m.isEmpty)
        XCTAssertTrue(InboxModel.build(approvals: [], targets: [], pinned: { _ in false }, lastActivity: { _ in 0 }).isEmpty, "空态：暂时无需处理")
    }

    func testRequestPlacementShortApprovalInlineOthersToDetail() {
        XCTAssertEqual(RequestPlacement.of(approval("a", summary: "pnpm test")), .inline)
        XCTAssertEqual(RequestPlacement.of(approval("a", summary: String(repeating: "x", count: 101))), .detail)
        XCTAssertEqual(RequestPlacement.of(approval("a", summary: "a\nb")), .detail)
        XCTAssertEqual(RequestPlacement.of(approval("a", truncated: true)), .detail)
        XCTAssertEqual(RequestPlacement.of(approval("a", kind: "question")), .detail)
        XCTAssertEqual(RequestPlacement.of(approval("a", kind: "plan")), .detail)
    }

    // MARK: 自绘分段规则

    func testSegmentedGeometryIsFixedAndKeyboardMovesClamp() {
        XCTAssertEqual(SegmentedRules.indicatorOffset(index: 0, segmentWidth: 64), 0)
        XCTAssertEqual(SegmentedRules.indicatorOffset(index: 1, segmentWidth: 64), 64)
        XCTAssertEqual(SegmentedRules.moved(from: 0, count: 2, by: -1), 0)
        XCTAssertEqual(SegmentedRules.moved(from: 0, count: 2, by: 1), 1)
        XCTAssertEqual(SegmentedRules.moved(from: 1, count: 2, by: 1), 1)
        XCTAssertFalse(SegmentedRules.animates(reduceMotion: true), "减弱动态效果：选中底直接跳变")
        XCTAssertEqual(SegmentedRules.focusInteractions, .activate, "只在键盘导航时可聚焦：点击不抢焦点")
        XCTAssertTrue(SegmentedRules.animates(reduceMotion: false))
    }

    // MARK: D4 请求草稿

    func testQuestionDraftSurvivesThreadSwitchAndIsIsolatedPerConnection() {
        let s = session()
        let a = approval("q1", kind: "question")
        s.approvals["q1"] = a
        let d = answered(s, a)
        s.selectTarget("B"); s.selectTarget("A")
        XCTAssertEqual(s.questionDraft(a), d, "切线程不丢")
        s.state = state(bridge: "other")
        XCTAssertNil(s.questionDraft(a), "别的连接身份不共用草稿")
        s.state = state(bridge: "b1")
        XCTAssertEqual(s.questionDraft(a), d)
    }

    func testReasonsAreKeptPerRequestAndPrunedWhenTheCardIsGone() {
        let s = session()
        let a = approval("p1", kind: "plan"), b = approval("p2", kind: "plan")
        s.approvals["p1"] = a; s.approvals["p2"] = b
        s.setReason("理由一", a, .planRevise)
        s.setReason("拒绝理由", b, .approvalDeny)
        XCTAssertEqual(s.reason(a, .planRevise), "理由一")
        XCTAssertEqual(s.reason(b, .planRevise), "", "不串请求 / 不串种类")
        s.approvals["p1"]?.status = "decided"
        s.pruneRequestDrafts()
        XCTAssertEqual(s.reason(a, .planRevise), "")
        XCTAssertEqual(s.reason(b, .approvalDeny), "拒绝理由")
    }

    func testLateLoadCannotWriteADraftForARequestThatNoLongerExists() {
        let s = session()
        let ghost = approval("gone", kind: "question")
        s.setQuestionDraft(QuestionDraft(questions()), for: ghost)
        XCTAssertNil(s.questionDraft(ghost))
        s.setReason("x", ghost, .planRevise)
        XCTAssertEqual(s.reason(ghost, .planRevise), "")
    }

    // MARK: D4 提交前复核

    private func submitCase(_ s: MacSession, _ a: ApprovalView) async -> MacSession.RequestSubmit {
        await s.submitQuestion(a, answered(s, a))
    }

    func testSubmitQuestionSucceedsAfterRecheckAndKeepsNothingStale() async {
        let s = session()
        let a = approval("q1", kind: "question"); s.approvals["q1"] = a
        s.approvalDetailOverride = { _ in detail(a, qs: questions()) }
        let calls = Box<[String]>([])
        s.pendingCallOverride = { op in calls.value.append(op); return decode(#"{"status":"decided"}"#) }
        let r = await submitCase(s, a)
        XCTAssertEqual(r, .submitted)
        XCTAssertEqual(calls.value, ["answer"])
    }

    func testSubmitQuestionKeepsDraftAndSendsNothingWhenOfflineReadonlyExpiredOrMissing() async {
        let s = session()
        let a = approval("q1", kind: "question"); s.approvals["q1"] = a
        let calls = Box(0)
        s.pendingCallOverride = { _ in calls.value += 1; return decode(#"{"status":"decided"}"#) }
        s.approvalDetailOverride = { _ in detail(a, qs: questions()) }
        // 离线
        s.link = .offline("x")
        if case .kept = await submitCase(s, a) {} else { XCTFail("离线应保留") }
        s.link = .connected
        // 只读
        let ro: DeviceInfo = decode(#"{"id":"d","name":"mac","paused":false,"permission":"readonly"}"#)
        s.device = ro
        // 复核会重新拉权威 state（含设备权限）：权威 state 说只读，就以它为准
        var roState = state(); roState.device = ro
        let roSnapshot = roState
        s.stateOverride = { roSnapshot }
        if case .kept = await submitCase(s, a) {} else { XCTFail("只读应保留") }
        s.stateOverride = { [unowned s] in await MainActor.run { s.state ?? BridgeState.empty } }
        s.state = state() // 权威 state 里的只读设备信息要一并清掉，否则后面各例都是被只读拦下，测不到真正的复核
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        // 已处理 / 过期
        s.approvalDetailOverride = { _ in detail(a, status: "decided", qs: questions()) }
        if case .kept = await submitCase(s, a) {} else { XCTFail("已处理应保留") }
        s.approvalDetailOverride = { _ in detail(a, expiresInMs: -5, qs: questions()) }
        if case .kept = await submitCase(s, a) {} else { XCTFail("过期应保留") }
        // 没取到
        s.approvalDetailOverride = { _ in nil }
        if case .kept = await submitCase(s, a) {} else { XCTFail("取不到应保留，不伪造") }
        XCTAssertEqual(calls.value, 0, "全程零提交")
        XCTAssertNotNil(s.questionDraft(a), "草稿一直保留，不自动重放")
    }

    func testSubmitQuestionReportsChangedQuestionsInsteadOfApplyingOldAnswers() async {
        let s = session()
        let a = approval("q1", kind: "question"); s.approvals["q1"] = a
        let newQs = questions("换了一道题？")
        s.approvalDetailOverride = { _ in detail(a, qs: newQs) }
        let calls = Box(0)
        s.pendingCallOverride = { _ in calls.value += 1; return decode(#"{"status":"decided"}"#) }
        let r = await submitCase(s, a)
        XCTAssertEqual(r, .changed(newQs))
        XCTAssertEqual(calls.value, 0)
    }

    func testSubmitIsSingleFlightPerRequest() async {
        let s = session()
        let a = approval("q1", kind: "question"); s.approvals["q1"] = a
        let gate = Gate()
        s.approvalDetailOverride = { _ in await gate.wait(); return detail(a, qs: questions()) }
        let calls = Box(0)
        s.pendingCallOverride = { _ in calls.value += 1; return decode(#"{"status":"decided"}"#) }
        let d = answered(s, a)
        let first = Task { @MainActor in await s.submitQuestion(a, d) }
        for _ in 0..<50 { await Task.yield() }
        let second = await s.submitQuestion(a, d)
        XCTAssertEqual(second, .busy, "同一请求同时只跑一次（卡重建也不会重复提交）")
        await gate.release()
        let r = await first.value
        XCTAssertEqual(r, .submitted)
        XCTAssertEqual(calls.value, 1)
    }

    func testConnectionChangingDuringRecheckKeepsDraftAndDoesNotSubmit() async {
        let s = session()
        let a = approval("q1", kind: "question"); s.approvals["q1"] = a
        let gate = Gate()
        s.approvalDetailOverride = { _ in await gate.wait(); return detail(a, qs: questions()) }
        let calls = Box(0)
        s.pendingCallOverride = { _ in calls.value += 1; return decode(#"{"status":"decided"}"#) }
        let d = answered(s, a)
        let task = Task { @MainActor in await s.submitQuestion(a, d) }
        for _ in 0..<50 { await Task.yield() }
        s.state = state(bridge: "other") // 复核期间换了连接身份
        await gate.release()
        let r = await task.value
        if case .kept = r {} else { XCTFail("连接变了应保留：\(r)") }
        XCTAssertEqual(calls.value, 0)
        s.state = state(bridge: "b1")
        XCTAssertNotNil(s.questionDraft(a), "草稿还在原连接身份下")
    }

    func testFailedSubmitKeepsDraftAndReportsReason() async {
        let s = session()
        let a = approval("q1", kind: "question"); s.approvals["q1"] = a
        s.approvalDetailOverride = { _ in detail(a, qs: questions()) }
        s.pendingCallOverride = { _ in throw URLError(.notConnectedToInternet) }
        let r = await submitCase(s, a)
        if case .kept = r {} else { XCTFail("提交失败应保留：\(r)") }
        XCTAssertNotNil(s.questionDraft(a))
        XCTAssertNotNil(s.decideError["q1"])
    }

    func testPlanReviseIsRecheckedToo() async {
        let s = session()
        let a = approval("p1", kind: "plan"); s.approvals["p1"] = a
        let calls = Box<[String]>([])
        s.pendingCallOverride = { op in calls.value.append(op); return decode(#"{"status":"revised"}"#) }
        s.approvalDetailOverride = { _ in detail(a, status: "decided") }
        if case .kept = await s.submitRevise(a, message: "改一下") {} else { XCTFail("已处理的计划不再打回") }
        XCTAssertTrue(calls.value.isEmpty)
        s.approvalDetailOverride = { _ in detail(a) }
        let r = await s.submitRevise(a, message: "改一下")
        XCTAssertEqual(r, .submitted)
        XCTAssertEqual(calls.value, ["revise"])
        let tooLong = String(repeating: "长", count: ApprovalMessage.maxUTF16 + 1)
        if case .kept = await s.submitRevise(a, message: tooLong) {} else { XCTFail("超长理由不提交") }
    }

    func testForgetClearsRequestDraftsAndNavigation() async {
        let s = session()
        let a = approval("q1", kind: "question"); s.approvals["q1"] = a
        _ = answered(s, a)
        s.setReason("x", a, .planRevise)
        await s.openRequest("q1")
        s.forget()
        XCTAssertTrue(s.questionDrafts.isEmpty)
        XCTAssertTrue(s.requestReasons.isEmpty)
        XCTAssertNil(s.selectedRequest)
        XCTAssertNil(s.pendingNav)
    }

    // MARK: 附件来源随发送快照保留（D5）

    func testSendSnapshotCarriesAttachmentSources() async {
        let s = session()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("src2-\(UUID().uuidString).png")
        try! FileManager.default.copyItem(at: url, to: url2)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url2) }
        let img = NSImage(contentsOf: url)!
        var d = MacSession.ComposerDraft()
        d.attachments = [ComposerAttachment(path: url.path, thumbnail: img, source: .userReference), ComposerAttachment(path: url2.path, thumbnail: img, source: .cachedBitmap)]
        s.setDraft(d, for: "A")
        s.sendOverride = { _, _ in throw URLError(.timedOut) } // 失败：快照留在 Sent 里
        _ = await s.submitComposer(threadId: "A", agent: nil)
        let m = s.sent.last!
        XCTAssertEqual(m.attachmentSources, [.userReference, .cachedBitmap])
        XCTAssertTrue(s.draft("A").attachments.isEmpty, "失败已入账：输入框清空，附件与来源留在失败记录里供重试")
    }
}
