import Foundation
import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

@MainActor final class QueueDeadlineSessionTests: XCTestCase {
    private func session() throws -> MacSession {
        let s = MacSession()
        s.stopStream()
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"deadline-device","name":"test","paused":false,"permission":"control"}"#.utf8))
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[{"id":"t1","projectName":"p","agentName":"a","capabilities":{"steer":false,"queueDeadline":true}}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.link = .connected
        s.sendOverride = { _, id in try JSONDecoder().decode(MessageReceipt.self, from: Data("{\"received\":true,\"eventKey\":\"\(id.uuidString)\"}".utf8)) }
        return s
    }
    func test_directDurationAndFreshResend() async throws {
        let s = try session()
        _ = await s.sendDirect("原文", agent: "a", threadId: "t1", queueTTLSeconds: 3600)
        XCTAssertTrue(s.lastSendMode == nil)
        XCTAssertTrue(s.lastQueueTTLSeconds == 3600)
        let old = try XCTUnwrap(s.sent.last?.eventKey)
        let c = try JSONDecoder().decode(ApiCommand.self, from: Data("{\"key\":\"\(old)\",\"inboxSeq\":1,\"text\":\"原文\",\"truncated\":false,\"origin\":\"api\",\"device\":{\"id\":\"deadline-device\",\"name\":\"test\"},\"targetId\":\"t1\",\"state\":\"paused\",\"reason\":\"queue_expired\"}".utf8))
        var direct = c; direct.directAgent = "a"
        s.commands[c.key] = direct
        await s.resendExpired(direct)
        XCTAssertTrue(s.sent.count == 2)
        XCTAssertTrue(s.sent.last?.eventKey != old)
        XCTAssertTrue(s.lastQueueTTLSeconds == nil)
        XCTAssertTrue(s.commands[c.key] == direct)
        s.link = .offline("test")
        await s.resendExpired(c)
        XCTAssertTrue(s.sent.count == 2)
        s.stopStream()
    }
    func test_unadvertisedDurationCannotSilentlyBecomeUnlimited() async throws {
        let s = try session()
        s.state?.targets[0].capabilities?.queueDeadline = nil
        _ = await s.sendDirect("原文", agent: "a", threadId: "t1", queueTTLSeconds: 3600)
        XCTAssertTrue(s.sent.isEmpty)
        s.link = .offline("test")
        s.state?.targets[0].capabilities?.queueDeadline = true
        _ = await s.sendDirect("原文", agent: "a", threadId: "t1", queueTTLSeconds: 86400)
        XCTAssertTrue(s.sent.isEmpty)
        s.stopStream()
    }
    private func expired(_ s: MacSession, directAgent: String? = nil) -> ApiCommand {
        var c = ApiCommand(key: "old", inboxSeq: 1, text: "use: 保留原文", origin: "api", targetId: "t1", state: "paused", reason: "queue_expired", lane: "ordinary")
        c.device = try! JSONDecoder().decode(ApiCommand.Device.self, from: Data(#"{"id":"deadline-device","name":"test"}"#.utf8))
        c.directAgent = directAgent
        s.commands[c.key] = c
        return c
    }
    func test_bothDurationsRequireTheCapabilityAndReachTheTransport() async throws {
        let s = try session(); defer { s.stopStream() }
        for ttl in [3600, 86400] {
            XCTAssertTrue(SendTimingRules.menu(steer: .unavailable, queueDeadline: true).contains { $0.choice.queueTTLSeconds == ttl })
            _ = await s.sendDirect("原文", agent: "a", threadId: "t1", queueTTLSeconds: ttl)
            XCTAssertTrue(s.lastQueueTTLSeconds == ttl)
        }
        XCTAssertTrue(SendTimingRules.menu(steer: .available, queueDeadline: false).allSatisfy { $0.choice.queueTTLSeconds == nil })
    }
    func test_boundResendKeepsQueueModeAndChangedBindingDoesNotBecomeDirect() async throws {
        let s = try session(); defer { s.stopStream() }
        let c = expired(s)
        await s.resendExpired(c)
        XCTAssertTrue(s.sent.isEmpty, "原绑定不在时不能改走直达，即使当前 agent 名合法")
        XCTAssertTrue(s.commandNotes[c.key]?.text.contains("原目标或绑定已变化") == true)
        s.state?.binding = try JSONDecoder().decode(Binding.self, from: Data(#"{"targetId":"t1","projectName":"p","agentName":"a"}"#.utf8))
        await s.resendExpired(c)
        XCTAssertTrue(s.sent.count == 1)
        XCTAssertTrue(s.lastSendMode == .queue, "use: 正文不能被升级成 steer")
        XCTAssertTrue(s.sent.last?.text == c.text)
        XCTAssertTrue(s.sent.last?.eventKey != c.key)
        XCTAssertTrue(s.commands[c.key] == c)
    }
    func test_directResendRejectsAChangedAgentButNotACollaborationRole() async throws {
        let s = try session(); defer { s.stopStream() }
        let c = expired(s, directAgent: "a")
        s.state?.targets[0].agentName = "a_execute"
        await s.resendExpired(c)
        XCTAssertTrue(s.sent.isEmpty, "原直达 agent 与目标当前 agent 不同：仍拒绝")
        XCTAssertTrue(s.commandNotes[c.key] != nil)
        var role = c; role.directAgent = "a_execute"; s.commands[c.key] = role
        await s.resendExpired(role)
        XCTAssertTrue(s.sent.count == 1 && s.sent.last?.targetId == "t1", "#81：协作角色名不再是拒绝理由")
    }
    func test_expiryAndUncertainLabelsRenderInTheProductionStatusView() throws {
        for (reason, expected) in [("queue_expired", "已过期，未发出"), ("queue_expired_uncertain", "停止后续排队，之前的结果待确认")] {
            let label = SendTimingCopy.commandStatus(state: "paused", reason: reason, lane: "ordinary", locale: Locale(identifier: "zh-Hans"))
            XCTAssertTrue(label == expected)
            XCTAssertTrue(SendTimingRules.isQueuedFamily(state: "paused", reason: reason))
            XCTAssertTrue(QueuedTone.of(reason: reason) == .muted)
            let view = QueuedStatusView(label: label, tone: QueuedTone.of(reason: reason), items: reason == "queue_expired" ? [QueuedActionItem(action: .resend, enabled: true, disabledReason: nil)] : [], note: nil, onWithdraw: {}, onPromote: {}).padding(16).frame(width: 440).background(Color.white)
            // Native link buttons need NSHostingView; ImageRenderer substitutes an unsupported-view glyph.
            let host = NSHostingView(rootView: view.frame(height: 80))
            host.frame = NSRect(x: 0, y: 0, width: 440, height: 80)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1000)
            if let dir = ProcessInfo.processInfo.environment["REINS_CAPTURE_DIR"] {
                let url = URL(fileURLWithPath: dir); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try png.write(to: url.appendingPathComponent("mac-\(reason).png"))
            }
        }
    }

}
