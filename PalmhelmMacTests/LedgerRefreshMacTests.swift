import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #110 A+B（Mac）：账本刷新与共同消息状态。合成数据，假 SearchTranscriptClient，不起 Bridge。

/// 按游标给页的假客户端；可让下一次请求挂起直到 release（模拟在途 / 迟到）。
private actor MacLedgerFake: SearchTranscriptClient {
    private(set) var calls: [String?] = []
    private var pages: [String: TargetHistoryPage] = [:]
    private var holdNextCall = false
    private var holding: CheckedContinuation<Void, Never>?
    func setPages(_ p: [String?: TargetHistoryPage]) { pages = Dictionary(uniqueKeysWithValues: p.map { ($0.key ?? "", $0.value) }) }
    func holdNext() { holdNextCall = true }
    var isHolding: Bool { holding != nil }
    func release() { holding?.resume(); holding = nil }
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage { throw URLError(.notConnectedToInternet) }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage {
        calls.append(before)
        if holdNextCall { holdNextCall = false; await withCheckedContinuation { holding = $0 } }
        return pages[before ?? ""] ?? TargetHistoryPage(items: [], nextBefore: nil, hasMore: false, partial: false)
    }
}

private func row(_ n: Int, state: String = "started") -> TargetHistoryRow {
    let key = "api:d:\(n)"
    return TargetHistoryRow(id: "inbox:\(key)", source: "inbox", text: "text\(n)", t: n * 10, targetId: "A", state: state,
                            command: ApiCommand(key: key, inboxSeq: n, text: "text\(n)", origin: "api", targetId: "A", state: state))
}

private func page(_ rows: [TargetHistoryRow], next: String?, more: Bool = true) -> TargetHistoryPage {
    TargetHistoryPage(items: rows, nextBefore: next, hasMore: more, partial: false)
}

@MainActor
final class LedgerRefreshMacTests: XCTestCase {
    private var suite = ""
    override func setUp() { super.setUp(); suite = "mac-ledger-refresh-\(UUID().uuidString)" }
    override func tearDown() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); super.tearDown() }

    private func rig() async throws -> MacSession {
        let s = MacSession()
        s.archive = ThreadArchiveStore(defaults: UserDefaults(suiteName: suite)!)
        let st = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[{"projectName":"P","id":"A","online":true},{"projectName":"Q","id":"B","online":true}],"history":{"highWater":0,"items":[]},"commands":[]}"#.utf8))
        s.stateOverride = { st }
        try await s.pullState()
        return s
    }

    /// 三页已加载：[9,8,7]（n1）→ [6,5,4]（n2）→ [3,2,1]（n3，仍有更多）。
    private func loadThreePages(_ s: MacSession, _ fake: MacLedgerFake) async {
        await fake.setPages([nil: page([row(7), row(8), row(9)], next: "n1"), "n1": page([row(4), row(5), row(6)], next: "n2"), "n2": page([row(1), row(2), row(3)], next: "n3")])
        s.archiveClientOverride = { fake }
        await s.loadArchivedHistory("A", older: false)
        await s.loadArchivedHistory("A", older: true)
        await s.loadArchivedHistory("A", older: true)
    }

    func testReopeningRefreshesChangedStatesAcrossAllLoadedPagesKeepingCursorAndOrder() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        let before = s.archivedPage("A").items.map(\.id)
        XCTAssertEqual(s.archivedPage("A").nextBefore, "n3")
        await fake.setPages([nil: page([row(7), row(8), row(9)], next: "n1"), "n1": page([row(4), row(5, state: "unknown"), row(6)], next: "n2"), "n2": page([row(1, state: "unknown"), row(2), row(3)], next: "n3")])
        await s.refreshArchivedHistory("A", scope: try XCTUnwrap(s.ledgerScope("A")))
        let p = s.archivedPage("A")
        XCTAssertEqual(p.items.map(\.id), before)
        XCTAssertEqual(p.items.first { $0.id == "inbox:api:d:5" }?.command?.state, "unknown")
        XCTAssertEqual(p.items.first { $0.id == "inbox:api:d:1" }?.state, "unknown")
        XCTAssertTrue(p.nextBefore == "n3" && p.hasMore && !p.refreshing && !p.failed)
        let calls = await fake.calls
        XCTAssertEqual(Array(calls.suffix(3)), [nil, "n1", "n2"])
    }

    func testRowsAddedAtTheHeadBeyondOnePageAreFilledWithoutAGap() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        await fake.setPages([nil: page([row(13), row(14), row(15)], next: "m1"), "m1": page([row(10), row(11), row(12)], next: "m2"), "m2": page([row(7), row(8), row(9)], next: "m3"),
                             "m3": page([row(4), row(5), row(6)], next: "m4"), "m4": page([row(1), row(2), row(3)], next: "m5")])
        await s.refreshArchivedHistory("A", scope: try XCTUnwrap(s.ledgerScope("A")))
        XCTAssertEqual(s.archivedPage("A").items.compactMap(\.t), (1...15).map { $0 * 10 })
    }

    private func waitHolding(_ fake: MacLedgerFake) async { while !(await fake.isHolding) { await Task.yield() } }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    func testActivationsDuringARefreshCoalesceIntoOneTrailingRound() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        let base = await fake.calls.count
        await fake.holdNext()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let first = Task { await s.refreshArchivedHistory("A", scope: scope) }
        await waitHolding(fake)
        // 前台 + 窗口成为 key 两路加一次：各自是独立任务，物理上排队等待，至多一次尾随。
        let more = (0..<3).map { _ in Task { await s.refreshArchivedHistory("A", scope: scope) } }
        await settle()
        let during = await fake.calls.count
        XCTAssertEqual(during - base, 1)
        await fake.release()
        await first.value
        for t in more { await t.value }
        let n = await fake.calls.count
        XCTAssertEqual(n - base, 6)
        XCTAssertFalse(s.archivedPage("A").refreshing)
    }

    // R2 反例：A 挂起 → 取消 A → 新激活 B 登记 → 释放 A → B 读并采纳新 unknown；A 的迟到页不采纳、不续页。
    func testCancellingTheOldRouteNeverSwallowsTheNewActivationsRefresh() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        let base = await fake.calls.count
        await fake.holdNext()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let a = Task { await s.refreshArchivedHistory("A", scope: scope) }
        await waitHolding(fake)
        a.cancel()
        let b = Task { await s.refreshArchivedHistory("A", scope: scope) }
        await settle()
        await fake.setPages([nil: page([row(7), row(8), row(9)], next: "n1"), "n1": page([row(4), row(5, state: "unknown"), row(6)], next: "n2"), "n2": page([row(1, state: "unknown"), row(2), row(3)], next: "n3")])
        await fake.release()
        await a.value
        await b.value
        let p = s.archivedPage("A")
        XCTAssertEqual(p.items.first { $0.id == "inbox:api:d:5" }?.command?.state, "unknown")
        XCTAssertEqual(p.items.first { $0.id == "inbox:api:d:1" }?.state, "unknown")
        let n = await fake.calls.count
        XCTAssertEqual(n - base, 1 + 3)
        XCTAssertTrue(!p.refreshing && !p.failed)
    }

    func testLeavingWithoutANewOwnerLeavesNoTrailingRound() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        let base = await fake.calls.count
        await fake.holdNext()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let a = Task { await s.refreshArchivedHistory("A", scope: scope) }
        await waitHolding(fake)
        a.cancel()
        await fake.release()
        await a.value
        await settle()
        let n = await fake.calls.count
        XCTAssertEqual(n - base, 1)
        XCTAssertTrue(!s.archivedPage("A").refreshing && !s.archivedPage("A").failed)
    }

    func testCancellingTheFirstLoadDiscardsTheLatePageAndDoesNotContinue() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await fake.setPages([nil: TargetHistoryPage(items: [], nextBefore: "n1", hasMore: true, partial: true), "n1": page([row(1)], next: nil, more: false)])
        s.archiveClientOverride = { fake }
        await fake.holdNext()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let t = Task { await s.refreshArchivedHistory("A", scope: scope) }
        await waitHolding(fake)
        t.cancel()
        await fake.release()
        await t.value
        let p = s.archivedPage("A")
        XCTAssertTrue(p.items.isEmpty && !p.loaded && !p.loading && !p.failed)
        let n = await fake.calls.count
        XCTAssertEqual(n, 1)
        await s.refreshArchivedHistory("A", scope: scope)
        XCTAssertEqual(s.archivedPage("A").items.map(\.id), ["inbox:api:d:1"])
    }

    func testACancelledOlderPageIsDiscardedAndTheNextRoundStillRuns() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        await fake.setPages([nil: page([row(7), row(8), row(9)], next: "n1"), "n1": page([row(4), row(5), row(6)], next: "n2"), "n2": page([row(1), row(2), row(3)], next: "n3"),
                             "n3": page([row(0, state: "stale-older")], next: nil, more: false)])
        await fake.holdNext()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let older = Task { await s.loadArchivedHistory("A", older: true, scope: scope) }
        await waitHolding(fake)
        older.cancel()
        let refresh = Task { await s.refreshArchivedHistory("A", scope: scope) }
        await settle()
        await fake.release()
        await older.value
        await refresh.value
        let p = s.archivedPage("A")
        XCTAssertFalse(p.items.contains { $0.state == "stale-older" })
        XCTAssertTrue(!p.loading && !p.refreshing)
        XCTAssertEqual(p.nextBefore, "n3")
    }

    // R4：等待槽期间缓存被删除 / 连接断开：醒来的旧排队请求按入队前冻结的归属零请求零写入退出，不复活已删缓存。
    private func deleteCache(_ s: MacSession) {
        let key = s.archiveKey("A")
        s.archivedPaging[key] = nil
        s.archiveDeleteEpoch[key, default: 0] += 1
    }

    func testAQueuedRequestWokenAfterTheCacheWasDeletedIssuesNothingAndResurrectsNothing() async throws {
        for kind in ["refresh", "older"] {
            let s = try await rig()
            let fake = MacLedgerFake()
            await loadThreePages(s, fake)
            let base = await fake.calls.count
            await fake.holdNext()
            let scope = try XCTUnwrap(s.ledgerScope("A"))
            let a = Task { await s.refreshArchivedHistory("A", scope: scope) }
            await waitHolding(fake)
            let b = Task {
                if kind == "refresh" { await s.refreshArchivedHistory("A", scope: scope) } else { await s.loadArchivedHistory("A", older: true, scope: scope) }
            }
            await settle()
            deleteCache(s)
            await fake.release()
            await a.value
            await b.value
            let n = await fake.calls.count
            XCTAssertEqual(n - base, 1, kind)
            let p = s.archivedPage("A")
            XCTAssertTrue(p.items.isEmpty && !p.loaded && !p.loading && !p.refreshing, kind)
        }
    }

    func testANewRouteAfterDeletionOwnsItsOwnSlotAndOldWaitersCannotTouchIt() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        let base = await fake.calls.count
        await fake.holdNext()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let a = Task { await s.refreshArchivedHistory("A", scope: scope) }
        await waitHolding(fake)
        let b = Task { await s.refreshArchivedHistory("A", scope: scope) }
        await settle()
        deleteCache(s)
        await s.refreshArchivedHistory("A", scope: scope)
        let afterC = s.archivedPage("A")
        XCTAssertTrue(afterC.loaded && afterC.items.count == 3)
        let callsAfterC = await fake.calls.count
        XCTAssertEqual(callsAfterC - base, 2)
        await fake.release()
        await a.value
        await b.value
        let p = s.archivedPage("A")
        let callsEnd = await fake.calls.count
        XCTAssertEqual(callsEnd, callsAfterC)
        XCTAssertEqual(p.items.map(\.id), afterC.items.map(\.id))
        XCTAssertTrue(!p.loading && !p.refreshing)
    }

    func testAQueuedRequestWithoutScopeDoesNotRebindAcrossADisconnect() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        let base = await fake.calls.count
        await fake.holdNext()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let a = Task { await s.refreshArchivedHistory("A", scope: scope) }
        await waitHolding(fake)
        let b = Task { await s.refreshArchivedHistory("A") }
        await settle()
        s.stopStream()
        await fake.release()
        await a.value
        await b.value
        let n = await fake.calls.count
        XCTAssertEqual(n - base, 1)
        XCTAssertTrue(s.archivedPage("A").items.isEmpty)
    }

    func testDisconnectDuringARefreshNeverResurrectsRows() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        await fake.holdNext()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let t = Task { await s.refreshArchivedHistory("A", scope: scope) }
        while !(await fake.isHolding) { await Task.yield() }
        s.stopStream()
        await fake.release()
        await t.value
        XCTAssertTrue(s.archivedPage("A").items.isEmpty)
    }

    func testAStaleScopeIssuesNoRequest() async throws {
        let s = try await rig()
        let fake = MacLedgerFake()
        await loadThreePages(s, fake)
        let n = await fake.calls.count
        await s.refreshArchivedHistory("A", scope: LedgerScope(targetId: "A", epoch: -1, bridgeId: "b1"))
        let m = await fake.calls.count
        XCTAssertEqual(m, n)
    }

    // B：账本与对话页同一状态

    func testLedgerStatusFollowsTheCurrentCommandAndEqualsTheConversationStatus() async throws {
        let s = try await rig()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let stale = row(5, state: "started")
        XCTAssertEqual(s.ledgerMessageStatus(stale, scope: scope), MessageStatusRules.standalone(try XCTUnwrap(stale.command)))
        let current = ApiCommand(key: "api:d:5", inboxSeq: 5, text: "text5", origin: "api", targetId: "A", state: "unknown")
        s.commands[current.key] = current
        let ledger = try XCTUnwrap(s.ledgerMessageStatus(stale, scope: scope))
        XCTAssertEqual(ledger, s.messageStatus(for: current))
        XCTAssertEqual(ledger.phase, .unknown)
        XCTAssertEqual(s.commands.count, 1)
        XCTAssertEqual(s.commands[current.key]?.state, "unknown")
    }

    func testLedgerStatusNeverBorrowsAcrossTargetsScopesOrSources() async throws {
        let s = try await rig()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let elsewhere = ApiCommand(key: "api:d:5", inboxSeq: 5, text: "x", origin: "api", targetId: "B", state: "unknown")
        s.commands[elsewhere.key] = elsewhere
        let r = row(5, state: "started")
        XCTAssertEqual(s.ledgerMessageStatus(r, scope: scope), MessageStatusRules.standalone(try XCTUnwrap(r.command)))
        XCTAssertNil(s.ledgerMessageStatus(r, scope: LedgerScope(targetId: "A", epoch: -1, bridgeId: "b1")))
        let outbox = TargetHistoryRow(id: "outbox:u1", source: "outbox", text: "r", t: 1, state: "delivered")
        XCTAssertNil(s.ledgerMessageStatus(outbox, scope: scope))
    }
}
