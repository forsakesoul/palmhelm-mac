import AppKit
import PalmhelmKit
import SwiftUI
import XCTest
@testable import PalmhelmMac

// #112 目检（方案 A：常驻行 = ⋯ + 标题 + 对话｜终端；可收起行 = 胶囊 + 详情 + 在 Herdr 中显示）：
// 默认跳过；PALMHELM_HEADER_SHOTS=<目录> 时离屏渲染真实 MainWindow（假数据，不连网、不碰真实 Bridge）：宽 / 窄 × 浅 / 深、已收起、超长名称的窄宽压力图。
@MainActor
final class ThreadHeaderLayoutShotTests: XCTestCase {
    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func capture(_ view: some View, size: NSSize, dark: Bool, to url: URL, beforeSnapshot: (() -> Void)? = nil) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        spin(1.5)
        beforeSnapshot?()
        spin(0.6)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func makeSession(defaults: UserDefaults, agent: String, project: String) async throws -> MacSession {
        let session = MacSession()
        session.preferences = defaults
        session.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-demo","name":"mac","paused":false,"permission":"control"}"#.utf8))
        session.link = .connected
        session.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let json = #"{"occupancy":"free","targets":[{"id":"t1","projectName":"\#(project)","agentName":"\#(agent)","status":"working","kind":"claude","model":{"id":"claude-opus-5-5","basis":"last_used","effort":"medium"},"location":{"workspace":"demo","tab":"1","pane":"p1"}}],"history":{"highWater":0,"items":[]}}"#
        session.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8)) }
        session.selectedTarget = "t1"; session.selectedThread = "t1"
        await session.refresh()
        var thread = TranscriptThread(); thread.status = .ok
        thread.items = TranscriptContentHeightTests.items(14)
        session.transcripts["t1"] = thread
        return session
    }

    func testCaptureHeaderShots() async throws {
        guard let output = ProcessInfo.processInfo.environment["PALMHELM_HEADER_SHOTS"] else { throw XCTSkip("opt-in visual capture") }
        let dir = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "palmhelm.mac.header.shots.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousPage = UserDefaults.standard.object(forKey: "palmhelm.mainPage")
        UserDefaults.standard.set(0, forKey: "palmhelm.mainPage")
        defer { if let previousPage { UserDefaults.standard.set(previousPage, forKey: "palmhelm.mainPage") } else { UserDefaults.standard.removeObject(forKey: "palmhelm.mainPage") } }
        let settings = EngineSettings(defaults: defaults)
        let engine = BridgeEngine(settings: settings)
        let updates = UpdateChecker(source: GitHubUpdateSource(userAgent: "shot"), currentBuild: nil, networkEnabled: false, defaults: defaults)

        func window(_ session: MacSession, width: Double) -> some View {
            MainWindow().environment(session).environment(engine).environment(settings).environment(updates).frame(width: width, height: 560)
                .background(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea() // 截图宿主的标题栏区域不画背景，深色下会透出白底
        }

        let session = try await makeSession(defaults: defaults, agent: "design", project: "demo")
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            for (name, w) in [("wide", 1100.0), ("narrow", 820.0), ("sidebar900", 900.0)] { // 900：侧栏仍显示时线程列最窄（约 590pt）
                try capture(window(session, width: w), size: NSSize(width: w, height: 560), dark: dark, to: dir.appendingPathComponent("A-\(name)-\(tag).png"))
            }
            // 已收起：模拟用户向下滚动一个头部高度以上（第二行淡出，常驻行保留）。
            try capture(window(session, width: 1100), size: NSSize(width: 1100, height: 560), dark: dark, to: dir.appendingPathComponent("A-collapsed-\(tag).png")) {
                guard let chrome = MacThreadChrome.latestForTest else { return }
                chrome.phaseChanged(to: .interacting)
                chrome.observeGeometry(offsetY: 120, rawAtBottom: false, layoutChanged: false)
                chrome.observeGeometry(offsetY: 120 + max(chrome.extent, 60) * 1.5, rawAtBottom: false, layoutChanged: false)
            }
        }
        // 压力：超长名称 + 窄宽，标题应先截断，⋯ 与分段控件仍在，按钮不换行。
        let long = try await makeSession(defaults: defaults, agent: "task_000000000000_execute_with_an_extremely_long_name", project: "example-app-with-a-very-long-project-name")
        for dark in [false, true] {
            for w in [820.0, 900.0] {
                try capture(window(long, width: w), size: NSSize(width: w, height: 560), dark: dark, to: dir.appendingPathComponent("A-longname-\(Int(w))-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
