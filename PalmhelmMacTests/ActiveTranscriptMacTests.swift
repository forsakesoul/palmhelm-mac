import Foundation
import PalmhelmKit
import XCTest
@testable import PalmhelmMac

// #88 S4：Mac 激活读取（条件读取、节拍、A→B→A 丢弃）与按条续读，在 MacSession 入口上验证。不计时：直接调用单次检查。

private actor FakeActiveMac: SearchTranscriptClient {
    private(set) var conditionalTags: [String?] = []
    private(set) var itemCalls: [String] = []
    var fetchResults: [Result<TranscriptFetch, Error>]
    var segmentResults: [Result<TranscriptItemSegment, Error>]
    var onFetch: (@MainActor @Sendable () -> Void)?

    init(fetch: [Result<TranscriptFetch, Error>] = [], segments: [Result<TranscriptItemSegment, Error>] = []) {
        fetchResults = fetch; segmentResults = segments
    }
    func setOnFetch(_ f: @escaping @MainActor @Sendable () -> Void) { onFetch = f }
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage { throw URLError(.notConnectedToInternet) }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage { throw URLError(.notConnectedToInternet) }
    func transcriptConditional(targetId: String, before: String?, limit: Int, ifNoneMatch: String?) async throws -> TranscriptFetch {
        conditionalTags.append(ifNoneMatch)
        if let f = onFetch { onFetch = nil; await f() }
        return try fetchResults.removeFirst().get()
    }
    func transcriptItem(targetId: String, itemId: String, continuation: String) async throws -> TranscriptItemSegment {
        itemCalls.append(continuation)
        return try segmentResults.removeFirst().get()
    }
}

@MainActor
final class ActiveTranscriptMacTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func page(_ items: [TranscriptItem], epoch: String = "e1") -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: epoch, revision: "r1", items: items, nextBefore: nil, hasMore: false, partial: false)
    }

    func testActiveTickFetchesLatestAndKeepsTheETag() async {
        let s = MacSession()
        let fake = FakeActiveMac(fetch: [.success(.page(page([TranscriptItem(id: "i1", role: "user", text: "你好")]), etag: "\"e1\""))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        XCTAssertEqual(s.transcripts["t1"]?.items.map(\.id), ["i1"])
        XCTAssertEqual(s.transcripts["t1"]?.latestETag, "\"e1\"")
        let tags = await fake.conditionalTags
        XCTAssertEqual(tags.count, 1)
        XCTAssertNil(tags[0])
    }

    func testUnchangedPageSendsTheValidatorAndKeepsItems() async {
        let s = MacSession()
        let fake = FakeActiveMac(fetch: [
            .success(.page(page([TranscriptItem(id: "i1", role: "user", text: "你好")]), etag: "\"e1\"")),
            .success(.notModified),
        ])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(2))
        let tags = await fake.conditionalTags
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(tags[1], "\"e1\"")
        XCTAssertEqual(s.transcripts["t1"]?.items.map(\.id), ["i1"])
    }

    func testTickWaitsForTheCadenceAndStopsWhenInactive() async {
        let s = MacSession()
        let fake = FakeActiveMac(fetch: [.success(.page(page([]), etag: "\"e1\"")), .success(.notModified)])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(0.4))
        let early = await fake.conditionalTags.count
        XCTAssertEqual(early, 1)
        s.transcriptActivation.deactivate()
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(5))
        let late = await fake.conditionalTags.count
        XCTAssertEqual(late, 1)
    }

    // A→B→A：读取进行中切到 B 再回到 A，之前 A 的结果不采纳。
    func testResultFromAnEarlierActivationIsDiscarded() async {
        let s = MacSession()
        let fake = FakeActiveMac(fetch: [.success(.page(page([TranscriptItem(id: "stale", role: "user", text: "旧")]), etag: nil))])
        s.searchClientOverride = { fake }
        let firstA = s.transcriptActivation.activate("t1")
        await fake.setOnFetch { _ = s.transcriptActivation.activate("B"); _ = s.transcriptActivation.activate("t1") }
        await s.activeTranscriptTick(firstA, now: t0)
        XCTAssertTrue(s.transcripts["t1"]?.items.isEmpty ?? true, "a result from an earlier activation must not be applied")
    }

    func testContinuationAppendsSegmentsAfterTheShownPrefix() async {
        let s = MacSession()
        let shown = TranscriptItem(id: "i1", role: "assistant", text: "长回复开头…", truncated: true, continuation: "tok1")
        let fake = FakeActiveMac(
            fetch: [.success(.page(page([shown]), etag: nil))],
            segments: [.success(TranscriptItemSegment(status: "ok", sessionEpoch: "e1", itemId: "i1", text: "后文", hasMore: false))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        s.beginTranscriptExpansion("t1", shown)
        await s.loadMoreTranscriptText("t1", "i1")
        let exp = s.transcriptExpansions[MacSession.expansionKey("t1", "i1")]
        XCTAssertEqual(exp?.text, "长回复开头后文")
        XCTAssertEqual(exp?.isComplete, true)
        let calls = await fake.itemCalls
        XCTAssertEqual(calls, ["tok1"])
    }

    func testContinuationResetMarksTheItemForRefetch() async {
        let s = MacSession()
        let shown = TranscriptItem(id: "i1", role: "assistant", text: "长…", truncated: true, continuation: "tok1")
        let fake = FakeActiveMac(
            fetch: [.success(.page(page([shown]), etag: nil))],
            segments: [.failure(BridgeError.http(status: 410))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        s.beginTranscriptExpansion("t1", shown)
        await s.loadMoreTranscriptText("t1", "i1")
        XCTAssertEqual(s.transcriptExpansions[MacSession.expansionKey("t1", "i1")]?.needsRefetch, true)
    }

    func testContinuationIsDiscardedWhenTheSessionChanged() async {
        let s = MacSession()
        let shown = TranscriptItem(id: "i1", role: "assistant", text: "长…", truncated: true, continuation: "tok1")
        let fake = FakeActiveMac(
            fetch: [.success(.page(page([shown]), etag: nil))],
            segments: [.success(TranscriptItemSegment(status: "ok", sessionEpoch: "e1", itemId: "i1", text: "后文", hasMore: false))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        s.beginTranscriptExpansion("t1", shown)
        s.transcripts["t1"]?.sessionEpoch = "e2"
        await s.loadMoreTranscriptText("t1", "i1")
        let text = s.transcriptExpansions[MacSession.expansionKey("t1", "i1")]?.text
        XCTAssertTrue(text == nil || text == "长", "a segment from before the session change must not be appended")
    }

    func testDeactivatingClearsTheThreadsExpansions() {
        let s = MacSession()
        s.setTranscriptActive("t1")
        s.transcriptExpansions[MacSession.expansionKey("t1", "i1")] = TranscriptExpansion(itemId: "i1", sessionEpoch: "e1", text: "长", continuation: "tok")
        s.setTranscriptActive(nil)
        XCTAssertTrue(s.transcriptExpansions.isEmpty)
        XCTAssertNil(s.activeTranscriptThread)
    }
}
