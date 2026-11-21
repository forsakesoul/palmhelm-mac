import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// O1-327 离屏截图（默认跳过）：TEST_RUNNER_REINS_SEND_SHOTS=1 时渲染到 /tmp/w1-send-shots/，浅色与深色各一套。
// 只渲染纯视图（排队状态行、系统回执行、回填提示），状态文字走真实的 SendTimingCopy / ReceiptText。
@MainActor
final class WithdrawShotTests: XCTestCase {
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

    /// 身份行只写来源；状态只在状态行出现一次（O1-327）。
    private func bubble(label: String, tone: QueuedTone, actions: [QueuedAction]) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            QueuedStatusView(label: label, tone: tone, items: actions.map { QueuedActionItem(action: $0, enabled: true, disabledReason: nil) }, note: nil, onWithdraw: {}, onPromote: {})
            Text("我 · 来自设备").font(.caption2).foregroundStyle(.secondary)
            Text("顺便把 820 窄窗的截图也补一下").font(.subheadline).foregroundStyle(PalmhelmTheme.emphasis)
                .padding(10).background(PalmhelmTheme.bubbleMe, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(16)
        .frame(width: 440)
    }

    func testRenderWithdrawShots() throws {
        guard ProcessInfo.processInfo.environment["REINS_SEND_SHOTS"] == "1" else { throw XCTSkip("set TEST_RUNNER_REINS_SEND_SHOTS=1 to render withdraw shots") }
        let dir = URL(fileURLWithPath: "/tmp/w1-send-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queued = SendTimingCopy.commandStatus(state: "queued", reason: nil, lane: "ordinary")
        let withdrawn = SendTimingCopy.commandStatus(state: "rejected", reason: "withdrawn", lane: "ordinary")
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let shots: [(String, Data?)] = [
                ("o327-mac-queued", render(bubble(label: queued, tone: .queued, actions: [.withdraw]), dark: dark, size: NSSize(width: 440, height: 110))),
                ("o327-mac-withdrawn", render(bubble(label: withdrawn, tone: .muted, actions: []), dark: dark, size: NSSize(width: 440, height: 110))),
                ("o327-mac-receipt", render(SystemReceiptLine(summary: ReceiptText.summary("已撤回，未发出。")).padding(16).frame(width: 440), dark: dark, size: NSSize(width: 440, height: 60))),
                ("o327-mac-banner", render(WithdrawnOfferBanner(canReplace: true, onReplace: {}, onDismiss: {}).padding(16).frame(width: 640), dark: dark, size: NSSize(width: 640, height: 60))),
                ("o327-mac-banner-disabled", render(WithdrawnOfferBanner(canReplace: false, onReplace: {}, onDismiss: {}).padding(16).frame(width: 640), dark: dark, size: NSSize(width: 640, height: 60))),
            ]
            for (name, png) in shots {
                let data = try XCTUnwrap(png, name)
                try data.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }
}
