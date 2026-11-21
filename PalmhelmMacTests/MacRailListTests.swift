import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// 目标栏展示投影与数据事件（A1-010 §4.1）：真实 MacSession + Observation / CountingDefaults。
// 负控：5 秒 targets 帧只推进 observation.t，目录输出不发布、行不重建、不保存；正控：真实展示变化发布且值正确。

private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    nonisolated(unsafe) var sets = 0
    override func set(_ value: Any?, forKey defaultName: String) { sets += 1; super.set(value, forKey: defaultName) }
}

private final class Fire: @unchecked Sendable { var n = 0 }

@MainActor
final class MacRailListTests: XCTestCase {
    static let t0 = 1_900_000_000_000
    private var suite = ""
    private let bridge = "rail-\(UUID().uuidString)" // 已读/钉住记在 UserDefaults 里，键含 Bridge id：每个用例自己的 id

    override func setUp() { super.setUp(); suite = "mac-rail-\(UUID().uuidString)" }
    override func tearDown() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); super.tearDown() }

    private func state(_ n: Int, working: Set<Int> = [], offline: Bool = false, obsT: Int = MacRailListTests.t0, bridgeId: String? = nil) -> BridgeState {
        let targets = (0..<n).map { i in
            #"{"projectName":"p\#(i)","id":"t\#(i)","online":\#(!offline),"status":"\#(working.contains(i) ? "working" : "idle")","location":{"workspace":"ws\#(i % 5)","tab":"tab\#(i)"},"workspaceId":"w\#(i % 5)","terminalId":"term-\#(i)"}"#
        }
        let history = (0..<n).map { i in
            #"{"seq":\#(i + 1),"uuid":"outbox:t\#(i)","text":"消息 \#(i)","kind":"text","target":{"id":"t\#(i)","projectName":"p\#(i)"},"t":\#(Self.t0 + i)}"#
        }
        let spaces = (0..<5).map { #"{"workspace":"ws\#($0)","agentlessTabCount":0,"workspaceId":"w\#($0)"}"# }
        return try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"\#(bridgeId ?? bridge)"},"occupancy":"free","targets":[\#(targets.joined(separator: ","))],"history":{"highWater":\#(n),"items":[\#(history.joined(separator: ","))]},"spaces":[\#(spaces.joined(separator: ","))],"observation":{"t":\#(obsT),"complete":true,"fresh":true}}"#.utf8))
    }

    private func session(lens: ThreadLens = .spaces, defaults: UserDefaults? = nil) -> MacSession {
        let s = MacSession()
        let d = defaults ?? UserDefaults(suiteName: suite)!
        s.spaceStore = SpaceOrderStore(defaults: d)
        s.spaceDocument = SpaceOrderDocument()
        s.archive = ThreadArchiveStore(defaults: d)
        s.lens = lens
        return s
    }

    private func feed(_ s: MacSession, _ st: BridgeState, lens: ThreadLens = .spaces) async throws {
        s.stateOverride = { st }
        try await s.pullState()
        s.lens = lens // 权威同步会恢复本机上次的视角偏好，测试固定
        await settle()
    }

    private func settle() async { for _ in 0..<8 { await Task.yield() } }

    private func frame(_ s: MacSession, _ st: BridgeState) {
        s.applyTargetsFrame(st.targets, spaces: st.spaces, observation: st.observation)
    }

    private func approval(_ id: String, target: String, exact: Bool = true) -> ApprovalView {
        var a = ApprovalView(id: id, status: "pending", targetLabel: target.replacingOccurrences(of: "t", with: "p"), attribution: exact ? "exact" : "candidate", toolName: "Bash", summary: "x", createdT: Self.t0, expiresT: Int(Date().timeIntervalSince1970 * 1000) + 3_600_000)
        if exact { a.targetId = target }
        return a
    }

    // MARK: A 归档批量保存

    func testAFreshObservationOfFortyOfflineTargetsSavesOnceAndKeepsTheDisplayVersion() async throws {
        let d = CountingDefaults(suiteName: suite)!
        let s = session(defaults: d)
        try await feed(s, state(40, offline: true))
        let versionBefore = s.archiveVersion, setsBefore = d.sets
        frame(s, state(40, offline: true, obsT: Self.t0 + 5_000))
        XCTAssertLessThanOrEqual(d.sets - setsBefore, 1 + 1, "整轮归档最多保存一次（逐条为 40 次；另含空间文档的至多一次）")
        XCTAssertTrue((0..<40).allSatisfy { s.archive.record(s.archiveKey("t\($0)"))?.lastObserved == Self.t0 + 5_000 }, "证据全部推进")
        XCTAssertEqual(s.archiveVersion, versionBefore, "只有证据变化：展示版本不推进")
        let again = d.sets
        frame(s, state(40, offline: true, obsT: Self.t0 + 5_000))
        XCTAssertEqual(d.sets, again, "重复帧：零保存")
        XCTAssertEqual(s.archiveVersion, versionBefore)
    }

    func testDisplayChangesStillAdvanceTheVersionAndTheTitleOrderIsKept() async throws {
        let s = session()
        try await feed(s, state(5))
        let v = s.archiveVersion
        frame(s, state(6, obsT: Self.t0 + 5_000))          // 新目标：目录新增一条
        XCTAssertGreaterThan(s.archiveVersion, v, "目录条目增加：展示变化，版本推进")
        // 标题触达顺序与原来一致：登记目标先写，历史条目后写（历史投影的 projectName 为最终标题）
        XCTAssertEqual(s.archive.record(s.archiveKey("t2"))?.title, "p2")
        XCTAssertNotNil(s.archive.record(s.archiveKey("t5"))?.lastActivity)
    }

    // MARK: B 空间文档

    func testIdenticalSpaceSnapshotsNeverNotifyOrSave() async throws {
        let d = CountingDefaults(suiteName: suite)!
        let s = session()
        s.spaceStore = SpaceOrderStore(defaults: d)
        try await feed(s, state(10))
        s.setSpaceListVisible(false)
        let fire = Fire()
        withObservationTracking { _ = s.spaceDocument } onChange: { fire.n += 1 }
        let v = s.spaceVersion, sets = d.sets
        for i in 1...20 { frame(s, state(10, obsT: Self.t0 + i * 5_000)); await settle() }
        XCTAssertEqual(fire.n, 0, "20 个仅 observation.t 的帧：spaceDocument 观察者 0")
        XCTAssertEqual(s.spaceVersion, v)
        XCTAssertEqual(d.sets, sets, "空间排序存储 set 0")
        // 正控：真实工作转换使文档变化
        frame(s, state(10, working: [3], obsT: Self.t0 + 200_000)); await settle()
        XCTAssertGreaterThan(s.spaceVersion, v)
        XCTAssertEqual(s.railSnapshot.sections.first?.title, "ws3", "运行中的组上移")
    }

    // MARK: C 目录

    func testObservationOnlyFramesNeverPublishTheRail() async throws {
        let s = session()
        try await feed(s, state(40, working: [0, 2, 4]))
        s.approvals["a1"] = approval("a1", target: "t3")
        s.setSpaceListVisible(true)
        await settle()
        let probe = s.railProbe
        let b0 = probe.builds, p0 = probe.publishes
        XCTAssertEqual(s.railSnapshot.rows.count, 40)
        let fire = Fire(), raw = Fire()
        withObservationTracking { _ = s.railSnapshot } onChange: { fire.n += 1 }
        withObservationTracking { _ = s.state?.targets } onChange: { raw.n += 1 }
        for i in 1...20 { frame(s, state(40, working: [0, 2, 4], obsT: Self.t0 + i * 5_000)); await settle() }
        XCTAssertEqual(s.state?.observation?.t, Self.t0 + 20 * 5_000, "原始观察照常接收")
        XCTAssertEqual(fire.n, 0, "目录输出观察者 0")
        XCTAssertEqual(probe.publishes, p0, "没有发布")
        XCTAssertLessThanOrEqual(probe.builds - b0, 20)
        XCTAssertGreaterThanOrEqual(probe.builds - b0, 1)
        XCTAssertGreaterThanOrEqual(raw.n, 1, "对照：原始 state 发布仍会失效直接读取它的消费者")
    }

    func testBuildReadsDoNotGrowWithRowCountAndRowsAreConsumedWithoutBuilding() async throws {
        var reads: [Int] = []
        for n in [40, 80] {
            let s = session()
            try await feed(s, state(n))
            s.approvals["a1"] = approval("a1", target: "t3")
            await settle()
            let r0 = s.railProbe.pendingReads
            _ = s.buildRail()
            reads.append(s.railProbe.pendingReads - r0)
            let b = s.railProbe.builds
            for i in 0..<n { XCTAssertNotNil(s.railSnapshot.rows["t\(i)"]) }
            XCTAssertEqual(s.railProbe.builds, b, "读取全部行不触发构建")
        }
        XCTAssertEqual(reads[0], reads[1], "待批投影读取次数与行数无关：\(reads)")
        XCTAssertLessThanOrEqual(reads[0], 3)
    }

    func testRailEqualsTheRawProjectionAndArchiveAvailabilityEqualsTheAuthoritativeRule() async throws {
        for lens in ThreadLens.allCases {
            let s = session(lens: lens)
            try await feed(s, state(12, working: [0, 5], offline: true), lens: lens)
            s.approvals["a1"] = approval("a1", target: "t3")
            s.setPinned("t7", true); s.markUnread("t8")
            await settle()
            let snap = s.railSnapshot
            XCTAssertEqual(snap.sections, s.railSections, "\(lens)：分组与原有投影相同")
            XCTAssertEqual(snap.inbox, s.inboxModel, "\(lens)：收件箱分区相同")
            func check(_ why: String) async {
                await settle()
                for (id, row) in s.railSnapshot.rows { XCTAssertEqual(row.canArchive, s.canArchiveOrDelete(id), "\(why)：\(id)") }
            }
            await check("基线")
            s.setDraft(MacSession.ComposerDraft(text: "x"), for: "t1"); await check("有草稿")
            s.setDraft(MacSession.ComposerDraft(), for: "t1"); await check("草稿清除")
            s.selectTarget("t2"); await check("选中（受保护）")
            var incomplete = state(12, working: [0, 5], offline: true)
            incomplete.observation = BridgeObservation(t: Self.t0, complete: false, fresh: true)
            try await feed(s, incomplete, lens: lens); await check("观察不完整（在线未知）")
        }
    }

    func testMetadataThatIsNotDisplayedNeverRepublishesWhileVisibleChangesDo() async throws {
        let s = session()
        let st = state(10, working: [1])
        try await feed(s, st)
        let probe = s.railProbe
        let p0 = probe.publishes
        var ts = st.targets
        ts[3].capabilities = TargetCapabilities(steer: true, nativeSteer: true, nativeSendNow: true)
        ts[4].identityPauseKey = "k1"
        s.applyTargetsFrame(ts, spaces: st.spaces, observation: BridgeObservation(t: Self.t0 + 5_000, complete: true, fresh: true)); await settle()
        XCTAssertEqual(probe.publishes, p0, "仅能力提示 / 暂停键变化：不发布")
        ts[5].role = "design"
        s.applyTargetsFrame(ts, spaces: st.spaces, observation: BridgeObservation(t: Self.t0 + 6_000, complete: true, fresh: true)); await settle()
        XCTAssertEqual(probe.publishes, p0 + 1, "角色变化（徽章文字）：发布")
        XCTAssertEqual(s.railSnapshot.rows["t5"]?.badgeRole, .design)
        ts[6].location = TargetLocation(workspace: "ws1", tab: "新标签", pane: nil)
        s.applyTargetsFrame(ts, spaces: st.spaces, observation: BridgeObservation(t: Self.t0 + 7_000, complete: true, fresh: true)); await settle()
        XCTAssertEqual(probe.publishes, p0 + 2, "位置变化：发布")
        ts[7].model = try JSONDecoder().decode(TargetModel.self, from: Data(#"{"id":"claude-opus","basis":"last_used"}"#.utf8))
        s.applyTargetsFrame(ts, spaces: st.spaces, observation: BridgeObservation(t: Self.t0 + 8_000, complete: true, fresh: true)); await settle()
        XCTAssertEqual(probe.publishes, p0 + 3, "模型变化：发布")
        ts[8].agentName = "改名"
        s.applyTargetsFrame(ts, spaces: st.spaces, observation: BridgeObservation(t: Self.t0 + 9_000, complete: true, fresh: true)); await settle()
        XCTAssertEqual(probe.publishes, p0 + 4, "标题变化：发布")
    }

    func testRealChangesPublishWithCorrectValuesAndScopeRejectsTheOldConnection() async throws {
        let s = session()
        try await feed(s, state(8, offline: false))
        s.setPinned("t2", true); await settle()
        XCTAssertEqual(s.railSnapshot.rows["t2"]?.pinned, true)
        s.approvals["a1"] = approval("a1", target: "t4"); await settle()
        XCTAssertEqual(s.railSnapshot.rows["t4"]?.pending, 1)
        s.selectTarget("t5"); await settle()
        XCTAssertEqual(s.railSnapshot.rows["t5"]?.selected, true)
        XCTAssertEqual(s.railSnapshot.rows["t2"]?.selected, false)
        let epoch = s.connectionEpoch
        s.stopStream() // 权威换代入口
        XCTAssertEqual(s.connectionEpoch, epoch + 1)
        XCTAssertTrue(s.railSnapshot.rows.isEmpty, "换代后重建之前不暴露旧代次的行")
        await settle()
        XCTAssertEqual(s.railSnapshot.rows.count, 8, "重建按当前事实读取")
    }

    // MARK: D 真实 NSHostingView：空间与收件箱侧栏

    private func mount(_ s: MacSession) -> (NSWindow, NSHostingView<AnyView>) {
        let defaults = UserDefaults(suiteName: "RailHost.\(UUID().uuidString)")!
        let settings = EngineSettings(defaults: defaults, secretsReady: true)
        let host = NSHostingView(rootView: AnyView(InboxSidebar().environment(s).environment(BridgeEngine(settings: settings)).environment(settings).frame(width: 300, height: 700)))
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return (w, host)
    }

    private func pump(_ host: NSView, _ sec: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(sec))
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(sec))
    }

    private func hostedRowsStayPutOnObservationOnlyFrames(lens: ThreadLens, working: Set<Int>) async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let s = session(lens: lens)
        try await feed(s, state(30, working: working), lens: lens)
        let (w, host) = mount(s)
        defer { w.orderOut(nil); w.contentView = nil; w.close() }
        await pump(host, 0.4)
        XCTAssertGreaterThanOrEqual(RailProbe.rowBodies, 5, "\(lens)：侧栏渲染了行：\(RailProbe.rowBodies)")

        // 正控：选中一个目标 → 真实的行重建（宿主确实会更新）
        let before = RailProbe.rowBodies
        let pick = lens == .spaces ? (s.railSnapshot.sections.first?.keys.first ?? "t0") : "t1"
        s.selectTarget(pick)
        for _ in 0..<10 where RailProbe.rowBodies == before { await pump(host, 0.2) }
        XCTAssertGreaterThan(RailProbe.rowBodies, before, "\(lens)：正控——宿主的行会更新")
        XCTAssertLessThanOrEqual(RailProbe.rowBodies - before, 4, "只重建变化的行：\(RailProbe.rowBodies - before)")
        await pump(host, 0.3)

        // 负控：20 个仅 observation.t 的帧
        let baseline = RailProbe.rowBodies
        for i in 1...20 { frame(s, state(30, working: working, obsT: Self.t0 + i * 5_000)); await pump(host, 0.03) }
        await pump(host, 0.3)
        XCTAssertEqual(RailProbe.rowBodies, baseline, "\(lens)：20 帧后行重建 0（\(RailProbe.rowBodies - baseline)）")
    }

    func testHostedSpacesSidebarRowsDoNotRebuildOnObservationOnlyFrames() async throws {
        try await hostedRowsStayPutOnObservationOnlyFrames(lens: .spaces, working: [0, 2])
    }

    func testHostedInboxSidebarRowsDoNotRebuildOnObservationOnlyFrames() async throws {
        try await hostedRowsStayPutOnObservationOnlyFrames(lens: .inbox, working: Set(0..<20))
    }

    // MARK: F10 Bridge 身份

    func testSameEndpointAndEpochNewBridgeNeverExposesTheOldRowsBeforeRebuild() async throws {
        let s = session()
        try await feed(s, state(5))
        XCTAssertEqual(s.railSnapshot.rows.count, 5)
        let epoch = s.connectionEpoch
        let raw = Fire()
        withObservationTracking { _ = s.railSnapshot } onChange: { raw.n += 1 }
        s.applyStateSnapshot(state(5, bridgeId: "other-\(bridge)")) // 权威入口：同端点、同代次、换 Bridge
        XCTAssertEqual(s.connectionEpoch, epoch)
        XCTAssertTrue(s.railSnapshot.rows.isEmpty, "重建之前不暴露旧 Bridge 的行")
        await settle()
        XCTAssertEqual(s.railSnapshot.rows.count, 5, "重建只发当前 Bridge 的事实")
        XCTAssertTrue(s.railSnapshot.scope.hasPrefix("other-"))
    }

    func testScopeDoesNotReadTheRawStateSoObservationOnlyFramesStayQuiet() async throws {
        let s = session()
        try await feed(s, state(5))
        let fire = Fire()
        withObservationTracking { _ = s.railSnapshot } onChange: { fire.n += 1 }
        for i in 1...20 { frame(s, state(5, obsT: Self.t0 + i * 5_000)); await settle() }
        XCTAssertEqual(fire.n, 0, "访问器不读整个 state：20 个仅 observation.t 的帧观察者 0")
    }

    // MARK: F11 活动 online 用同轮索引

    func testActivityOnlineFollowsTheLinkAndTheTargetIndex() async throws {
        let s = session()
        try await feed(s, state(40, working: [1]))
        s.link = .connected; await settle()
        let lookups = s.railProbe.targetLookups
        _ = s.buildRail()
        XCTAssertEqual(s.railProbe.targetLookups, lookups, "构建不再逐行线性查找目标（旧路径每行一次）")
        XCTAssertEqual(s.railSnapshot.rows["t1"]?.activity, ThreadActivity.activity(online: s.targetOnline("t1"), status: .working, pending: 0))
        s.link = .offline("x"); await settle()
        XCTAssertEqual(s.railSnapshot.rows["t1"]?.activity, ThreadActivity.activity(online: s.targetOnline("t1"), status: .working, pending: 0), "断线按未知")
    }

    // MARK: E 刘海：稳定拍不再求 pending；数据 / 撤回 / 到期 / 30 秒都能更新缓存

    func testNotchCacheFollowsDataExpiryAndThirtySecondsAndStaysQuietOtherwise() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let s = session()
        try await feed(s, state(10, working: [1]))
        s.link = .connected
        await settle()
        let c = NotchController()
        c.attach(session: s)
        addTeardownBlock { @MainActor in c.detach() }
        for _ in 0..<5 { c.debugTick() }
        let idle = c.base
        XCTAssertNotEqual(idle, NotchRules.base(pending: 1, running: c.workingRows.count), "前提：0 条待答的 base 不是 waiting")
        let r0 = s.railProbe.pendingReads
        for _ in 0..<100 { c.debugTick() }
        XCTAssertEqual(s.railProbe.pendingReads - r0, 0, "100 次稳定拍：pending 投影增量 0（旧路径每拍 2 次）")

        // 0 → 1：base 变 waiting（旧缓存停在 0 条会失败）
        s.approvals["a1"] = approval("a1", target: "t3")
        c.debugTick()
        XCTAssertEqual(c.base, NotchRules.base(pending: 1, running: c.workingRows.count))
        XCTAssertNotEqual(c.base, idle, "新待答使 base 离开 idle")
        let r1 = s.railProbe.pendingReads
        for _ in 0..<100 { c.debugTick() }
        XCTAssertEqual(s.railProbe.pendingReads - r1, 0, "重算后继续静默")

        // 撤回：离开 waiting，再静默
        s.approvals["a1"] = nil
        c.debugTick()
        XCTAssertEqual(c.base, idle, "撤回最后一条：base 回到原值")
        let r2 = s.railProbe.pendingReads
        for _ in 0..<100 { c.debugTick() }
        XCTAssertEqual(s.railProbe.pendingReads - r2, 0)

        // 跨 30 秒：只做一次必要重建
        let g0 = c.debugDerivedGeneration
        let later = Date().addingTimeInterval(31)
        c.debugTick(now: later)
        XCTAssertEqual(c.debugDerivedGeneration, g0 + 1, "超过 30 秒：重建一次")
        c.debugTick(now: later.addingTimeInterval(0.5)); c.debugTick(now: later.addingTimeInterval(1))
        XCTAssertEqual(c.debugDerivedGeneration, g0 + 1, "之后继续静默")
    }

    func testNotchCacheDropsAnApprovalThatExpires() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let s = session()
        try await feed(s, state(10, working: [1]))
        s.link = .connected
        let c = NotchController()
        c.attach(session: s)
        addTeardownBlock { @MainActor in c.detach() }
        for _ in 0..<3 { c.debugTick() }
        let idle = c.base
        var a = approval("a1", target: "t3")
        a.expiresT = Int(Date().timeIntervalSince1970 * 1000) + 1_500
        s.approvals["a1"] = a
        c.debugTick()
        XCTAssertNotEqual(c.base, idle, "未到期：waiting")
        try await Task.sleep(for: .milliseconds(1_800)) // 精确到期边界（不再等 5 秒拍）
        c.debugTick()
        XCTAssertEqual(c.base, idle, "到期后缓存随有效性版本失效，base 离开 waiting")
        let r = s.railProbe.pendingReads
        for _ in 0..<100 { c.debugTick() }
        XCTAssertEqual(s.railProbe.pendingReads - r, 0, "到期重算后继续静默")
    }

    // MARK: 工具栏：铃铛与提醒入口各自重算

    func testBellAndAlertsEntriesRecomputeOnlyThemselves() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let s = session()
        try await feed(s, state(6))
        var shown = false
        let binding = SwiftUI.Binding<Bool>(get: { shown }, set: { shown = $0 })
        let host = NSHostingView(rootView: AnyView(HStack { BellToolbarButton(action: {}); AlertsToolbarButton(shown: binding) }.environment(s)))
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderBack(nil)
        defer { w.orderOut(nil); w.contentView = nil; w.close() }
        await pump(host, 0.3)
        let bell0 = RailProbe.bellBodies
        for i in 1...20 { frame(s, state(6, obsT: Self.t0 + i * 5_000)); await pump(host, 0.02) }
        XCTAssertEqual(RailProbe.bellBodies, bell0, "20 个仅 observation.t 的帧：铃铛不重算")
        s.approvals["a1"] = approval("a1", target: "t2")
        for _ in 0..<10 where RailProbe.bellBodies == bell0 { await pump(host, 0.2) }
        XCTAssertGreaterThan(RailProbe.bellBodies, bell0, "正控：新待答使铃铛重算")
        XCTAssertEqual(s.pendingApprovals.count, 1)
    }

    /// F13：提醒入口的正控——种一条可见提醒 → 入口出现（宿主宽度变化、小视图重算）→ 已读后图标变化 → 撤回后消失，稳定帧再静默。
    func testAlertsEntryAppearsChangesAndDisappearsWithTheReminder() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let s = session()
        s.streamDisabled = true
        try await feed(s, state(6))
        s.link = .connected
        s.reminderLedger = ReminderLedger()
        var shown = false
        let binding = SwiftUI.Binding<Bool>(get: { shown }, set: { shown = $0 })
        let host = NSHostingView(rootView: AnyView(HStack { AlertsToolbarButton(shown: binding) }.fixedSize().environment(s)))
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderBack(nil)
        defer { w.orderOut(nil); w.contentView = nil; w.close() }
        func width() -> CGFloat { host.layoutSubtreeIfNeeded(); return host.fittingSize.width }
        await pump(host, 0.3)
        XCTAssertTrue(s.inboxAlerts.isEmpty && s.blockedReminders.isEmpty, "前提：没有提醒时入口不出现")
        let emptyWidth = width()
        let b0 = RailProbe.alertsBodies

        // 种一条可见提醒（失败发送 + 指向它的回执）：入口出现
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        s.sent = [MacSession.Sent(id: UUID(), text: "x", at: Date(), afterSeq: 0, targetId: nil, eventKey: "k1", error: "failed", draft: "draft", attachmentPaths: [])]
        s.history = [HistoryItem(seq: 900, uuid: "rj-1", text: "rejected:x", kind: "text", replyTo: "k1", t: nowMs)]
        XCTAssertEqual(s.inboxAlerts.count, 1)
        XCTAssertEqual(s.unreadReminderCount, 1)
        for _ in 0..<10 where RailProbe.alertsBodies == b0 { await pump(host, 0.2) }
        XCTAssertGreaterThan(RailProbe.alertsBodies, b0, "正控：提醒出现使入口小视图重算")
        let shownWidth = width()
        XCTAssertGreaterThan(shownWidth, emptyWidth + 4, "入口真实出现（宿主宽度变大）：\(emptyWidth) → \(shownWidth)")

        // 已读：未读数归零，图标由实心变空心（再次重算）
        let b1 = RailProbe.alertsBodies
        s.openReminders()
        XCTAssertEqual(s.unreadReminderCount, 0)
        for _ in 0..<10 where RailProbe.alertsBodies == b1 { await pump(host, 0.2) }
        XCTAssertGreaterThan(RailProbe.alertsBodies, b1, "正控：未读 → 已读使入口重算")
        XCTAssertGreaterThan(width(), emptyWidth + 4, "已读后入口仍在（只是不再标未读）")
        s.closeReminders()

        // 稳定帧：20 个仅 observation.t 的帧，入口不重算
        await pump(host, 0.3)
        let quiet = RailProbe.alertsBodies
        for i in 1...20 { frame(s, state(6, obsT: Self.t0 + i * 5_000)); await pump(host, 0.02) }
        XCTAssertEqual(RailProbe.alertsBodies, quiet, "稳定帧：提醒入口不重算（入口读判变后才写的摘要）")

        // 撤回：发送与回执都没了 → 入口消失，宽度回到空值
        let b2 = RailProbe.alertsBodies
        s.sent = []; s.history = []
        XCTAssertTrue(s.inboxAlerts.isEmpty)
        for _ in 0..<10 where RailProbe.alertsBodies == b2 { await pump(host, 0.2) }
        XCTAssertGreaterThan(RailProbe.alertsBodies, b2, "正控：撤回使入口重算")
        XCTAssertEqual(width(), emptyWidth, accuracy: 1, "入口消失，宽度恢复")
        let quiet2 = RailProbe.alertsBodies
        for i in 21...40 { frame(s, state(6, obsT: Self.t0 + i * 5_000)); await pump(host, 0.02) }
        XCTAssertEqual(RailProbe.alertsBodies, quiet2, "恢复后再次静默")
    }

    // MARK: D 完整 MainWindow 旅程（右侧真实线程、侧栏隐藏/恢复、切统计返回）

    func testFullMainWindowJourneyKeepsSelectionDraftAndRowsAcrossLifecycle() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let ud = UserDefaults.standard
        let keys = ["palmhelm.mainPage", "palmhelm.sidebarShown"]
        let previous = keys.map { ud.object(forKey: $0) }
        ud.set(0, forKey: "palmhelm.mainPage"); ud.set(true, forKey: "palmhelm.sidebarShown")
        defer { for (k, v) in zip(keys, previous) { if let v { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) } } }

        let s = session()
        s.preferences = UserDefaults(suiteName: suite)!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-rail","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let st = state(12, working: [1, 2])
        s.stateOverride = { st }
        s.streamDisabled = true // 不起真实事件流：连接状态不抖动，行值只随被测数据变化
        s.selectedTarget = "t1"; s.selectedThread = "t1"
        await s.refresh()
        s.lens = .spaces
        // 历史目标：整理目录里有、但已不在登记表的条目
        s.archive.touch(s.archiveKey("gone"), title: "已离线的旧会话", lastActivity: 1)
        s.archiveVersion += 1
        var thread = TranscriptThread(); thread.status = .ok
        thread.items = (0..<20).map { TranscriptItem(id: "tr-\($0)", role: $0 % 2 == 0 ? "assistant" : "user", text: "第 \($0) 条消息") }
        s.transcripts["t1"] = thread
        await settle()
        XCTAssertNotNil(s.railSnapshot.historical["gone"], "合成历史目标进入快照")

        let settings = EngineSettings(defaults: UserDefaults(suiteName: "RailJourney.\(UUID().uuidString)")!)
        let hv = NSHostingView(rootView: MainWindow().environment(s).environment(BridgeEngine(settings: settings)).environment(settings).frame(width: 1100, height: 700))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hv
        win.orderBack(nil)
        defer { win.orderOut(nil); win.contentView = nil; win.close() }
        func spin(_ sec: Double) async {
            try? await Task.sleep(for: .seconds(sec / 2))
            hv.needsLayout = true; hv.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .seconds(sec / 2))
        }
        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
        func quietFrames(_ label: String) async {
            await spin(0.4)
            let baseline = RailProbe.rowBodies
            for i in 1...20 { frame(s, state(12, working: [1, 2], obsT: Self.t0 + 100_000 * (label.hashValue == 0 ? 1 : 1) + i * 5_000 + Int(Date().timeIntervalSince1970) % 1000)); await spin(0.03) }
            await spin(0.3)
            XCTAssertEqual(RailProbe.rowBodies, baseline, "\(label)：20 个仅 observation.t 的帧后行重建 0（\(RailProbe.rowBodies - baseline)）")
        }

        await spin(1.5)
        XCTAssertGreaterThanOrEqual(RailProbe.rowBodies, 5, "侧栏渲染了行")
        XCTAssertGreaterThanOrEqual(scrollViews(hv).count, 2, "侧栏与右侧真实线程区都已挂载")

        // 正控：选中另一个目标 → 行重建且右侧线程切换
        let before = RailProbe.rowBodies
        s.selectTarget("t2")
        for _ in 0..<10 where RailProbe.rowBodies == before { await spin(0.3) }
        XCTAssertGreaterThan(RailProbe.rowBodies, before, "正控：宿主确实会更新行")
        XCTAssertLessThanOrEqual(RailProbe.rowBodies - before, 6)
        XCTAssertEqual(s.selectedTarget, "t2")
        await quietFrames("线程挂载后")

        // 草稿跨生命周期保留
        s.setDraft(MacSession.ComposerDraft(text: "未发送的草稿"), for: "t2")

        // 隐藏 → 恢复侧栏
        ud.set(false, forKey: "palmhelm.sidebarShown"); await spin(0.8)
        ud.set(true, forKey: "palmhelm.sidebarShown"); await spin(1.0)
        XCTAssertEqual(s.selectedTarget, "t2", "隐藏/恢复侧栏后选中保留")
        XCTAssertEqual(s.draft("t2").text, "未发送的草稿", "草稿保留")
        await quietFrames("恢复侧栏后")

        // 切统计 → 返回
        ud.set(1, forKey: "palmhelm.mainPage"); await spin(0.8)
        ud.set(0, forKey: "palmhelm.mainPage"); await spin(1.2)
        XCTAssertEqual(s.selectedTarget, "t2", "切统计返回后选中保留")
        XCTAssertEqual(s.draft("t2").text, "未发送的草稿", "草稿保留")
        XCTAssertGreaterThanOrEqual(scrollViews(hv).count, 2, "返回后侧栏与线程区都重新挂载")
        await quietFrames("统计返回后")
    }
}
