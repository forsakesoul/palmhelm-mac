import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// 展开 / 收起改图标，展开态“时间 + 收起”同一行（Mac）：渲染真实的 TranscriptItemRow，比较高度并截图（PALMHELM_FOLD_SHOTS_DIR 指定输出目录）。
@MainActor
final class FoldIconsMacTests: XCTestCase {
    private let item = TranscriptItem(id: "long", role: "assistant", text: (0..<12).map { "第 \($0) 行：这是一段用来超过折叠阈值的中文回复，包含 **加粗** 与 `code`。" }.joined(separator: "\n"), t: 1_763_200_060_000)

    private func host(_ folding: TranscriptRowFolding?) -> NSHostingView<some View> {
        let hv = NSHostingView(rootView: TranscriptItemRow(item: item, folding: folding).frame(width: 640).background(Color.white))
        hv.frame = NSRect(x: 0, y: 0, width: 640, height: 10)
        hv.layoutSubtreeIfNeeded()
        return hv
    }
    private func height(_ f: TranscriptRowFolding?) -> CGFloat { host(f).fittingSize.height }
    private func folding(folded: Bool) -> TranscriptRowFolding { TranscriptRowFolding(folded: folded, expansion: nil, expand: {}, collapse: {}, loadMore: {}) }

    private func shot(_ f: TranscriptRowFolding, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PALMHELM_FOLD_SHOTS_DIR"] else { return }
        let hv = host(f)
        hv.frame = NSRect(origin: .zero, size: hv.fittingSize)
        let win = NSWindow(contentRect: hv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = hv
        hv.layoutSubtreeIfNeeded()
        guard let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { return }
        hv.cacheDisplay(in: hv.bounds, to: rep)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        win.contentView = nil; win.close()
    }

    /// 展开态：时间与收起图标合并成一行，整行比“正文 + 单独时间行”只多出按钮高度与时间行高度之差，不再多占一整行。
    func testExpandedFooterIsOneLineNotTwo() {
        let plain = height(nil)                     // 正文 + 一行时间（不参与折叠）
        let expanded = height(folding(folded: false)) // 正文 + 一行（时间 + 收起图标）
        XCTAssertLessThan(expanded - plain, 20, "展开态底栏只有一行：展开态 \(expanded) vs 无折叠 \(plain)")
        XCTAssertGreaterThan(expanded, plain - 1, "底栏至少与时间行等高")
        shot(folding(folded: true), "mac-fold-1-folded")
        shot(folding(folded: false), "mac-fold-2-expanded-one-line")
    }
}
