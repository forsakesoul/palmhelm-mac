import XCTest
@testable import PalmhelmMac

@MainActor
final class EngineHostIsolationTests: XCTestCase {
    func testHostRefusesTheRealLauncherBeforeCreatingAProcess() {
        XCTAssertTrue(RuntimeEnvironment.isTestHost)
        var factories = 0
        let launch = EngineLaunch(executable: "/unused", environment: [:], directory: NSTemporaryDirectory(), onStdout: { _ in }, onStderr: { _ in }, onExit: { _ in })
        XCTAssertThrowsError(try ProcessChild.launch(launch, makeProcess: {
            factories += 1
            return Process()
        })) { error in
            XCTAssertEqual(error as? EngineProcessError, .testHostForbidden)
        }
        XCTAssertEqual(factories, 0, "test host never reaches Process construction or run")
    }

    /// 测试宿主使用独立 bundle id（O1-075）：它的 UserDefaults.standard、AppKit 记录与正式版、.dev 互不相干。
    func testTestHostHasItsOwnBundleIdentifier() {
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.forsakesoul.palmhelm.mac")
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.forsakesoul.palmhelm.mac.dev")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.forsakesoul.palmhelm.mac.testhost")
    }

    private let prod = "com.forsakesoul.palmhelm.mac"

    func testProductionBundleDefaultsToTheNewDirectoryAndPort() {
        let value = EngineSettings.defaults(for: prod, home: "/h", fileExists: { _ in false })
        XCTAssertEqual(value.dataDir, "/h/.palmhelm-bridge")
        XCTAssertEqual(value.port, 47821)
    }

    func testProductionFallsBackToTheOldDirectoryOnlyWhileTheNewOneIsMissingAndTheOldHoldsALedger() {
        let legacyDB = "/h/.remote-herdr-bridge/bridge.db"
        // 新目录不存在、旧库在：沿用旧目录，不在新位置建空库
        XCTAssertEqual(EngineSettings.defaults(for: prod, home: "/h", fileExists: { $0 == legacyDB }).dataDir, "/h/.remote-herdr-bridge")
        // 新目录已存在（窗口里 mv 之后）：用新目录
        XCTAssertEqual(EngineSettings.defaults(for: prod, home: "/h", fileExists: { $0 == legacyDB || $0 == "/h/.palmhelm-bridge" }).dataDir, "/h/.palmhelm-bridge")
        // 旧目录存在但没有库：不回退
        XCTAssertEqual(EngineSettings.defaults(for: prod, home: "/h", fileExists: { $0 == "/h/.remote-herdr-bridge" }).dataDir, "/h/.palmhelm-bridge")
        XCTAssertEqual(EngineSettings.defaults(for: prod, home: "/h", fileExists: { $0 == legacyDB }).port, 47821)
    }

    func testDevelopmentBundlesNeverUseTheLegacyFallback() {
        let v = EngineSettings.defaults(for: "com.forsakesoul.palmhelm.mac.dev", home: "/h", fileExists: { _ in true })
        XCTAssertEqual(v.dataDir, "/h/Library/Application Support/Palmhelm-dev/bridge")
        XCTAssertEqual(v.port, 47831)
    }

    func testTheOldBundleIdentifierIsNoLongerTheProductionBundle() {
        let v = EngineSettings.defaults(for: "com.forsakesoul.reins.mac", home: "/h", fileExists: { _ in false })
        XCTAssertEqual(v.port, 47831, "旧 Bundle ID 不再被当作正式版")
    }

    func testEveryOtherBundleUsesDevelopmentDefaults() {
        for id in ["com.forsakesoul.palmhelm.mac.dev", "example.test", nil] as [String?] {
            let value = EngineSettings.defaults(for: id)
            XCTAssertEqual(value.dataDir, (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Palmhelm-dev/bridge"))
            XCTAssertEqual(value.port, 47831)
        }
    }

    func testSettingsUseBundleDefaultsButPreserveExplicitConfiguration() {
        let suite = "palmhelm.test.host-isolation.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let settings = EngineSettings(defaults: d, secretsReady: true)
        XCTAssertEqual(settings.dataDir, EngineSettings.defaults(for: Bundle.main.bundleIdentifier).dataDir)
        XCTAssertEqual(settings.port, EngineSettings.defaults(for: Bundle.main.bundleIdentifier).port)
        settings.dataDir = NSTemporaryDirectory() + UUID().uuidString
        settings.port = 49001
        let restored = EngineSettings(defaults: d, secretsReady: true)
        restored.interfaceProvider = { [] }
        XCTAssertEqual(restored.dataDir, settings.dataDir)
        XCTAssertEqual(restored.port, 49001)
        XCTAssertEqual(restored.environment()["BRIDGE_DATA_DIR"], settings.dataDir)
        XCTAssertEqual(restored.environment()["BRIDGE_PARENT_PID"], String(ProcessInfo.processInfo.processIdentifier))
    }
}
