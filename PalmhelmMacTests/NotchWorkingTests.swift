import Foundation
import PalmhelmKit
import XCTest
@testable import PalmhelmMac

// #56：刘海「工作中」= 在途指令 ∪ 没有对应在途指令的工作中目标。合并 / 去重、计数、差分与连通态门禁。
@MainActor
final class NotchWorkingTests: XCTestCase {
    private func cmd(_ key: String, _ target: String?) -> NotchWorking.Command {
        NotchWorking.Command(key: key, targetId: target, name: "P-\(target ?? "none")", text: "指令 \(key)", label: "排队中")
    }
    private func target(_ id: String) -> NotchWorking.Target {
        NotchWorking.Target(id: id, name: "线程 \(id)", activity: "运行 3 分钟")
    }

    func testWorkingTargetWithoutCommandAddsOneTargetRow() {
        let rows = NotchWorking.rows(commands: [], working: [target("b")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].key, "target:b", "目标行键带 target: 前缀，与指令键不冲突")
        XCTAssertEqual(rows[0].targetId, "b")
        XCTAssertEqual(rows[0].title, "线程 b")
        XCTAssertEqual(rows[0].trailing, "运行 3 分钟", "右侧是活动文案")
    }

    func testTargetWithRunningCommandIsNotCountedTwice() {
        let rows = NotchWorking.rows(commands: [cmd("c1", "a")], working: [target("a"), target("b")])
        XCTAssertEqual(rows.map(\.key), ["c1", "target:b"], "目标 a 已有在途指令，只留指令行；指令在前，目标在后")
        XCTAssertEqual(rows.count, 2)
    }

    func testSeveralCommandsOnSameTargetStillCountEachCommand() {
        let rows = NotchWorking.rows(commands: [cmd("c1", "a"), cmd("c2", "a")], working: [target("a")])
        XCTAssertEqual(rows.map(\.key), ["c1", "c2"], "与原来的计数语义一致：每条在途指令一行；同一目标不再额外补一行")
    }

    func testCommandWithoutTargetIsKeptAndDoesNotCoverAnyTarget() {
        let rows = NotchWorking.rows(commands: [cmd("c1", nil)], working: [target("a")])
        XCTAssertEqual(rows.map(\.key), ["c1", "target:a"])
        XCTAssertNil(rows[0].targetId, "没有目标的指令打开收件箱，不做目标覆盖")
    }

    func testBaseIsWorkingWhenOnlyAWorkingTargetIsPresent() {
        let rows = NotchWorking.rows(commands: [], working: [target("a")])
        XCTAssertEqual(NotchRules.base(pending: 0, running: rows.count), .working, "没有在途指令，只有工作中的目标：刘海切到工作态")
        XCTAssertEqual(NotchRules.base(pending: 0, running: NotchWorking.rows(commands: [], working: []).count), .idle)
    }

    func testTargetLeavingWorkingEmitsNoDoneEvent() {
        var old = NotchSnapshot()
        old.running["target:a"] = "线程 a"
        var new = NotchSnapshot()
        new.running = [:]
        XCTAssertTrue(NotchEvents.diff(old: old, new: new).isEmpty, "目标离开 working 不弹完成提示")
    }

    func testCommandFinishingStillEmitsDone() {
        var old = NotchSnapshot()
        old.running["c1"] = "P"
        var new = NotchSnapshot()
        new.finished["c1"] = "P"
        XCTAssertEqual(NotchEvents.diff(old: old, new: new).map(\.kind), [.done], "完成提示仍只针对在途指令")
    }

    func testWorkingTargetsRequireConnectedLiveSnapshot() throws {
        let s = MacSession()
        let json = #"{"occupancy":"free","targets":[{"projectName":"A","id":"a","online":true,"status":"working"},{"projectName":"B","id":"b","online":true,"status":"idle"}],"history":{"highWater":0,"items":[]}}"#
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8))
        s.link = .notPaired
        XCTAssertTrue(s.workingTargets.isEmpty, "未连通时不计工作中，避免冒充当前")
        s.link = .connected
        XCTAssertEqual(s.workingTargets.map(\.id), ["a"], "只取 status 为 working 的目标")
    }
}
