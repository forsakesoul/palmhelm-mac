import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// O1-338（Mac）：身份暂停横幅只看服务端 target.identityPauseKey（不看历史回执）；恢复只发条件命令「恢复身份 <名> #<eventKey>」；只读时不发。
@MainActor
final class IdentityPauseMacTests: XCTestCase {
    private func session() -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.identity-pause")!
        s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-i","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        return s
    }
    /// 装入一份权威快照：t1 带 identityPauseKey（可选），并附一条旧式历史回执（不应再决定横幅）。
    private func withTargets(_ s: MacSession, pauseKey: String?) async {
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let pause = pauseKey.map { ",\"identityPauseKey\":\"\($0)\"" } ?? ""
        let json = #"{"occupancy":"free","targets":[{"id":"t1","projectName":"task_x_design","agentName":"task_x_design","status":"idle"\#(pause)}],"history":{"highWater":1,"items":[{"seq":1,"uuid":"ack:k9","text":"rejected:direct_identity_changed","kind":"text","replyTo":"k9"}]}}"#
        s.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8)) }
        await s.refresh()
    }

    func testBannerFollowsTheAuthoritativeTargetFieldNotHistory() async {
        let s = session()
        await withTargets(s, pauseKey: "d2")
        XCTAssertEqual(s.identityPauseKey("t1"), "d2")
        XCTAssertNil(s.identityPauseKey("t2"), "别的线程不显示")
        await withTargets(s, pauseKey: nil)
        XCTAssertNil(s.identityPauseKey("t1"), "服务端已解除暂停：横幅收起，即使历史里还有旧回执")
    }

    func testRecoverSendsOnlyTheConditionalCommand() async {
        let s = session()
        await withTargets(s, pauseKey: "d2")
        let wires = WireLog()
        s.sendOverride = { wire, _ in wires.add(wire); return MessageReceipt.stub("r1") }
        let note = await s.recoverIdentityPause(eventKey: "d2")
        XCTAssertNil(note)
        XCTAssertEqual(wires.all, ["恢复身份 #d2"], "只发条件恢复，不发裸重置、不切换绑定")
    }

    func testReadOnlyDeviceDoesNotSendAndSaysWhy() async {
        let s = session()
        await withTargets(s, pauseKey: "d2")
        // 刷新会用快照覆盖设备，所以只读身份在刷新之后装入
        s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-i","name":"mac","paused":false,"permission":"readonly"}"#.utf8))
        let wires = WireLog()
        s.sendOverride = { wire, _ in wires.add(wire); return MessageReceipt.stub("r1") }
        let note = await s.recoverIdentityPause(eventKey: "d2")
        XCTAssertNotNil(note)
        XCTAssertTrue(wires.all.isEmpty)
    }

    /// 测试用的线程安全收集器（sendOverride 是 Sendable 闭包）。
    final class WireLog: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }
}
