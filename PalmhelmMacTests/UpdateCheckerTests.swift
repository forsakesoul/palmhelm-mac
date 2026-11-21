import XCTest
@testable import PalmhelmMac
import PalmhelmKit

/// #115：纯逻辑测试，不连网（数据源是假的）。
final class UpdateReleaseParsingTests: XCTestCase {
    private func make(_ tag: String, url: String? = "https://github.com/forsakesoul/palmhelm/releases/tag/v1.0-150", draft: Bool = false, pre: Bool = false) -> UpdateRelease? {
        UpdateRelease(tag: tag, htmlURL: url, draft: draft, prerelease: pre)
    }

    func testParsesVersionAndBuild() throws {
        let r = try XCTUnwrap(make("v1.0-150"))
        XCTAssertEqual(r.version, "1.0"); XCTAssertEqual(r.build, 150); XCTAssertEqual(r.title, "1.0 (150)")
        XCTAssertEqual(try XCTUnwrap(make("v2.1.3-9")).build, 9)
    }

    func testRejectsMalformedDraftAndPrerelease() {
        for t in ["1.0-150", "v1.0", "v1.0-", "v1.0-abc", "v1.0-150-rc1", "vx-1", "latest", "", "v1.0-99999999999"] { XCTAssertNil(make(t), t) }
        XCTAssertNil(make("v1.0-150", draft: true))
        XCTAssertNil(make("v1.0-150", pre: true))
    }

    /// “更新内容”按 App 内选定的语言：简体中文 → 中文页，其余 → 英文页。
    func testChangelogPageFollowsTheAppLanguage() {
        let base = "https://github.com/forsakesoul/palmhelm/blob/main/"
        KitL10n.$locale.withValue(Locale(identifier: "zh-Hans")) { XCTAssertEqual(UpdateRelease.changelogURL.absoluteString, base + "CHANGELOG.zh-CN.md") }
        KitL10n.$locale.withValue(Locale(identifier: "en")) { XCTAssertEqual(UpdateRelease.changelogURL.absoluteString, base + "CHANGELOG.md") }
    }

    func testOnlyTrustsRepoReleaseLinks() throws {
        XCTAssertEqual(try XCTUnwrap(make("v1.0-150")).releaseURL.absoluteString, "https://github.com/forsakesoul/palmhelm/releases/tag/v1.0-150")
        for bad: String? in [nil, "https://evil.example/x", "http://github.com/forsakesoul/palmhelm/x", "https://github.com/forsakesoul/palmhelm-evil/x"] {
            XCTAssertEqual(try XCTUnwrap(make("v1.0-150", url: bad)).releaseURL.absoluteString, "https://github.com/forsakesoul/palmhelm/releases/tag/v1.0-150", "\(bad ?? "nil")")
        }
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private final class FakeSource: UpdateSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var result: Result<UpdateRelease?, Error> = .success(nil)
        var calls: Int { lock.withLock { _calls } }
        func latestRelease() async throws -> UpdateRelease? { try lock.withLock { _calls += 1; return try result.get() } }
    }
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000) }

    private func release(_ build: Int) -> UpdateRelease { UpdateRelease(tag: "v1.0-\(build)", htmlURL: nil, draft: false, prerelease: false)! }
    private var suites: [String] = []
    private func defaults() -> UserDefaults {
        let n = "PalmhelmUpdateTests-\(UUID().uuidString)"
        suites.append(n)
        return UserDefaults(suiteName: n)!
    }
    override func tearDown() { suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }; suites = [] }

    private func make(current: Int? = 149, network: Bool = true, source: FakeSource, defaults: UserDefaults? = nil, clock: Clock = Clock()) -> UpdateChecker {
        UpdateChecker(source: source, currentBuild: current, networkEnabled: network, defaults: defaults ?? self.defaults(), now: { clock.t })
    }

    func testNewerOlderEqual() async {
        let s = FakeSource()
        let c = make(source: s)
        s.result = .success(release(150)); await c.checkNow(); XCTAssertEqual(c.status, .available(release(150)))
        s.result = .success(release(149)); await c.checkNow(); XCTAssertEqual(c.status, .upToDate)
        s.result = .success(release(100)); await c.checkNow(); XCTAssertEqual(c.status, .upToDate)
        s.result = .success(nil); await c.checkNow(); XCTAssertEqual(c.status, .upToDate)
    }

    func testSkipRemembersBuildAndOnlyNewerReprompts() async {
        let s = FakeSource(), d = defaults()
        let c = make(source: s, defaults: d)
        s.result = .success(release(150)); await c.checkNow()
        XCTAssertEqual(c.banner, release(150))
        c.skip(); XCTAssertNil(c.banner)
        let c2 = make(source: s, defaults: d) // 重启后仍记得
        await c2.checkNow(); XCTAssertNil(c2.banner); XCTAssertEqual(c2.status, .available(release(150))) // 设置页仍可见
        s.result = .success(release(151)); await c2.checkNow(); XCTAssertEqual(c2.banner, release(151))
    }

    func testDismissLastsOnlyThisRun() async {
        let s = FakeSource(), d = defaults()
        s.result = .success(release(150))
        let c = make(source: s, defaults: d)
        await c.checkNow(); c.dismiss(); XCTAssertNil(c.banner)
        let c2 = make(source: s, defaults: d); await c2.checkNow(); XCTAssertEqual(c2.banner, release(150))
    }

    func testAutoCheckOffSendsNothingButManualStillWorks() async {
        let s = FakeSource(); s.result = .success(release(150))
        let d = defaults()
        let c = make(source: s, defaults: d)
        XCTAssertTrue(c.autoCheck) // 默认开
        c.autoCheck = false
        await c.checkIfDue(); XCTAssertEqual(s.calls, 0); XCTAssertEqual(c.status, .idle)
        XCTAssertFalse(make(source: s, defaults: d).autoCheck) // 持久化
        await c.checkNow(); XCTAssertEqual(s.calls, 1)
    }

    func testNonDistributionNeverRequests() async {
        let s = FakeSource(); s.result = .success(release(150))
        let c = make(network: false, source: s)
        await c.checkIfDue(); await c.checkNow(); await c.runLoop(startDelay: .milliseconds(1))
        XCTAssertEqual(s.calls, 0)
        let noBuild = make(current: nil, source: s)
        await noBuild.checkNow(); XCTAssertEqual(s.calls, 0)
    }

    func testThrottleIs24HoursAfterSuccess() async {
        let s = FakeSource(), clock = Clock()
        let c = make(source: s, clock: clock)
        await c.checkIfDue(); XCTAssertEqual(s.calls, 1)
        clock.t += 23 * 3600; await c.checkIfDue(); XCTAssertEqual(s.calls, 1)
        clock.t += 2 * 3600; await c.checkIfDue(); XCTAssertEqual(s.calls, 2)
    }

    func testAutoFailureIsSilentAndRetriesNextTick() async {
        let s = FakeSource(), clock = Clock()
        let c = make(source: s, clock: clock)
        s.result = .failure(URLError(.notConnectedToInternet))
        await c.checkIfDue(); XCTAssertEqual(c.status, .idle); XCTAssertNil(c.lastCheck)
        s.result = .success(release(150)); clock.t += 3600
        await c.checkIfDue(); XCTAssertEqual(s.calls, 2); XCTAssertEqual(c.status, .available(release(150)))
        s.result = .failure(URLError(.timedOut)); clock.t += 25 * 3600
        await c.checkIfDue(); XCTAssertEqual(c.status, .available(release(150))) // 失败不抹掉已知的新版
    }

    func testManualFailureIsReported() async {
        let s = FakeSource(); s.result = .failure(URLError(.badServerResponse))
        let c = make(source: s)
        await c.checkNow(); XCTAssertEqual(c.status, .failed)
    }
}
