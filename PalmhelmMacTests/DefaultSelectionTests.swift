import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// 打开后自动选哪个目标（方向 B，A1-109 §3）的纯规则测试。
@MainActor
final class DefaultSelectionTests: XCTestCase {
    private func t(_ id: String, online: Bool?) -> TargetSummary { TargetSummary(projectName: id, online: online, targetId: id) }
    private func pick(_ ts: [TargetSummary], connected: Bool = true, bound: String? = nil, pending: Set<String> = [], activity: [String: Int] = [:]) -> String? {
        MacSession.autoPick(targets: ts, onlineTrusted: connected, bound: bound, pending: pending, activity: { activity[$0] ?? 0 })
    }

    func testOfflineBindingLosesToOnlineTarget() {
        // 用户报告的现象：绑定的是离线目标时，不再默认停在它上面
        XCTAssertEqual(pick([t("ops-readonly", online: false), t("palmhelm", online: true)], bound: "ops-readonly"), "palmhelm")
    }

    func testOnlineWithExactPendingWinsOverRecentActivity() {
        let ts = [t("a", online: true), t("b", online: true)]
        XCTAssertEqual(pick(ts, pending: ["b"], activity: ["a": 9]), "b")
    }

    func testRecentActivityThenOnlineBindingThenStableOrder() {
        let ts = [t("c", online: true), t("a", online: true), t("b", online: true)]
        XCTAssertEqual(pick(ts, bound: "a", activity: ["b": 3, "c": 7]), "c", "在线里最近有回执的优先")
        XCTAssertEqual(pick(ts, bound: "b"), "b", "没有回执时取在线的绑定目标")
        XCTAssertEqual(pick(ts), "a", "都没有时按 id 稳定排序，不随目录顺序跳动")
    }

    func testAllOfflineFallsBackToBindingThenRecords() {
        let ts = [t("a", online: false), t("b", online: false)]
        XCTAssertEqual(pick(ts, bound: "b"), "b")
        XCTAssertEqual(pick(ts, activity: ["b": 2]), "b")
        XCTAssertEqual(pick(ts), "a")
    }

    func testUntrustedOnlineIsIgnored() {
        // online 不可信（缓存）时不按它排序，回到绑定目标
        XCTAssertEqual(pick([t("a", online: true), t("b", online: false)], connected: false, bound: "b"), "b")
    }

    func testCandidatePendingDoesNotSteerSelection() {
        // pending 只含 exact 解析出的目标；没有就不参与（候选 / 未匹配不进入这里）
        XCTAssertEqual(pick([t("a", online: true), t("b", online: true)], pending: [], activity: ["a": 1]), "a")
    }

    func testNoTargets() {
        XCTAssertNil(pick([]))
    }

    // MARK: 待办归属映射（A1-110 S1）与“全部离线”判断（A1-111 F1）

    private func a(_ label: String, _ attribution: String?) -> ApprovalView {
        ApprovalView(id: UUID().uuidString, status: "pending", targetLabel: label, attribution: attribution, toolName: "Bash", summary: "ls", createdT: 0, expiresT: 0)
    }

    func testExactPendingMapsOnlyUniqueExactTargets() {
        let ts = [t("a", online: true), t("b", online: true), TargetSummary(projectName: "dup", online: true, targetId: "dup-1"), TargetSummary(projectName: "dup", online: true, targetId: "dup-2")]
        XCTAssertEqual(MacSession.exactPendingTargets([a("a", "exact")], targets: ts), ["a"], "exact 且唯一")
        XCTAssertEqual(MacSession.exactPendingTargets([a("候选：b", "candidate")], targets: ts), [], "候选不参与")
        XCTAssertEqual(MacSession.exactPendingTargets([a("未登记目标", "unregistered")], targets: ts), [], "未登记不参与")
        XCTAssertEqual(MacSession.exactPendingTargets([a("dup", "exact")], targets: ts), [], "同项目多目标不参与")
    }

    func testAllConfirmedOfflineTreatsUnknownAsNotOffline() {
        XCTAssertTrue(MacSession.allConfirmedOffline([t("a", online: false), t("b", online: false)]))
        XCTAssertFalse(MacSession.allConfirmedOffline([t("a", online: nil), t("b", online: nil)]), "状态未知不是离线")
        XCTAssertFalse(MacSession.allConfirmedOffline([t("a", online: false), t("b", online: nil)]), "混有未知不算全部离线")
        XCTAssertFalse(MacSession.allConfirmedOffline([t("a", online: false), t("b", online: true)]))
        XCTAssertFalse(MacSession.allConfirmedOffline([]))
    }
}
