import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #98 Mac 会话接线（合成数据、隔离偏好域）：冻结与静默应用、置顶、上下移动、拖动、重置、旧 Bridge 降级、不完整观察不推进。
@MainActor
final class SpaceGroupingMacTests: XCTestCase {
    static let t0 = 1_700_000_000_000
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "mac-space-\(UUID().uuidString)"
    }
    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func session() -> MacSession {
        let s = MacSession()
        let d = UserDefaults(suiteName: suite)!
        s.spaceStore = SpaceOrderStore(defaults: d)
        s.spaceDocument = SpaceOrderDocument()
        s.archive = ThreadArchiveStore(defaults: d)
        s.lens = .spaces
        return s
    }

    private typealias Group = (id: String, ws: String?, label: String, working: Bool)

    private func state(_ groups: [Group], complete: Bool = true, fresh: Bool = true) -> BridgeState {
        let targets = groups.map { g -> String in
            let ws = g.ws.map { #","workspaceId":"\#($0)","terminalId":"term-\#(g.id)""# } ?? ""
            return #"{"projectName":"\#(g.id)","id":"\#(g.id)","online":true,"status":"\#(g.working ? "working" : "idle")","location":{"workspace":"\#(g.label)"}\#(ws)}"#
        }
        let obs = #","observation":{"t":\#(Self.t0),"complete":\#(complete),"fresh":\#(fresh)}"#
        return try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[\#(targets.joined(separator: ","))],"history":{"highWater":0,"items":[]}\#(obs)}"#.utf8))
    }

    private func feed(_ s: MacSession, _ st: BridgeState) async throws {
        s.stateOverride = { st }
        try await s.pullState()
        s.lens = .spaces // 权威同步会恢复本机上次的视角偏好，测试固定为空间视角
    }

    private func titles(_ s: MacSession) -> [String] { s.railSections.map(\.title) }

    private let base: [Group] = [
        (id: "a", ws: "w1", label: "alpha", working: false),
        (id: "b", ws: "w2", label: "beta", working: false),
        (id: "c", ws: "w3", label: "gamma", working: false),
    ]

    func testRunningGroupPromotesOnceAfterAnEffectiveSnapshot() async throws {
        let s = session()
        try await feed(s, state(base))
        XCTAssertEqual(titles(s), ["alpha", "beta", "gamma"])
        var running = base; running[1].working = true
        try await feed(s, state(running))
        XCTAssertEqual(titles(s).first, "beta")
        try await feed(s, state(base))
        XCTAssertEqual(titles(s).first, "beta", "ending does not fall back")
    }

    func testVisibleRailFreezesAndLeavingAppliesSilently() async throws {
        let s = session()
        try await feed(s, state(base))
        s.setSpaceListVisible(true)
        var running = base; running[2].working = true
        try await feed(s, state(running))
        XCTAssertEqual(titles(s), ["alpha", "beta", "gamma"], "a visible rail does not reorder")
        s.setSpaceListVisible(false)
        XCTAssertEqual(titles(s).first, "gamma")
    }

    func testIncompleteOrStaleObservationNeverPromotes() async throws {
        let s = session()
        try await feed(s, state(base))
        var running = base; running[1].working = true
        try await feed(s, state(running, complete: false))
        XCTAssertEqual(titles(s), ["alpha", "beta", "gamma"])
        try await feed(s, state(running, fresh: false))
        XCTAssertEqual(titles(s), ["alpha", "beta", "gamma"])
    }

    func testPinAndUnpinThroughTheSectionIdentity() async throws {
        let s = session()
        try await feed(s, state(base))
        let gamma = s.railSections.first { $0.title == "gamma" }!.id
        s.setSpaceGroupPinned(gamma, true)
        XCTAssertTrue(s.isSpaceGroupPinned(gamma))
        XCTAssertEqual(titles(s).first, "gamma")
        s.setSpaceGroupPinned(gamma, false)
        XCTAssertEqual(titles(s), ["alpha", "beta", "gamma"])
    }

    func testAccessibilityMovesStopAtTheEdgesAndAroundPins() async throws {
        let s = session()
        try await feed(s, state(base))
        let alpha = s.railSections.first { $0.title == "alpha" }!.id
        let beta = s.railSections.first { $0.title == "beta" }!.id
        s.setSpaceGroupPinned(alpha, true)
        s.moveSpaceGroup(beta, delta: -1)
        XCTAssertEqual(titles(s), ["alpha", "beta", "gamma"], "beta cannot move above the pinned alpha")
        s.moveSpaceGroup(beta, delta: 1)
        XCTAssertEqual(titles(s), ["alpha", "gamma", "beta"])
    }

    func testDragDropMovesTheGroupBeforeTheTarget() async throws {
        let s = session()
        try await feed(s, state(base))
        let alpha = s.railSections.first { $0.title == "alpha" }!.id
        let gamma = s.railSections.first { $0.title == "gamma" }!.id
        s.dropSpaceGroup(gamma, before: alpha)
        XCTAssertEqual(titles(s), ["gamma", "alpha", "beta"])
        let beta = s.railSections.first { $0.title == "beta" }!.id
        s.dropSpaceGroup(gamma, before: beta)
        XCTAssertEqual(titles(s), ["alpha", "gamma", "beta"], "dropping downward lands before the target")
    }

    func testResetReturnsToTheAutomaticOrderAndStaysLocal() async throws {
        let s = session()
        try await feed(s, state(base))
        let gamma = s.railSections.first { $0.title == "gamma" }!.id
        s.setSpaceGroupPinned(gamma, true)
        s.resetSpaceOrder()
        XCTAssertEqual(titles(s), ["alpha", "beta", "gamma"])
        XCTAssertTrue(s.spaceStore.load().state.pinned.isEmpty)
    }

    func testOldBridgeWithoutWorkspaceIdsGroupsByLabel() async throws {
        let s = session()
        let legacy: [Group] = [(id: "a", ws: nil, label: "alpha", working: false), (id: "b", ws: nil, label: "beta", working: false)]
        try await feed(s, state(legacy))
        XCTAssertEqual(titles(s), ["alpha", "beta"])
    }

    // #98 F3：断开后，旧代次的待上移不得在离开列表时被应用；新代次的有效快照恢复正常上移。
    func testDisconnectInvalidatesDeferredPromotion() async throws {
        let s = session()
        try await feed(s, state(base))
        s.setSpaceListVisible(true)
        var running = base; running[2].working = true
        try await feed(s, state(running))
        XCTAssertEqual(titles(s), ["alpha", "beta", "gamma"])
        s.disconnect(reason: "synthetic disconnect")
        s.setSpaceListVisible(false)
        XCTAssertEqual(titles(s), ["alpha", "beta", "gamma"], "old generation evidence must not promote after disconnect")
        try await feed(s, state(running))
        XCTAssertEqual(titles(s).first, "gamma", "a current effective snapshot promotes again")
    }

    // h91：边界动作禁用；移动后播报新位置（按移动后的显示顺序，从 1 起）。
    func testBoundaryMovesAreDisabledAndAnnounceTheNewPosition() async throws {
        let s = session()
        try await feed(s, state(base))
        let alpha = s.railSections.first { $0.title == "alpha" }!.id
        let gamma = s.railSections.first { $0.title == "gamma" }!.id
        XCTAssertFalse(s.spaceCanMove(alpha, delta: -1), "the first group has no upward move")
        XCTAssertFalse(s.spaceCanMove(gamma, delta: 1), "the last group has no downward move")
        XCTAssertNil(s.moveSpaceGroup(alpha, delta: -1))
        XCTAssertEqual(s.moveSpaceGroup(gamma, delta: -1), "gamma 已移到第 2 位")
        XCTAssertEqual(titles(s), ["alpha", "gamma", "beta"])
    }

    // R1（A1-152）：隐藏的置顶偏好不占用“一位”；播报与显示一致。
    func testA1HiddenPinnedGroupMustNotConsumeVisibleMove() async throws {
        let s = session()
        try await feed(s, state(base))
        let alpha = s.railSections.first { $0.title == "alpha" }!.id
        let gamma = s.railSections.first { $0.title == "gamma" }!.id
        s.setSpaceGroupPinned(alpha, true)
        s.setSpaceGroupPinned(gamma, true)
        s.spaceDocument.state.pinned.insert("b1|ws|hidden", at: 1)
        XCTAssertEqual(s.moveSpaceGroup(gamma, delta: -1), "gamma 已移到第 1 位")
        XCTAssertEqual(titles(s), ["gamma", "alpha", "beta"])
        let gammaId = SpaceOrderSession.groupId(sectionId: gamma)!, alphaId = SpaceOrderSession.groupId(sectionId: alpha)!
        XCTAssertEqual(s.spaceDocument.state.pinned, [gammaId, alphaId, "b1|ws|hidden"], "the hidden preference is kept")
    }

    // R1（A1-152）：最后一个可见置顶组不能借隐藏组下移进普通区。
    func testA1LastVisiblePinHasNoDownwardMoveOverAHiddenPin() async throws {
        let s = session()
        try await feed(s, state(base))
        let alpha = s.railSections.first { $0.title == "alpha" }!.id
        s.setSpaceGroupPinned(alpha, true)
        s.spaceDocument.state.pinned.append("b1|ws|hidden")
        XCTAssertFalse(s.spaceCanMove(alpha, delta: 1))
        XCTAssertNil(s.moveSpaceGroup(alpha, delta: 1))
        XCTAssertEqual(titles(s).first, "alpha")
    }
}
