import AppKit
import PalmhelmKit
import SwiftUI
import XCTest
@testable import PalmhelmMac

// 英文界面目检（#63，O1-317）：默认跳过；PALMHELM_MAC_I18N_EN_SHOTS=<目录> 时渲染真实主窗口（会话 / 用量）与设置窗口，浅色。
// 测试语言由 xcodebuild -testLanguage en -testRegion US 决定，不写用户偏好。
@MainActor
final class MacI18nEnglishShotTests: XCTestCase {
    private let pageKey = "palmhelm.mainPage"

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func capture(_ view: some View, size: NSSize, to url: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        spin(1.5)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testCaptureMainWindowAndSettingsLight() async throws {
        guard let output = ProcessInfo.processInfo.environment["PALMHELM_MAC_I18N_EN_SHOTS"] else { throw XCTSkip("opt-in visual capture") }
        let dir = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previousPage = UserDefaults.standard.object(forKey: pageKey)
        defer {
            if let previousPage { UserDefaults.standard.set(previousPage, forKey: pageKey) } else { UserDefaults.standard.removeObject(forKey: pageKey) }
        }
        let settings = EngineSettings(defaults: UserDefaults(suiteName: "palmhelm.mac.i18n.shots")!)
        let session = MacSession()
        session.preferences = UserDefaults(suiteName: "palmhelm.mac.i18n.shots")!
        session.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-i18n","name":"mac","paused":false,"permission":"control"}"#.utf8))
        session.link = .connected
        session.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let json = #"{"occupancy":"free","targets":[{"id":"t1","projectName":"demo","agentName":"demo","status":"working"}],"history":{"highWater":0,"items":[]}}"#
        session.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8)) }
        session.selectedTarget = "t1"; session.selectedThread = "t1"
        await session.refresh()
        var thread = TranscriptThread(); thread.status = .ok
        thread.items = TranscriptContentHeightTests.items(6) + [TranscriptItem(id: "tr-last", role: "assistant", text: TranscriptContentHeightTests.markdown(999, long: true))]
        session.transcripts["t1"] = thread
        let engine = BridgeEngine(settings: settings)

        // 会话（列表 + 会话页含头部与折叠）与用量：同一主窗口，切换页面键
        for (name, page) in [("conversation", 0), ("usage", 1)] {
            UserDefaults.standard.set(page, forKey: pageKey)
            let view = MainWindow().environment(session).environment(engine).environment(settings).frame(width: 1100, height: 720)
            try capture(view, size: NSSize(width: 1100, height: 720), to: dir.appendingPathComponent("mac-\(name)-light.png"))
        }
        // 设置窗口
        let settingsView = SettingsView().environment(session).environment(engine).environment(settings).frame(width: 720, height: 640)
        try capture(settingsView, size: NSSize(width: 720, height: 640), to: dir.appendingPathComponent("mac-settings-light.png"))
    }
}
