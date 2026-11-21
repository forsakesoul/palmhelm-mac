import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// 历史分页的假传输：记录每次请求的游标；可注入首次失败与在途断开（R1/R2）。
private actor MacHistoryFake: SearchTranscriptClient {
    private(set) var calls: [String?] = []
    private var failFirst = false
    private var stopDuring: (@MainActor @Sendable () -> Void)?
    private var pages: [TargetHistoryPage]
    init(pages: [TargetHistoryPage]) { self.pages = pages }
    func setFailFirst() { failFirst = true }
    func setStopDuring(_ f: @escaping @MainActor @Sendable () -> Void) { stopDuring = f }
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage { throw URLError(.notConnectedToInternet) }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage {
        calls.append(before)
        if let f = stopDuring { stopDuring = nil; await f() }
        if failFirst { failFirst = false; throw URLError(.timedOut) }
        return pages.isEmpty ? TargetHistoryPage(items: [], nextBefore: nil, hasMore: false, partial: false) : pages.removeFirst()
    }
}

// #97 S3：Mac 的历史会话整理接线（合成数据、注入的 Bridge 观察时刻、一次性偏好域并在测试结束时清理）。
// 观察与整理都经真实的权威同步（pullState）进入会话，与线上顺序一致。
@MainActor
final class MacArchiveTests: XCTestCase {
    static let day = 24 * 60 * 60 * 1000
    static let t0 = 1_700_000_000_000

    private func state(online: Bool, observation: String?, targets: String? = nil, history: String = #"[{"seq":1,"uuid":"outbox:u1","text":"旧的对话","kind":"text","target":{"id":"A","projectName":"P"},"t":1700000000000}]"#, commands: String = "[]") -> BridgeState {
        let obs = observation.map { #","observation":\#($0)"# } ?? ""
        let on = online ? "true" : "false"
        // B 始终在线：fixSelection 会自动选中在线目标，A 因此不被当作“正在查看”而受保护。
        let list = targets ?? #"[{"projectName":"P","id":"A","online":\#(on)},{"projectName":"Q","id":"B","online":true}]"#
        return try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":\#(list),"history":{"highWater":1,"items":\#(history)},"commands":\#(commands)\#(obs)}"#.utf8))
    }

    private func obs(_ t: Int, fresh: Bool = true) -> String { #"{"t":\#(t),"complete":true,"fresh":\#(fresh)}"# }

    /// 经权威同步进入会话（不直接调用 applyStateSnapshot，否则绕过整理的最终合并顺序）。
    private func feed(_ s: MacSession, _ st: BridgeState) async throws {
        s.stateOverride = { st }
        try await s.pullState()
    }

    /// 每个测试用一次性偏好域；tearDown 时清理。
    private var suite: String = ""
    override func setUp() {
        super.setUp()
        suite = "mac-archive-\(UUID().uuidString)"
    }
    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func session() -> MacSession {
        let s = MacSession()
        s.archive = ThreadArchiveStore(defaults: UserDefaults(suiteName: suite)!)
        return s
    }

    func testOldBridgeWithoutObservationNeverArchives() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: nil))
        try await feed(s, state(online: false, observation: nil))
        XCTAssertTrue(s.archivedThreads.isEmpty)
        XCTAssertTrue(s.railInputs.contains { $0.key == "A" })
    }

    func testStaleSnapshotsNeverCountAsAbsence() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0, fresh: false)))
        try await feed(s, state(online: false, observation: obs(Self.t0 + 8 * Self.day, fresh: false)))
        XCTAssertTrue(s.archivedThreads.isEmpty)
    }

    func testOfflineThreadArchivesAfterSevenDaysLeavesTheRailAndRestores() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0)))
        XCTAssertTrue(s.archivedThreads.isEmpty)
        try await feed(s, state(online: false, observation: obs(Self.t0 + 7 * Self.day)))
        XCTAssertEqual(s.archivedThreads.map(\.id), ["A"])
        XCTAssertFalse(s.railInputs.contains { $0.key == "A" }, "archived threads leave the rail")
        XCTAssertTrue(s.restoreThread("A"))
        XCTAssertTrue(s.railInputs.contains { $0.key == "A" }, "a restored thread is back on the rail")
    }

    func testOnlineThreadNeverArchivesAndTheSelectedTargetIsProtected() async throws {
        let online = session()
        try await feed(online, state(online: true, observation: obs(Self.t0)))
        try await feed(online, state(online: true, observation: obs(Self.t0 + 9 * Self.day)))
        XCTAssertTrue(online.archivedThreads.isEmpty)
        let selected = session()
        selected.selectedTarget = "A"
        try await feed(selected, state(online: false, observation: obs(Self.t0)))
        try await feed(selected, state(online: false, observation: obs(Self.t0 + 9 * Self.day)))
        XCTAssertTrue(selected.archivedThreads.isEmpty, "the selected target must not be archived under the reader")
    }

    func testManualActionsAndDeleteClearTheLocalCopy() async throws {
        let online = session()
        try await feed(online, state(online: true, observation: obs(Self.t0)))
        XCTAssertFalse(online.canArchiveOrDelete("A"))
        XCTAssertFalse(online.archiveThread("A"))
        let off = session()
        try await feed(off, state(online: false, observation: obs(Self.t0)))
        XCTAssertTrue(off.canArchiveOrDelete("A"))
        XCTAssertTrue(off.archiveThread("A"))
        XCTAssertEqual(off.archivedThreads.first?.reason, .manual)
        XCTAssertTrue(off.deleteThread("A"))
        XCTAssertTrue(off.archivedThreads.isEmpty)
        XCTAssertTrue(off.history.allSatisfy { $0.target?.id != "A" })
        try await feed(off, state(online: false, observation: obs(Self.t0 + 1)))
        XCTAssertFalse(off.railInputs.contains { $0.key == "A" }, "the historical replay must not resurrect a deleted thread")
    }

    // R5：登记表为空、历史投影里仍有旧目标 A：必须出现在目录与目标栏（只用已投影的 projectName，不读文件）。
    func testHistoryOnlyTargetIsDiscoveredFromTheProjection() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0), targets: "[]"))
        XCTAssertTrue(s.railInputs.contains { $0.key == "A" }, "a history-only target must enter the directory")
        XCTAssertEqual(s.railInputs.first { $0.key == "A" }?.title, "P")
        XCTAssertNil(s.railInputs.first { $0.key == "A" }?.target)
    }

    // R5：历史投影发现的旧目标是墓碑时，重放不复活。
    func testDiscoveredTombstoneIsNotRevivedByReplay() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0), targets: "[]"))
        XCTAssertTrue(s.deleteThread("A"))
        try await feed(s, state(online: false, observation: obs(Self.t0 + 1), targets: "[]"))
        XCTAssertFalse(s.railInputs.contains { $0.key == "A" })
    }

    func testHistoricalTargetNotInTheRegistryAppearsOnTheRail() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0), targets: "[]", history: "[]"))
        s.archive.touch("b1|gone", title: "已登记的旧目标", lastActivity: Self.t0 - Self.day)
        let gone = s.railInputs.first { $0.key == "gone" }
        XCTAssertEqual(gone?.title, "已登记的旧目标", "the integrity directory supplies historical rows the state no longer lists")
        XCTAssertNil(gone?.target)
    }

    // R3：同一帧的新排队工作在第 7 天也必须保护（经最终合并后裁决）。
    func testSameFrameWorkProtectsOnTheSeventhDay() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0)))
        let queued = #"[{"key":"new","inboxSeq":1,"truncated":false,"origin":"api","state":"queued","targetId":"A","text":"new work"}]"#
        try await feed(s, state(online: false, observation: obs(Self.t0 + 7 * Self.day), commands: queued))
        XCTAssertTrue(s.archivedThreads.isEmpty, "queued work in the same snapshot must protect before absence is judged")
        XCTAssertFalse(s.isHiddenFromMain("A"))
    }

    // R3：草稿（即使未选中）与未知结果同样保护。
    func testDraftAndUnknownResultProtect() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0)))
        var d = s.draft("A")
        d.text = "未发送的草稿"
        s.setDraft(d, for: "A")
        try await feed(s, state(online: false, observation: obs(Self.t0 + 7 * Self.day)))
        XCTAssertTrue(s.archivedThreads.isEmpty, "an unsent draft protects the thread even when not selected")
        XCTAssertFalse(s.canArchiveOrDelete("A"))

        let u = session()
        try await feed(u, state(online: false, observation: obs(Self.t0)))
        let unknown = #"[{"key":"uncertain","inboxSeq":1,"truncated":false,"origin":"api","state":"unknown","targetId":"A","text":"unsure"}]"#
        try await feed(u, state(online: false, observation: obs(Self.t0 + 7 * Self.day), commands: unknown))
        XCTAssertTrue(u.archivedThreads.isEmpty, "an unknown send result is protected work")
    }

    // R3：同一时刻的新工作立即恢复（不受 complete/fresh/t 推进门禁限制）。
    func testSameTimestampWorkRestoresTheThread() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0)))
        try await feed(s, state(online: false, observation: obs(Self.t0 + 7 * Self.day)))
        XCTAssertEqual(s.archivedThreads.map(\.id), ["A"])
        let queued = #"[{"key":"new","inboxSeq":1,"truncated":false,"origin":"api","state":"queued","targetId":"A","text":"new work"}]"#
        try await feed(s, state(online: false, observation: obs(Self.t0 + 7 * Self.day), commands: queued))
        XCTAssertTrue(s.archivedThreads.isEmpty && !s.isHiddenFromMain("A"))
    }

    // R4：online 为 null 且无完整观察（未知）时不得归档或删除。
    func testUnknownOnlineIsNeverTreatedAsOffline() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: nil, targets: #"[{"projectName":"P","id":"A","online":null}]"#))
        XCTAssertFalse(s.canArchiveOrDelete("A"))
        XCTAssertFalse(s.archiveThread("A"))
        XCTAssertFalse(s.deleteThread("A"))
    }

    // R1：首载不靠 nextBefore；失败可重试；hasMore 为假后不再请求。
    func testFirstLoadIssuesOneRequestAndRetriesAfterFailure() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0)))
        let fake = MacHistoryFake(pages: [TargetHistoryPage(items: [TargetHistoryRow(id: "outbox:u1", source: "outbox", text: "旧的对话", t: 1)], nextBefore: nil, hasMore: false, partial: false)])
        await fake.setFailFirst()
        s.archiveClientOverride = { fake }
        await s.loadArchivedHistory("A", older: false)
        XCTAssertTrue(s.archivedPage("A").failed && s.archivedPage("A").canLoadInitial, "a failed first load stays retryable")
        await s.loadArchivedHistory("A", older: true)
        let calls = await fake.calls
        XCTAssertEqual(calls, [nil, nil], "the retry is an initial request, not a cursor request")
        XCTAssertEqual(s.archivedPage("A").items.map(\.id), ["outbox:u1"])
        XCTAssertFalse(s.archivedPage("A").canLoadMore || s.archivedPage("A").canLoadInitial)
        await s.loadArchivedHistory("A", older: true)
        let after = await fake.calls
        XCTAssertEqual(after.count, 2, "no request once the history is exhausted")
    }

    // R2：断开后不得看到旧正文；在途请求返回前已断开，结果不回填。
    func testCachedBodyDoesNotCrossBridgeOrReturnAfterStop() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0)))
        let page = TargetHistoryPage(items: [TargetHistoryRow(id: "outbox:x", source: "outbox", text: "bridge-one-only", t: 1)], nextBefore: nil, hasMore: false, partial: false)
        s.archiveClientOverride = { MacHistoryFake(pages: [page]) }
        await s.loadArchivedHistory("A", older: false)
        XCTAssertEqual(s.archivedPage("A").items.count, 1)
        s.stopStream()
        XCTAssertTrue(s.archivedPage("A").items.isEmpty, "stop clears the archived bodies")
        let late = MacHistoryFake(pages: [page])
        await late.setStopDuring { s.stopStream() }
        s.archiveClientOverride = { late }
        await s.loadArchivedHistory("A", older: false)
        XCTAssertTrue(s.archivedPage("A").items.isEmpty, "a late reply after stop must not be written back")
    }

    // F1：没有指令的本机未决发送（结果不明）必须保护，即使缺席已满 7 天；已明确失败的本地记录不保护。
    func testLocalUnknownSendMustProtect() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0)))
        var local = MacSession.Sent(id: UUID(), text: "synthetic uncertain send", at: Date(), afterSeq: 0, targetId: "A")
        local.resultUnknown = true
        s.sent.append(local)
        XCTAssertFalse(s.canArchiveOrDelete("A"), "a local send with no command or inflight entry is still unresolved")
        try await feed(s, state(online: false, observation: obs(Self.t0 + 7 * Self.day)))
        XCTAssertFalse(s.isHiddenFromMain("A"), "an unconfirmed local result must block auto archive")
    }

    func testTerminalLocalSendDoesNotProtect() async throws {
        let s = session()
        try await feed(s, state(online: false, observation: obs(Self.t0)))
        var failed = MacSession.Sent(id: UUID(), text: "definitely failed", at: Date(), afterSeq: 0, targetId: "A")
        failed.error = "rejected"
        s.sent.append(failed)
        try await feed(s, state(online: false, observation: obs(Self.t0 + 7 * Self.day)))
        XCTAssertEqual(s.archivedThreads.map(\.id), ["A"], "a definitively failed send is terminal and does not protect")
    }

    // F2：已授权的指令投影即使没有有效观察（旧 Bridge）也建立本机目录；标题不足时用目标 ID。
    func testCommandOnlyDirectoryWithoutObservation() async throws {
        let s = session()
        let cmds = #"[{"key":"done","inboxSeq":1,"truncated":false,"origin":"api","state":"finished","targetId":"A","text":"old user message"}]"#
        try await feed(s, state(online: false, observation: nil, targets: "[]", history: "[]", commands: cmds))
        XCTAssertTrue(s.railInputs.contains { $0.key == "A" }, "a known command target must enter the directory without an observation")
        XCTAssertEqual(s.railInputs.first { $0.key == "A" }?.title, "A", "without a projected title the target id is used")
    }
}
