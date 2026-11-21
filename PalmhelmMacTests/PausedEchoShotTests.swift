import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// O1-068：原生插话被暂停时的本机失败行（真实 QueuedStatusView，文案来自 Kit 的 OutgoingStatus）：默认跳过。
// TEST_RUNNER_REINS_PAUSED_SHOTS=1 时渲染到 TEST_RUNNER_REINS_PAUSED_SHOTS_DIR（缺省 /tmp/W1-h39-shots），文件名以 mac- 开头。
@MainActor
final class PausedEchoShotTests: XCTestCase {
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

    func testRenderPausedEchoShots() throws {
        guard ProcessInfo.processInfo.environment["REINS_PAUSED_SHOTS"] == "1" else { throw XCTSkip("set TEST_RUNNER_REINS_PAUSED_SHOTS=1 to render paused-echo shots") }
        let path = ProcessInfo.processInfo.environment["REINS_PAUSED_SHOTS_DIR"] ?? "/tmp/W1-h39-shots"
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let label = OutgoingStatus.label(.nativePaused)
        for dark in [false, true] {
            let view = VStack(alignment: .trailing, spacing: 3) {
                QueuedStatusView(label: label, tone: .queued, items: [], note: nil, onWithdraw: {}, onPromote: {})
                Text("补一句：顺便把截图也补一下").font(.subheadline).foregroundStyle(PalmhelmTheme.emphasis)
                    .padding(10).background(PalmhelmTheme.bubbleMe, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(16)
            .frame(width: 420)
            let data = try XCTUnwrap(render(view, dark: dark, size: NSSize(width: 460, height: 120)))
            try data.write(to: dir.appendingPathComponent("mac-paused-native-echo-\(dark ? "dark" : "light").png"))
        }
    }
}
