import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// #32 近 30 天能力发现（O1-244）：每连接一次、与今日快照隔离、400/404/缺字段 = 不支持、网络失败保留判断、换连接重置。
@MainActor
final class UsageLast30dProbeTests: XCTestCase {
    nonisolated private static func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    private static func state(_ bridge: String) -> BridgeState {
        decode(#"{"bridge":{"id":"\#(bridge)"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#)
    }
    nonisolated private static func win(_ f: String, _ t: String) -> String {
        #"{"from":"\#(f)","to":"\#(t)","rows":[],"totals":{"tokens":{"input":1,"output":0,"cacheRead":0,"cacheWrite":0},"costUsd":null,"hasUnpriced":false,"partial":false,"priceStale":false}}"#
    }
    /// 有 last30d 的估价（windows.last30d 非 nil）或旧版（没有 last30d 键）。
    nonisolated private static func usage(window: String, withLast30d: Bool) -> UsageResponse {
        let l30 = withLast30d ? #","last30d":\#(Self.win("2026-09-25", "2026-10-24"))"# : ""
        let est = #"{"version":1,"windows":{"today":\#(Self.win("2026-10-24", "2026-10-24")),"last7d":\#(Self.win("2026-10-18", "2026-10-24"))\#(l30)},"pricing":{"source":"models.dev","origin":"downloaded","freshness":"current","versionHash":"abcdef123456","asOfT":1761270000000,"lastValidatedT":1761273600000,"lastCheckT":null,"autoUpdate":true,"updatePolicy":"startup_if_older_than_3d"},"sources":[],"truncated":[]}"#
        return decode(#"{"window":"\#(window)","timeZone":"Asia/Shanghai","generatedT":1761300000000,"partial":false,"reasons":[],"quality":{},"bucketMs":3600000,"buckets":[],"recent":{"today":{"from":"2026-10-24","to":"2026-10-24","byModel":{}},"d7":{"from":"2026-10-18","to":"2026-10-24","byModel":{}},"d30":{"from":"2026-09-25","to":"2026-10-24","byModel":{}}},"heatmap":{"days":[],"activity":[]},"prices":{},"agents":{"claude":{"candidates":0,"parsed":0,"complete":0},"codex":{"candidates":0,"parsed":0,"complete":0}},"estimate":\#(est)}"#)
    }
    private static func session(bridge: String = "b1", _ probe: @escaping @Sendable (UsageWindow) async throws -> UsageResponse) -> MacSession {
        let s = MacSession()
        s.state = Self.state(bridge)
        s.link = .connected
        s.usageOverride = probe
        return s
    }

    func testSupportedWhenResponseCarriesLast30d() async {
        let s = Self.session { _ in Self.usage(window: "30d", withLast30d: true) }
        await s.probeLast30d()
        XCTAssertTrue(s.last30dAvailable)
        XCTAssertEqual(UsageSegment.visible(last30dAvailable: s.last30dAvailable).last, .last30d)
    }

    func testProbeDoesNotTouchTodaySnapshot() async {
        let s = Self.session { _ in Self.usage(window: "30d", withLast30d: true) }
        await s.probeLast30d()
        XCTAssertNil(s.visibleUsage, "探测与今日快照隔离")
        XCTAssertNil(s.usageError)
    }

    func testOldBridgeWithoutLast30dKeyIsUnsupported() async {
        let s = Self.session { _ in Self.usage(window: "30d", withLast30d: false) }
        await s.probeLast30d()
        XCTAssertFalse(s.last30dAvailable)
        XCTAssertEqual(s.last30dCapability, .unsupported)
    }

    func testHttp400And404AndDecodingAreUnsupported() async {
        for error in [BridgeError.http(status: 400), .http(status: 404), .decoding] {
            let s = Self.session { _ in throw error }
            await s.probeLast30d()
            XCTAssertEqual(s.last30dCapability, .unsupported, "\(error)")
        }
    }

    func testNetworkFailureDoesNotMarkUnsupportedAndRetryWorks() async {
        let s = Self.session { _ in throw URLError(.notConnectedToInternet) }
        await s.probeLast30d()
        XCTAssertEqual(s.last30dCapability, .unknown, "断网不是不支持")
        XCTAssertFalse(s.last30dAvailable)
        s.usageOverride = { _ in Self.usage(window: "30d", withLast30d: true) }
        await s.probeLast30d()
        XCTAssertTrue(s.last30dAvailable, "恢复后再次探测得到 supported")
    }

    func testSwitchingBridgeResetsCapability() async {
        let s = Self.session(bridge: "b1") { _ in Self.usage(window: "30d", withLast30d: true) }
        await s.probeLast30d()
        XCTAssertTrue(s.last30dAvailable)
        s.state = Self.state("b2")
        XCTAssertFalse(s.last30dAvailable, "换 Mac 后第三档不成立，直到对新连接探测")
        XCTAssertEqual(UsageSegment.visible(last30dAvailable: s.last30dAvailable), [.today, .last7d])
    }

    /// 手动闸门：探测挂起直到 release，用来制造「迟到」的结果。
    actor Gate {
        private var open = false
        private(set) var entered = false
        func wait() async { entered = true; while !open { try? await Task.sleep(nanoseconds: 2_000_000) } }
        func release() { open = true }
        /// 等到探测确实进入闸门（即已经发起旧生命周期的请求）。
        func awaitEntered() async { while !entered { try? await Task.sleep(nanoseconds: 2_000_000) } }
    }

    func testSupportedDegradesWhenThirtyDayUsageReturns404AndSelectionFallsBack() async {
        let s = Self.session { _ in Self.usage(window: "30d", withLast30d: true) }
        await s.probeLast30d()
        XCTAssertTrue(s.last30dAvailable)
        s.usageOverride = { _ in throw BridgeError.http(status: 404) }
        _ = await s.loadUsage(.d30)
        XCTAssertFalse(s.last30dAvailable, "30 天请求 404：降级")
        XCTAssertEqual(s.last30dCapability, .unsupported)
        XCTAssertEqual(UsageSegment.visible(last30dAvailable: s.last30dAvailable), [.today, .last7d], "第三档消失，选中项由界面退回今日")
    }

    func testSuccessWithoutLast30dDegrades() async {
        let s = Self.session { _ in Self.usage(window: "30d", withLast30d: true) }
        await s.probeLast30d()
        s.usageOverride = { _ in Self.usage(window: "30d", withLast30d: false) }
        _ = await s.loadUsage(.d30)
        XCTAssertEqual(s.last30dCapability, .unsupported, "成功但缺 last30d：降级")
    }

    func testForgetThenSameBridgeIdDoesNotReuseCapability() async {
        let s = Self.session { _ in Self.usage(window: "30d", withLast30d: true) }
        await s.probeLast30d()
        XCTAssertTrue(s.last30dAvailable)
        s.forget()
        XCTAssertFalse(s.last30dAvailable, "忘记配对后立即不成立")
        // 重新配对到同一个 bridge id：生命周期已变，旧能力不得复用。
        s.state = Self.state("b1")
        s.link = .connected
        XCTAssertFalse(s.last30dAvailable, "同一个 id 重新配对：必须重新探测")
    }

    func testLateSuccessAfterForgetIsIgnored() async {
        let gate = Gate()
        let s = Self.session { _ in
            await gate.wait()
            return Self.usage(window: "30d", withLast30d: true)
        }
        let task = Task { await s.probeLast30d() }
        await gate.awaitEntered()
        s.forget()
        await gate.release()
        await task.value
        XCTAssertFalse(s.last30dAvailable, "迟到的成功在忘记配对之后被丢弃")
        XCTAssertEqual(s.last30dCapability, .unknown)
    }

    func testLateFailureAfterForgetIsIgnored() async {
        let gate = Gate()
        let s = Self.session { _ in
            await gate.wait()
            throw BridgeError.http(status: 404)
        }
        let task = Task { await s.probeLast30d() }
        await gate.awaitEntered()
        s.forget()
        await gate.release()
        await task.value
        XCTAssertEqual(s.last30dCapability, .unknown, "迟到的 404 不得把新生命周期降级")
    }

    /// 按调用顺序编号的计数器（用于让不同的调用得到不同的结果）。
    actor Counter {
        private var n = 0
        func next() -> Int { n += 1; return n }
    }

    /// A：旧 load(.d30) 挂起 → 新 load(.d30) 返回支持 → 旧 load 最后 404：能力必须仍是支持。
    func testOldThirtyDayLoadLateFailureCannotDowngradeNewerSuccess() async {
        let gate = Gate()
        let counter = Counter()
        let s = Self.session { _ in
            if await counter.next() == 1 {
                await gate.wait()
                throw BridgeError.http(status: 404)
            }
            return Self.usage(window: "30d", withLast30d: true)
        }
        let old = Task { await s.loadUsage(.d30) }
        await gate.awaitEntered()
        _ = await s.loadUsage(.d30)
        XCTAssertTrue(s.last30dAvailable, "新请求支持")
        await gate.release()
        _ = await old.value
        XCTAssertEqual(s.last30dCapability, .supported, "旧请求的 404 不得覆盖新请求的支持")
        XCTAssertTrue(s.last30dAvailable)
    }

    /// B：旧 probe 挂起 → 真实的 30 天请求 404 → 旧 probe 最后成功：能力必须仍是不支持。
    func testOldProbeLateSuccessCannotUpgradeNewerFailure() async {
        let gate = Gate()
        let counter = Counter()
        let s = Self.session { _ in
            if await counter.next() == 1 {
                await gate.wait()
                return Self.usage(window: "30d", withLast30d: true)
            }
            throw BridgeError.http(status: 404)
        }
        let probe = Task { await s.probeLast30d() }
        await gate.awaitEntered()
        _ = await s.loadUsage(.d30)
        XCTAssertEqual(s.last30dCapability, .unsupported, "真实请求 404 确认不支持")
        await gate.release()
        await probe.value
        XCTAssertEqual(s.last30dCapability, .unsupported, "旧 probe 的迟到成功不得把能力升级回支持")
        XCTAssertFalse(s.last30dAvailable)
    }

    /// 网络失败保留原判断：支持之后，30 天请求遇到网络错误，能力仍是支持。
    func testNetworkFailureOnThirtyDayRequestKeepsSupport() async {
        let s = Self.session { _ in Self.usage(window: "30d", withLast30d: true) }
        await s.probeLast30d()
        XCTAssertTrue(s.last30dAvailable)
        s.usageOverride = { _ in throw URLError(.timedOut) }
        _ = await s.loadUsage(.d30)
        XCTAssertTrue(s.last30dAvailable, "网络失败保留原判断")
    }
}
