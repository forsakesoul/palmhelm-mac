import XCTest
import PalmhelmKit
@testable import PalmhelmMac

@MainActor final class ApprovalPaneTargetTests: XCTestCase {
    func testSameProjectUsesIDForIdentityPendingCountsAndInbox() throws {
        let s = MacSession()
        let state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[{"id":"design","projectName":"same","status":"blocked"},{"id":"execute","projectName":"same","status":"blocked"}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.applyStateSnapshot(state)
        let a = ApprovalView(id: "a", status: "pending", targetLabel: "same", attribution: "exact", toolName: "Bash", summary: "ls", createdT: 0, expiresT: Int(Date().timeIntervalSince1970 * 1000) + 60000, targetId: "execute")
        s.approvals[a.id] = a
        XCTAssertEqual(s.target(forApproval: a)?.id, "execute")
        XCTAssertEqual(s.approvals(for: state.targets[0]).count, 0)
        XCTAssertEqual(s.approvals(for: state.targets[1]).count, 1)
        XCTAssertEqual(MacSession.exactPendingTargets([a], targets: state.targets), ["execute"])
        XCTAssertFalse(InboxModel.hasReliableCard(state.targets[0], approvals: [a], targets: state.targets))
        XCTAssertTrue(InboxModel.hasReliableCard(state.targets[1], approvals: [a], targets: state.targets))
    }
}
