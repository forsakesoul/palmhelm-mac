import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #21 S2 截图（Mac，合成数据，深/浅色）：新任务 sheet 的 GitHub 来源与已读取 Issue。默认跳过；TEST_RUNNER_PALMHELM_H105_SHOTS=1 时写入 TEST_RUNNER_PALMHELM_H105_SHOTS_DIR。
@MainActor
final class IssueTaskShotMacTests: XCTestCase {
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

    func testRenderIssueTaskSheetShots() throws {
        guard ProcessInfo.processInfo.environment["PALMHELM_H105_SHOTS"] == "1" else { throw XCTSkip("set TEST_RUNNER_PALMHELM_H105_SHOTS=1 to render issue task shots") }
        let dirPath = ProcessInfo.processInfo.environment["PALMHELM_H105_SHOTS_DIR"] ?? "/tmp/W1-h105-shots"
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let options = try JSONDecoder().decode(IssueTaskOptions.self, from: Data(#"""
        {"createSupported":true,"dispatchEnabled":true,
         "github":{"available":true,"reason":null,"createSupported":true},
         "sources":[{"sourceId":"0123456789abcdef","repo":"octo/handoff"}],
         "targets":[{"targetId":"target:a","label":"palmhelm-mac · design","destinationVersion":"abc","reason":null},
                    {"targetId":"target:b","label":"palmhelm-mac · execute","destinationVersion":null,"reason":"owner_only"}],
         "maxPromptUnits":8000}
        """#.utf8))
        let detail = try JSONDecoder().decode(IssueTaskDetail.self, from: Data(#"""
        {"number":21,"title":"设备列表支持按名称搜索","state":"open","updatedAt":"2026-11-07T08:00:00Z",
         "url":"https://github.com/octo/handoff/issues/21","body":"验收：搜索框在窄窗口下不截字；空结果显示说明。","sourceVersion":"sv"}
        """#.utf8))
        var draft = IssueTaskDraft()
        draft.source = .github
        draft.targetId = "target:a"
        draft.destinationVersion = "abc"
        draft.sourceId = "0123456789abcdef"
        draft.issue = detail
        draft.instructions = "只处理搜索框布局；保留现有数据逻辑。"
        let session = MacSession()
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let view = IssueTaskSheet(initialOptions: options, initialDraft: draft, onAccepted: { _ in }).environment(session)
            let png = try XCTUnwrap(render(view, dark: dark, size: NSSize(width: 560, height: 760)))
            try png.write(to: dir.appendingPathComponent("mac-issue-task-sheet-\(suffix).png"))
        }
    }
}
