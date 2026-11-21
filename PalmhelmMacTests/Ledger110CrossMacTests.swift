import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #110 组合交叉（A+B 账本刷新/共同状态 × C 回执后补，Mac）：真实 MacSession，假客户端，不起 Bridge。

private actor MacCrossFake: SearchTranscriptClient {
    private(set) var transcriptCalls = 0
    var historyPages: [String: TargetHistoryPage] = [:]
    var transcript: [Result<TranscriptFetch, Error>] = []
    private var holdHistory = false
    private var holding: CheckedContinuation<Void, Never>?
    func set(history: [String?: TargetHistoryPage]) { historyPages = Dictionary(uniqueKeysWithValues: history.map { ($0.key ?? "", $0.value) }) }
    func set(transcript t: [Result<TranscriptFetch, Error>]) { transcript = t }
    func holdNextHistory() { holdHistory = true }
    var isHolding: Bool { holding != nil }
    func release() { holding?.resume(); holding = nil }
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage { throw URLError(.notConnectedToInternet) }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage {
        if holdHistory { holdHistory = false; await withCheckedContinuation { holding = $0 } }
        return historyPages[before ?? ""] ?? TargetHistoryPage(items: [], nextBefore: nil, hasMore: false, partial: false)
    }
    func transcriptConditional(targetId: String, before: String?, limit: Int, ifNoneMatch: String?, receipt: TranscriptReceiptRequest?) async throws -> TranscriptFetch {
        transcriptCalls += 1
        return try transcript.isEmpty ? .notModified : transcript.removeFirst().get()
    }
}

@MainActor
final class Ledger110CrossMacTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 20_000)
    private let key = "api:d:5"
    private var suite = ""
    override func setUp() { super.setUp(); suite = "mac-cross110-\(UUID().uuidString)" }
    override func tearDown() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); super.tearDown() }

    private func rig() async throws -> MacSession {
        let s = MacSession()
        s.stopStream()
        s.archive = ThreadArchiveStore(defaults: UserDefaults(suiteName: suite)!)
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"cross-mac","name":"mac","paused":false,"permission":"control"}"#.utf8))
        let st = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[{"projectName":"P","id":"A","online":true}],"history":{"highWater":0,"items":[]},"commands":[]}"#.utf8))
        s.stateOverride = { st }
        try await s.pullState()
        return s
    }
    private func wire(_ s: MacSession, _ fake: MacCrossFake) { s.archiveClientOverride = { fake }; s.searchClientOverride = { fake } }
    private func inbound(_ s: MacSession, _ state: String) {
        let json = #"{"key":"\#(key)","inboxSeq":5,"text":"text5","truncated":false,"origin":"api","state":"\#(state)","lane":"ordinary","targetId":"A"}"#
        var parser = SSEParser()
        s.applyStreamEventForTest(BridgeEventDecoder.decode(parser.feed(Data("event: inbound\ndata: \(json)\n\n".utf8))[0]))
    }
    private func historyRow(_ state: String) -> TargetHistoryRow {
        TargetHistoryRow(id: "inbox:\(key)", source: "inbox", text: "text5", t: 50, targetId: "A", state: state,
                         command: ApiCommand(key: key, inboxSeq: 5, text: "text5", origin: "api", targetId: "A", state: state))
    }
    private func historyPage(_ state: String) -> [String?: TargetHistoryPage] { [nil: TargetHistoryPage(items: [historyRow(state)], nextBefore: "n1", hasMore: true, partial: false)] }
    private func tpage(updates: [TranscriptReceiptUpdate]? = nil, epoch: String = "e1") -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: epoch, revision: "r1", items: [TranscriptItem(id: "U", role: "user", text: "text5"), TranscriptItem(id: "R", role: "assistant", text: "答")],
                       nextBefore: nil, hasMore: true, partial: false, receiptUpdates: updates)
    }
    private var patch: TranscriptReceiptUpdate { TranscriptReceiptUpdate(itemId: "U", receipt: TranscriptReceipt(commandKey: "ck", origin: "api", receiptState: "sent", eventKey: key)) }
    private func loadTranscript(_ s: MacSession) {
        var th = TranscriptThread(); th.applyLatest(tpage()); s.transcripts["A"] = th
    }

    func testLedgerAndThreadShareOneUnknownAndTheRefreshUpdatesStateAndCommandTogether() async throws {
        let s = try await rig(); let fake = MacCrossFake(); wire(s, fake)
        await fake.set(history: historyPage("started"))
        await s.loadArchivedHistory("A", older: false)
        inbound(s, "unknown")
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let live = try XCTUnwrap(s.commands[key])
        let row0 = try XCTUnwrap(s.archivedPage("A").items.first)
        XCTAssertEqual(row0.state, "started")
        XCTAssertEqual(s.ledgerMessageStatus(row0, scope: scope)?.phase, s.messageStatus(for: live).phase)
        XCTAssertEqual(s.ledgerMessageStatus(row0, scope: scope)?.phase, .unknown)
        await fake.set(history: historyPage("unknown"))
        await s.refreshArchivedHistory("A", scope: scope)
        let row1 = try XCTUnwrap(s.archivedPage("A").items.first)
        XCTAssertTrue(row1.state == "unknown" && row1.command?.state == "unknown" && row1.text == row0.text && row1.t == row0.t)
        XCTAssertEqual(s.ledgerMessageStatus(row1, scope: scope)?.phase, .unknown)
    }

    func testSupplementRowIsClaimedThenReplacedByTheReceiptWithoutPretendingToBeFinished() async throws {
        let s = try await rig(); let fake = MacCrossFake(); wire(s, fake)
        await fake.set(history: historyPage("unknown"))
        await fake.set(transcript: [.success(.page(tpage(updates: [patch]), etag: "\"v2\"")), .success(.page(tpage(), etag: "\"v3\""))])
        await s.loadArchivedHistory("A", older: false)
        inbound(s, "unknown"); loadTranscript(s)
        XCTAssertTrue(s.sent.isEmpty)
        XCTAssertEqual(s.threadTail(threadId: "A").supplement.map(\.key), [key])
        let token = s.transcriptActivation.activate("A")
        await s.activeTranscriptTick(token, now: t0)
        XCTAssertEqual(s.transcripts["A"]?.items.first?.receipt?.eventKey, key)
        XCTAssertEqual(s.transcripts["A"]?.linkedEventKeys, [key])
        XCTAssertTrue(s.threadTail(threadId: "A").commandRows.isEmpty, "B 消失")
        XCTAssertEqual(s.commands[key]?.state, "unknown", "命令 / inbox 不追认")
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let row = try XCTUnwrap(s.archivedPage("A").items.first)
        XCTAssertEqual(s.ledgerMessageStatus(row, scope: scope)?.phase, .unknown, "账本仍 unknown，没有伪 finished")
        s.transcriptActivation.deactivate()
        let again = s.transcriptActivation.activate("A")
        await s.activeTranscriptTick(again, now: t0.addingTimeInterval(5))
        XCTAssertTrue(s.threadTail(threadId: "A").commandRows.isEmpty)
        XCTAssertEqual(s.transcripts["A"]?.linkedEventKeys, [key])
    }

    func testALedgerRefreshInFlightAndAReceiptPatchEachKeepTheirOwnTicketsAcrossAScopeSwitch() async throws {
        let s = try await rig(); let fake = MacCrossFake(); wire(s, fake)
        await fake.set(history: historyPage("started"))
        await s.loadArchivedHistory("A", older: false)
        inbound(s, "unknown"); loadTranscript(s)
        await fake.set(history: historyPage("unknown"))
        await fake.set(transcript: [.success(.page(tpage(updates: [patch]), etag: "\"v2\""))])
        await fake.holdNextHistory()
        let scope = try XCTUnwrap(s.ledgerScope("A"))
        let refresh = Task { await s.refreshArchivedHistory("A", scope: scope) }
        while !(await fake.isHolding) { await Task.yield() }
        let token = s.transcriptActivation.activate("A")
        await s.activeTranscriptTick(token, now: t0)
        XCTAssertEqual(s.transcripts["A"]?.linkedEventKeys, [key], "刷新挂起期间，回执补丁走自己的票据照常采纳")
        XCTAssertEqual(s.archivedPage("A").items.first?.state, "started", "账本刷新尚未到达，不被回执链改写")
        s.disconnect(reason: "test") // scope（连接代次）变化：旧账本票据失效
        await fake.release(); await refresh.value
        XCTAssertNotEqual(s.ledgerScope("A"), scope)
        // Mac 断连会清掉账本缓存：迟到的旧刷新既不能写回新值，也不能让已清掉的页复活。
        let items = s.archivedPage("A").items
        XCTAssertTrue(items.isEmpty || (items.first?.state == "started" && items.first?.command?.state == "started"), "旧 scope 的迟到刷新零写 / 不复活")
        if let first = s.archivedPage("A").items.first { XCTAssertNil(s.ledgerMessageStatus(first, scope: scope), "旧 scope 不再给状态") }
    }
}
