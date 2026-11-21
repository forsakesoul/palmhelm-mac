import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// A1-071 F3：铃铛脉冲先于侧栏挂载（窄窗收起、在用量页）时，侧栏挂载那一刻也要呈现定位 / 提示；已消费的 serial 不重复。
@MainActor
final class InboxFocusMountTests: XCTestCase {
    private func session() -> MacSession {
        let s = MacSession()
        s.state = try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.link = .connected
        return s
    }

    private func mount(_ s: MacSession, onConsumed: @escaping (MacSession.InboxFocus) -> Void) async -> (NSWindow, NSView) {
        let defaults = UserDefaults(suiteName: "InboxFocusMount.\(UUID().uuidString)")!
        let settings = EngineSettings(defaults: defaults, secretsReady: true)
        let host = NSHostingView(rootView: InboxSidebar(onConsumed: onConsumed).environment(s).environment(BridgeEngine(settings: settings)).environment(settings).frame(width: 300, height: 500))
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false // ARC 持有：默认 true 会在 close 时多释放一次
        w.contentView = host
        w.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(50)) }
        return (w, host)
    }

    func testPulseThatArrivedBeforeMountIsShownOnFirstAppear() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let s = session()
        s.pulseInboxFocus(.top) // 侧栏还没挂载（窄窗收起 / 用量页）：脉冲先到
        var got: [MacSession.InboxFocus] = []
        let (w, _) = await mount(s) { got.append($0) }
        defer { w.orderOut(nil); w.contentView = nil; w.close() }
        XCTAssertEqual(got.map(\.target), [.top], "首次挂载就要消费并呈现（高亮 + 「没有需要你处理的请求」）")
        XCTAssertNil(s.takeInboxFocus(), "已消费的 serial 不会再触发")
        s.pulseInboxFocus(.top) // 已挂载时再点铃铛：onChange 路径仍然有效
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(got.count, 2)
    }

    func testConsumedPulseIsNotReplayedOnRemountAndStalePulseIsDropped() async throws {
        let s = session()
        s.pulseInboxFocus(.top)
        XCTAssertEqual(s.takeInboxFocus()?.target, .top)
        XCTAssertNil(s.takeInboxFocus(), "同一 serial 只消费一次")
        s.pulseInboxFocus(.request("r1"))
        XCTAssertNil(s.takeInboxFocus(now: Date().addingTimeInterval(MacSession.focusFreshSeconds + 1)), "过了鲜活期的旧脉冲不补播")
        s.pulseInboxFocus(.top)
        XCTAssertNotNil(s.takeInboxFocus(), "新脉冲（新 serial）照常")
    }
}
