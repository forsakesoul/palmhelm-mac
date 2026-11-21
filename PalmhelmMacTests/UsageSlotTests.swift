import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// #32 柱图：今日时段的状态（R1 时间语义 / R3 全零）、DST 当天的时段数、键盘步进与占位文案。纯逻辑，不依赖 UI。
final class UsageSlotTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    private let shMidnight = 1_792_771_200_000   // 2026-10-24 00:00 上海
    private let hour = 3_600_000

    /// buckets: (起点, 输入 token)；输入为 0 的桶也会被服务端返回（模拟「服务端补出的空桶」）。
    private func usage(tz: String = "Asia/Shanghai", generatedT: Int, buckets: [(Int, Int)], coverage: String? = nil) -> UsageResponse {
        let b = buckets.map { #"{"t":\#($0.0),"byModel":{"m":{"input":\#($0.1),"output":0,"cacheRead":0,"cacheWrite":0,"activity":1}}}"# }.joined(separator: ",")
        let cov = coverage.map { #","coverage":\#($0)"# } ?? ""
        return decode(#"{"window":"24h","timeZone":"\#(tz)","generatedT":\#(generatedT),"partial":false,"reasons":[],"quality":{},"bucketMs":3600000,"buckets":[\#(b)]\#(cov),"recent":{"today":{"from":"x","to":"x","byModel":{}},"d7":{"from":"x","to":"x","byModel":{}},"d30":{"from":"x","to":"x","byModel":{}}},"heatmap":{"days":[],"activity":[]},"prices":{},"agents":{"claude":{"candidates":0,"parsed":0,"complete":0},"codex":{"candidates":0,"parsed":0,"complete":0}}}"#)
    }
    private func window(from: String) -> UsageEstimateWindow {
        decode(#"{"from":"\#(from)","to":"\#(from)","rows":[],"totals":{"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"costUsd":null,"hasUnpriced":false,"partial":false,"priceStale":false}}"#)
    }
    private func coverage(refresh: String, lastSuccessT: Int?) -> String {
        let l = lastSuccessT.map { "\($0)" } ?? "null"
        return #"{"enumeration":"complete","filesTotal":3,"filesIndexed":3,"bytesTotal":10,"bytesIndexed":10,"percent":100,"updatedT":1,"backfilling":false,"rebuilding":false,"refresh":"\#(refresh)","lastSuccessT":\#(l)}"#
    }

    func testConfirmedUntilIsTheSingleSourceOfTruth() {
        let ok = usage(generatedT: 500, buckets: [])
        XCTAssertEqual(UsageModel.confirmedUntil(ok), 500, "有效快照：确认截止 = 生成时刻")
        let failed = usage(generatedT: 500, buckets: [], coverage: coverage(refresh: "failed", lastSuccessT: 300))
        XCTAssertEqual(UsageModel.confirmedUntil(failed), 300, "扫描失败：确认截止 = 最近一次成功")
        let unknown = usage(generatedT: 500, buckets: [], coverage: coverage(refresh: "failed", lastSuccessT: nil))
        XCTAssertNil(UsageModel.confirmedUntil(unknown), "缺失即未知")
    }

    func testShanghaiDayStatesAcrossNowAndConfirmation() {
        // 真实当前时间 10:30：0–9 点有正值桶；10 点是当前小时（还没有桶）；11 点起是还没到。
        let now = shMidnight + 10 * hour + hour / 2
        let u = usage(generatedT: now, buckets: (0..<10).map { (shMidnight + $0 * hour, 5) })
        let slots = UsageModel.todaySlots(u, window(from: "2026-10-24"), coversAll: true, now: now, confirmed: UsageModel.confirmedUntil(u))
        XCTAssertEqual(slots.count, 24)
        XCTAssertEqual(slots[0].state, .present)
        XCTAssertEqual(slots[9].state, .present)
        XCTAssertEqual(slots[10].state, .current)
        XCTAssertEqual(slots[11].state, .future)
        XCTAssertEqual(slots[10].key, String(shMidnight + 10 * hour), "键与 UsageChartData.key 同格式")
    }

    func testPastMissingHourIsConfirmedZeroOrGapOnlyInsideConfirmation() {
        let g = shMidnight + 12 * hour + hour / 2
        let buckets = (0..<10).map { (shMidnight + $0 * hour, 5) }
        let u = usage(generatedT: g, buckets: buckets)
        let covered = UsageModel.todaySlots(u, window(from: "2026-10-24"), coversAll: true, now: g, confirmed: UsageModel.confirmedUntil(u))
        XCTAssertEqual(covered[10].state, .zero, "10–11 点在确认截止之内：确认为零")
        XCTAssertEqual(covered[11].state, .zero)
        XCTAssertEqual(covered[12].state, .current)
        let partial = UsageModel.todaySlots(u, window(from: "2026-10-24"), coversAll: false, now: g, confirmed: UsageModel.confirmedUntil(u))
        XCTAssertEqual(partial[10].state, .gap, "响应没覆盖全部小时：覆盖不足，不能当成为零")
    }

    func testBeyondConfirmationIsUncoveredNotZero() {
        // 扫描失败：确认截止停在 10:00。now 12:30。10 点起的时段都没有被确认。
        let now = shMidnight + 12 * hour + hour / 2
        let u = usage(generatedT: now, buckets: (0..<10).map { (shMidnight + $0 * hour, 5) }, coverage: coverage(refresh: "failed", lastSuccessT: shMidnight + 10 * hour))
        let slots = UsageModel.todaySlots(u, window(from: "2026-10-24"), coversAll: true, now: now, confirmed: UsageModel.confirmedUntil(u))
        XCTAssertEqual(slots[9].state, .present)
        XCTAssertEqual(slots[10].state, .uncovered, "截止之后未确认：未覆盖，不是确认为零")
        XCTAssertEqual(slots[11].state, .uncovered)
    }

    func testServerZeroBucketBeyondConfirmationIsNotZero() {
        // 服务端补出了 11 点的空桶（0 token）；确认截止在 10:00：不能当成「确认为零」。
        let now = shMidnight + 12 * hour
        let u = usage(generatedT: now, buckets: [(shMidnight + 11 * hour, 0)], coverage: coverage(refresh: "failed", lastSuccessT: shMidnight + 10 * hour))
        let slots = UsageModel.todaySlots(u, window(from: "2026-10-24"), coversAll: true, now: now, confirmed: UsageModel.confirmedUntil(u))
        XCTAssertEqual(slots[11].state, .uncovered)
    }

    func testUnknownConfirmationMakesPastMissingUncovered() {
        let now = shMidnight + 12 * hour
        let u = usage(generatedT: now, buckets: [], coverage: coverage(refresh: "failed", lastSuccessT: nil))
        let slots = UsageModel.todaySlots(u, window(from: "2026-10-24"), coversAll: true, now: now, confirmed: nil)
        XCTAssertEqual(slots[3].state, .uncovered, "确认截止未知：过去的空时段都是未覆盖")
    }

    func testAllZeroKeepsTheSlotDomainAndInteraction() {
        // 全零（已确认）：时段域完整，未来仍是还没到，现在仍是当前小时；零值不是 present。
        let now = shMidnight + 9 * hour + hour / 2
        let u = usage(generatedT: now, buckets: (0..<10).map { (shMidnight + $0 * hour, 0) })
        let slots = UsageModel.todaySlots(u, window(from: "2026-10-24"), coversAll: true, now: now, confirmed: UsageModel.confirmedUntil(u))
        XCTAssertEqual(slots.count, 24, "全零时段域不缩小")
        XCTAssertEqual(slots[2].state, .zero)
        XCTAssertEqual(slots[9].state, .current)
        XCTAssertEqual(slots[10].state, .future)
    }

    func testDaylightSavingDayHasTwentyThreeSlotsAndHoursAreAbsolute() {
        // 纽约 2026-03-08（DST 起始日，只有 23 小时）：00:00 EST = 05:00Z。
        let ny = 1_772_946_000_000
        let u = usage(tz: "America/New_York", generatedT: ny + 5 * hour, buckets: [])
        let slots = UsageModel.todaySlots(u, window(from: "2026-03-08"), coversAll: true, now: ny + 5 * hour, confirmed: UsageModel.confirmedUntil(u))
        XCTAssertEqual(slots.count, 23, "DST 起始日 23 个小时")
        XCTAssertEqual(slots.last?.end, ny + 23 * hour, "最后一个时段终点为次日 0 点（绝对时间）")
    }

    func testKeyboardStepCoversPlaceholderSlots() {
        let axis = ["1", "2", "3"].map { ChartCard.AxisItem(key: $0, start: Date(timeIntervalSince1970: 0)) }
        XCTAssertEqual(ChartCard.stepKey(axis, "2", +1), "3")
        XCTAssertEqual(ChartCard.stepKey(axis, "3", +1), "3", "右端不回绕")
        XCTAssertEqual(ChartCard.stepKey(axis, nil, +1), "1")
        XCTAssertEqual(ChartCard.stepKey(axis, nil, -1), "3")
    }

    func testPlaceholderTextsAreSeparate() {
        func slot(_ st: UsageModel.SlotState) -> UsageModel.Slot { UsageModel.Slot(key: "k", start: 0, end: 1, state: st) }
        XCTAssertEqual(ChartCard.slotText(slot(.future)), "还没到")
        XCTAssertEqual(ChartCard.slotText(slot(.gap)), "数据没覆盖到")
        XCTAssertEqual(ChartCard.slotText(slot(.zero)), UsageModel.Tip.emptyText)
        XCTAssertTrue(ChartCard.slotText(slot(.uncovered)).hasPrefix("未覆盖"))
    }

    /// S1：朗读的事实包含价格不确定、未报价、价格过期、更新失败与确认截止。
    func testDataStatusFactsCoverAllUncertaintiesForAccessibility() {
        let u = usage(generatedT: 500, buckets: [])
        let t: UsageEstimateTotals = decode(#"{"tokens":{"input":1,"output":0,"cacheRead":0,"cacheWrite":0},"costUsd":null,"hasUnpriced":true,"partial":false,"priceStale":true,"ttlUnknownTokens":5}"#)
        let facts = UsageModel.dataStatusFacts(u, totals: t, offline: "离线 · 上次数据", failure: "更新失败 · 超时，下面是上次结果")
        XCTAssertTrue(facts.contains("价格有不确定部分"))
        XCTAssertTrue(facts.contains("有未报价"))
        XCTAssertTrue(facts.contains("价格可能过期"))
        XCTAssertTrue(facts.contains("更新失败 · 超时，下面是上次结果"))
        XCTAssertTrue(facts.contains { $0.hasPrefix("确认截止") })
    }

    /// 贯通（R1a）：服务端补出的 0 桶（15 点）+ 选中 + Audio Graph descriptor。
    /// 确认截止 14:30（扫描失败），真实时间 16:30：15 点是 uncovered，即使 raw bar 存在也不能显示「本次记录无用量」，也不能进入 Audio Graph。
    func testServerZeroBucketSelectionAndAudioAgreeWithSlotState() {
        let now = shMidnight + 16 * hour + hour / 2
        let confirmed = shMidnight + 14 * hour + hour / 2
        let cov = #"{"enumeration":"complete","filesTotal":3,"filesIndexed":3,"bytesTotal":10,"bytesIndexed":10,"percent":100,"updatedT":1,"backfilling":false,"rebuilding":false,"refresh":"failed","lastSuccessT":\#(confirmed)}"#
        let u = usage(generatedT: now, buckets: (0..<15).map { (shMidnight + $0 * hour, 5) } + [(shMidnight + 15 * hour, 0)], coverage: cov)
        let w = window(from: "2026-10-24")
        let slots = UsageModel.todaySlots(u, w, coversAll: true, now: now, confirmed: UsageModel.confirmedUntil(u))
        let data = UsageModel.chartData(u, w, .today)
        let slot15 = slots[15]
        let bar15 = data.bar(key: slot15.key)
        XCTAssertEqual(slot15.state, .uncovered, "确认截止 14:30，15 点未确认")
        XCTAssertNotNil(bar15, "服务端补出的 0 桶确实在图表数据里")
        XCTAssertEqual(bar15?.total, 0)
        // 选中说明由 slot 状态决定：不是「本次记录无用量」，而是未覆盖。
        XCTAssertEqual(ChartCard.selectionTip(slot: slot15, bar: bar15), .slot)
        XCTAssertTrue(ChartCard.slotText(slot15).hasPrefix("未覆盖"))
        XCTAssertNotEqual(ChartCard.slotText(slot15), UsageModel.Tip.emptyText)
        // 确认的正值时段仍用柱子的浮层。
        XCTAssertEqual(ChartCard.selectionTip(slot: slots[3], bar: data.bar(key: slots[3].key)), .bar)
        // Audio Graph：只允许已观测的正值时段；15 点的 0 桶不进入数据点。
        let presentKeys = Set(slots.filter { $0.state == .present }.map(\.key))
        let parts = UsageAudioGraph.parts(data, keys: presentKeys)
        XCTAssertEqual(parts.x.categoryOrder.count, 15, "0–14 点（正值）进入 Audio Graph")
        XCTAssertEqual(parts.series.first?.dataPoints.count, 15)
        // 无 keys（近 7 / 30 天）保持全部桶。
        XCTAssertEqual(UsageAudioGraph.parts(data).series.first?.dataPoints.count, data.bars.count)
    }

    /// Audio Graph（A1-125）：已确认的真零桶保留，正值保留；mixed [0, 正值, 0] 三个时段都进入数据点。
    func testAudioGraphKeepsConfirmedZerosAndPositivesMixed() {
        let now = shMidnight + 16 * hour + hour / 2
        let u = usage(generatedT: now, buckets: [(shMidnight + 9 * hour, 0), (shMidnight + 10 * hour, 5), (shMidnight + 11 * hour, 0)])
        let w = window(from: "2026-10-24")
        let slots = UsageModel.todaySlots(u, w, coversAll: true, now: now, confirmed: UsageModel.confirmedUntil(u))
        XCTAssertEqual(slots[9].state, .zero, "确认截止之内的 0 桶是确认为零")
        XCTAssertEqual(slots[10].state, .present)
        let data = UsageModel.chartData(u, w, .today)
        let keys = Set(slots.filter { $0.state == .present || $0.state == .zero }.map(\.key))
        let bars = data.bars.filter { keys.contains(UsageChartData.key($0)) }
        let parts = UsageAudioGraph.parts(data, keys: keys)
        for i in [9, 10, 11] {
            XCTAssertTrue(bars.contains { UsageChartData.key($0) == slots[i].key }, "\(i) 点进入 Audio Graph")
        }
        XCTAssertEqual(parts.x.categoryOrder, bars.map(\.title))
        XCTAssertEqual(parts.series.first?.dataPoints.count, bars.count)
        XCTAssertEqual(bars.map(\.total).filter { $0 > 0 }, [5], "正值时段保留原值")
        XCTAssertEqual(data.bar(key: slots[9].key)?.total, 0)
        XCTAssertEqual(data.bar(key: slots[11].key)?.total, 0)
    }

    /// 全零（已确认）：Audio Graph 仍保留零点，不因为全零而变成空图。
    func testAudioGraphKeepsAllConfirmedZeros() {
        let now = shMidnight + 16 * hour + hour / 2
        let u = usage(generatedT: now, buckets: [(shMidnight + 9 * hour, 0), (shMidnight + 10 * hour, 0), (shMidnight + 11 * hour, 0)])
        let w = window(from: "2026-10-24")
        let slots = UsageModel.todaySlots(u, w, coversAll: true, now: now, confirmed: UsageModel.confirmedUntil(u))
        let data = UsageModel.chartData(u, w, .today)
        let keys = Set(slots.filter { $0.state == .present || $0.state == .zero }.map(\.key))
        let bars = data.bars.filter { keys.contains(UsageChartData.key($0)) }
        let parts = UsageAudioGraph.parts(data, keys: keys)
        for i in [9, 10, 11] {
            XCTAssertTrue(bars.contains { UsageChartData.key($0) == slots[i].key }, "\(i) 零点进入 Audio Graph")
        }
        XCTAssertEqual(parts.series.first?.dataPoints.count, bars.count)
        XCTAssertTrue(bars.allSatisfy { $0.total == 0 }, "全零时段的数值都是 0")
        XCTAssertFalse(bars.isEmpty)
    }
}
