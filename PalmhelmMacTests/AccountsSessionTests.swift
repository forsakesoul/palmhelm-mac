import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// 账户额度的 Session 状态（#26）：真实 MacSession + accountsOverride。
@MainActor
final class AccountsSessionTests: XCTestCase {
    private func state(bridge: String = "b1") -> BridgeState {
        decode(#"{"bridge":{"id":"\#(bridge)"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#)
    }
    private func session(_ load: @escaping @Sendable (Bool) async throws -> AccountsResponse) -> MacSession {
        let s = MacSession()
        s.state = state()
        s.link = .connected
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        s.accountsOverride = load
        return s
    }
    private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    private var ok: AccountsResponse {
        AccountsResponse(accounts: [AccountSnapshot(provider: "codex", accountId: "acct_1", plan: "plus", windows: [AccountWindow(id: "codex:primary", usedPercent: 42, windowMins: 300, resetAt: nil)], source: "codex_app_server", observedAt: 1, status: "ok")])
    }

    func testOkResponseIsVisibleOnTheSameConnection() async {
        let r = ok
        let s = session { _ in r }
        await s.loadAccounts()
        XCTAssertEqual(s.visibleAccounts?.accounts.first?.accountId, "acct_1")
        XCTAssertFalse(s.accountsUnsupported)
    }

    func testAPIRefreshReplacesOldSubscriptionWindowsAndPlan() async {
        var subscription = ok
        subscription.accounts[0].billingMode = "subscription"
        subscription.accounts[0].plan = "promax"
        let initial = subscription
        let api = AccountsResponse(accounts: [AccountSnapshot(provider: "codex", accountId: "unidentified", billingMode: "api", source: "codex_app_server", observedAt: 2, status: "ok")])
        let s = session { refresh in refresh ? api : initial }
        await s.loadAccounts()
        XCTAssertEqual(QuotaCopy.planTitle(s.visibleAccounts!.accounts[0]), "Pro 500")
        await s.loadAccounts(refresh: true)
        let a = QuotaCopy.displayAccount(s.visibleAccounts!.accounts[0], now: .now)
        XCTAssertEqual(QuotaCopy.planTitle(a), "API")
        XCTAssertNil(a.windows)
        XCTAssertEqual(a.observedAt, 2)
    }

    func testOldBridgeWithout404IsUnsupportedNotAnError() async {
        let s = session { _ in throw BridgeError.http(status: 404) }
        await s.loadAccounts()
        XCTAssertTrue(s.accountsUnsupported, "旧 Bridge：整个区块不显示")
        XCTAssertNil(s.accountsError)
        XCTAssertNil(s.visibleAccounts)
    }

    func testManualRefreshPassesTheFlagThrough() async {
        let flags = Flags()
        let r = ok
        let s = session { refresh in await flags.add(refresh); return r }
        await s.loadAccounts(refresh: true)
        await s.loadAccounts()
        let seen = await flags.values
        XCTAssertEqual(seen, [true, false])
    }

    /// F4：成功之后请求失败：旧快照保留，错误单独记录。
    func testFailureAfterSuccessKeepsOldSnapshot() async {
        let r = ok
        let s = session { refresh in if refresh { throw BridgeError.http(status: 502) }; return r }
        await s.loadAccounts()
        await s.loadAccounts(refresh: true)
        XCTAssertEqual(s.visibleAccounts, r, "旧快照原样保留")
        XCTAssertNotNil(s.accountsError)
    }

    func testLateAccountsFromAnotherConnectionIsDropped() async {
        let gate = AccountsGate()
        let r = ok
        let s = session { _ in await gate.wait(); return r }
        let pending = Task { await s.loadAccounts() }
        await gate.waitUntilEntered()
        s.state = state(bridge: "other") // 换了连接：在途结果作废
        await gate.open()
        await pending.value
        XCTAssertNil(s.visibleAccounts, "迟到的旧连接结果不写进另一台")
    }
}

private actor Flags {
    var values: [Bool] = []
    func add(_ v: Bool) { values.append(v) }
}

/// 把读取挂起到测试放行，并允许测试确认「已进入等待」。
private actor AccountsGate {
    private var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        for c in enteredWaiters { c.resume() }
        enteredWaiters = []
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func open() {
        opened = true
        for c in waiters { c.resume() }
        waiters = []
    }
}
