import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// 发送时机的离屏截图（O1-305）：默认跳过。TEST_RUNNER_REINS_SEND_SHOTS=1 时渲染到 /tmp/w1-send-shots/。
// 只渲染纯视图组件（SendControls / QueuedStatusView / AttributionPreferenceRows），输入全部是测试值，不依赖 Session。
// 菜单打开的状态不截（系统 Menu 无法离屏渲染）；菜单项与灰掉的原因由 Kit 的单元测试覆盖。
@MainActor
final class SendTimingShotTests: XCTestCase {
    private func render<V: View>(_ view: V, dark: Bool, size: NSSize) -> Data? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: host.frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)).cgColor
        container.addSubview(host)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        host.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// 排队气泡：正文气泡 + 状态行（真实的 QueuedStatusView）。
    private func bubble(label: String, tone: QueuedTone, actions: [QueuedAction]) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            QueuedStatusView(label: label, tone: tone, items: actions.map { QueuedActionItem(action: $0, enabled: true, disabledReason: nil) }, note: nil, onWithdraw: {}, onPromote: {})
            Text("顺便把 820 窄窗的截图也补一下").font(.subheadline).foregroundStyle(PalmhelmTheme.emphasis)
                .padding(10).background(PalmhelmTheme.bubbleMe, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(16)
        .frame(width: 420)
    }

    /// 「已并入」的文字走真实链路：排队行（服务端快照）→ 收到 hook 确认的快照（reason=merged）→ CommandMerge → commandStatus。
    private static func mergedLabel() -> String {
        func command(_ json: String) -> ApiCommand { try! JSONDecoder().decode(ApiCommand.self, from: Data(json.utf8)) }
        let queued = command(#"{"key":"api:d:1","inboxSeq":2,"text":"顺便把 820 窄窗的截图也补一下","truncated":false,"origin":"api","state":"queued","lane":"use","targetId":"t1"}"#)
        let confirmed = command(#"{"key":"api:d:1","inboxSeq":2,"text":"顺便把 820 窄窗的截图也补一下","truncated":false,"origin":"api","state":"finished","lane":"use","reason":"merged","targetId":"t1"}"#)
        let row = CommandMerge.merged(old: queued, new: confirmed)
        return SendTimingCopy.commandStatus(state: row.state, reason: row.reason, lane: row.lane)
    }

    private func sendBar(menuShown: Bool, steer: SteerAvailability) -> some View {
        SendControls(busy: false, canSubmit: true, menuShown: menuShown, steer: steer, onPrimary: {}, onChoose: { _ in })
            .padding(16)
    }

    func testRenderSendTimingShots() throws {
        guard ProcessInfo.processInfo.environment["REINS_SEND_SHOTS"] == "1" else { throw XCTSkip("set REINS_SEND_SHOTS=1 to render send-timing shots") }
        let dir = URL(fileURLWithPath: "/tmp/w1-send-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let shots: [(String, AnyView, NSSize)] = [
                ("mac-send-idle", AnyView(sendBar(menuShown: false, steer: .unknown)), NSSize(width: 360, height: 70)),
                ("mac-send-working-steer-supported", AnyView(sendBar(menuShown: true, steer: .available)), NSSize(width: 360, height: 70)),
                ("mac-send-working-steer-unsupported", AnyView(sendBar(menuShown: true, steer: .unavailable)), NSSize(width: 360, height: 70)),
                ("mac-queued-after-turn", AnyView(bubble(label: SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: "ordinary"), tone: .queued, actions: [.withdraw, .promote])), NSSize(width: 460, height: 120)),
                ("mac-queued-use-promoted", AnyView(bubble(label: SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: "use"), tone: .queued, actions: [.withdraw])), NSSize(width: 460, height: 120)),
                ("mac-merged", AnyView(bubble(label: Self.mergedLabel(), tone: .merged, actions: [])), NSSize(width: 460, height: 120)),
                ("mac-withdrawn", AnyView(bubble(label: SendTimingCopy.commandStatus(state: "rejected", reason: "withdrawn", lane: "ordinary"), tone: .muted, actions: [])), NSSize(width: 460, height: 120)),
            ]
            for (name, view, size) in shots {
                let png = try XCTUnwrap(render(view, dark: dark, size: size), name)
                try png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }

    /// 立即发送（send_now）：排队行的三态标题（灰显带原因 / 可选）与回执文案，全部来自 Kit 的 QueuedActionItem / SendTimingCopy。菜单打开的状态不截（系统 Menu）。
    func testRenderSendNowShots() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["REINS_SEND_SHOTS"] == "1" else { throw XCTSkip("set REINS_SEND_SHOTS=1 to render send-now shots") }
        let dir = URL(fileURLWithPath: env["REINS_CAPTURE_DIR"] ?? NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("send-now-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func queued(nativeSendNow: Bool?) -> [QueuedActionItem] {
            SendTimingRules.queuedActionItems(state: "queued", reason: nil, steer: .unavailable, direct: true, nativeSteer: false, nativeSendNow: nativeSendNow)
        }
        func row(_ items: [QueuedActionItem], _ label: String) -> some View {
            VStack(alignment: .trailing, spacing: 3) {
                QueuedStatusView(label: label, tone: .queued, items: items, note: nil, onWithdraw: {}, onPromote: {})
                Text("顺便把 820 窄窗的截图也补一下").font(.subheadline).foregroundStyle(PalmhelmTheme.emphasis)
                    .padding(10).background(PalmhelmTheme.bubbleMe, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(16)
            .frame(width: 460)
        }
        let queuedLabel = SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: "use", direct: true)
        let shots: [(String, AnyView, NSSize)] = [
            ("mac-sendnow-queued-disabled-reason", AnyView(row(queued(nativeSendNow: false), queuedLabel)), NSSize(width: 460, height: 120)),
            ("mac-sendnow-queued-enabled", AnyView(row(queued(nativeSendNow: true), queuedLabel)), NSSize(width: 460, height: 120)),
            ("mac-sendnow-receipt-requested", AnyView(row([], SendTimingCopy.statusText(state: "finished", reason: "native_send_now_requested"))), NSSize(width: 460, height: 120)),
            ("mac-sendnow-receipt-skipped", AnyView(row([], SendTimingCopy.statusText(state: "finished", reason: "native_send_now_skipped"))), NSSize(width: 460, height: 120)),
        ]
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for (name, view, size) in shots {
                let png = try XCTUnwrap(render(view, dark: dark, size: size), name)
                try png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }
}
