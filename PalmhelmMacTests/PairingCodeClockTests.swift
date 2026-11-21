import XCTest
@testable import PalmhelmMac

// O1-341 R2：配对码的倒计时、过期与二维码从同一个时间点判断；过期后码与二维码一起失效。
final class PairingCodeClockTests: XCTestCase {
    func testCountdownAndExpiryShareOneTimePoint() {
        let code = HookClient.PairCode(code: "123456", expiresT: 1_000_000) // 1000 秒时过期
        XCTAssertEqual(PairingCodeClock.remaining(code, at: Date(timeIntervalSince1970: 998.5)), 1)
        XCTAssertFalse(PairingCodeClock.expired(code, at: Date(timeIntervalSince1970: 998.5)))
        XCTAssertEqual(PairingCodeClock.remaining(code, at: Date(timeIntervalSince1970: 1000)), 0)
        XCTAssertTrue(PairingCodeClock.expired(code, at: Date(timeIntervalSince1970: 1000)))
        XCTAssertTrue(PairingCodeClock.expired(code, at: Date(timeIntervalSince1970: 1001)), "过期后不回头")
    }

    func testQRImageIsRegeneratedOnlyWhenThePayloadChanges() {
        let cache = QRImageCache()
        var made = 0
        let make: (String) -> NSImage? = { _ in made += 1; return NSImage(size: NSSize(width: 1, height: 1)) }
        _ = cache.image(for: "a", make: make)
        _ = cache.image(for: "a", make: make)
        XCTAssertEqual(made, 1, "同一 payload 不重画，界面每秒求值不会重新生成二维码")
        _ = cache.image(for: "b", make: make)
        XCTAssertEqual(made, 2)
    }
}
