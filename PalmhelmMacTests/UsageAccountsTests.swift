import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// O1-368：账户额度的真实窗口白名单（Codex 5h/7d；Claude 5h/7d/Fable）、默认最紧账户、选择保持。
final class UsageAccountsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var nowMs: Int { Int(now.timeIntervalSince1970 * 1000) }
    private func win(_ id: String, mins: Int?, used: Double?, resetIn: Int = 3_600_000) -> AccountWindow {
        AccountWindow(id: id, label: nil, usedPercent: used, reset: nil, windowMins: mins, resetAt: resetIn == 0 ? nil : nowMs + resetIn)
    }
    private func acct(_ provider: String, _ id: String, status: String = "ok", windows: [AccountWindow]?) -> AccountSnapshot {
        AccountSnapshot(provider: provider, accountId: id, label: nil, plan: nil, billingMode: "subscription", windows: windows, source: "x", observedAt: nowMs, status: status)
    }

    func testWhitelistKeepsOnlyConfirmedWindows() {
        let claude = acct("claude", "c1", windows: [
            win("five_hour", mins: 300, used: 10), win("seven_day", mins: 10080, used: 20), win("seven_day:fable", mins: 10080, used: 30),
            win("seven_day_opus", mins: 10080, used: 40), win("seven_day_sonnet", mins: 10080, used: 50), win("extra", mins: 10080, used: 60),
        ])
        XCTAssertEqual(QuotaWindowPolicy.windows(of: claude).map(\.id), ["five_hour", "seven_day", "seven_day:fable"], "Opus / Sonnet 与未知窗口不显示")
        XCTAssertEqual(QuotaWindowPolicy.windows(of: acct("claude", "p", windows: [win("five_hour:primary", mins: 300, used: 1), win("seven_day:primary", mins: 10080, used: 2)])).map(\.id), ["five_hour:primary", "seven_day:primary"], "状态行的 :primary 形式也是 5h/7d")
        let codex = acct("codex", "x1", windows: [win("bucket0", mins: 300, used: 5), win("bucket1", mins: 10080, used: 6), win("bucket9", mins: 1440, used: 7)])
        XCTAssertEqual(QuotaWindowPolicy.windows(of: codex).map(\.id), ["bucket0", "bucket1"], "Codex 只有 5 小时与 7 天")
        XCTAssertEqual(QuotaWindowPolicy.windows(of: acct("api", "a", windows: nil)).count, 0, "API 无订阅窗口")
    }

    func testDefaultIsTheHighestUsedLiveWindowAndIgnoresDeadOrUnknownAccounts() {
        let low = acct("codex", "a", windows: [win("bucket0", mins: 300, used: 20)])
        let high = acct("claude", "b", windows: [win("seven_day:fable", mins: 10080, used: 97)])
        let reset = acct("codex", "c", windows: [win("bucket0", mins: 300, used: 99, resetIn: -1_000)]) // 已重置：不参与
        let failed = acct("claude", "d", status: "error", windows: [win("five_hour", mins: 300, used: 99)])
        XCTAssertEqual(AccountSelection.tightest([low, high, reset, failed], now: now).map(AccountSelection.key), "claude|b")
        XCTAssertNil(AccountSelection.tightest([acct("api", "e", windows: nil)], now: now), "API 与失败不作为默认")
    }

    func testTiesBreakByStableKeyAndSavedSelectionSurvivesReordering() {
        let x = acct("codex", "zz", windows: [win("bucket0", mins: 300, used: 50)])
        let y = acct("codex", "aa", windows: [win("bucket0", mins: 300, used: 50)])
        XCTAssertEqual(AccountSelection.tightest([x, y], now: now).map(AccountSelection.key), "codex|aa", "相等按稳定键决胜")
        // 用户已选的账户仍在列表里：即使默认变了也沿用，不抢回
        XCTAssertEqual(AccountSelection.resolve(selectedKey: "codex|zz", accounts: [y, x], now: now).map(AccountSelection.key), "codex|zz")
        // 所选账户移除后回到默认
        XCTAssertEqual(AccountSelection.resolve(selectedKey: "codex|gone", accounts: [y, x], now: now).map(AccountSelection.key), "codex|aa")
    }
}
