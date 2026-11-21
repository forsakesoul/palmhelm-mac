import AppKit
import PalmhelmKit
import SwiftUI
import XCTest
@testable import PalmhelmMac

// #115 目检：默认跳过；PALMHELM_UPDATE_SHOTS=<目录> 时离屏渲染主窗口横幅与设置 › 关于（假数据源，不连网）。语言由 -testLanguage 决定。
@MainActor
final class UpdateShotTests: XCTestCase {
    private struct Fixed: UpdateSource {
        let build: Int
        func latestRelease() async throws -> UpdateRelease? { UpdateRelease(tag: "v1.0-\(build)", htmlURL: nil, draft: false, prerelease: false) }
    }

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func capture(_ view: some View, size: NSSize, dark: Bool, to url: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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

    func testCaptureBannerAndAbout() async throws {
        guard let output = ProcessInfo.processInfo.environment["PALMHELM_UPDATE_SHOTS"] else { throw XCTSkip("opt-in visual capture") }
        let dir = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "palmhelm.mac.update.shots.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousPage = UserDefaults.standard.object(forKey: "palmhelm.mainPage")
        UserDefaults.standard.set(0, forKey: "palmhelm.mainPage")
        defer { if let previousPage { UserDefaults.standard.set(previousPage, forKey: "palmhelm.mainPage") } else { UserDefaults.standard.removeObject(forKey: "palmhelm.mainPage") } }

        let settings = EngineSettings(defaults: defaults)
        let engine = BridgeEngine(settings: settings)
        let session = MacSession()
        session.preferences = defaults
        session.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-demo","name":"mac","paused":false,"permission":"control"}"#.utf8))
        session.link = .connected
        session.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let json = #"{"occupancy":"free","targets":[{"id":"t1","projectName":"demo","agentName":"demo","status":"working"}],"history":{"highWater":0,"items":[]}}"#
        session.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8)) }
        session.selectedTarget = "t1"; session.selectedThread = "t1"
        await session.refresh()
        var thread = TranscriptThread(); thread.status = .ok
        thread.items = TranscriptContentHeightTests.items(6)
        session.transcripts["t1"] = thread

        let newer = UpdateChecker(source: Fixed(build: 150), currentBuild: 149, networkEnabled: true, defaults: defaults)
        await newer.checkNow()
        let latest = UpdateChecker(source: Fixed(build: 149), currentBuild: 149, networkEnabled: true, defaults: defaults)
        await latest.checkNow()

        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            let main = MainWindow().environment(session).environment(engine).environment(settings).environment(newer).frame(width: 1100, height: 720)
            try capture(main, size: NSSize(width: 1100, height: 720), dark: dark, to: dir.appendingPathComponent("banner-\(tag).png"))
            for (name, c) in [("available", newer), ("uptodate", latest)] {
                let v = SettingsView(initialPane: .about).environment(session).environment(engine).environment(settings).environment(c).frame(width: 860, height: 620)
                try capture(v, size: NSSize(width: 860, height: 620), dark: dark, to: dir.appendingPathComponent("about-\(name)-\(tag).png"))
            }
        }
    }
}
