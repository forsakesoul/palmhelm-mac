import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #97 S3：合成截图（归档列表、归档历史、目标栏里的历史行；深色与浅色）。默认跳过；
// REINS_... 之外使用 PALMHELM_H51_SHOTS=1 时写入 PALMHELM_H51_SHOTS_DIR（缺省 /tmp/W1-h51-shots）。
@MainActor
final class MacArchiveShotTests: XCTestCase {
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

    func testRenderArchiveShots() async throws {
        guard ProcessInfo.processInfo.environment["PALMHELM_H51_SHOTS"] == "1" else { throw XCTSkip("set PALMHELM_H51_SHOTS=1 to render archive shots") }
        let dirPath = ProcessInfo.processInfo.environment["PALMHELM_H51_SHOTS_DIR"] ?? "/tmp/W1-h51-shots"
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = 24 * 60 * 60 * 1000
        let t0 = 1_700_000_000_000
        let suite = "mac-archive-shots-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let s = MacSession()
        s.archive = ThreadArchiveStore(defaults: UserDefaults(suiteName: suite)!)
        let st = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[{"projectName":"设计","id":"alpha","online":false},{"projectName":"执行","id":"beta","online":false}],"history":{"highWater":1,"items":[]},"observation":{"t":\#(t0),"complete":true,"fresh":true}}"#.utf8))
        s.stateOverride = { st }
        try await s.pullState()
        s.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[{"projectName":"设计","id":"alpha","online":false},{"projectName":"执行","id":"beta","online":false}],"history":{"highWater":1,"items":[]},"observation":{"t":\#(t0 + 7 * day),"complete":true,"fresh":true}}"#.utf8)) }
        try await s.pullState()
        s.archive.touch("b1|alpha", title: "设计", lastActivity: t0)
        s.archive.touch("b1|beta", title: "执行", lastActivity: t0 - day)
        s.archiveThread("beta")
        var page = TargetHistoryPaging()
        page.beginLoad()
        page.apply(TargetHistoryPage(items: [
            TargetHistoryRow(id: "inbox:api:d:1", source: "inbox", text: "请检查归档的历史会话是否保留用户消息", t: t0 - 3_600_000, targetId: "alpha", state: "finished"),
            TargetHistoryRow(id: "outbox:u1", source: "outbox", text: "已处理，结果见终端", t: t0 - 3_500_000, kind: "text", replyTo: "api:d:1"),
        ], nextBefore: "12.34", hasMore: true, partial: false), older: false)
        s.archivedPaging[s.archiveKey("alpha")] = page
        let dirPathSafe = dir
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let list = render(ArchivedThreadsWindow().environment(s), dark: dark, size: NSSize(width: 640, height: 440))
            let history = render(ArchivedHistoryPane(targetId: "alpha", title: "设计").environment(s), dark: dark, size: NSSize(width: 360, height: 420))
            let rail = render(VStack(alignment: .leading) { HistoricalRowView(row: HistoricalRailRow(id: "gone", title: s.railInputs.first { $0.key == "gone" }?.title ?? "gone", canArchive: s.canArchiveOrDelete("gone"))).environment(s) }.environment(s), dark: dark, size: NSSize(width: 260, height: 60))
            for (name, data) in [("mac-archive-list", list), ("mac-archive-history", history), ("mac-rail-historical", rail)] {
                let png = try XCTUnwrap(data, name)
                try png.write(to: dirPathSafe.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }
}
