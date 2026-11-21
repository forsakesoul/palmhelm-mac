import AppKit
import XCTest
@testable import PalmhelmMac

/// 测试宿主不产生 App 自动 UI（菜单栏图标、自动打开/恢复的窗口、Dock 常驻）。
/// 菜单栏与窗口场景直接读 RuntimeEnvironment.isTestHost，这里断言它与运行中的 App 状态一致。
@MainActor
final class TestHostQuietTests: XCTestCase {
    func testTestHostFlagComesFromTheSchemeEnvironment() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["REINS_TEST_HOST"], "1")
        XCTAssertTrue(RuntimeEnvironment.isTestHost)
    }

    func testActualRunningHostUsesAccessoryPolicy() {
        XCTAssertEqual(NSApp.activationPolicy(), .accessory, "actual application policy must reflect willFinishLaunching wiring")
    }
}
