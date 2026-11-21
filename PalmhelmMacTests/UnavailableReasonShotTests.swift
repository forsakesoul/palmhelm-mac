import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// O1-080：会话记录不可用卡片的离屏截图（真实的 TranscriptUnavailableCard，文案来自 Kit）：默认跳过。
// TEST_RUNNER_PALMHELM_H46_SHOTS=1 时渲染到 TEST_RUNNER_PALMHELM_H46_SHOTS_DIR（缺省 /tmp/W1-h46-shots）。
@MainActor
final class UnavailableReasonShotTests: XCTestCase {
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

    func testRenderUnavailableReasonShots() throws {
        guard ProcessInfo.processInfo.environment["PALMHELM_H46_SHOTS"] == "1" else { throw XCTSkip("set PALMHELM_H46_SHOTS=1 to render shots") }
        let dirPath = ProcessInfo.processInfo.environment["PALMHELM_H46_SHOTS_DIR"] ?? "/tmp/W1-h46-shots"
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for (name, reason) in [("unavailable-owner-mismatch", "owner_mismatch"), ("unavailable-generic", nil)] {
                let png = try XCTUnwrap(render(TranscriptUnavailableCard(status: .unavailable, reason: reason).frame(width: 360, alignment: .leading).padding(16), dark: dark, size: NSSize(width: 392, height: 150)), name)
                try png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }
}
