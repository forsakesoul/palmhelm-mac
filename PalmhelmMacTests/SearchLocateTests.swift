import Foundation
import PalmhelmKit
import XCTest
@testable import PalmhelmMac

// 会话搜索的定位（h6b 终审 F1–F4）：真实调用 MacSession.openSearchHit / loadTranscriptOlder / transcriptChanged / selectTarget，
// 网络由注入的假客户端替身，挂起点由 Gate 控制。
/// 假客户端：可变状态只在 actor 内访问。参数：第几次调用（从 1 起）、cursor。
private actor FakeTranscriptClient: SearchTranscriptClient {
    private let handler: @Sendable (Int, String?) async throws -> TranscriptPage
    private var calls = 0
    init(_ handler: @escaping @Sendable (Int, String?) async throws -> TranscriptPage) { self.handler = handler }
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage {
        calls += 1
        return try await handler(calls, before)
    }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage {
        TargetHistoryPage(items: [], nextBefore: nil, hasMore: false, partial: false)
    }
    func callCount() -> Int { calls }
}

/// 测试里可变的最新页内容（actor 隔离）。
private actor IdBox {
    private(set) var value: [String]
    init(_ v: [String]) { value = v }
    func append(_ id: String) { value.append(id) }
}

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func page(_ ids: [String], before: String? = nil, hasMore: Bool = false, revision: String = "r") -> TranscriptPage {
    TranscriptPage(status: "ok", sessionEpoch: "e1", revision: revision, items: ids.map { TranscriptItem(id: $0, role: "user", text: $0) }, nextBefore: before, hasMore: hasMore)
}

private func hit(_ item: String, before: String?) -> SearchHit {
    SearchHit(targetId: "A", itemId: item, sessionEpoch: "e1", pageBefore: before, role: "user", snippet: "zeta", ranges: [[0, 4]])
}

/// 最新页 [m5, m6]（有更早的 c-latest）。
private var latest: TranscriptPage { page(["m5", "m6"], before: "c-latest", hasMore: true) }

final class SearchLocateTests: XCTestCase {
    @MainActor
    private func session(_ handler: @escaping @Sendable (Int, String?) async throws -> TranscriptPage) -> (MacSession, FakeTranscriptClient) {
        let s = MacSession()
        // 搜索入口与打开线程共用「在线 + 目标存在」守卫：这里把会话置为已连接且有 A / B 两个目标
        s.state = try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[{"projectName":"A","id":"A","online":true},{"projectName":"B","id":"B","online":true}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.link = .connected
        let client = FakeTranscriptClient(handler)
        s.searchClientOverride = { client }
        s.selectTarget("A")
        _ = s.transcriptActivation.activate("A") // 线程可见且在前台：与视图的激活一致（会话读取只在此时发起）
        return (s, client)
    }

    /// 等到条件成立；超时记为失败。
    @MainActor
    private func waitUntil(_ cond: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("等待条件超时", file: file, line: line)
    }

    /// 等到某线程的在途请求数达到 n；超时记为失败（不静默继续）。
    @MainActor
    private func waitForActive(_ s: MacSession, _ id: String, _ n: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if s.requestBook(id).activeRequests >= n { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("等待 \(id) 在途请求达到 \(n) 超时", file: file, line: line)
    }

    @MainActor
    func testHitPageLocatesAndSetsForcedConversationMode() async {
        let (s, _) = session { _, before in before == nil ? latest : page(["x1", "x2"], before: "c-x", hasMore: true) }
        s.threadMode = 1
        await s.openSearchHit(hit("x2", before: "c-x"))
        XCTAssertEqual(s.threadMode, 0)
        XCTAssertEqual(s.located?.threadId, "A")
        XCTAssertEqual(s.located?.itemId, "x2")
        XCTAssertEqual(s.transcripts["A"]?.pinnedHit, "x2")
        XCTAssertEqual(s.transcripts["A"]?.items.map(\.id), ["x1", "x2"])
        XCTAssertNil(s.locateNote)
    }

    @MainActor
    func testReopeningSameHitBumpsSerial() async {
        let (s, _) = session { _, before in before == nil ? latest : page(["x1", "x2"], before: "c-x") }
        await s.openSearchHit(hit("x2", before: "c-x"))
        let first = s.located?.serial
        await s.openSearchHit(hit("x2", before: "c-x"))
        XCTAssertNotNil(first)
        XCTAssertEqual(s.located?.serial, (first ?? 0) + 1)
    }

    @MainActor
    func testCursorPageWithoutItemReportsMovedAndKeepsLatest() async {
        let (s, _) = session { _, before in before == nil ? latest : page(["x1"]) }
        await s.openSearchHit(hit("gone", before: "c-x"))
        XCTAssertNil(s.located)
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
        XCTAssertEqual(s.locateNote, "这条记录已移动，请重新搜索")
    }

    @MainActor
    func testGoneCursorReportsMovedAndOtherFailuresReportOpenFailure() async {
        let (s, _) = session { _, before in
            if before == "c-410" { throw BridgeError.http(status: 410) }
            if before == "c-503" { throw BridgeError.http(status: 503) }
            return latest
        }
        await s.openSearchHit(hit("x", before: "c-410"))
        XCTAssertEqual(s.locateNote, "这条记录已移动，请重新搜索")
        await s.openSearchHit(hit("x", before: "c-503"))
        XCTAssertEqual(s.locateNote, "打开这条记录失败，请稍后再试")
        XCTAssertNil(s.located)
    }

    @MainActor
    func testCursorlessHitLocatesOnFreshLatestPage() async {
        let (s, _) = session { _, _ in page(["m5", "m6"]) }
        await s.openSearchHit(hit("m6", before: nil))
        XCTAssertEqual(s.located?.itemId, "m6")
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
        XCTAssertNil(s.locateNote)
    }

    // F1：最新页请求在途时，无 cursor 命中不等它：自己读一页判定，成功即定位，失败只报打开失败。
    @MainActor
    func testInFlightLatestDoesNotMakeCursorlessHitMoved() async {
        let gate = Gate()
        let (s, client) = session { call, _ in
            if call == 1 { await gate.wait(); return page(["m5"]) }
            return page(["m5", "m6"])
        }
        let inFlight = Task { @MainActor in await s.loadTranscriptLatest("A") }
        await waitForActive(s, "A", 1)
        await s.openSearchHit(hit("m6", before: nil))
        XCTAssertEqual(s.located?.itemId, "m6")
        XCTAssertNil(s.locateNote)
        await gate.release()
        await inFlight.value
        XCTAssertEqual(s.located?.itemId, "m6") // 迟到的最新页不改定位（它的快照已过期，只记 dirty）
        XCTAssertNil(s.locateNote)
        let calls = await client.callCount()
        XCTAssertGreaterThanOrEqual(calls, 2)
    }

    @MainActor
    func testInFlightLatestThenFailedFreshReadReportsOpenFailure() async {
        let gate = Gate()
        let (s, _) = session { call, _ in
            if call == 1 { await gate.wait(); return page(["m5"]) }
            throw URLError(.networkConnectionLost)
        }
        let inFlight = Task { @MainActor in await s.loadTranscriptLatest("A") }
        await waitForActive(s, "A", 1)
        await s.openSearchHit(hit("m6", before: nil))
        XCTAssertNil(s.located)
        XCTAssertEqual(s.locateNote, "打开这条记录失败，请稍后再试")
        await gate.release()
        await inFlight.value
    }

    // F2：旧 pin → 410 → 最新
    @MainActor
    func testStalePinThenOlderGoneReturnsToLatest() async {
        let (s, _) = session { _, before in
            if before == nil { return latest }
            if before == "c-x" { return page(["x1", "x2"], before: "c-y", hasMore: true) }
            throw BridgeError.http(status: 410)
        }
        await s.openSearchHit(hit("x2", before: "c-x"))
        XCTAssertEqual(s.transcripts["A"]?.pinnedHit, "x2")
        await s.loadTranscriptOlder("A")
        XCTAssertNil(s.located)
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
        await s.loadTranscriptLatest("A")
        XCTAssertEqual(s.transcripts["A"]?.items.map(\.id), ["m5", "m6"])
    }

    // F2：旧 pin → 缺 item → 最新
    @MainActor
    func testStalePinThenMissingItemReturnsToLatest() async {
        let (s, _) = session { _, before in before == nil ? latest : (before == "c-x" ? page(["x1", "x2"]) : page(["y1"])) }
        await s.openSearchHit(hit("x2", before: "c-x"))
        await s.openSearchHit(hit("missing", before: "c-y"))
        XCTAssertNil(s.located)
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
        XCTAssertEqual(s.locateNote, "这条记录已移动，请重新搜索")
        XCTAssertEqual(s.transcripts["A"]?.items.map(\.id).suffix(2), ["m5", "m6"]) // 首屏补齐（#111）会在前面接上更早页：只断言最新两条仍在末尾
    }

    // F2：旧 pin → 无 cursor 命中
    @MainActor
    func testStalePinThenCursorlessHitReturnsToLatest() async {
        let (s, _) = session { _, before in before == nil ? latest : page(["x1", "x2"]) }
        await s.openSearchHit(hit("x2", before: "c-x"))
        await s.openSearchHit(hit("m6", before: nil))
        XCTAssertEqual(s.located?.itemId, "m6")
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
        XCTAssertEqual(s.transcripts["A"]?.items.map(\.id), ["m5", "m6"])
    }

    // F2：A → B → A 不残留横幅，A 正常接新消息。
    @MainActor
    func testAThenBThenADoesNotKeepPinAndReceivesNewMessages() async {
        let ids = IdBox(["m5", "m6"])
        let (s, _) = session { _, before in
            before == nil ? page(await ids.value, before: "c-latest", hasMore: true) : page(["x1", "x2"], before: "c-x", hasMore: true)
        }
        await s.openSearchHit(hit("x2", before: "c-x"))
        s.selectTarget("B")
        XCTAssertNil(s.located)
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
        s.selectTarget("A")
        await ids.append("m7")
        await s.loadTranscriptLatest("A")
        XCTAssertNil(s.located)
        XCTAssertEqual(s.transcripts["A"]?.items.map(\.id).suffix(3), ["m5", "m6", "m7"]) // 同上：补齐接在前面
    }

    // F3：挂起的定位 → reset → 释放旧响应不生效。
    @MainActor
    func testResetWhileLocatingDropsLateResponse() async {
        let gate = Gate()
        let (s, _) = session { _, before in
            if before == "c-x" { await gate.wait(); return page(["x1", "x2"], before: "c-y") }
            return latest
        }
        let opening = Task { @MainActor in await s.openSearchHit(hit("x2", before: "c-x")) }
        await waitForActive(s, "A", 1)
        s.transcriptChanged(TranscriptChange(targetId: "A", sessionEpoch: "e1", revision: "r2", kind: "reset"))
        await gate.release()
        await opening.value
        XCTAssertNil(s.located)
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
    }

    // F3：两槽满不发请求，提示稍后再试。
    @MainActor
    func testFullSlotsSendNothingAndSayBusy() async {
        let (s, client) = session { _, _ in latest }
        s.transcripts["A"] = TranscriptThread()
        s.transcriptRequestBook["A"] = TranscriptRequestBook(activeRequests: 2)
        await s.openSearchHit(hit("x2", before: "c-x"))
        let calls = await client.callCount()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(s.located)
        XCTAssertEqual(s.locateNote, "记录还在加载，稍后再试")
    }

    // F3：同线程连点两次，只有后一次生效。
    @MainActor
    func testDoubleOpenInSameThreadOnlyLaterApplies() async {
        let g1 = Gate(), g2 = Gate()
        let (s, _) = session { _, before in
            if before == "c-1" { await g1.wait(); return page(["x1"]) }
            if before == "c-2" { await g2.wait(); return page(["x2"]) }
            return latest
        }
        let first = Task { @MainActor in await s.openSearchHit(hit("x1", before: "c-1")) }
        await waitForActive(s, "A", 1)
        let second = Task { @MainActor in await s.openSearchHit(hit("x2", before: "c-2")) }
        await waitForActive(s, "A", 2)
        await g1.release()
        await first.value
        XCTAssertNil(s.located)
        await g2.release()
        await second.value
        XCTAssertEqual(s.located?.itemId, "x2")
        XCTAssertEqual(s.transcripts["A"]?.pinnedHit, "x2")
    }

    // R2：两个挂起定位占满槽 → 失效 → 释放 → 无需额外事件即补拉，最终 activeRequests == 0。
    @MainActor
    func testDirtyRefillRunsAfterLocateReleasesSlots() async {
        let g1 = Gate(), g2 = Gate()
        let (s, _) = session { _, before in
            if before == "c-1" { await g1.wait(); return page(["x1"]) }
            if before == "c-2" { await g2.wait(); return page(["x2"]) }
            return page(["m5", "fresh"], revision: "r10")
        }
        let a = Task { @MainActor in await s.openSearchHit(hit("x1", before: "c-1")) }
        await waitForActive(s, "A", 1)
        let b = Task { @MainActor in await s.openSearchHit(hit("x2", before: "c-2")) }
        await waitForActive(s, "A", 2)
        s.transcriptChanged(TranscriptChange(targetId: "A", sessionEpoch: "e1", revision: "r9", kind: "append")) // 槽满 → 记 dirty
        s.transcriptChanged(TranscriptChange(targetId: "A", sessionEpoch: "e1", revision: "r10", kind: "reset"))
        await waitUntil { s.transcripts["A"]?.dirty == true } // transcriptChanged 内部的补拉是异步任务，等它记下 dirty
        XCTAssertEqual(s.transcripts["A"]?.dirty, true)
        XCTAssertEqual(s.requestBook("A").activeRequests, 2)
        await g1.release()
        await g2.release()
        await a.value
        await b.value
        XCTAssertEqual(s.transcripts["A"]?.items.map(\.id), ["m5", "fresh"])
        XCTAssertEqual(s.requestBook("A").activeRequests, 0)
    }

    // R3：普通最新页在途时，定位自读的新页生效；旧普通页迟到不得覆盖正文与 revision。
    @MainActor
    func testStaleLatestCannotOverwriteLocatedFreshPage() async {
        let gate = Gate()
        let (s, _) = session { call, before in
            if before == nil && call == 1 { await gate.wait(); return page(["m5", "old"], revision: "r1") }
            if before == nil { return page(["m5", "needle"], revision: "r2") }
            return page(["x"])
        }
        var cached = TranscriptThread()
        cached.applyLatest(page(["m5", "old"], revision: "r1"))
        s.transcripts["A"] = cached
        let latestTask = Task { @MainActor in await s.loadTranscriptLatest("A") }
        await waitForActive(s, "A", 1)
        await s.openSearchHit(hit("needle", before: nil))
        await gate.release()
        await latestTask.value
        XCTAssertEqual(s.transcripts["A"]?.items.map(\.text), ["m5", "needle"])
        XCTAssertEqual(s.transcripts["A"]?.revision, "r2")
    }

    // R4：挂起 A 定位 → 列表选系统 → 选回 A → 旧响应不生效（ABA）。
    @MainActor
    func testSelectionAwayAndBackDropsPendingLocate() async {
        let gate = Gate()
        let (s, _) = session { _, before in
            if before == "c-x" { await gate.wait(); return page(["x1", "x2"]) }
            return page(["m5"])
        }
        let opening = Task { @MainActor in await s.openSearchHit(hit("x2", before: "c-x")) }
        await waitForActive(s, "A", 1)
        s.selectedThread = MacSession.legacySystemThread
        s.selectedThread = "A"
        await gate.release()
        await opening.value
        XCTAssertNil(s.located)
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
    }

    // F4：新的导航意图（openInbox / openThread / openRequest …）使在途定位失效；已落地的 pin 不受影响。
    @MainActor
    func testNewNavigationIntentInvalidatesInFlightLocate() async {
        let gate = Gate()
        let (s, _) = session { _, before in
            if before == "c-x" { await gate.wait(); return page(["x1", "x2"]) }
            return page(["m5"])
        }
        let opening = Task { @MainActor in await s.openSearchHit(hit("x2", before: "c-x")) }
        await waitForActive(s, "A", 1)
        s.openInbox() // 新的导航意图
        await gate.release()
        await opening.value
        XCTAssertNil(s.located, "旧页返回不应用")
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
        XCTAssertNil(s.locateNote)
        XCTAssertEqual(s.pendingNav?.destination, .inbox)
    }

    @MainActor
    func testOpenThreadIntentAlsoInvalidatesInFlightLocate() async {
        let gate = Gate()
        let (s, _) = session { _, before in
            if before == "c-x" { await gate.wait(); return page(["x1", "x2"]) }
            return page(["m5"])
        }
        let opening = Task { @MainActor in await s.openSearchHit(hit("x2", before: "c-x")) }
        await waitForActive(s, "A", 1)
        s.openThread("B")
        await gate.release()
        await opening.value
        XCTAssertNil(s.located)
        XCTAssertEqual(s.selectedTarget, "B")
    }

    @MainActor
    func testExistingPinSurvivesALaterInboxIntent() async {
        let (s, _) = session { _, before in before == nil ? latest : page(["x1", "x2"], before: "c-x", hasMore: true) }
        await s.openSearchHit(hit("x2", before: "c-x"))
        XCTAssertEqual(s.located?.itemId, "x2")
        s.openInbox()
        XCTAssertEqual(s.located?.itemId, "x2", "已落地的定位不因导航意图被清掉（回到最新规则不变）")
    }

    // F4：搜索入口与 openThread 同一守卫：离线 / 目标已移除 → 转收件箱并说明，不读页、不定位
    @MainActor
    func testSearchOpenIsGuardedWhenOfflineOrTargetRemoved() async {
        let (s, client) = session { _, _ in latest }
        s.link = .offline("x")
        await s.openSearchHit(hit("m6", before: nil))
        XCTAssertNil(s.located)
        XCTAssertEqual(s.pendingNav?.destination, .inbox)
        XCTAssertNotNil(s.navNotice)
        s.openFromSearch(targetId: "B")
        XCTAssertEqual(s.selectedTarget, "A", "离线不切目标")
        XCTAssertEqual(s.pendingNav?.destination, .inbox)
        s.link = .connected
        let gone = SearchHit(targetId: "ZZ", itemId: "m6", sessionEpoch: "e1", pageBefore: nil, role: "user", snippet: "zeta", ranges: [[0, 4]])
        await s.openSearchHit(gone)
        XCTAssertNil(s.located)
        XCTAssertTrue(s.navNotice?.text.contains("不在") == true)
        s.openFromSearch(targetId: "ZZ")
        XCTAssertEqual(s.selectedTarget, "A")
        let calls = await client.callCount()
        XCTAssertEqual(calls, 0, "被守卫拦下的入口不读任何页")
    }

    // R4：目标移除（选中被清空）即退出定位与 pin。
    @MainActor
    func testTargetRemovalClearsLocatedPin() async {
        let (s, _) = session { _, before in before == nil ? latest : page(["x1", "x2"], before: "c-x", hasMore: true) }
        await s.openSearchHit(hit("x2", before: "c-x"))
        XCTAssertEqual(s.located?.itemId, "x2")
        s.selectedThread = nil
        XCTAssertNil(s.located)
        XCTAssertNil(s.transcripts["A"]?.pinnedHit)
    }

    // R5：独立搜索窗口打开命中时请求主窗口切到对话页（视图侧在 onAppear / onChange 里消费）。
    @MainActor
    func testHitRequestsConversationPage() async {
        let (s, _) = session { _, _ in latest }
        XCTAssertFalse(s.requestConversation)
        await s.openSearchHit(hit("m6", before: nil))
        XCTAssertTrue(s.requestConversation)
    }

    // S3：搜索窗口的目标行入口请求回对话页；普通 selectTarget 没有页面副作用。
    @MainActor
    func testSearchTargetRowRequestsConversationButPlainSelectDoesNot() {
        let (s, _) = session { _, _ in latest }
        s.requestConversation = false
        s.selectTarget("B")
        XCTAssertFalse(s.requestConversation)
        s.openFromSearch(targetId: "B")
        XCTAssertTrue(s.requestConversation)
        XCTAssertEqual(s.selectedThread, "B")
    }
}
