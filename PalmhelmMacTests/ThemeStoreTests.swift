import AppKit
import PalmhelmKit
import XCTest
@testable import PalmhelmMac

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0
    var n: Int { lock.withLock { v } }
    func bump() { lock.withLock { v += 1 } }
}

/// 主题接线：存储可观察、按本机保存、外观只落到应用级外观（不重建任何东西）、刘海固定取深色 token。
@MainActor
final class ThemeStoreTests: XCTestCase {
    private func store() -> (PalmhelmThemeStore, UserDefaults, String) {
        let suite = "palmhelm.test.theme.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return (PalmhelmThemeStore(defaults: d), d, suite)
    }

    func testDefaultsAndPersistence() {
        let (s, d, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(s.family, .clearBlue)
        XCTAssertEqual(s.appearance, .system)
        s.applyAppearance = { _ in }
        s.family = .warmOrange
        s.appearance = .dark
        let again = PalmhelmThemeStore(defaults: d)
        XCTAssertEqual(again.family, .warmOrange)
        XCTAssertEqual(again.appearance, .dark)
        s.family = .deepSea
        XCTAssertEqual(PalmhelmThemeStore(defaults: d).family, .deepSea)
    }

    func testTokensFollowFamilyAndAppearanceOnlyTouchesAppLevel() {
        let (s, _, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var applied: [NSAppearance?] = []
        s.applyAppearance = { applied.append($0) }
        s.family = .qoderGreen
        XCTAssertEqual(s.tokens, PalmhelmThemeTokens.tokens(.qoderGreen))
        XCTAssertTrue(applied.isEmpty, "换家族不动应用外观")
        s.appearance = .light
        s.appearance = .system
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(applied[0]?.name, .aqua)
        XCTAssertNil(applied[1], "跟随系统 = 清掉应用级外观")
    }

    func testObservationFiresOnFamilyChangeWithoutRebuild() {
        let (s, _, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        s.applyAppearance = { _ in }
        let fired = Counter()
        withObservationTracking({ _ = s.tokens }, onChange: { fired.bump() })
        s.family = .warmOrange
        XCTAssertEqual(fired.n, 1, "读 tokens 的视图会因换家族而刷新")
    }

    func testNotchAlwaysUsesDarkSwatchOfCurrentFamily() {
        let shared = PalmhelmThemeStore.shared
        let old = shared.family
        defer { shared.family = old }
        shared.family = .warmOrange
        XCTAssertEqual(PalmhelmTheme.notchTokens, PalmhelmThemeTokens.tokens(.warmOrange).dark)
    }

    func testOnAccentAndAccentComeFromKitTokens() {
        // 固定表值：清蓝浅色 accent 0x245AC7 / onAccent 白；深色 accent 0x8CB4FF / onAccent 0x102445
        let t = PalmhelmThemeTokens.tokens(.clearBlue)
        XCTAssertEqual(t.light.accent, 0x245AC7)
        XCTAssertEqual(t.dark.onAccent, 0x102445)
    }
}
