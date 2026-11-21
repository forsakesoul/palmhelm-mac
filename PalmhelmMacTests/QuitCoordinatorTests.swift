import AppKit
import XCTest
@testable import PalmhelmMac

// issue #54：⌘Q 退出确认。只有用户主动退出才问；系统注销、脚本 quit 不问；「不再询问」持久化；后台运行的 Bridge 不停。

@MainActor
private final class FakeConfirmer: QuitConfirming {
    let answer: QuitAnswer
    var calls: [Bool] = [] // 每次弹窗时的 keepsAfterQuit
    init(_ answer: QuitAnswer) { self.answer = answer }
    func confirm(keepsAfterQuit: Bool) -> QuitAnswer {
        calls.append(keepsAfterQuit)
        return answer
    }
}

private let systemQuit = QuitEventInfo(isQuit: true, hasReason: true, senderIsDock: false) // 注销 / 重启 / 关机
private let scriptedQuit = QuitEventInfo(isQuit: true, hasReason: false, senderIsDock: false) // osascript quit
private let dockQuit = QuitEventInfo(isQuit: true, hasReason: false, senderIsDock: true) // Dock 退出
private let otherEvent = QuitEventInfo(isQuit: false, hasReason: false, senderIsDock: false)

@MainActor
final class QuitCoordinatorTests: XCTestCase {
    private func decide(_ rig: TakeoverRig, _ event: QuitEventInfo?, _ confirmer: FakeConfirmer) -> QuitOutcome {
        QuitCoordinator(settings: rig.settings, engine: rig.engine, confirmer: confirmer).decide(event: event)
    }

    func testMenuOrCmdQWithoutAppleEventPrompts() throws {
        let rig = try TakeoverRig()
        let c = FakeConfirmer(QuitAnswer(quit: true, suppress: false))
        XCTAssertEqual(decide(rig, nil, c), .quitNow)
        XCTAssertEqual(c.calls, [false], "没有 Bridge 在运行时仍然询问，文案按「会一起停止」")
    }

    func testDockQuitPrompts() throws {
        let rig = try TakeoverRig()
        let c = FakeConfirmer(QuitAnswer(quit: true, suppress: false))
        _ = decide(rig, dockQuit, c)
        XCTAssertEqual(c.calls.count, 1)
    }

    func testSystemShutdownOrLogoutDoesNotPrompt() throws {
        let rig = try TakeoverRig()
        let c = FakeConfirmer(QuitAnswer(quit: false, suppress: false))
        XCTAssertEqual(decide(rig, systemQuit, c), .quitNow, "系统注销 / 关机不阻塞，即使回答会是取消")
        XCTAssertTrue(c.calls.isEmpty)
    }

    func testScriptedQuitDoesNotPrompt() throws {
        let rig = try TakeoverRig()
        let c = FakeConfirmer(QuitAnswer(quit: false, suppress: false))
        XCTAssertEqual(decide(rig, scriptedQuit, c), .quitNow)
        XCTAssertTrue(c.calls.isEmpty)
    }

    func testNonQuitAppleEventDoesNotPrompt() throws {
        let rig = try TakeoverRig()
        let c = FakeConfirmer(QuitAnswer(quit: false, suppress: false))
        XCTAssertEqual(decide(rig, otherEvent, c), .quitNow)
        XCTAssertTrue(c.calls.isEmpty)
    }

    func testRequestClassification() {
        XCTAssertEqual(QuitPolicy.request(nil), .user)
        XCTAssertEqual(QuitPolicy.request(dockQuit), .user)
        XCTAssertEqual(QuitPolicy.request(systemQuit), .system)
        XCTAssertEqual(QuitPolicy.request(scriptedQuit), .scripted)
        XCTAssertEqual(QuitPolicy.request(otherEvent), .scripted)
        XCTAssertFalse(QuitPolicy.shouldConfirm(.user, confirmEnabled: false), "关闭确认后用户退出也直接退")
    }

    func testCancelLeavesForegroundBridgeAlone() throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        rig.engine.start()
        let c = FakeConfirmer(QuitAnswer(quit: false, suppress: false))
        XCTAssertEqual(decide(rig, nil, c), .cancel)
        XCTAssertEqual(rig.launched[0].terminateCount, 0)
        XCTAssertTrue(rig.signals.isEmpty)
        XCTAssertTrue(rig.settings.confirmQuit, "取消不改变确认设置")
    }

    func testForegroundBridgeIsStoppedBeforeQuit() throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        rig.engine.start()
        let c = FakeConfirmer(QuitAnswer(quit: true, suppress: false))
        XCTAssertEqual(decide(rig, nil, c), .stopBridgeThenQuit)
        XCTAssertEqual(c.calls, [false], "文案：会一起停止")
    }

    func testBackgroundBridgeIsLeftRunningOnQuit() throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        rig.engine.start()
        let c = FakeConfirmer(QuitAnswer(quit: true, suppress: false))
        XCTAssertEqual(decide(rig, nil, c), .quitNow)
        XCTAssertEqual(c.calls, [true], "文案：会继续在后台运行")
        XCTAssertEqual(rig.launched[0].terminateCount, 0, "后台运行：退出时不停 Bridge")
        XCTAssertTrue(rig.signals.isEmpty)
    }

    func testSystemQuitStopsForegroundBridgeWithoutPrompt() throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        rig.engine.start()
        let c = FakeConfirmer(QuitAnswer(quit: false, suppress: false))
        XCTAssertEqual(decide(rig, systemQuit, c), .stopBridgeThenQuit, "注销 / 关机照旧先停 Bridge，但不弹窗")
        XCTAssertTrue(c.calls.isEmpty)
    }

    func testDontAskAgainPersistsAndSkipsNextPrompt() throws {
        let rig = try TakeoverRig()
        let c = FakeConfirmer(QuitAnswer(quit: true, suppress: true))
        XCTAssertEqual(decide(rig, nil, c), .quitNow)
        XCTAssertFalse(rig.settings.confirmQuit)
        XCTAssertEqual(decide(rig, nil, c), .quitNow)
        XCTAssertEqual(c.calls.count, 1, "勾选后的下一次退出不再弹窗")
        let reloaded = EngineSettings(defaults: rig.defaults, secretsReady: true)
        XCTAssertFalse(reloaded.confirmQuit, "「不再询问」跨启动保存")
    }

    func testDontAskAgainWithCancelIsNotSaved() throws {
        let rig = try TakeoverRig()
        let c = FakeConfirmer(QuitAnswer(quit: false, suppress: true))
        XCTAssertEqual(decide(rig, nil, c), .cancel)
        XCTAssertTrue(rig.settings.confirmQuit, "「不再询问」只随「退出」保存；取消时不保存")
        XCTAssertEqual(decide(rig, nil, c), .cancel)
        XCTAssertEqual(c.calls.count, 2, "取消后的下一次 ⌘Q 仍会询问")
        XCTAssertTrue(EngineSettings(defaults: rig.defaults, secretsReady: true).confirmQuit)
    }

    func testReopeningConfirmationPromptsAgain() throws {
        let rig = try TakeoverRig()
        rig.settings.confirmQuit = false
        let c = FakeConfirmer(QuitAnswer(quit: true, suppress: false))
        XCTAssertEqual(decide(rig, nil, c), .quitNow)
        XCTAssertTrue(c.calls.isEmpty)
        rig.settings.confirmQuit = true
        XCTAssertEqual(decide(rig, nil, c), .quitNow)
        XCTAssertEqual(c.calls.count, 1, "设置里重新打开后又会询问")
    }

    func testAlertCopyFollowsBridgeMode() {
        XCTAssertTrue(QuitPolicy.alertText(keepsAfterQuit: true).text.contains("继续在后台运行"))
        XCTAssertTrue(QuitPolicy.alertText(keepsAfterQuit: false).text.contains("一起停止"))
        XCTAssertEqual(QuitPolicy.alertText(keepsAfterQuit: false).title, "退出 Palmhelm？")
    }
}

/// S1：从真实的 NSAppleEventDescriptor 构造退出信息，再到分类结果（接线测试，不靠手工拼 Bool）。
/// why? 是 kAEQuitApplication 的参数（paramDescriptor）；发送者 pid 是属性（attributeDescriptor 'spid'）。
@MainActor
final class QuitEventDescriptorTests: XCTestCase {
    private let dockPid: Int32 = 301
    private let scriptPid: Int32 = 302

    private func probe() -> FakeProcessProbe {
        let p = FakeProcessProbe()
        p.table[dockPid] = BridgeProcessSnapshot(pid: dockPid, startMicros: 1, executable: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")
        p.table[scriptPid] = BridgeProcessSnapshot(pid: scriptPid, startMicros: 2, executable: "/usr/bin/osascript")
        return p
    }

    /// 构造真实的 quit 描述符：why? 作为参数写入（与系统一致）。发送者 pid 不在这里伪造（'spid' 是系统投递时填入的属性），由 from(_:probe:senderPID:) 显式传入。
    private func quitEvent(reason: FourCharCode? = nil, reasonAsAttribute: Bool = false) -> NSAppleEventDescriptor {
        let ev = NSAppleEventDescriptor(eventClass: 0x6165_7674, eventID: 0x7175_6974, targetDescriptor: nil, returnID: -1, transactionID: 0)
        if let reason, !reasonAsAttribute { ev.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: 0x7768_793F) } // why? 参数
        if let reason, reasonAsAttribute { ev.setAttribute(NSAppleEventDescriptor(enumCode: reason), forKeyword: 0x7768_793F) }
        return ev
    }

    func testSystemShutdownWithReasonParameterIsSystemEvenWhenSentByDock() {
        let info = QuitEventInfo.from(quitEvent(reason: 0x7368_7574), probe: probe(), senderPID: dockPid) // 'shut'
        XCTAssertTrue(info.hasReason)
        XCTAssertTrue(info.senderIsDock)
        XCTAssertEqual(QuitPolicy.request(info), .system, "带 why? 参数的 Dock 来源是系统关机，不是用户退出")
        XCTAssertFalse(QuitPolicy.shouldConfirm(QuitPolicy.request(info), confirmEnabled: true))
    }

    func testDockQuitWithoutReasonPrompts() {
        let info = QuitEventInfo.from(quitEvent(), probe: probe(), senderPID: dockPid)
        XCTAssertTrue(info.isQuit)
        XCTAssertFalse(info.hasReason)
        XCTAssertEqual(QuitPolicy.request(info), .user)
        XCTAssertTrue(QuitPolicy.shouldConfirm(QuitPolicy.request(info), confirmEnabled: true))
    }

    func testOsascriptQuitIsScriptedAndDoesNotPrompt() {
        let info = QuitEventInfo.from(quitEvent(), probe: probe(), senderPID: scriptPid)
        XCTAssertEqual(QuitPolicy.request(info), .scripted)
        XCTAssertFalse(QuitPolicy.shouldConfirm(QuitPolicy.request(info), confirmEnabled: true))
    }

    func testReasonInAttributeIsNotTheQuitReason() {
        let info = QuitEventInfo.from(quitEvent(reason: 0x7368_7574, reasonAsAttribute: true), probe: probe(), senderPID: dockPid)
        XCTAssertFalse(info.hasReason, "why? 只认参数，属性里的同名键不算")
        XCTAssertEqual(QuitPolicy.request(info), .user)
    }

    func testNonQuitEventIsScripted() {
        let ev = NSAppleEventDescriptor(eventClass: 0x6165_7674, eventID: 0x6f61_7070, targetDescriptor: nil, returnID: -1, transactionID: 0) // 'oapp'
        let info = QuitEventInfo.from(ev, probe: probe())
        XCTAssertFalse(info.isQuit)
        XCTAssertEqual(QuitPolicy.request(info), .scripted)
    }

    func testRealDescriptorThroughCoordinatorSkipsPromptForSystemShutdown() throws {
        let rig = try TakeoverRig()
        let confirmer = CountingConfirmer()
        let info = QuitEventInfo.from(quitEvent(reason: 0x7368_7574), probe: probe(), senderPID: dockPid)
        XCTAssertEqual(QuitCoordinator(settings: rig.settings, engine: rig.engine, confirmer: confirmer).decide(event: info), .quitNow)
        XCTAssertEqual(confirmer.calls, 0, "系统关机不弹窗")
    }
}

@MainActor
private final class CountingConfirmer: QuitConfirming {
    var calls = 0
    func confirm(keepsAfterQuit: Bool) -> QuitAnswer {
        calls += 1
        return QuitAnswer(quit: true, suppress: false)
    }
}
