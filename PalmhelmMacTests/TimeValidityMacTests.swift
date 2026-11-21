import AppKit
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// 时间有效性（Mac，A1-010 §4.2 / §6.F）：待答过期与提醒 72 小时上限按边界调度，普通秒 / 分钟且集合不变时
// 待答 / 目录 / 刘海 / 提醒入口的读取者都不失效；回前台 / 唤醒 / 改时补算；到期后真实动作零传输。
private final class Fire: @unchecked Sendable { var n = 0 }

@MainActor
private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
    var ms: Int { get { Int(now.timeIntervalSince1970 * 1000) } set { now = Date(timeIntervalSince1970: Double(newValue) / 1000) } }
}

@MainActor
final class TimeValidityMacTests: XCTestCase {
    private let base = 1_900_000_000_000

    private func approval(_ id: String, expires: Int) -> ApprovalView {
        ApprovalView(id: id, status: "pending", targetLabel: "T", attribution: "exact", toolName: "Bash", summary: "x", createdT: base, expiresT: expires)
    }
    private func session(_ clock: Clock) -> MacSession {
        let s = MacSession()
        s.streamDisabled = true
        s.reminderLedger = ReminderLedger()
        s.dateProvider = { clock.now }
        return s
    }
    private func alertHistory(_ t: Int, n: Int = 1) -> HistoryItem {
        HistoryItem(seq: n, uuid: "rj-\(n)", text: "rejected:x", kind: "text", replyTo: "k\(n)", t: t)
    }
    private func settle() async { for _ in 0..<8 { await Task.yield() } }

    /// 读取所有曾被时钟污染过的消费者；返回触发计数。
    private func observe(_ s: MacSession) -> Fire {
        let fire = Fire()
        withObservationTracking {
            _ = s.pendingApprovals
            _ = s.activeRequest
            _ = s.railSnapshot
            _ = s.reminderSummary
        } onChange: { fire.n += 1 }
        return fire
    }

    func testOrdinarySecondsAndMinutesNeverInvalidateWhenTheSetIsUnchanged() async throws {
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let s = session(clock)
        s.approvals["a"] = approval("a", expires: base + 3_600_000)
        s.history = [alertHistory(base - 1_000)]
        s.reconcileTimeValidity()
        await settle()
        let fire = observe(s)
        for _ in 0..<5 { clock.now.addTimeInterval(1); s.reconcileTimeValidity(fromTime: true) }
        for _ in 0..<5 { clock.now.addTimeInterval(61); s.reconcileTimeValidity(fromTime: true) } // 跨分钟
        await settle()
        XCTAssertEqual(fire.n, 0, "普通秒与分钟：待答 / 目录 / 提醒入口摘要零失效")
        XCTAssertEqual(s.pendingApprovals.count, 1)
        XCTAssertEqual(s.reminderSummary.alerts, 1)
    }

    /// E-1 / E / E+1：只在 E 当刻发布一次；原始状态不改，零写请求。
    func testApprovalExpiryPublishesExactlyAtTheBoundaryWithZeroWrites() async throws {
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let s = session(clock)
        let e = base + 60_000
        s.approvals["a"] = approval("a", expires: e)
        let decided = Fire()
        s.decideOverride = { _, _ in decided.n += 1 }
        s.reconcileTimeValidity()
        XCTAssertEqual(s.validity.deadlineMs, e, "挂定时器的边界就是 expiresT")
        let fire = observe(s)
        clock.ms = e - 1; s.reconcileTimeValidity(fromTime: true)
        XCTAssertEqual(fire.n, 0); XCTAssertEqual(s.pendingApprovals.count, 1, "E-1：仍有效")
        clock.ms = e; s.reconcileTimeValidity(fromTime: true)
        XCTAssertEqual(fire.n, 1, "恰好 E：发布一次")
        XCTAssertTrue(s.pendingApprovals.isEmpty)
        clock.ms = e + 1; s.reconcileTimeValidity(fromTime: true)
        XCTAssertEqual(fire.n, 1, "E+1：不再重复")
        XCTAssertEqual(s.approvals["a"]?.status, ApprovalStatus.pending.rawValue, "原始状态不改")
        XCTAssertEqual(decided.n, 0)
        // 真实动作：E 后零传输，给固定提示
        await s.decide(approval("a", expires: e), .allowOnce)
        XCTAssertEqual(decided.n, 0, "到期后不发请求")
        XCTAssertEqual(s.decideError["a"]?.text, "这条审批已过期，不能再处理")
    }

    /// 72 小时边界：t + 72h 仍可见，+1 毫秒隐藏；提醒入口摘要在该当刻变化。
    func testReminderSeventyTwoHourBoundaryPublishesAtPlusOneMillisecond() async throws {
        let t = base
        let clock = Clock(Date(timeIntervalSince1970: Double(t + 1000) / 1000))
        let s = session(clock)
        s.history = [alertHistory(t)]
        s.reconcileTimeValidity()
        XCTAssertEqual(s.reminderSummary.alerts, 1)
        XCTAssertEqual(s.validity.deadlineMs, t + ReminderRules.maxAgeMs + 1, "边界 = t + 72h + 1ms")
        let fire = observe(s)
        clock.ms = t + ReminderRules.maxAgeMs; s.reconcileTimeValidity(fromTime: true)
        XCTAssertEqual(fire.n, 0); XCTAssertEqual(s.inboxAlerts.count, 1, "t + 72h 仍可见")
        clock.ms = t + ReminderRules.maxAgeMs + 1; s.reconcileTimeValidity(fromTime: true)
        XCTAssertEqual(fire.n, 1, "+1ms：发布一次")
        XCTAssertTrue(s.inboxAlerts.isEmpty)
        XCTAssertEqual(s.reminderSummary, ReminderSummary(), "入口摘要随之清空")
    }

    /// 回前台 / 唤醒 / 显著改时：睡眠期间到期的边界与被改过的时钟都补算。
    func testForegroundWakeAndClockChangeNotificationsReconcile() async throws {
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let s = session(clock)
        let e = base + 120_000
        s.approvals["a"] = approval("a", expires: e)
        s.reconcileTimeValidity()
        await settle()
        // 睡眠：时钟越过 E，定时器没机会跑
        clock.ms = e + 5_000
        XCTAssertEqual(s.validity.signature, ["l:a"], "尚未补算")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()
        XCTAssertTrue(s.pendingApprovals.isEmpty, "唤醒后补算：已过期")
        // 回拨时钟：集合回来
        clock.ms = e - 60_000
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        await settle()
        XCTAssertEqual(s.pendingApprovals.map(\.id), ["a"], "显著改时（回拨）：重新有效")
        clock.ms = e + 1_000
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        XCTAssertTrue(s.pendingApprovals.isEmpty, "回前台补算")
    }

    /// 取消 / 换代：同一边界不重建；边界变化换代并取消旧任务；没有边界不挂任务也不循环。
    func testSchedulerCancelsReplacesAndNeverLoopsWithoutABoundary() async throws {
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let s = session(clock)
        s.reconcileTimeValidity()
        XCTAssertNil(s.validity.task); XCTAssertNil(s.validity.deadlineMs, "没有边界：不挂任务")
        s.approvals["a"] = approval("a", expires: base + 60_000)
        s.reconcileTimeValidity()
        let g1 = s.validity.generation
        s.reconcileTimeValidity()
        XCTAssertEqual(s.validity.generation, g1, "同一边界：不取消重建")
        s.approvals["a"] = approval("a", expires: base + 120_000)
        s.reconcileTimeValidity()
        XCTAssertEqual(s.validity.deadlineMs, base + 120_000)
        XCTAssertGreaterThan(s.validity.generation, g1, "边界变化：换代，旧任务作废")
        s.approvals["a"] = nil
        s.reconcileTimeValidity()
        XCTAssertNil(s.validity.task); XCTAssertNil(s.validity.deadlineMs, "待答撤回：取消定时器")
    }

    /// 真实定时器：约 0.8 秒后到期，通知在 1.5 秒内到达（不等旧的 5 秒拍）。
    func testRealTimerFiresAtTheBoundary() async throws {
        let s = MacSession()
        s.streamDisabled = true
        let e = Int(Date().timeIntervalSince1970 * 1000) + 800
        s.approvals["a"] = approval("a", expires: e)
        s.reconcileTimeValidity()
        let fire = observe(s)
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(fire.n, 1)
        XCTAssertTrue(s.pendingApprovals.isEmpty)
    }

    /// 刘海缓存随有效性版本失效（精确到期，不等 5 秒拍）。
    func testNotchDerivedFollowsTheValidityVersion() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let s = MacSession()
        s.streamDisabled = true
        s.link = .connected
        let e = Int(Date().timeIntervalSince1970 * 1000) + 900
        s.approvals["a"] = approval("a", expires: e)
        s.reconcileTimeValidity()
        let c = NotchController()
        c.attach(session: s)
        addTeardownBlock { @MainActor in c.detach() }
        c.debugTick()
        XCTAssertEqual(c.base, NotchRules.base(pending: 1, running: c.workingRows.count))
        try await Task.sleep(for: .milliseconds(1_600))
        c.debugTick()
        XCTAssertEqual(c.base, NotchRules.base(pending: 0, running: c.workingRows.count), "到期当刻 base 离开 waiting")
    }

    // MARK: T1 改时 / 前台 / 唤醒：同一绝对 E 的相对睡眠必须重排

    /// 可偏移的墙钟：真实时间 + 偏移（模拟系统时钟被改）。
    private final class Shifted: @unchecked Sendable { var offset: TimeInterval = 0 }

    func testForwardClockChangeBeforeTheDeadlineReschedulesTheSleep() async throws {
        let shift = Shifted()
        let s = MacSession(); s.streamDisabled = true
        s.dateProvider = { Date().addingTimeInterval(shift.offset) }
        let e = Int(s.currentDate.timeIntervalSince1970 * 1000) + 1_200
        s.approvals["a"] = approval("a", expires: e)
        s.reconcileTimeValidity()
        await settle()
        let fire = observe(s)
        let g0 = s.validity.generation
        try await Task.sleep(for: .milliseconds(200))
        shift.offset = 0.7 // 前拨 700ms：E 仍在未来，约剩 300ms
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(s.validity.deadlineMs, e, "绝对 E 不变")
        XCTAssertGreaterThan(s.validity.generation, g0, "重基准：旧相对睡眠作废，重挂")
        XCTAssertLessThan(s.validity.lastDelayMs ?? Int.max, 450, "按新的 now 重算睡眠（剩约 300ms）：\(s.validity.lastDelayMs ?? -1)")
        XCTAssertEqual(fire.n, 0, "重挂本身不发布（签名不变）")
        try await Task.sleep(for: .milliseconds(600)) // 距挂起 ~0.8s < 旧睡眠到点的 1.2s
        XCTAssertEqual(fire.n, 1, "按改时后的墙钟在 E 当刻发布，不等旧的相对睡眠")
        XCTAssertTrue(s.pendingApprovals.isEmpty)
    }

    func testBackwardClockChangeKeepsTheApprovalUntilTheWallClockReachesE() async throws {
        let shift = Shifted()
        let s = MacSession(); s.streamDisabled = true
        s.dateProvider = { Date().addingTimeInterval(shift.offset) }
        let e = Int(s.currentDate.timeIntervalSince1970 * 1000) + 900
        s.approvals["a"] = approval("a", expires: e)
        s.reconcileTimeValidity()
        await settle()
        let fire = observe(s)
        try await Task.sleep(for: .milliseconds(200))
        shift.offset = -0.6 // 回拨 600ms：E 还有 ~1300ms
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertGreaterThan(s.validity.lastDelayMs ?? 0, 1_000, "回拨后睡眠变长：\(s.validity.lastDelayMs ?? -1)")
        try await Task.sleep(for: .milliseconds(900)) // 原 E 的真实时刻（~0.9s）已过
        XCTAssertEqual(fire.n, 0, "回拨后墙钟还没到 E：不提前失效")
        XCTAssertEqual(s.pendingApprovals.count, 1)
        try await Task.sleep(for: .milliseconds(1_000))
        XCTAssertEqual(fire.n, 1)
        XCTAssertTrue(s.pendingApprovals.isEmpty)
    }

    func testPlainDataEventsKeepTheSingleFlightSleepForTheSameDeadline() async throws {
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let s = session(clock)
        s.approvals["a"] = approval("a", expires: base + 60_000)
        s.reconcileTimeValidity()
        let g = s.validity.generation
        s.history = [alertHistory(base - 1_000, n: 5)] // 普通数据事件
        await settle()
        s.reconcileTimeValidity()
        XCTAssertEqual(s.validity.deadlineMs, base + 60_000 + 0)
        XCTAssertEqual(s.validity.generation, g, "同一 E 的普通数据事件不取消重建")
    }

    // MARK: T2 提交入口当刻零写

    func testExpiredReleaseAnswerReviseNeverReachTheTransport() async throws {
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let s = session(clock)
        s.link = .connected
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let calls = Fire()
        s.pendingCallOverride = { _ in calls.n += 1; return try JSONDecoder().decode(DecisionResponse.self, from: Data(#"{"status":"approved"}"#.utf8)) }
        let e = base + 30_000
        let a = approval("a", expires: e)
        s.approvals["a"] = a
        // E 前：正常提交（正控）
        let ok = await s.release(a)
        XCTAssertTrue(ok); XCTAssertEqual(calls.n, 1, "未到期：进入传输")
        s.approvals["a"] = a                                    // 复位（提交成功会把它标成已决定）
        clock.ms = e + 1                                        // 越过 E，但操作闭包还握着 E 前的请求
        let r = await s.release(a)
        let n = await s.answer(a, [])
        let v = await s.revise(a, message: nil)
        XCTAssertFalse(r); XCTAssertFalse(n); XCTAssertFalse(v)
        XCTAssertEqual(calls.n, 1, "过期后 release / answer / revise 都不进传输")
        XCTAssertEqual(s.decideError["a"]?.text, "这条审批已过期，不能再处理")
    }

    // MARK: T2-a 当前请求事实缺失 / 已处理 / 已过期：decide 与 submitPending 实际入口零传输

    private func transportSession(_ clock: Clock, calls: Fire, decides: Fire) -> MacSession {
        let s = session(clock)
        s.link = .connected
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        s.pendingCallOverride = { _ in calls.n += 1; return try JSONDecoder().decode(DecisionResponse.self, from: Data(#"{"status":"approved"}"#.utf8)) }
        s.decideOverride = { _, _ in decides.n += 1 }
        return s
    }

    func testRemovedProcessedOrExpiredCurrentFactNeverTransmits() async throws {
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let calls = Fire(), decides = Fire()
        let s = transportSession(clock, calls: calls, decides: decides)
        let e = base + 60_000
        let a = approval("a", expires: e)
        // 正控：E 前、当前事实在且待答 → decide / release 都进入传输
        s.approvals["a"] = a
        await s.decide(a, .allowOnce)
        XCTAssertEqual(decides.n, 1, "E 前 decide 进入传输（正控）")
        s.approvals["a"] = a
        let positive = await s.release(a)
        XCTAssertTrue(positive); XCTAssertEqual(calls.n, 1)
        let reason = "这一条已在别处处理、过期或撤回"
        for (name, setup) in [("已移除", { s.approvals["a"] = nil }),
                              ("已处理", { var done = a; done.status = "approved"; s.approvals["a"] = done })] as [(String, () -> Void)] {
            setup()
            let d0 = decides.n, c0 = calls.n
            await s.decide(a, .allowOnce)
            let r = await s.release(a); let n = await s.answer(a, []); let v = await s.revise(a, message: nil)
            XCTAssertEqual(decides.n, d0, "\(name)：decide 零传输")
            XCTAssertEqual(calls.n, c0, "\(name)：release / answer / revise 零传输")
            XCTAssertFalse(r || n || v, "\(name)：返回 false")
            XCTAssertEqual(s.decideError["a"]?.text, reason, "\(name)：沿“已在别处处理、过期或撤回”语义")
        }
        // 已过期：当前事实仍在，但时刻越过 E
        s.approvals["a"] = a
        clock.ms = e + 1
        let d1 = decides.n, c1 = calls.n
        await s.decide(a, .allowOnce)
        let r2 = await s.release(a)
        XCTAssertEqual(decides.n, d1); XCTAssertEqual(calls.n, c1); XCTAssertFalse(r2)
        XCTAssertEqual(s.decideError["a"]?.text, "这条审批已过期，不能再处理")
    }

    // MARK: T2-b 取详情跨 E：有效详情 + 可控挂起

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Never>?
        private var open = false
        private(set) var waiting = false
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock(); defer { lock.unlock() }
                if open { c.resume() } else { cont = c; waiting = true }
            }
        }
        func release() { lock.lock(); open = true; let c = cont; cont = nil; lock.unlock(); c?.resume() }
        var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    }

    private func questions() throws -> [ProjectedQuestion] {
        try JSONDecoder().decode([ProjectedQuestion].self, from: Data(#"[{"header":"h","question":"选哪个？","multiSelect":false,"options":[{"label":"甲","description":"","selectable":true},{"label":"乙","description":"","selectable":true}]}]"#.utf8))
    }

    private func detail(_ a: ApprovalView, qs: [ProjectedQuestion]?) throws -> ApprovalDetail {
        let view = String(data: try JSONEncoder().encode(a), encoding: .utf8)!
        let body = try qs.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! }.map { #"{"questions":\#($0)}"# } ?? "null"
        return try JSONDecoder().decode(ApprovalDetail.self, from: Data(#"{"view":\#(view),"body":\#(body)}"#.utf8))
    }

    private enum Kind { case question, plan }

    /// 同一旅程：E 前提交成功（正控）；取详情挂起期间越过 E（到期）或请求被撤回 → 零传输。
    private func journey(_ kind: Kind, crossing: String) async throws -> (calls: Int, outcome: MacSession.RequestSubmit) {
        let box = Shifted()
        let calls = Fire()
        let s = MacSession(); s.streamDisabled = true; s.reminderLedger = ReminderLedger()
        s.dateProvider = { Date(timeIntervalSince1970: Double(self.base) / 1000 + box.offset) }
        s.link = .connected
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        s.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#.utf8)) }
        s.pendingCallOverride = { _ in calls.n += 1; return try JSONDecoder().decode(DecisionResponse.self, from: Data(#"{"status":"approved"}"#.utf8)) }
        var a = approval("req", expires: base + 30_000)
        a.kind = kind == .question ? "question" : "plan"
        let qs = try questions()
        let fresh = try detail(a, qs: kind == .question ? qs : nil)
        s.approvals["req"] = a
        let gate = Gate()
        s.approvalDetailOverride = { _ in await gate.wait(); return fresh } // 非 nil、待答、E 前有效的详情；挂起由测试控制
        var draft = QuestionDraft(qs); draft.toggle(question: 0, option: 0)
        s.setQuestionDraft(draft, for: a)
        let task = Task { @MainActor () -> MacSession.RequestSubmit in
            kind == .question ? await s.submitQuestion(a, draft) : await s.submitRevise(a, message: "改一下")
        }
        for _ in 0..<200 where !gate.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(gate.isWaiting, "recheck 确实走到了取详情的 await")
        switch crossing {
        case "none": break
        case "expire": box.offset = 31                          // 挂起期间越过 E
        default: s.approvals["req"] = nil                       // 挂起期间被撤回（当前事实移除）
        }
        gate.release()
        let outcome = await task.value
        return (calls.n, outcome)
    }

    func testPlanSubmitSucceedsBeforeTheDeadlineAndNeverTransmitsAfterExpiryOrWithdrawal() async throws {
        let ok = try await journey(.plan, crossing: "none")
        XCTAssertEqual(ok.calls, 1, "E 前：计划打回正常进入传输（正控）")
        if case .submitted = ok.outcome {} else { XCTFail("应提交成功：\(ok.outcome)") }
        let expired = try await journey(.plan, crossing: "expire")
        XCTAssertEqual(expired.calls, 0, "取详情跨过 E：零传输")
        if case .kept(let why) = expired.outcome { XCTAssertEqual(why, "这一条已处理、过期或撤回，没有提交") } else { XCTFail("应保留草稿：\(expired.outcome)") }
        let withdrawn = try await journey(.plan, crossing: "withdraw")
        XCTAssertEqual(withdrawn.calls, 0, "取详情期间请求被撤回：零传输")
        if case .submitted = withdrawn.outcome { XCTFail("不应提交") }
    }

    func testQuestionSubmitSucceedsBeforeTheDeadlineAndNeverTransmitsAfterExpiryOrWithdrawal() async throws {
        let ok = try await journey(.question, crossing: "none")
        XCTAssertEqual(ok.calls, 1, "E 前：提问答案正常进入传输（正控）")
        if case .submitted = ok.outcome {} else { XCTFail("应提交成功：\(ok.outcome)") }
        let expired = try await journey(.question, crossing: "expire")
        XCTAssertEqual(expired.calls, 0, "取详情跨过 E：零传输")
        if case .kept(let why) = expired.outcome { XCTAssertEqual(why, "这一条已处理、过期或撤回，没有提交") } else { XCTFail("应保留草稿：\(expired.outcome)") }
        let withdrawn = try await journey(.question, crossing: "withdraw")
        XCTAssertEqual(withdrawn.calls, 0, "取详情期间请求被撤回：零传输")
        if case .submitted = withdrawn.outcome { XCTFail("不应提交") }
    }

    // MARK: T3 生命周期

    func testObserversAreRegisteredOnceAndRemovedOnEndAndDeinit() async throws {
        let s = MacSession(); s.streamDisabled = true
        XCTAssertEqual(s.validity.resources.observerCount, 3, "三个时钟通知各注册一次")
        s.observeClockEvents()
        XCTAssertEqual(s.validity.resources.observerCount, 3, "重复调用不重复注册")
        s.approvals["a"] = approval("a", expires: Int(Date().timeIntervalSince1970 * 1000) + 600_000)
        s.reconcileTimeValidity()
        XCTAssertNotNil(s.validity.task)
        s.endTimeValidity()
        XCTAssertEqual(s.validity.resources.observerCount, 0); XCTAssertNil(s.validity.task, "结束：移除注册并取消任务")
        let before = s.validity.generation
        s.reconcileTimeValidity()
        XCTAssertNil(s.validity.task); XCTAssertEqual(s.validity.generation, before, "结束后不再挂任务")

        weak var weakSession: MacSession?
        weak var weakResources: TimeValidityResources?
        autoreleasepool {
            let t = MacSession(); t.streamDisabled = true
            t.approvals["a"] = approval("a", expires: Int(Date().timeIntervalSince1970 * 1000) + 600_000)
            t.reconcileTimeValidity()
            weakSession = t; weakResources = t.validity.resources
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(weakSession, "Session 可被释放（通知 block 与定时任务都是弱引用）")
        XCTAssertNil(weakResources, "销毁后资源一并释放（deinit 里取消任务并移除注册）")
    }

    func testStopStreamDoesNotPermanentlyStopTheValidityScheduling() async throws {
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let s = session(clock)
        s.approvals["a"] = approval("a", expires: base + 60_000)
        s.reconcileTimeValidity()
        s.stopStream()
        s.approvals["a"] = approval("a", expires: base + 60_000) // 断线后缓存仍在
        s.reconcileTimeValidity()
        XCTAssertNotNil(s.validity.task, "换代后仍按当前事实调度（断线阅读缓存照常到期）")
        let fire = observe(s)
        clock.ms = base + 60_000; s.reconcileTimeValidity(fromTime: true)
        XCTAssertEqual(fire.n, 1)
    }

    // MARK: 数据事件先消费 E / 换连接与旧回调

    func testDataEventThatConsumesTheDeadlineFirstCancelsTheTimerAndConvergesTheNotch() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let s = session(clock)
        s.link = .connected
        let e = base + 60_000
        s.approvals["a"] = approval("a", expires: e)
        s.reconcileTimeValidity()
        let c = NotchController()
        c.attach(session: s)
        addTeardownBlock { @MainActor in c.detach() }
        c.debugTick()
        let waiting = c.base
        XCTAssertEqual(waiting, NotchRules.base(pending: 1, running: c.workingRows.count))
        XCTAssertNotNil(s.validity.task, "E 的定时器已挂")
        let fire = observe(s)
        clock.ms = e + 1                                   // 定时器还没醒，数据事件先到
        s.history = [alertHistory(clock.ms - 1_000, n: 9)] // 普通数据事件 → tracking → reconcile
        await settle()
        XCTAssertEqual(fire.n, 1, "数据事件先消费到期：恰好发布一次")
        XCTAssertNotEqual(s.validity.deadlineMs, e, "旧 E 的定时器已被取代（只剩提醒的 72h 边界）")
        XCTAssertEqual(s.validity.deadlineMs, clock.ms - 1_000 + ReminderRules.maxAgeMs + 1)
        c.debugTick()
        XCTAssertNotEqual(c.base, waiting, "刘海随之收敛")
        XCTAssertEqual(c.base, NotchRules.base(pending: 0, running: c.workingRows.count))
    }

    func testSameDeadlineBridgeSwitchConvergesOnCurrentFactsWithoutDuplicatePublishes() async throws {
        let clock = Clock(Date(timeIntervalSince1970: Double(base) / 1000))
        let s = session(clock)
        s.applyStateSnapshot(try JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"bridge-A"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#.utf8)))
        let e = base + 60_000
        s.approvals["same"] = approval("same", expires: e)
        s.reconcileTimeValidity()
        await settle()
        let g = s.validity.generation
        // 同一 ID、同一 E，但换了 Bridge（旧连接的待答被新连接的同 ID 条目取代）
        s.applyStateSnapshot(try JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"bridge-B"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#.utf8)))
        s.approvals = ["same": approval("same", expires: e)]
        await settle()
        XCTAssertEqual(s.validity.generation, g, "同一 E：不重复重挂")
        let fire = observe(s)
        clock.ms = e
        s.reconcileTimeValidity(fromTime: true); s.reconcileTimeValidity(fromTime: true); await settle() // 旧回调与新回调都排队
        XCTAssertEqual(fire.n, 1, "到期恰好发布一次，没有旧结果 / 重复发布")
        XCTAssertTrue(s.pendingApprovals.isEmpty)
        XCTAssertNil(s.validity.task)
    }
}
