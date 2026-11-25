import AppKit
import SwiftUI
import XCTest
@testable import PalmhelmMac

@MainActor
final class PairingDevicesLayoutTests: XCTestCase {
    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    func testLongDeviceListScrollsInsideBoundedPairingWindow() async throws {
        let devices = (0..<30).map { i in
            HookClient.Device(id: "device-\(String(format: "%02d", i))", name: i % 2 == 0 ? "MacBook Pro \(i)" : "iPhone \(i)",
                              pairedT: 1_793_000_000_000, lastSeenT: i % 3 == 0 ? nil : 1_793_000_100_000,
                              paused: i % 4 == 1, revoked: i % 3 == 0, permission: i % 5 == 0 ? nil : "readonly")
        }
        for dark in [false, true] {
            let suite = "palmhelm.o370.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = EngineSettings(defaults: defaults)
            let host = NSHostingView(rootView: PairingWindow(devicesForTesting: devices)
                .environment(MacSession()).environment(BridgeEngine(settings: settings)).environment(settings))
            let size = NSSize(width: 840, height: 730)
            host.frame = NSRect(origin: .zero, size: size)
            let container = NSView(frame: host.frame)
            container.wantsLayer = true
            container.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor.white).cgColor
            container.addSubview(host)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = container
            defer { window.contentView = nil; window.close() }
            for _ in 0..<4 { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
            func capture(_ name: String) throws {
                let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
                container.cacheDisplay(in: container.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REINS_CAPTURE_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("pairing-devices")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try png.write(to: dir.appendingPathComponent("\(dark ? "dark" : "light")-\(name).png"))
            }
            try capture("top")
            XCTAssertLessThan(host.fittingSize.height, 850, "多设备不能把配对窗口撑出屏幕")
            let scroll = try XCTUnwrap(scrollViews(host).first, "只有设备表需要可滚动区域")
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height + 500)
            XCTAssertLessThanOrEqual(scroll.frame.height, 300)
            let originalFrame = scroll.convert(scroll.bounds, to: host)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500, "末尾已撤销设备应可滚动到达")
            XCTAssertEqual(scroll.convert(scroll.bounds, to: host), originalFrame, "滚动只改变表内位置")
            try capture("bottom")
        }
    }
}
