import Foundation
import PalmhelmKit
import XCTest
@testable import PalmhelmMac

// 工作时长的状态转换（D2）：只在进入 working 时记时，保持 working 不重置，离开即删除。
final class WorkingSinceTests: XCTestCase {
    private func target(_ id: String, _ status: String) -> TargetSummary {
        TargetSummary(projectName: id, targetId: id, status: status)
    }

    @MainActor
    func testEnteringWorkingRecordsStartTime() {
        var since: [String: Date] = [:]
        let t0 = Date(timeIntervalSince1970: 1_000)
        MacSession.observeWorking(&since, targets: [target("a", "working"), target("b", "idle")], now: t0)
        XCTAssertEqual(since, ["a": t0])
    }

    @MainActor
    func testRepeatedWorkingKeepsOriginalStartTime() {
        var since: [String: Date] = [:]
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 1_030)
        MacSession.observeWorking(&since, targets: [target("a", "working")], now: t0)
        MacSession.observeWorking(&since, targets: [target("a", "working")], now: t1)
        XCTAssertEqual(since["a"], t0, "重复 working 不重置")
    }

    @MainActor
    func testLeavingWorkingClearsAndReenteringRestarts() {
        var since: [String: Date] = [:]
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 1_100), t2 = Date(timeIntervalSince1970: 1_200)
        MacSession.observeWorking(&since, targets: [target("a", "working")], now: t0)
        MacSession.observeWorking(&since, targets: [target("a", "idle")], now: t1)
        XCTAssertNil(since["a"], "离开 working 即删除")
        MacSession.observeWorking(&since, targets: [target("a", "working")], now: t2)
        XCTAssertEqual(since["a"], t2, "再次进入 working 从头计")
    }

    @MainActor
    func testTargetMissingFromSnapshotIsDropped() {
        var since: [String: Date] = [:]
        MacSession.observeWorking(&since, targets: [target("a", "working")], now: Date(timeIntervalSince1970: 1))
        MacSession.observeWorking(&since, targets: [], now: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(since.isEmpty)
    }
}

// F1/F2/F3：经真实应用入口（快照解码后走 applyStateSnapshot / applyTargetsFrame / stopStream）验证工作计时与状态推导。
final class SessionActivityTests: XCTestCase {
    private func json(_ any: Any) throws -> Data { try JSONSerialization.data(withJSONObject: any) }

    private func tgt(_ id: String, status: String, online: Bool = true) -> [String: Any] {
        ["id": id, "projectName": id, "online": online, "status": status]
    }

    private func targets(_ arr: [[String: Any]]) throws -> [TargetSummary] {
        try JSONDecoder().decode([TargetSummary].self, from: try json(arr))
    }

    private func snapshot(_ arr: [[String: Any]]) throws -> BridgeState {
        try JSONDecoder().decode(BridgeState.self, from: try json(["occupancy": "none", "targets": arr, "history": ["highWater": 0, "items": []]]))
    }

    private func approval(_ id: String, label: String, status: String = "pending", now: Date) throws -> ApprovalView {
        try JSONDecoder().decode(ApprovalView.self, from: try json([
            "id": id, "status": status, "targetLabel": label, "toolName": "Bash", "summary": "ls", "truncated": false,
            "createdT": Int(now.timeIntervalSince1970 * 1000) - 1000, "expiresT": Int(now.timeIntervalSince1970 * 1000) + 600_000,
        ]))
    }

    @MainActor
    func testIdleToWorkingRefreshesStartAndRemovalClears() throws {
        let s = MacSession()
        s.link = .connected
        let t0 = Date(timeIntervalSince1970: 1_000)
        s.applyStateSnapshot(try snapshot([tgt("a", status: "idle")]), now: t0)
        XCTAssertNil(s.workingSince["a"])
        s.applyTargetsFrame(try targets([tgt("a", status: "working")]), spaces: nil, now: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(s.workingSince["a"], Date(timeIntervalSince1970: 1_100))
        s.applyTargetsFrame(try targets([tgt("a", status: "idle")]), spaces: nil, now: Date(timeIntervalSince1970: 1_200))
        XCTAssertNil(s.workingSince["a"])
        s.applyTargetsFrame(try targets([tgt("a", status: "working")]), spaces: nil, now: Date(timeIntervalSince1970: 1_300))
        XCTAssertEqual(s.workingSince["a"], Date(timeIntervalSince1970: 1_300), "idle→working 起点刷新")
        s.applyTargetsFrame(try targets([]), spaces: nil, now: Date(timeIntervalSince1970: 1_400))
        XCTAssertNil(s.workingSince["a"], "SSE 移除目标即清除计时")
    }

    @MainActor
    func testDisconnectThenReconnectStartsFromNewObservation() throws {
        let s = MacSession()
        s.link = .connected
        s.applyStateSnapshot(try snapshot([tgt("a", status: "working")]), now: Date(timeIntervalSince1970: 1_000))
        XCTAssertNotNil(s.workingSince["a"])
        s.stopStream()
        XCTAssertTrue(s.workingSince.isEmpty, "断开清空计时")
        s.applyStateSnapshot(try snapshot([tgt("a", status: "working")]), now: Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(s.workingSince["a"], Date(timeIntervalSince1970: 5_000), "重连后从新观测时刻起算")
    }

    @MainActor
    func testActivityTextAndKindComeFromOneMapping() throws {
        let s = MacSession()
        let now = Date(timeIntervalSince1970: 2_000)
        s.link = .connected
        s.applyStateSnapshot(try snapshot([tgt("w", status: "working"), tgt("b", status: "blocked"), tgt("o", status: "working", online: false), tgt("d", status: "done"), tgt("u", status: "unknown")]), now: now)
        let byId = Dictionary(uniqueKeysWithValues: s.state!.targets.map { ($0.id, $0) })
        XCTAssertEqual(s.activityText(byId["w"]!, at: now.addingTimeInterval(120)), "工作中 · 2 分钟")
        XCTAssertEqual(s.activityText(byId["b"]!, at: now), "等你", "等你覆盖工作中（blocked）")
        XCTAssertEqual(s.activityText(byId["o"]!, at: now), "离线", "离线覆盖工作中")
        XCTAssertEqual(s.activityKind(byId["o"]!), .offline)
        XCTAssertEqual(s.activityText(byId["d"]!, at: now), "空闲")
        XCTAssertEqual(s.activityText(byId["u"]!, at: now), "空闲")
    }

    @MainActor
    func testPendingApprovalsFollowCandidatePrefixRule() throws {
        let s = MacSession()
        let now = Date()
        s.link = .connected
        s.applyStateSnapshot(try snapshot([tgt("proj", status: "working"), tgt("other", status: "idle")]), now: now)
        s.approvals = [
            "1": try approval("1", label: "proj", now: now),
            "2": try approval("2", label: "候选：proj", now: now),
            "3": try approval("3", label: "other", now: now),
            "4": try approval("4", label: "proj", status: "allowed", now: now),
        ]
        let proj = s.state!.targets.first { $0.id == "proj" }!
        XCTAssertEqual(s.approvals(for: proj).map(\.id).sorted(), ["1", "2"], "精确与候选前缀归同一目标；非 pending 与其他目标不计")
        XCTAssertEqual(s.activityKind(proj), .waiting, "有待答即等你")
    }
}
