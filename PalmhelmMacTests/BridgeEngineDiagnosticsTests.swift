import XCTest
@testable import PalmhelmMac

/// 配对诊断去重：只与上一条比较；相同阶段连续出现只记一条。
@MainActor
final class BridgeEngineDiagnosticsTests: XCTestCase {
    private func stages(_ engine: BridgeEngine) -> [String] {
        // 日志行格式为 `[palmhelm] 时间 阶段`：去掉前缀与时间，只比较阶段文本
        engine.logs.map { line in String(line.split(separator: " ", maxSplits: 2).last ?? "") }
    }

    func testRepeatedFailuresCollapseAcrossSuccessToThreeTransitions() {
        // 回归触发：若去重改为只看 logs.last 或删除去重，离线重试会留下 N 条相同 refresh_failed
        let engine = BridgeEngine(settings: EngineSettings())
        for _ in 0..<5 { engine.diagnose("refresh_failed") }
        engine.diagnose("refresh 成功")
        for _ in 0..<5 { engine.diagnose("refresh_failed") }
        XCTAssertEqual(stages(engine), ["refresh_failed", "refresh 成功", "refresh_failed"])
        XCTAssertTrue(engine.logs.allSatisfy { $0.hasPrefix("[palmhelm] ") })
    }

    func testOtherStageBetweenAllowsSameFailureAgain() {
        // 回归触发：若去重改为全局集合（而非只比上一条），中间插入其它阶段后同名失败不再记录
        let engine = BridgeEngine(settings: EngineSettings())
        engine.diagnose("refresh_failed")
        engine.diagnose("selfPair 开始")
        engine.diagnose("refresh_failed")
        XCTAssertEqual(stages(engine), ["refresh_failed", "selfPair 开始", "refresh_failed"])
    }
}
