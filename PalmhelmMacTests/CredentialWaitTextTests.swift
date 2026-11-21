import XCTest
@testable import PalmhelmMac

// A1-081 片 3：凭据读取中的提示只有一套文案（主窗、菜单、设置共用）；超时只提示授权窗口，不要求重启。
final class CredentialWaitTextTests: XCTestCase {
    func testWaitingTextAsksToAllowTheSystemPrompt() {
        XCTAssertEqual(ConnectionPhase.credentialsWaitText(stalled: false), "正在读取凭据（如有授权窗口请允许）")
    }

    func testStalledTextDoesNotDemandARestart() {
        let text = ConnectionPhase.credentialsWaitText(stalled: true)
        XCTAssertEqual(text, "钥匙串读取较慢，请处理系统授权窗口（如有）")
        XCTAssertFalse(text.contains("重启"))
    }

    func testReadingPhaseUsesTheSameWaitingText() {
        XCTAssertEqual(ConnectionPhase.readingCredentials.label, ConnectionPhase.credentialsWaitText(stalled: false))
        let phase = ConnectionPhase.from(engineStatus: .stopped, portFileReady: false, credentialsLoaded: false, secretsLoaded: true, link: .notPaired)
        XCTAssertEqual(phase, .readingCredentials)
        XCTAssertTrue(phase.isTransitional)
    }
}
