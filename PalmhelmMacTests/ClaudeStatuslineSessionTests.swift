import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// Claude 额度的状态行开关（#26 第二段，A1-109 返工）：状态确定之前不可操作；未知 / 旧 Bridge 不是「已关闭」；
/// 只有 2xx 且 ok == true 才算成功；未知错误码显示固定文案。真实 MacSession + override。
@MainActor
final class ClaudeStatuslineSessionTests: XCTestCase {
    private func session() -> MacSession {
        let s = MacSession()
        s.link = .connected
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        return s
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }
    private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }

    func testStateIsUnknownUntilLoadedAndUnsupportedFor404() async {
        let s = session()
        XCTAssertEqual(s.claudeStatuslineState, .unknown, "未加载前不是已关闭")
        s.claudeStatuslineStatusOverride = { throw BridgeError.http(status: 404) }
        await s.loadClaudeStatusline()
        XCTAssertEqual(s.claudeStatuslineState, .unsupported, "旧 Bridge 不当作已关闭")
    }

    func testUnreadableStatusStaysUnknownNotOff() async {
        let s = session()
        s.claudeStatuslineStatusOverride = { throw BridgeError.http(status: 503) }
        await s.loadClaudeStatusline()
        XCTAssertEqual(s.claudeStatuslineState, .unknown, "读取失败不是已关闭")
    }

    func testOperationsAreRefusedUntilStateIsKnown() async {
        let s = session()
        let called = Flag()
        s.claudeStatuslineOverride = { _ in called.set(); return ClaudeStatuslineResult(ok: true) }
        await s.setClaudeStatusline(install: true)
        XCTAssertFalse(called.value, "状态未知时不发起安装")
        XCTAssertNotNil(s.claudeStatuslineNote)
    }

    func testLoadedOffThenSuccessfulInstallReloadsState() async {
        let s = session()
        s.claudeStatuslineStatusOverride = { false }
        await s.loadClaudeStatusline()
        XCTAssertEqual(s.claudeStatuslineState, .off)
        s.claudeStatuslineOverride = { _ in ClaudeStatuslineResult(ok: true, settings: "changed", restored: "none") }
        s.claudeStatuslineStatusOverride = { true }
        await s.setClaudeStatusline(install: true)
        XCTAssertEqual(s.claudeStatuslineState, .on)
        XCTAssertEqual(s.claudeStatuslineNote, "已开启：状态行已换成 Palmhelm 的透传包装，原来的状态行照常显示")
    }

    func testResponseWithoutOkIsNotSuccess() async {
        let s = session()
        s.claudeStatuslineStatusOverride = { false }
        await s.loadClaudeStatusline()
        // 2xx 但内容不对：客户端解码后得到 invalid_response，状态不变。
        s.claudeStatuslineOverride = { _ in decodeClaudeStatuslineResult(status: 200, data: Data(#"{"settings":"changed"}"#.utf8)) }
        await s.setClaudeStatusline(install: true)
        XCTAssertEqual(s.claudeStatuslineState, .off, "坏的 2xx 不改开关状态")
        XCTAssertEqual(s.claudeStatuslineNote, "Bridge 的回复不认识，请升级 Bridge 后重试")
    }

    func testUnknownErrorCodeShowsFixedTextNotEcho() async {
        let s = session()
        s.claudeStatuslineStatusOverride = { false }
        await s.loadClaudeStatusline()
        s.claudeStatuslineOverride = { _ in ClaudeStatuslineResult(ok: false, error: "/opt/example/secret path") }
        await s.setClaudeStatusline(install: true)
        XCTAssertEqual(s.claudeStatuslineNote, "安装失败", "未知码不回显")
    }
}
