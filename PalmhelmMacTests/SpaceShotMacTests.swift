import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #98 h91：合成截图（侧栏空间分组，深/浅色）。默认跳过；TEST_RUNNER_PALMHELM_H91_SHOTS=1 时写入 TEST_RUNNER_PALMHELM_H91_SHOTS_DIR。
// ⋯ 菜单与右键菜单的展开内容不能离屏截取，未包含在截图中。
@MainActor
final class SpaceShotMacTests: XCTestCase {
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

    nonisolated private static func state(_ groups: [(id: String, ws: String, label: String, working: Bool)]) -> BridgeState {
        let targets = groups.map { g in
            #"{"projectName":"\#(g.id)","id":"\#(g.id)","online":true,"status":"\#(g.working ? "working" : "idle")","location":{"workspace":"\#(g.label)"},"workspaceId":"\#(g.ws)","terminalId":"term-\#(g.id)"}"#
        }
        let spaces = groups.map { #"{"workspace":"\#($0.label)","agentlessTabCount":0,"workspaceId":"\#($0.ws)"}"# }
        return try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[\#(targets.joined(separator: ","))],"history":{"highWater":0,"items":[]},"spaces":[\#(spaces.joined(separator: ","))],"observation":{"t":1700000000000,"complete":true,"fresh":true}}"#.utf8))
    }

    func testRenderSpaceSidebarShots() async throws {
        guard ProcessInfo.processInfo.environment["PALMHELM_H91_SHOTS"] == "1" else { throw XCTSkip("set TEST_RUNNER_PALMHELM_H91_SHOTS=1 to render space shots") }
        let dirPath = ProcessInfo.processInfo.environment["PALMHELM_H91_SHOTS_DIR"] ?? "/tmp/W1-h91-shots"
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "mac-space-shots-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let s = MacSession()
        let d = UserDefaults(suiteName: suite)!
        s.spaceStore = SpaceOrderStore(defaults: d)
        s.spaceDocument = SpaceOrderDocument()
        s.archive = ThreadArchiveStore(defaults: d)
        s.lens = .spaces
        s.stateOverride = { Self.state([(id: "a", ws: "w1", label: "设计空间", working: false), (id: "b", ws: "w2", label: "执行空间", working: false), (id: "c", ws: "w3", label: "顾问空间", working: false)]) }
        try await s.pullState()
        s.stateOverride = { Self.state([(id: "a", ws: "w1", label: "设计空间", working: false), (id: "b", ws: "w2", label: "执行空间", working: true), (id: "c", ws: "w3", label: "顾问空间", working: false)]) }
        s.setSpaceListVisible(false)
        try await s.pullState()
        let gamma = s.railSections.first { $0.title == "顾问空间" }!.id
        s.setSpaceGroupPinned(gamma, true)
        s.lens = .spaces
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let rail = render(VStack(alignment: .leading, spacing: 0) { SpacesContent().environment(s) }.environment(s), dark: dark, size: NSSize(width: 300, height: 420))
            let png = try XCTUnwrap(rail, "rail")
            try png.write(to: dir.appendingPathComponent("mac-space-sidebar-\(suffix).png"))
        }
    }
}
