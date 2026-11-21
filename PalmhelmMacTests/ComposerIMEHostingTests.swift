import AppKit
import Observation
import SwiftUI
import XCTest
@testable import PalmhelmMac

// 真实 SwiftUI 接线：NSHostingView 里的 ComposerView 换草稿 scope 时，经真实 updateNSView 作废旧组字，不串草稿。
@MainActor
@Observable
private final class Harness {
    var scope = "A"
    var textA = ""
    var textB = "bee"
    var enabled = true
    let gate = ComposerCompositionGate()
}

private struct HarnessView: View {
    let h: Harness
    var body: some View {
        ComposerView(
            draft: Binding(get: { h.scope == "A" ? h.textA : h.textB }, set: { if h.scope == "A" { h.textA = $0 } else { h.textB = $0 } }),
            attachments: .constant([]), enabled: h.enabled, placeholder: "", onSubmit: {}, onError: { _ in },
            scope: h.scope, gate: h.gate)
    }
}

@MainActor
final class ComposerIMEHostingTests: XCTestCase {
    private func findTextView(in view: NSView) -> ComposerNSTextView? {
        if let tv = view as? ComposerNSTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }

    private func spin(_ host: NSView, _ seconds: TimeInterval = 0.3) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    /// 组字中把 scope 从 A 换到 B（并同时禁用）：旧组字不留给 B，B 的草稿原样。
    func testSwitchingTheDraftScopeThroughRealSwiftUIEndsTheOldComposition() throws {
        let h = Harness()
        let host = NSHostingView(rootView: HarnessView(h: h))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        spin(host)
        let tv = try XCTUnwrap(findTextView(in: host), "应已挂载输入框")
        tv.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(tv.hasMarkedText())
        for _ in 0..<5 { h.textA = h.textA; spin(host, 0.05) }               // 同 scope 的重算
        XCTAssertTrue(tv.hasMarkedText(), "同 scope 普通重算保持组字")
        h.scope = "B"
        h.enabled = false
        spin(host)
        let tv2 = try XCTUnwrap(findTextView(in: host))
        XCTAssertFalse(tv2.hasMarkedText(), "换 scope：旧组字作废")
        XCTAssertEqual(tv2.string, "bee", "显示 B 的草稿")
        XCTAssertEqual(h.textB, "bee", "B 没有收到 A 的组字")
        XCTAssertEqual(h.textA, "", "A 的草稿没被改写")
        window.contentView = nil
    }
}
