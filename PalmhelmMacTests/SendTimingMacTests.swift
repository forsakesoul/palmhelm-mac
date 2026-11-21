import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// 发送时机（#23，Mac）：发送模式确实传到传输层；菜单与 ⌘↩ 的规则在 Kit 中有覆盖。署名已取消（O1-364）。
@MainActor
final class SendTimingMacTests: XCTestCase {
    private func device(_ id: String) -> DeviceInfo {
        try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"\#(id)","name":"mac","paused":false,"permission":"control"}"#.utf8))
    }

    /// S3：偏好走隔离的 suite，不写入真实的 standard 域。
    private let suite = UserDefaults(suiteName: "palmhelm.send-timing.tests")!

    override func tearDown() {
        suite.removePersistentDomain(forName: "palmhelm.send-timing.tests")
        super.tearDown()
    }

    /// 新协议的会话（target 带 capabilities 字段）；旧协议的会话没有该字段。
    private func newProtocolState() -> BridgeState {
        try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[{"id":"t1","projectName":"p","agentName":"a","capabilities":{"steer":false}}],"history":{"highWater":0,"items":[]}}"#.utf8))
    }

    func testSendPassesModeToTheTransport() async {
        let s = MacSession()
        s.preferences = suite
        s.device = device("mac-test-a")
        s.link = .connected
        s.state = newProtocolState()
        s.sendOverride = { _, _ in MessageReceipt.stub("k") }
        _ = await s.send("补一句", mode: .queue)
        XCTAssertEqual(s.lastSendMode, .queue)
    }

    func testOldBridgeGetsNoMode() async {
        let s = MacSession()
        s.preferences = suite
        s.device = device("mac-test-b")
        s.link = .connected
        s.sendOverride = { _, _ in MessageReceipt.stub("k") }
        _ = await s.send("旧 Bridge", mode: .queue)
        XCTAssertNil(s.lastSendMode, "没有 capabilities 的 Bridge：不发 mode")
    }

    func testPausedDeviceStillWithdrawsAndPromoteIsGuarded() async {
        let s = MacSession()
        s.preferences = suite
        s.device = device("mac-test-b")
        s.link = .connected
        s.commandOverride = { _, _ in }
        let c = try! JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"api:d:1","inboxSeq":1,"text":"补","truncated":false,"origin":"api","state":"queued","lane":"use","targetId":"t1"}"#.utf8))
        await s.withdrawQueued(c)
        XCTAssertEqual(s.commandRequests, [.withdraw])
    }

    func testPlainSendKeepsLegacyBodyFields() async {
        let s = MacSession()
        s.preferences = suite
        s.device = device("mac-test-b")
        s.link = .connected
        s.state = newProtocolState()
        s.sendOverride = { _, _ in MessageReceipt.stub("k") }
        _ = await s.send("空闲时的普通发送")
        XCTAssertNil(s.lastSendMode, "空闲目标：不带 mode，与旧请求一致")
    }
}

// O1-307 a)：⌘↩ 的接线（真实入口 MacSession.commandReturn，界面闭包调用的就是它）。
@MainActor
final class SendTimingCommandReturnTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    private func workingSession(steer: Bool, counter: Counter) -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.send-timing.return")!
        s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-return","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.state = try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"busy","targets":[{"id":"t1","projectName":"p","agentName":"design","status":"working","capabilities":{"steer":\#(steer)}}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.sendOverride = { _, _ in counter.bump(); return MessageReceipt.stub("k") }
        var d = MacSession.ComposerDraft()
        d.text = "直达的补充"
        s.setDraft(d, for: "t1")
        return s
    }

    /// S5（Owner 裁决）：直达工作中的 ⌘↩ 是普通发送（工作中即排队），不再拦下；立即插入只从菜单显式选择。
    func testDirectThreadCommandReturnWhileWorkingSendsOrdinarily() async {
        let counter = Counter()
        let s = workingSession(steer: true, counter: counter)
        let note = await s.commandReturn(threadId: "t1", agent: "design")
        XCTAssertNil(note)
        XCTAssertEqual(counter.value, 1)
        XCTAssertNil(s.lastSendMode, "直达 ⌘↩ 不带 mode")
    }

    /// O1-325：直达工作中菜单可见，主按钮仍是直达发送（不传 mode），立即插入灰掉并写明原因。
    func testDirectWorkingShowsMenuPrimaryKeepsDirectShapeAndSteerIsGreyedWithReason() async {
        let counter = Counter()
        let s = workingSession(steer: true, counter: counter)
        XCTAssertTrue(SendTimingRules.showsMenu(targetStatus: s.targetStatus("t1")), "直达工作中也显示菜单")
        let ok = await s.submitComposer(threadId: "t1", agent: "design", mode: SendTimingRules.primaryMode(direct: true, targetStatus: "working"))
        XCTAssertTrue(ok)
        XCTAssertEqual(counter.value, 1)
        XCTAssertNil(s.lastSendMode, "直达主按钮不带 mode：请求形状与以前的直达发送一致")
        let steer = SendTimingRules.menu(steer: .available, direct: true)[1]
        XCTAssertFalse(steer.enabled, "hook steer 不授权直达")
        XCTAssertEqual(SendControls.title(steer, direct: true), "立即插入当前回合 — 直达暂不支持", "直达菜单不写 ⌘↩")
        XCTAssertTrue(SendTimingRules.menu(steer: .unavailable, direct: true, nativeSteer: true)[1].enabled, "声明 nativeSteer 才可立即插入")
        XCTAssertEqual(SendControls.title(SendTimingRules.menu(steer: .available)[1]), "立即插入当前回合 ⌘↩", "绑定目标可用时不改标题")
    }

    /// O1-325：直达发出、仍在排队的消息可以撤回（不能改为立即插入）。
    func testDirectQueuedMessageIsWithdrawableButNotPromotable() async throws {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.send-timing.direct-withdraw")!
        s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-direct","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.commandOverride = { _, _ in }
        let c = try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"api:mac-direct:1","inboxSeq":1,"text":"派给 design：补","truncated":false,"origin":"api","state":"queued","lane":"ordinary","targetId":"t1"}"#.utf8))
        XCTAssertEqual(SendTimingRules.queuedActions(state: c.state, reason: c.reason, steer: .available, direct: true), [.withdraw])
        await s.withdrawQueued(c)
        XCTAssertEqual(s.commandRequests, [.withdraw])
    }

    func testOrdinaryThreadCommandReturnWhileWorkingSendsWithSteer() async {
        let counter = Counter()
        let s = workingSession(steer: true, counter: counter)
        let note = await s.commandReturn(threadId: "t1", agent: nil)
        XCTAssertNil(note)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(s.lastSendMode, .steer)
    }

    /// R1a：没有 capability 的旧 Bridge，普通目标工作中按 ⌘↩：能力 unknown，不能降为排队，要明确提示。
    func testOldBridgeOrdinaryWorkingCommandReturnIsBlockedNotQueued() async {
        let counter = Counter()
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.send-timing.return")!
        s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-return-old","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.state = try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"busy","targets":[{"id":"t1","projectName":"p","agentName":"design","status":"working"}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.sendOverride = { _, _ in counter.bump(); return MessageReceipt.stub("k") }
        var d = MacSession.ComposerDraft()
        d.text = "旧 Bridge 的补充"
        s.setDraft(d, for: "t1")
        let note = await s.commandReturn(threadId: "t1", agent: nil)
        XCTAssertNotNil(note, "能力未知时 ⌘↩ 给出提示")
        XCTAssertEqual(counter.value, 0, "不能降为排队发出")
        XCTAssertNil(s.lastSendMode)
    }
}
