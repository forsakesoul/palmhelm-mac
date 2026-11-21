import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// 骨架门禁（transcriptShowsSkeleton）：失焦 / 非活跃 / 重新聚焦不把已有内容盖回骨架；切到别的线程仍先骨架。

private actor GateFakeMac: SearchTranscriptClient {
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage { throw URLError(.notConnectedToInternet) }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage { throw URLError(.notConnectedToInternet) }
    func transcriptConditional(targetId: String, before: String?, limit: Int, ifNoneMatch: String?, receipt: TranscriptReceiptRequest?) async throws -> TranscriptFetch {
        .page(TranscriptPage(status: "ok", sessionEpoch: "e", revision: "r", items: [TranscriptItem(id: "i-\(targetId)", role: "user", text: "你好")], nextBefore: nil, hasMore: false, partial: false), etag: "\"\(targetId)\"")
    }
}

@MainActor
final class SkeletonGateMacTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 30_000)
    private func session() -> MacSession {
        let s = MacSession(); s.link = .connected; s.searchClientOverride = { GateFakeMac() }; return s
    }
    private func open(_ s: MacSession, _ id: String, confirm: Bool = true, at: Date) async {
        s.setTranscriptActive(id)
        guard confirm, let token = s.transcriptActivation.current else { return }
        await s.activeTranscriptTick(token, now: at)
    }

    func test_firstOpenBeforeConfirmationShowsTheSkeleton() {
        let s = session()
        s.setTranscriptActive("A")
        XCTAssertTrue(s.transcriptShowsSkeleton("A"))
        XCTAssertFalse(s.transcriptSettled("A"))
    }
    func test_losingFocusAfterConfirmationKeepsTheContent() async {
        let s = session()
        await open(s, "A", at: t0)
        XCTAssertTrue(!s.transcriptShowsSkeleton("A") && s.transcriptSettled("A"))
        s.setTranscriptActive(nil) // 失焦 / 场景非活跃
        XCTAssertFalse(s.transcriptSettled("A"), "transcriptSettled 语义不变")
        XCTAssertFalse(s.transcriptShowsSkeleton("A"), "已有内容不回到骨架")
    }
    func test_reactivatingTheSameThreadBeforeItsNewTokenConfirmsDoesNotFlashTheSkeleton() async {
        let s = session()
        await open(s, "A", at: t0)
        s.setTranscriptActive(nil)
        s.setTranscriptActive("A") // 重新聚焦，新 token 尚未确认
        XCTAssertTrue(!s.transcriptSettled("A") && !s.transcriptShowsSkeleton("A"))
    }
    func test_switchingThreadsStillShowsTheSkeletonUntilTheFirstReply() async {
        let s = session()
        await open(s, "A", at: t0)
        await open(s, "B", confirm: false, at: t0)
        XCTAssertTrue(s.transcriptShowsSkeleton("B"), "A→B 未确认：骨架")
        await open(s, "B", at: t0.addingTimeInterval(2))
        XCTAssertFalse(s.transcriptShowsSkeleton("B"))
        s.setTranscriptActive("A")
        XCTAssertTrue(s.transcriptShowsSkeleton("A"), "A→B→A：A 的新激活未确认前仍先骨架（最近确认的是 B）")
        s.link = .connecting
        XCTAssertFalse(s.transcriptShowsSkeleton("A"), "未连接不显示骨架（原行为）")
    }
}
