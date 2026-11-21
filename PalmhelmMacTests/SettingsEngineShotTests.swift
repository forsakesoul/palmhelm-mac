import AppKit
import SwiftUI
import XCTest
@testable import PalmhelmMac

// O1-399 截图：设置页「引擎」区（含后台运行与退出确认两个开关），亮色、暗色各一张。
// 写入 $REINS_CAPTURE_DIR/settings-engine/{light,dark}-engine.png；未设置时写到系统临时目录。不启动 Bridge。
@MainActor
final class SettingsEngineShotTests: XCTestCase {
    func testWritesLightAndDarkEngineSettingsScreenshots() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REINS_CAPTURE_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("settings-engine")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suite = "palmhelm.o399.shot.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = EngineSettings(defaults: defaults, secretsReady: true)
            let engine = BridgeEngine(settings: settings)
            let host = NSHostingView(
                rootView: SettingsView(initialPane: .engine)
                    .environment(settings).environment(engine).environment(MacSession()))
            let size = NSSize(width: 900, height: 720)
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
            window.makeKeyAndOrderFront(nil) // 成为 key 窗口：侧栏选中行按系统样式绘制，截图才看得见文字
            for _ in 0..<8 { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
            let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let url = dir.appendingPathComponent("\(dark ? "dark" : "light")-engine.png")
            try png.write(to: url)
            XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0, 10_000)
        }
    }
}
