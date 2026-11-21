import XCTest
@testable import PalmhelmMac

// #88 S4：Mac 会话读取门禁（线程可见、窗口为 key、窗口未遮挡、对话页）。只有四者同时成立才发起读取。
final class ThreadActivityGateTests: XCTestCase {
    func testOnlyAllFourConditionsStartReads() {
        for visible in [false, true] {
            for key in [false, true] {
                for windowVisible in [false, true] {
                    for mode in [0, 1] {
                        let expected = visible && key && windowVisible && mode == 0
                        XCTAssertEqual(ThreadActivityGate.isActive(threadVisible: visible, keyWindow: key, windowVisible: windowVisible, mode: mode), expected,
                                       "visible=\(visible) key=\(key) windowVisible=\(windowVisible) mode=\(mode)")
                    }
                }
            }
        }
    }

    // 窗口被遮挡（如最小化、隐藏或完全被其它窗口盖住）时即使仍是 key 也不读取。
    func testOccludedWindowStopsReadsEvenWhenKey() {
        XCTAssertFalse(ThreadActivityGate.isActive(threadVisible: true, keyWindow: true, windowVisible: false, mode: 0))
        XCTAssertTrue(ThreadActivityGate.isActive(threadVisible: true, keyWindow: true, windowVisible: true, mode: 0))
    }
}
