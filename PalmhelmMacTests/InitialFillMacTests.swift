import Foundation
import PalmhelmKit
import XCTest
@testable import PalmhelmMac

// #111：首页被大段工具输出占满时（2 条 partial → 空 partial → 20 条），冷打开会话后无需点击就补齐。真实调用 MacSession.loadTranscriptLatest / loadTranscriptOlder，网络由假客户端替身。
private actor PagedClient: SearchTranscriptClient {
    private let pages: [String?: Result<TranscriptPage, Error>]
    private(set) var cursors: [String?] = []
    init(_ pages: [String?: Result<TranscriptPage, Error>]) { self.pages = pages }
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage {
        cursors.append(before)
        return try (pages[before] ?? .failure(URLError(.badServerResponse))).get()
    }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage { TargetHistoryPage(items: [], nextBefore: nil, hasMore: false, partial: false) }
}

final class InitialFillMacTests: XCTestCase {
    private func page(_ ids: [String], before: String?, hasMore: Bool = true) -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: ids.map { TranscriptItem(id: $0, role: "assistant", text: $0) }, nextBefore: before, hasMore: hasMore)
    }

    @MainActor
    private func session(_ client: PagedClient) -> MacSession {
        let s = MacSession()
        s.state = try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[{"projectName":"A","id":"A","online":true}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.link = .connected
        s.searchClientOverride = { client }
        s.selectTarget("A")
        _ = s.transcriptActivation.activate("A")
        return s
    }

    @MainActor
    func testSparseFirstPageIsFilledWithoutAnyClick() async {
        let client = PagedClient([nil: .success(page(["m98", "m99"], before: "c1")), "c1": .success(page([], before: "c2")),
                                  "c2": .success(page((78..<98).map { "m\($0)" }, before: "c3"))])
        let s = session(client)
        await s.loadTranscriptLatest("A")
        XCTAssertEqual(s.transcripts["A"]?.items.count, 22)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "c1", "c2"])
    }

    @MainActor
    func testFillStopsAtThePageCapAndDoesNotRetryAFailure() async {
        var all: [String?: Result<TranscriptPage, Error>] = [nil: .success(page(["m99"], before: "c1"))]
        for i in 1..<10 { all["c\(i)"] = .success(page([], before: "c\(i + 1)")) }
        let capped = PagedClient(all)
        let s = session(capped)
        await s.loadTranscriptLatest("A")
        let cursors = await capped.cursors
        XCTAssertEqual(cursors.count, 1 + TranscriptThread.fillMaxPages)

        let failing = PagedClient([nil: .success(page(["m99"], before: "c1")), "c1": .failure(BridgeError.http(status: 503))])
        let f = session(failing)
        await f.loadTranscriptLatest("A")
        let fc = await failing.cursors
        XCTAssertEqual(fc, [nil, "c1"], "失败不自动重试，交还给手动加载")
        XCTAssertEqual(f.transcripts["A"]?.items.count, 1)
    }

    @MainActor
    func testShortHistoryThatEndsDoesNotSpin() async {
        let client = PagedClient([nil: .success(page(["m1", "m2"], before: nil, hasMore: false))])
        let s = session(client)
        await s.loadTranscriptLatest("A")
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil])
    }
}
