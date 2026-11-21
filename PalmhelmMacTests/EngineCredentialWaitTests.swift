import XCTest
@testable import PalmhelmMac

// A1-081 片 3：钥匙串未读完时不以空配置启动 Bridge（看门狗超时也不改变这一点；晚到的装载才放行）。
@MainActor
final class EngineCredentialWaitTests: XCTestCase {
    func testStartIsRefusedUntilSecretsAreLoaded() throws {
        let suite = "credwait-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = EngineSettings(defaults: defaults) // secretsReady 缺省 false：装载尚未完成
        let engine = BridgeEngine(settings: settings)
        engine.start()
        XCTAssertEqual(engine.status, .stopped, "no child process may be launched with empty configuration")
        XCTAssertTrue(engine.logs.contains { $0.contains("钥匙串尚未读完") })
        XCTAssertNil(engine.startedAt)
    }
}
