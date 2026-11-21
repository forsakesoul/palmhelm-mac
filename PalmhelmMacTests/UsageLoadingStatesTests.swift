import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// O1-368 追加：页面状态映射、各范围快照缓存（切换不清空、切回直接显示）、页头副标题文案。
@MainActor
final class UsageLoadingStatesTests: XCTestCase {
    func testPageStateMapsFactsToTheNineAndTheTwoNewStates() {
        // 有快照：永远是 ready（后台刷新、离线旧值、失败保留上次都在页头说明，不换卡位）
        XCTAssertEqual(UsagePageState.from(hasData: true, loading: true, settled: false, error: "x", connected: false), .ready)
        // 无快照：未连接优先
        XCTAssertEqual(UsagePageState.from(hasData: false, loading: false, settled: false, error: nil, connected: false), .disconnected)
        // 无快照 + 错误
        XCTAssertEqual(UsagePageState.from(hasData: false, loading: false, settled: true, error: "超时", connected: true), .failed("超时"))
        // 加载中：请求在途，或还没有完成过本范围
        XCTAssertEqual(UsagePageState.from(hasData: false, loading: true, settled: false, error: nil, connected: true), .loading)
        XCTAssertEqual(UsagePageState.from(hasData: false, loading: false, settled: false, error: nil, connected: true), .loading, "尚未完成过：加载中，不是首次无数据")
        // 首次无数据：已完成一次请求，连接正常，但没有快照
        XCTAssertEqual(UsagePageState.from(hasData: false, loading: false, settled: true, error: nil, connected: true), .empty)
    }

    func testSubtitleReplacesTheDescriptionOnlyInItsOneLine() {
        let base = "这台 Mac 的本地记录"
        XCTAssertEqual(UsagePageState.loading.headline(defaultText: base, lastUpdated: nil, refreshing: false, offline: false, failure: nil), "正在加载用量…")
        XCTAssertEqual(UsagePageState.empty.headline(defaultText: base, lastUpdated: nil, refreshing: false, offline: false, failure: nil), "这个范围还没有用量记录")
        XCTAssertEqual(UsagePageState.ready.headline(defaultText: base, lastUpdated: "14:30", refreshing: true, offline: false, failure: nil), "正在刷新 · 上次 14:30", "静默刷新只在页头说明")
        XCTAssertEqual(UsagePageState.ready.headline(defaultText: base, lastUpdated: "14:30", refreshing: false, offline: true, failure: nil), "离线 · 显示 14:30 的上次数据")
        XCTAssertEqual(UsagePageState.ready.headline(defaultText: base, lastUpdated: "14:30", refreshing: false, offline: false, failure: "超时"), "更新失败 · 超时，下面是上次结果")
        XCTAssertEqual(UsagePageState.ready.headline(defaultText: base, lastUpdated: nil, refreshing: false, offline: false, failure: nil), base)
    }

    func testSwitchingRangesKeepsEachSnapshotAndShowsItWithoutAFetch() async throws {
        let s = MacSession()
        s.link = .connected
        s.usageOverride = { w in UsageShotFixture.usage(w, .normal) }
        _ = await s.loadUsage(.h24)
        XCTAssertEqual(s.visibleUsage?.window, UsageWindow.h24.rawValue)
        _ = await s.loadUsage(.d7)
        XCTAssertEqual(s.visibleUsage?.window, UsageWindow.d7.rawValue)
        // 切回今日：立即显示已有快照（不进加载态，也不等网络）
        s.showUsageWindow(.h24)
        XCTAssertEqual(s.visibleUsage?.window, UsageWindow.h24.rawValue, "切回已有范围：直接显示")
        // 没有缓存的范围：为 nil（卡内加载中），不沿用别的范围的数据
        s.showUsageWindow(.d30)
        XCTAssertNil(s.visibleUsage, "没有该范围的快照时不显示别的范围")
        XCTAssertEqual(s.usageSettledWindow, UsageWindow.d7.rawValue, "完成过的范围仍记录在案")
    }

    func testSnapshotSurvivesSwitchingWithinTheSameConnection() async throws {
        let s = MacSession()
        s.link = .connected
        s.usageOverride = { w in UsageShotFixture.usage(w, .normal) }
        _ = await s.loadUsage(.h24)
        XCTAssertNotNil(s.visibleUsage)
        s.stopStream()
        s.showUsageWindow(.h24) // 同一连接内切换仍可用缓存；换连接会整体清空（由 connectionId 决定）
        XCTAssertNotNil(s.visibleUsage)
    }
}
