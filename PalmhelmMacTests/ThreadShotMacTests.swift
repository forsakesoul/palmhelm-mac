import AppKit
import PalmhelmKit
import SwiftUI
import XCTest
@testable import PalmhelmMac

// #88 S4 + #101 截图（Mac，合成数据，深/浅色）：线程头部、折叠长回复（续读入口）、发送提示。
// 默认跳过；TEST_RUNNER_PALMHELM_H140_SHOTS=1 时写入 TEST_RUNNER_PALMHELM_H140_SHOTS_DIR。
@MainActor
final class ThreadShotMacTests: XCTestCase {
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

    func testRenderThreadHeaderFoldedReplyAndSendHintShots() throws {
        guard ProcessInfo.processInfo.environment["PALMHELM_H140_SHOTS"] == "1" else { throw XCTSkip("set TEST_RUNNER_PALMHELM_H140_SHOTS=1 to render thread shots") }
        let dirPath = ProcessInfo.processInfo.environment["PALMHELM_H140_SHOTS_DIR"] ?? "/tmp/W1-h140-shots"
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let long = (1...14).map { "第 \($0) 行：合成的长回复内容，用于检查折叠与渐隐。" }.joined(separator: "\n")
        let item = TranscriptItem(id: "reply-1", role: "assistant", text: long, t: 1_700_000_000_000, truncated: true, continuation: "tok")
        let folding = TranscriptRowFolding(folded: true, expansion: nil, expand: {}, collapse: {}, loadMore: {})
        let details = [
            ThreadDetail(label: "状态", value: "工作中 · 2 分钟"),
            ThreadDetail(label: "位置", value: "工作区 › 标签 · 窗格 p1"),
            ThreadDetail(label: "智能体与模型", value: "design · claude-opus"),
            ThreadDetail(label: "飞书消息发往", value: "「handoff」"),
        ]
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let view = VStack(alignment: .leading, spacing: 14) {
                Text("设计执行线程").font(.title3.weight(.bold))
                HStack(spacing: 10) {
                    ThreadHeaderBar(statusText: "工作中", statusTone: PalmhelmTheme.accent, durationText: "2 分钟", modelText: "claude-opus")
                    Spacer()
                    ThreadDetailsButton(details: details)
                    Button("在 Herdr 中显示") {}
                }
                TranscriptItemRow(item: item, folding: folding)
                ComposerSendHint(hint: .queued(ahead: 1), agentName: "design")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            let png = try XCTUnwrap(render(view, dark: dark, size: NSSize(width: 560, height: 520)))
            try png.write(to: dir.appendingPathComponent("mac-thread-\(suffix).png"))
        }
        // 旧 Bridge 的截断长回复（没有续读令牌）：展开后仍可看已收到的正文，并说明不能继续加载（R1）。
        let legacy = TranscriptItem(id: "legacy-1", role: "assistant", text: long, t: 1_700_000_000_000, truncated: true, continuation: nil)
        let expanded = TranscriptRowFolding(folded: false, expansion: nil, expand: {}, collapse: {}, loadMore: {})
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let view = TranscriptItemRow(item: legacy, folding: expanded)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            let png = try XCTUnwrap(render(view, dark: dark, size: NSSize(width: 560, height: 420)))
            try png.write(to: dir.appendingPathComponent("mac-thread-legacy-expanded-\(suffix).png"))
        }
    }
}
