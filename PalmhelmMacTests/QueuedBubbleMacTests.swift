import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(QueuedAction, String)] = []
    func add(_ a: QueuedAction, _ k: String) { lock.withLock { items.append((a, k)) } }
    var count: Int { lock.withLock { items.count } }
    var actions: [QueuedAction] { lock.withLock { items.map { $0.0 } } }
    var keys: [String] { lock.withLock { items.map { $0.1 } } }
}

// #69（Mac）：本机排队消息的操作必须经生产 RowView 接线露出，与 iOS 同一权威指令与守卫。
// 宿主真实行（.mine / .command），统计承载操作的按钮视图，并实际按下，记录经 commandOverride 的动作与 key。
// 按钮标题在 SwiftUI 承载视图中不可读，因此按 QueuedStatusView 的固定顺序（撤回、改为立即插入）按下来验证动作。
@MainActor
final class QueuedBubbleMacTests: XCTestCase {
    private let mineKey = "api:mac-69:1"

    private func session(device: String = "mac-69", permission: String = "control", bridgeCapabilities: Bool = true) throws -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.69.mac.\(UUID().uuidString)")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"\#(device)","name":"mac","paused":false,"permission":"\#(permission)"}"#.utf8))
        s.link = .connected
        s.sendOverride = { _, _ in MessageReceipt.stub("k") } // 与现有发送时机测试一致：通过 sendBlocker 的配对检查
        let caps = bridgeCapabilities ? #","capabilities":{"steer":true}"# : ""
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"busy","targets":[{"id":"t1","projectName":"p","agentName":"design","status":"working"\#(caps)}],"history":{"highWater":0,"items":[]}}"#.utf8))
        return s
    }

    private func command(state: String, device: String = "mac-69", origin: String = "api", direct: String? = nil) throws -> ApiCommand {
        let d = direct.map { #","directAgent":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"\#(mineKey)","inboxSeq":1,"text":"开始了吗","truncated":false,"origin":"\#(origin)","device":{"id":"\#(device)","name":"mac"},"state":"\#(state)","lane":"use","targetId":"t1"\#(d)}"#.utf8))
    }

    private func mine() -> MacSession.Sent {
        MacSession.Sent(id: UUID(), text: "开始了吗", at: Date(), afterSeq: 0, targetId: "t1", eventKey: mineKey)
    }

    /// 生产 RowView 的宿主窗口；调用方负责 orderOut。
    private func host(_ row: ThreadRow, _ s: MacSession) -> (NSWindow, NSView) {
        let hv = NSHostingView(rootView: RowView(row: row).environment(s).frame(width: 520, height: 160))
        hv.frame = NSRect(x: 0, y: 0, width: 520, height: 160)
        let win = NSWindow(contentRect: hv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hv
        win.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        return (win, hv)
    }

    /// 视图树中承载 SwiftUI 按钮的视图（AppKitButton），按出现顺序。
    private func actionButtons(_ v: NSView) -> [NSView] {
        var out: [NSView] = []
        if String(describing: type(of: v)).contains("AppKitButton") { out.append(v) }
        for sub in v.subviews { out += actionButtons(sub) }
        return out
    }

    /// 按下第 index 个操作按钮（鼠标按下与抬起，走控件的真实点击路径）。
    private func press(_ hv: NSView, at index: Int) throws {
        let buttons = actionButtons(hv)
        XCTAssertGreaterThan(buttons.count, index, "应有第 \(index + 1) 个操作按钮")
        let target = try XCTUnwrap(buttons.dropFirst(index).first)
        let window = try XCTUnwrap(target.window)
        let p = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(e)
        }
    }

    private func waitFor(_ rec: Recorder, count: Int) async throws {
        for _ in 0..<100 where rec.count < count { try await Task.sleep(for: .milliseconds(20)) }
    }

    // 1. 本机排队消息（权威 queued + 本机 + 可控 + 支持时机，非直达）：撤回与改为立即插入都在真实行上。
    func testMineQueuedWithAuthoritativeCommandShowsWithdrawAndPromote() throws {
        let s = try session()
        s.commands[mineKey] = try command(state: "queued")
        let (win, hv) = host(.mine(mine()), s)
        defer { win.orderOut(nil) }
        XCTAssertEqual(actionButtons(hv).count, 2, "撤回 + 改为立即插入")
    }

    // 2. 直达（指令带 directAgent）：只给撤回，不出现改为立即插入（两个入口都要）。
    func testDirectCommandRowOffersWithdrawOnlyEvenAfterBindingChanged() throws {
        let s = try session()
        s.commands[mineKey] = try command(state: "queued", direct: "design")
        let (win, hv) = host(.command(s.commands[mineKey]!), s)
        defer { win.orderOut(nil) }
        XCTAssertEqual(actionButtons(hv).count, 1, "直达：只给撤回")
    }

    func testDirectMineRowOffersWithdrawOnly() throws {
        let s = try session()
        s.commands[mineKey] = try command(state: "queued", direct: "design")
        let (win, hv) = host(.mine(mine()), s)
        defer { win.orderOut(nil) }
        XCTAssertEqual(actionButtons(hv).count, 1)
    }

    // 3. 缺权威 command / 他设备 / 只读 / 旧 Bridge：不出现任何操作。
    func testWithoutAuthoritativeCommandNoActions() throws {
        let s = try session()
        let (win, hv) = host(.mine(mine()), s)
        defer { win.orderOut(nil) }
        XCTAssertEqual(actionButtons(hv).count, 0)
    }

    func testOtherDeviceNoActions() throws {
        let s = try session()
        s.commands[mineKey] = try command(state: "queued", device: "mac-other")
        let (win, hv) = host(.mine(mine()), s)
        defer { win.orderOut(nil) }
        XCTAssertEqual(actionButtons(hv).count, 0)
    }

    func testReadOnlyNoActions() throws {
        let s = try session(permission: "readonly")
        s.commands[mineKey] = try command(state: "queued")
        let (win, hv) = host(.mine(mine()), s)
        defer { win.orderOut(nil) }
        XCTAssertEqual(actionButtons(hv).count, 0)
    }

    func testOldBridgeNoActions() throws {
        let s = try session(bridgeCapabilities: false)
        s.commands[mineKey] = try command(state: "queued")
        let (win, hv) = host(.mine(mine()), s)
        defer { win.orderOut(nil) }
        XCTAssertEqual(actionButtons(hv).count, 0)
    }

    // 4. queued → started（实际渲染并推进 tracker）→ 迟到的旧 queued 快照写回：不复活操作，有效阶段不回退为排队。
    func testStaleQueuedSnapshotAfterStartedShowsNoActions() throws {
        let s = try session()
        let m = mine()
        s.commands[mineKey] = try command(state: "queued")
        let (win, hv) = host(.mine(m), s)
        XCTAssertEqual(actionButtons(hv).count, 2)
        win.orderOut(nil)
        // started 真实渲染：tracker 推进到非排队阶段
        s.commands[mineKey] = try command(state: "started")
        let (win2, hv2) = host(.mine(m), s)
        XCTAssertEqual(actionButtons(hv2).count, 0)
        let advanced = s.outgoingStatus(m).phase
        XCTAssertFalse([OutgoingPhase.queued, .queuedSteer].contains(advanced), "started 之后不得仍是排队阶段，实际 \(advanced)")
        XCTAssertTrue([OutgoingPhase.processing, .delivered].contains(advanced), "started 应进入处理/送达阶段，实际 \(advanced)")
        win2.orderOut(nil)
        // 迟到的旧 queued 快照写回；inflight 不以 started 遮蔽，使 commands[key] 的 queued 生效
        s.inflight = [:]
        s.commands[mineKey] = try command(state: "queued")
        let (win3, hv3) = host(.mine(m), s)
        defer { win3.orderOut(nil) }
        XCTAssertEqual(actionButtons(hv3).count, 0, "已前进阶段不得因迟到的旧 queued 快照重新露出操作")
        XCTAssertEqual(s.outgoingStatus(m).phase, advanced, "有效阶段仍为处理/送达，不回退为排队")
    }

    // 5. 实际按下第一个按钮：撤回，经 commandOverride 记录 withdraw 与原 key。
    func testPressingWithdrawRecordsRequestAndKey() async throws {
        let s = try session()
        let rec = Recorder()
        s.commandOverride = { action, key in rec.add(action, key) }
        s.commands[mineKey] = try command(state: "queued")
        let (win, hv) = host(.mine(mine()), s)
        defer { win.orderOut(nil) }
        try press(hv, at: 0)
        try await waitFor(rec, count: 1)
        XCTAssertEqual(rec.actions, [.withdraw])
        XCTAssertEqual(rec.keys, [mineKey])
    }

    // 6. 实际按下第二个按钮：改为立即插入（非直达），经 commandOverride 记录 promote 与原 key。
    func testPressingPromoteRecordsRequestAndKey() async throws {
        let s = try session()
        let rec = Recorder()
        s.commandOverride = { action, key in rec.add(action, key) }
        s.commands[mineKey] = try command(state: "queued")
        let (win, hv) = host(.mine(mine()), s)
        defer { win.orderOut(nil) }
        try press(hv, at: 1)
        try await waitFor(rec, count: 1)
        XCTAssertEqual(rec.actions, [.promote])
        XCTAssertEqual(rec.keys, [mineKey])
    }

    // 0. 对照（修复前即应通过）：现有 .command 排队行的按钮可实际按下，证明按压接线可用。
    func testControlCommandRowPressWithdrawRecordsRequest() async throws {
        let s = try session()
        let rec = Recorder()
        s.commandOverride = { action, key in rec.add(action, key) }
        s.commands[mineKey] = try command(state: "queued")
        let (win, hv) = host(.command(s.commands[mineKey]!), s)
        defer { win.orderOut(nil) }
        XCTAssertEqual(actionButtons(hv).count, 2)
        try press(hv, at: 0)
        try await waitFor(rec, count: 1)
        XCTAssertEqual(rec.actions, [.withdraw])
        XCTAssertEqual(rec.keys, [mineKey])
    }
}
