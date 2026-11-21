import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #21 S2（Mac）：结果只在发起时的连接上落账（A1-187 R1/R2）。不触网：只测代次不一致的丢弃路径。
@MainActor
final class IssueTaskSessionMacTests: XCTestCase {
    func testAcceptedResultFromAStaleConnectionIsNotRecorded() {
        let s = MacSession()
        let before = s.sent.count
        let recorded = s.recordIssueAccepted(clientMsgId: "00000000-0000-4000-8000-00000000000a", summary: "[任务] x", targetId: "t1", eventKey: "api:d:u", epoch: s.connectionEpoch - 1)
        XCTAssertFalse(recorded)
        XCTAssertEqual(s.sent.count, before, "旧连接的受理不得落到当前连接的回显里")
    }
}
