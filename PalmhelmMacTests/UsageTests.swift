import XCTest
import PalmhelmKit
@testable import PalmhelmMac

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }

private let tokens0 = #"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}"#

private func row(_ model: String, source: String = "claude", provider: String? = "anthropic", ref: String? = nil, input: Int = 100, cost: Double? = 1.5, unpriced: Int = 0, reasons: [String] = []) -> String {
    let p = provider.map { #""provider":"\#($0)","# } ?? ""
    let r = ref.map { #""referenceProvider":"\#($0)","# } ?? ""
    let c = cost.map { "\($0)" } ?? "null"
    let rs = reasons.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"source":"\#(source)","model":"\#(model)",\#(p)\#(r)"tokens":{"input":\#(input),"output":10,"cacheRead":5,"cacheWrite":1},"costUsd":\#(c),"unpricedTokens":\#(unpriced),"reasons":[\#(rs)],"usedBands":[]}"#
}

private func estimateJSON(version: Int = 1, todayRows: [String] = [], todayCost: String = "1.5", hasUnpriced: Bool = false, partial: Bool = false, stale: Bool = false, truncated: [String] = [], autoUpdate: Bool = true, from: String = "2026-10-24", sources: String = #"[{"source":"claude","status":"collected","reasons":[]},{"source":"opencode","status":"partial","reasons":["sqlite_not_opened"]}]"#) -> String {
    func win(_ rows: [String], _ f: String, _ t: String) -> String {
        #"{"from":"\#(f)","to":"\#(t)","rows":[\#(rows.joined(separator: ","))],"totals":{"tokens":{"input":100,"output":10,"cacheRead":5,"cacheWrite":1},"costUsd":\#(todayCost),"hasUnpriced":\#(hasUnpriced),"partial":\#(partial),"priceStale":\#(stale)}}"#
    }
    let tr = truncated.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"version":\#(version),"windows":{"today":\#(win(todayRows, from, from)),"last7d":\#(win([], "2026-10-18", "2026-10-24"))},"pricing":{"source":"models.dev","origin":"downloaded","freshness":"current","versionHash":"abcdef123456","asOfT":1761270000000,"lastValidatedT":1761273600000,"lastCheckT":null,"autoUpdate":\#(autoUpdate),"updatePolicy":"startup_if_older_than_3d"},"sources":\#(sources),"truncated":[\#(tr)]}"#
}

private func usageJSON(window: String = "24h", tz: String = "Asia/Shanghai", buckets: String = "[]", bucketMs: Int = 3_600_000, estimate: String? = nil, generatedT: Int = 1_761_300_000_000) -> String {
    let est = estimate.map { #","estimate":\#($0)"# } ?? ""
    let r = #"{"from":"2026-10-24","to":"2026-10-24","byModel":{}}"#
    return #"""
    {"window":"\#(window)","timeZone":"\#(tz)","generatedT":\#(generatedT),"partial":false,"reasons":[],"quality":{},"bucketMs":\#(bucketMs),"buckets":\#(buckets),
     "recent":{"today":\#(r),"d7":\#(r),"d30":\#(r)},"heatmap":{"days":[],"activity":[]},"prices":{},
     "agents":{"claude":{"candidates":0,"parsed":0,"complete":0},"codex":{"candidates":0,"parsed":0,"complete":0}}\#(est)}
    """#
}

private func usage(_ window: String = "24h", estimate: String? = nil, buckets: String = "[]", tz: String = "Asia/Shanghai", bucketMs: Int = 3_600_000) -> UsageResponse {
    decode(usageJSON(window: window, tz: tz, buckets: buckets, bucketMs: bucketMs, estimate: estimate))
}

private func bucket(_ t: Int, date: String? = nil, input: Int = 10) -> String {
    let d = date.map { #""date":"\#($0)","# } ?? ""
    return #"{"t":\#(t),\#(d)"byModel":{"m":{"input":\#(input),"output":0,"cacheRead":0,"cacheWrite":0,"activity":1}}}"#
}

// 上海时区 2026-10-24 00:00 = UTC 2026-10-23 16:00
private let shMidnight = 1_792_771_200_000
private let hour = 3_600_000

/// 用量页纯逻辑（D1 / D2）。
final class UsageModelTests: XCTestCase {
    func testModeLegacyUnsupportedAndV1() {
        XCTAssertEqual(UsageModel.mode(usage()), .legacy, "没有 estimate = 旧版 Bridge")
        XCTAssertEqual(UsageModel.mode(usage(estimate: estimateJSON(version: 2))), .unsupported, "version≠1 暂不支持，不静默套用")
        if case .v1 = UsageModel.mode(usage(estimate: estimateJSON())) {} else { XCTFail("v1") }
    }

    func testLegacyCostShowsDashWhenNothingPriceable() {
        XCTAssertEqual(UsageModel.legacyCost((usd: 0, hasUnpriced: true)), "—", "全不可估是「—」不是 ≈$0")
        XCTAssertEqual(UsageModel.legacyCost((usd: 1.234, hasUnpriced: true)), "≈$1.23 · 含未报价部分")
        XCTAssertEqual(UsageModel.legacyCost((usd: 0, hasUnpriced: false)), "≈$0.00")
    }

    func testTodayChartPicksOnlyTodayHourBucketsInResponseTimeZone() {
        // 24h 响应：昨天 23 点 + 今天 0、1 点；今日图只取落在 today.from–to（上海日历日）里的桶
        let b = "[" + [bucket(shMidnight - hour), bucket(shMidnight), bucket(shMidnight + hour)].joined(separator: ",") + "]"
        let u = usage(estimate: estimateJSON(), buckets: b)
        guard case .v1(let e) = UsageModel.mode(u) else { return XCTFail() }
        let c = UsageModel.chart(u, .today, window: e.windows.today)
        XCTAssertEqual(c.bars.map(\.t), [shMidnight, shMidnight + hour])
        XCTAssertTrue(c.coversAll)
        XCTAssertFalse(c.daily)
    }

    func testTodayChartFlagsIncompleteCoverageWithoutFabricatingZeros() {
        // 第一根桶晚于今日 0 点：覆盖不全，不补 0
        let late = "[" + [bucket(shMidnight + 3 * hour), bucket(shMidnight + 4 * hour)].joined(separator: ",") + "]"
        let u = usage(estimate: estimateJSON(), buckets: late)
        guard case .v1(let e) = UsageModel.mode(u) else { return XCTFail() }
        let c = UsageModel.chart(u, .today, window: e.windows.today)
        XCTAssertFalse(c.coversAll)
        XCTAssertEqual(c.bars.count, 2, "只画有数据的桶")
        // 中间缺一个小时：同样标注
        let gap = "[" + [bucket(shMidnight), bucket(shMidnight + 2 * hour)].joined(separator: ",") + "]"
        let u2 = usage(estimate: estimateJSON(), buckets: gap)
        guard case .v1(let e2) = UsageModel.mode(u2) else { return XCTFail() }
        XCTAssertFalse(UsageModel.chart(u2, .today, window: e2.windows.today).coversAll)
    }

    func testBucketsAreIdentifiedByEpochSoRepeatedFallBackHoursStaySeparate() {
        let b = "[" + [bucket(shMidnight), bucket(shMidnight + hour)].joined(separator: ",") + "]"
        let u = usage(estimate: estimateJSON(), buckets: b)
        guard case .v1(let e) = UsageModel.mode(u) else { return XCTFail() }
        let c = UsageModel.chart(u, .today, window: e.windows.today)
        XCTAssertEqual(Set(c.bars.map(\.id)).count, 2)
    }

    func testLast7dChartUsesDailyBucketsByDate() {
        let day = 24 * hour
        let b = "[" + (0..<9).map { bucket(shMidnight - 8 * day + $0 * day, date: ["2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24"][$0]) }.joined(separator: ",") + "]"
        let u = usage("7d", estimate: estimateJSON(), buckets: b, bucketMs: day)
        guard case .v1(let e) = UsageModel.mode(u) else { return XCTFail() }
        let c = UsageModel.chart(u, .last7d, window: e.windows.last7d) // last7d: 2026-10-18 … 10-24
        XCTAssertEqual(c.bars.count, 7)
        XCTAssertTrue(c.daily)
    }

    func testFallBackDayInNewYorkKeepsBothRepeatedHoursAsSeparateBars() {
        // 2026-11-01 美东回拨日：本地 0 点 = 04:00Z，当天 25 个小时桶（01:00 出现两次），都落在这一天
        let start = 1793505600000
        let b = "[" + (0..<25).map { bucket(start + $0 * hour) }.joined(separator: ",") + "]"
        let u = usage(estimate: estimateJSON(from: "2026-11-01"), buckets: b, tz: "America/New_York")
        guard case .v1(let e) = UsageModel.mode(u) else { return XCTFail() }
        let c = UsageModel.chart(u, .today, window: e.windows.today)
        XCTAssertEqual(c.bars.count, 25)
        XCTAssertEqual(Set(c.bars.map(\.id)).count, 25, "重复的小时按 epoch 区分，不并成一根")
        XCTAssertTrue(c.coversAll)
        // 同一份桶按上海时区看，日期归属不同：按响应 timeZone 取日历日，不用设备时区
        let u2 = usage(estimate: estimateJSON(from: "2026-11-01"), buckets: b, tz: "Asia/Shanghai")
        guard case .v1(let e2) = UsageModel.mode(u2) else { return XCTFail() }
        XCTAssertNotEqual(UsageModel.chart(u2, .today, window: e2.windows.today).bars.count, 25)
    }

    func testCompactTokensNeverUseScientificNotation() {
        XCTAssertEqual(UsageModel.tokens(150_000_000), "150M")
        XCTAssertEqual(UsageModel.tokens(50_000_000), "50M")
        XCTAssertEqual(UsageModel.tokens(1_500_000), "1.5M")
        XCTAssertEqual(UsageModel.tokens(12_300), "12.3K")
        XCTAssertEqual(UsageModel.tokens(980), "980")
        XCTAssertEqual(UsageModel.tokens(0), "0")
        XCTAssertEqual(UsageModel.tokens(2_000_000_000), "2B")
        XCTAssertFalse(UsageModel.tokens(150_000_000).contains("E"))
    }

    func testHourStrideByBarCount() {
        XCTAssertEqual(UsageModel.hourStride(barCount: 6), 1)
        XCTAssertEqual(UsageModel.hourStride(barCount: 12), 2)
        XCTAssertEqual(UsageModel.hourStride(barCount: 24), 3)
    }

    // 时区：Bridge 在上海，机器在洛杉矶——归组、轴标签、时间行都按响应 timeZone，不看机器时区
    func testChartAndLabelsUseTheResponseTimeZoneNotTheMachines() {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = saved }
        let b = "[" + [bucket(shMidnight - hour), bucket(shMidnight), bucket(shMidnight + hour)].joined(separator: ",") + "]"
        let u = usage(estimate: estimateJSON(), buckets: b) // 响应 timeZone = Asia/Shanghai
        guard case .v1(let e) = UsageModel.mode(u) else { return XCTFail() }
        XCTAssertEqual(UsageModel.chart(u, .today, window: e.windows.today).bars.map(\.t), [shMidnight, shMidnight + hour], "按上海日历日归组")
        XCTAssertEqual(UsageModel.timeZone(u).identifier, "Asia/Shanghai")
        let sh = UsageModel.timeZone(u), la = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertTrue(UsageModel.axisLabel(shMidnight, daily: true, tz: sh).contains("24"), "同一时刻上海是 10/24")
        XCTAssertTrue(UsageModel.axisLabel(shMidnight, daily: true, tz: la).contains("23"), "洛杉矶是 10/23")
        XCTAssertNotEqual(UsageModel.axisLabel(shMidnight, daily: false, tz: sh), UsageModel.axisLabel(shMidnight, daily: false, tz: la), "小时标签随响应时区")
        XCTAssertEqual(UsageModel.calendar(sh).component(.hour, from: UsageModel.ms(shMidnight)), 0)
        XCTAssertEqual(UsageModel.calendar(la).component(.hour, from: UsageModel.ms(shMidnight)), 9)
        XCTAssertNotEqual(UsageModel.timesLine(generatedT: shMidnight, asOfT: nil, tz: sh), UsageModel.timesLine(generatedT: shMidnight, asOfT: nil, tz: la), "数据时间行也按响应时区")
    }

    func testZeroTokenRowsAreHiddenAndCounted() {
        let rows: [UsageEstimateRow] = decode("[" + [row("real"), row("<synthetic>", provider: nil, input: 0, cost: 0, reasons: ["model_unlisted"])].joined(separator: ",") + "]")
        // row() 的 output/cache 固定非 0；这里把 synthetic 行的全部 token 清零
        var zero = rows[1]; zero.tokens = decode(#"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}"#)
        let v = UsageModel.visibleRows([rows[0], zero])
        XCTAssertEqual(v.rows.map(\.model), ["real"])
        XCTAssertEqual(v.hidden, 1, "确有隐藏时表头才注明")
        XCTAssertEqual(UsageModel.visibleRows([rows[0]]).hidden, 0)
        XCTAssertTrue(UsageModel.visibleRows([zero]).rows.isEmpty)
    }

    // MARK: h11c 悬停浮层 / 堆叠 / 布局

    private func multiBucket(_ t: Int, _ models: [String: Int]) -> String {
        let m = models.sorted { $0.key < $1.key }.map { #""\#($0.key)":{"input":\#($0.value),"output":0,"cacheRead":0,"cacheWrite":0,"activity":1}"# }.joined(separator: ",")
        return #"{"t":\#(t),"byModel":{\#(m)}}"#
    }
    private func chartFixture() -> (UsageResponse, UsageChartData) {
        let b = "[" + [
            multiBucket(shMidnight, ["big": 600, "mid": 300, "small": 90, "tiny": 10]),            // 第 4 个模型 + other 都归「其他」
            multiBucket(shMidnight + hour, [:]),                                                    // 零总量
            multiBucket(shMidnight + 2 * hour, ["big": 100, "other": 50]),                          // Bridge 的 other 聚合项并入「其他」
        ].joined(separator: ",") + "]"
        let u = usage(estimate: estimateJSON(), buckets: b)
        guard case .v1(let e) = UsageModel.mode(u) else { fatalError() }
        return (u, UsageModel.chartData(u, e.windows.today, .today))
    }

    func testSeriesIsTopThreeNamedModelsAndOthersMergeIncludingBridgeOther() {
        let (_, d) = chartFixture()
        XCTAssertEqual(d.series, ["big", "mid", "small"], "整图前 3 个具名模型，other 聚合项不算")
        let tip0 = UsageModel.tip(d.bars[0], series: d.series)
        XCTAssertEqual(tip0.rows.map(\.name), ["big", "mid", "small", "其他"])
        XCTAssertEqual(tip0.rows.map(\.colorIndex), [0, 1, 2, nil])
        XCTAssertEqual(tip0.rows.map(\.percent).reduce(0, +), 100)
        XCTAssertEqual(tip0.totalText, "1K")
        let tip2 = UsageModel.tip(d.bars[2], series: d.series)
        XCTAssertEqual(tip2.rows.map(\.name), ["big", "其他"], "为 0 的行省略；Bridge other 只写「其他」")
        XCTAssertEqual(tip2.rows.last?.tokensText, "50")
    }

    func testZeroTotalBarTipSaysNoUsage() {
        let (_, d) = chartFixture()
        let t = UsageModel.tip(d.bars[1], series: d.series)
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(UsageModel.Tip.emptyText, "本次记录无用量")
        XCTAssertTrue(UsageModel.spokenSummary(d.bars[1], series: d.series).contains("本次记录无用量"))
        XCTAssertTrue(t.rows.isEmpty)
    }

    func testTipTitleIsInResponseTimeZoneAndStackSumsToTotal() {
        let (_, d) = chartFixture()
        XCTAssertEqual(d.bars[0].title, "00:00–01:00", "按 Bridge 上海时区的小时标题")
        for bar in d.bars {
            let segs = UsageModel.stack(bar)
            XCTAssertEqual(Int(segs.last?.end ?? 0), bar.total, "各段累加恰为柱总量")
            XCTAssertEqual(segs.first?.start ?? 0, 0)
        }
        let spoken = UsageModel.spokenSummary(d.bars[0], series: d.series)
        XCTAssertTrue(spoken.contains("00:00–01:00") && spoken.contains("big") && spoken.contains("60%"))
    }

    func testSelectionMapsHalfOpenIntervalsAndKeyboardStepsBarByBar() {
        let (_, d) = chartFixture()
        let t0 = Date(timeIntervalSince1970: Double(shMidnight) / 1000)
        XCTAssertEqual(d.bar(at: t0)?.id, shMidnight)
        XCTAssertEqual(d.bar(at: t0.addingTimeInterval(3_599.9))?.id, shMidnight)
        XCTAssertEqual(d.bar(at: t0.addingTimeInterval(3_600))?.id, shMidnight + hour, "半开区间：下一根从 end 起")
        XCTAssertNil(d.bar(at: t0.addingTimeInterval(-1)))
        XCTAssertEqual(UsageModel.step(d, from: nil, by: -1), d.bars.last?.id, "未选中时左键取最后一根")
        XCTAssertEqual(UsageModel.step(d, from: nil, by: 1), d.bars.first?.id)
        XCTAssertEqual(UsageModel.step(d, from: shMidnight, by: 1), shMidnight + hour)
        XCTAssertEqual(UsageModel.step(d, from: shMidnight, by: -1), shMidnight, "到头停住")
        XCTAssertEqual(UsageModel.step(d, from: shMidnight + 2 * hour, by: 1), shMidnight + 2 * hour)
        XCTAssertNil(UsageModel.step(UsageChartData.make(usage(estimate: estimateJSON()), from: "2026-10-24", to: "2026-10-24", daily: false), from: nil, by: 1))
    }

    // 实机发现：柱子画到 0 线以下。坐标系必须是「柱底 = 0、domain 下界 = 0」，与浮层预留方式无关
    func testBarsStartExactlyAtZeroAndYDomainStartsAtZero() {
        let (_, d) = chartFixture()
        for bar in d.bars where bar.total > 0 {
            let segs = UsageModel.stack(bar)
            XCTAssertEqual(segs.map(\.start).min(), 0, "每根柱的最低 yStart 是 0")
            XCTAssertEqual(segs.first?.start, 0)
            for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertEqual(a.end, b.start, "各段首尾相接") }
        }
        let dom = UsageModel.yDomain(d)
        XCTAssertEqual(dom.lowerBound, 0, "domain 下界为 0")
        XCTAssertEqual(dom.upperBound, Double(d.bars.map(\.total).max()!) * 1.08, accuracy: 0.001, "上界 = 最高柱 × 1.08，最高柱不贴顶")
        XCTAssertGreaterThan(dom.upperBound, Double(d.bars.map(\.total).max()!))
        let empty = UsageChartData.make(usage(estimate: estimateJSON()), from: "2026-10-24", to: "2026-10-24", daily: false)
        XCTAssertEqual(UsageModel.yDomain(empty), 0...1, "无数据时 domain 仍是 0…1，不出现负区间")
    }

    // O1-127：首 / 末是零桶（没有 mark）时仍可选中、有浮层文本；x 域锚定全部桶
    func testLeadingAndTrailingZeroBucketsAreReachable() {
        let b = "[" + [multiBucket(shMidnight, [:]), multiBucket(shMidnight + hour, ["big": 100]), multiBucket(shMidnight + 2 * hour, [:])].joined(separator: ",") + "]"
        let u = usage(estimate: estimateJSON(), buckets: b)
        guard case .v1(let e) = UsageModel.mode(u) else { return XCTFail() }
        let d = UsageModel.chartData(u, e.windows.today, .today)
        XCTAssertEqual(d.bars.count, 3)
        // 分类 x 轴：每根柱子有唯一键，键能映射回零桶（悬停 / 键盘选中据此找到它）
        XCTAssertEqual(Set(d.bars.map { UsageChartData.key($0) }).count, 3)
        for i in [0, 2] {
            let mid = d.bars[i].start.addingTimeInterval(1800)
            XCTAssertEqual(d.bar(at: mid)?.id, d.bars[i].id, "零桶可被 bar(at:) 映射")
            XCTAssertEqual(d.bar(key: UsageChartData.key(d.bars[i]))?.id, d.bars[i].id, "零桶可被键映射")
            let t = UsageModel.tip(d.bars[i], series: d.series)
            XCTAssertTrue(t.isEmpty)
            XCTAssertEqual(UsageModel.Tip.emptyText, "本次记录无用量")
        }
        XCTAssertEqual(UsageModel.step(d, from: d.bars[1].id, by: -1), d.bars[0].id, "键盘能停在首零桶")
        XCTAssertEqual(UsageModel.step(d, from: d.bars[1].id, by: 1), d.bars[2].id, "键盘能停在末零桶")
        XCTAssertTrue(UsageModel.isLabeledBar(d, d.bars[0], daily: false), "首根总是标注")
        XCTAssertEqual(UsageChartData.barRatio < 1, true, "柱宽小于类目宽，首尾柱子不会越出绘图区")
    }

    // A1-061 R1：同一 Chart 切范围 / 响应刷新后，Audio Graph 描述器随新数据改写
    func testAudioGraphDescriptorIsRewrittenByUpdate() {
        let (_, old) = chartFixture() // 3 根桶
        let b = "[" + [multiBucket(shMidnight, ["a": 10]), multiBucket(shMidnight + hour, ["a": 30])].joined(separator: ",") + "]"
        let u2 = usage(estimate: estimateJSON(), buckets: b)
        guard case .v1(let e2) = UsageModel.mode(u2) else { return XCTFail() }
        let new = UsageModel.chartData(u2, e2.windows.today, .today)
        XCTAssertNotEqual(old.bars.count, new.bars.count)
        let descriptor = UsageAudioGraph(data: old).makeChartDescriptor()
        let oldPoints: [AXDataPoint] = descriptor.series.first.flatMap { $0.dataPoints } ?? []
        XCTAssertEqual(oldPoints.count, 3)
        XCTAssertEqual(descriptor.summary, "共 3 个时段，各时段 token 总量")
        UsageAudioGraph(data: new).updateChartDescriptor(descriptor) // 同一个描述器对象被改写
        XCTAssertEqual(descriptor.title, "用量柱图")
        XCTAssertEqual(descriptor.summary, "共 2 个时段，各时段 token 总量")
        XCTAssertEqual((descriptor.xAxis as? AXCategoricalDataAxisDescriptor)?.categoryOrder, new.bars.map(\.title))
        let newPoints: [AXDataPoint] = descriptor.series.first.flatMap { $0.dataPoints } ?? []
        XCTAssertEqual(newPoints.count, 2)
        let ys = newPoints.compactMap { $0.yValue }.map { Double(String(describing: $0)) }
        XCTAssertEqual(ys, [10.0, 30.0])
        let upper: Double = descriptor.yAxis?.range.upperBound ?? -1
        XCTAssertEqual(upper, 30, "y 轴范围随新数据")
    }

    func testTipSitsOnTheSideAwayFromTheSelectedBar() {
        let (_, d) = chartFixture() // 3 根柱
        XCTAssertTrue(UsageModel.tipOnTrailingSide(selected: d.bars[0].id, in: d), "左半边：浮层放右侧")
        XCTAssertFalse(UsageModel.tipOnTrailingSide(selected: d.bars[2].id, in: d), "右半边：浮层放左侧")
    }

    func testModelTableAndChartShareTheSameSeriesColorMapping() {
        let (_, d) = chartFixture()
        XCTAssertEqual(UsageModel.seriesIndex("mid", series: d.series), 1)
        XCTAssertNil(UsageModel.seriesIndex("tiny", series: d.series), "不在前 3：灰")
        XCTAssertNil(UsageModel.seriesIndex(nil, series: d.series))
        XCTAssertEqual(UsageModel.tip(d.bars[0], series: d.series).rows[1].colorIndex, UsageModel.seriesIndex("mid", series: d.series), "浮层与模型表同一映射")
    }

    func testUsageLayoutOrderAndSizingRules() {
        // O1-368：两行配对。第 1 行 左 趋势 | 右 账户额度 + 正在工作；第 2 行 左 活动时段 | 右 数据与价格；第 3 行 模型明细通栏。
        XCTAssertEqual(UsageLayout.rows.map(\.left), [[.trend], [.activity]])
        XCTAssertEqual(UsageLayout.rows.map(\.right), [[.account, .working], [.sources]])
        XCTAssertEqual(UsageLayout.fullWidthRow, .modelTable)
        XCTAssertEqual(UsageLayout.singleColumn, [.trend, .account, .activity, .working, .modelTable, .sources], "窄窗单列顺序（规格）")
        XCTAssertEqual(Set(UsageLayout.singleColumn).count, UsageLayout.singleColumn.count, "每张卡只出现一次")
        XCTAssertEqual(UsageLayout.chartHeight(wide: true), 320, "宽窗柱图绘图区固定 320")
        XCTAssertEqual(UsageLayout.chartHeight(wide: false), 240, "窄窗 240")
        XCTAssertEqual(UsageLayout.heatCellHeight(wide: true), 28)
        XCTAssertEqual(UsageLayout.heatCellHeight(wide: false), 18)
        XCTAssertEqual(UsageLayout.rightWidth, 332)
        // 固定尺寸的等式（规格）：624 = 416 + 16 + 192；336 = 336
        XCTAssertEqual(UsageLayout.trendHeight, UsageLayout.accountHeight + UsageLayout.rowGap + UsageLayout.workingHeight)
        XCTAssertEqual(UsageLayout.activityHeight, UsageLayout.sourcesHeight)
        XCTAssertEqual(UsageLayout.heatGap * 6 + UsageLayout.heatCellWide * 7, 220, "7 行热力格总高 220")
        // 断点按用量页的可用内容宽度：820 最小窗口仍是单列；960 起两栏
        XCTAssertFalse(UsageLayout.isWide(contentWidth: 780), "820 窗口扣掉侧栏与内边距后仍单列")
        XCTAssertTrue(UsageLayout.isWide(contentWidth: 960))
        XCTAssertFalse(UsageLayout.isWide(contentWidth: 959))
    }

    func testNearThirtyDaySegmentAppearsOnlyWhenCapabilityIsConfirmed() {
        XCTAssertEqual(UsageSegment.visible(last30dAvailable: false), [.today, .last7d])
        XCTAssertEqual(UsageSegment.visible(last30dAvailable: true), [.today, .last7d, .last30d])
        XCTAssertEqual(UsageSegment.last30d.window, .d30)
        XCTAssertEqual(UsageSegment.last30d.label, "近 30 天")
    }

    func testSegmentsMapToTheirOwnWindows() {
        XCTAssertEqual(UsageSegment.today.window, .h24)
        XCTAssertEqual(UsageSegment.last7d.window, .d7)
    }

    func testRowTextProviderUnknownReferencePartialCostAndTruncation() {
        let rows: [UsageEstimateRow] = decode("[" + [
            row("a"), row("b", provider: nil, ref: "anthropic", cost: nil, reasons: ["region_ambiguous"]),
            row("c", cost: 2, unpriced: 40), row("d", provider: nil),
        ].joined(separator: ",") + "]")
        XCTAssertEqual(UsageModel.providerText(rows[0]), "anthropic")
        XCTAssertEqual(UsageModel.providerText(rows[1]), "服务商未知 · 按 anthropic 参考价")
        XCTAssertEqual(UsageModel.providerText(rows[3]), "服务商未知")
        XCTAssertEqual(UsageModel.costText(rows[0]), "≈$1.50")
        XCTAssertEqual(UsageModel.costText(rows[1]), "未报价")
        XCTAssertEqual(UsageModel.reasonsText(rows[1]), "参考渠道不唯一，暂不估价")
        XCTAssertEqual(UsageModel.costText(rows[2]), "≈$2.00 · 可估部分，另有未报价")
        let e: UsageEstimate = decode(estimateJSON(truncated: ["rows_truncated", "bands_omitted", "brand_new_code"]))
        XCTAssertEqual(UsageModel.truncationNotes(e), ["部分模型明细已省略，总量仍含全部", "单价详情已省略", "brand_new_code"], "未知码原样")
    }

    func testPartialTotalsKeepAmountButFlagUnpricedAndQualityBadgesAreCalm() {
        let e: UsageEstimate = decode(estimateJSON(hasUnpriced: true, partial: true, stale: true))
        XCTAssertEqual(UsageModel.qualityBadges(e.windows.today.totals, scanPartial: true), ["扫描有缺口", "有未报价", "价格可能过期"])
        XCTAssertEqual(UsageModel.qualityBadges(e.windows.today.totals, scanPartial: false), ["有未报价", "价格可能过期"], "totals.partial 不再被当成扫描缺口")
        XCTAssertEqual(UsageModel.usd(e.windows.today.totals.costUsd), "≈$1.50")
        let none: UsageEstimate = decode(estimateJSON(todayCost: "null"))
        XCTAssertEqual(UsageModel.usd(none.windows.today.totals.costUsd), "—")
    }

    func testWorkingCountIsNilWhenDisconnectedNotZero() {
        let ts: [TargetSummary] = [TargetSummary(projectName: "A", online: true, targetId: "a", status: "working"), TargetSummary(projectName: "B", online: true, targetId: "b", status: "idle")]
        XCTAssertEqual(UsageModel.workingCount(targets: ts, connected: true), 1)
        XCTAssertEqual(UsageModel.workingCount(targets: [], connected: true), 0)
        XCTAssertNil(UsageModel.workingCount(targets: ts, connected: false), "断线不写 0")
        XCTAssertNil(UsageModel.workingCount(targets: nil, connected: true))
    }

    func testFourTimesStaySeparateAndFreshnessIsServers() {
        let line = UsageModel.timesLine(generatedT: 1_761_300_000_000, asOfT: 1_761_270_000_000)
        XCTAssertTrue(line.hasPrefix("响应生成 ") && line.contains("价格 "))
        XCTAssertEqual(UsageModel.timesLine(generatedT: 1, asOfT: nil), "响应生成 " + UsageModel.ms(1).formatted(date: .omitted, time: .shortened))
        XCTAssertEqual(UsageModel.freshnessText("stale"), "价格表较旧")
        XCTAssertEqual(UsageModel.freshnessText("weird"), "weird")
    }
}

/// 用量与价格刷新的 Session 状态（D4 / D5）：真实 MacSession + usageOverride / refreshPricesOverride。
@MainActor
final class UsageSessionTests: XCTestCase {
    private func state(bridge: String = "b1") -> BridgeState {
        decode(#"{"bridge":{"id":"\#(bridge)"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#)
    }
    private func session(_ load: @escaping @Sendable (UsageWindow) async throws -> UsageResponse = { w in usage(w.rawValue, estimate: estimateJSON()) },
                         refresh: @escaping @Sendable () async throws -> PriceRefreshResult = { .updated(pricingInfo()) }) -> MacSession {
        let s = MacSession()
        s.state = state()
        s.link = .connected
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        s.usageOverride = load
        s.refreshPricesOverride = refresh
        return s
    }

    // MARK: D4

    func testUsageIsHiddenOnAnotherConnectionAndKeptOfflineOnTheSameOne() async {
        let s = session()
        await s.loadUsage(.h24)
        XCTAssertNotNil(s.visibleUsage)
        s.link = .offline("x")
        XCTAssertNotNil(s.visibleUsage, "离线：同连接的上次快照继续显示")
        XCTAssertNotNil(s.usageFetchedAt, "并有取到的时间可标")
        s.state = state(bridge: "other")
        XCTAssertNil(s.visibleUsage, "换了连接不显示前一台的数据")
    }

    func testLateUsageFromThePreviousConnectionIsDiscarded() async {
        let gate = Gate()
        let s = session { w in await gate.wait(); return usage(w.rawValue, estimate: estimateJSON()) }
        let task = Task { @MainActor in await s.loadUsage(.h24) }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(s.usageLoading)
        s.state = state(bridge: "other") // 在途期间换了连接
        await gate.release()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertNil(s.usage, "迟到结果不写")
        XCTAssertFalse(s.usageLoading, "busy 释放")
    }

    func testLateUsageAfterDisconnectIsDiscardedByConnectionGeneration() async {
        let gate = Gate()
        let s = session { w in await gate.wait(); return usage(w.rawValue, estimate: estimateJSON()) }
        let task = Task { @MainActor in await s.loadUsage(.h24) }
        for _ in 0..<30 { await Task.yield() }
        s.disconnect(reason: "断开")
        await gate.release()
        _ = await task.value
        XCTAssertNil(s.usage)
    }

    func testWindowSwitchDropsTheOlderWindowsLateResponse() async {
        let gateOld = Gate()
        let s = session { w in
            if w == .h24 { await gateOld.wait() }
            return usage(w.rawValue, estimate: estimateJSON())
        }
        let old = Task { @MainActor in await s.loadUsage(.h24) } // 今日，挂起
        for _ in 0..<30 { await Task.yield() }
        let newer = await s.loadUsage(.d7) // 切到近 7 天，先完成
        XCTAssertTrue(newer)
        await gateOld.release()
        let oldOK = await old.value
        XCTAssertFalse(oldOK)
        XCTAssertEqual(s.usage?.window, "7d", "晚到的旧窗口不覆盖当前")
        XCTAssertNil(s.usageError)
    }

    // A1-056 M1：价格刷新挂起期间用户切到 7 天；刷新成功后按「当前窗口意图」重拉，不从结果快照推断
    func testRefreshSuccessReloadsTheCurrentWindowIntentEvenIfUserSwitchedWhileRefreshing() async {
        let gateRefresh = Gate(), gate7 = Gate()
        let s = session({ w in
            if w == .d7 { await gate7.wait() }
            return usage(w.rawValue, estimate: estimateJSON())
        }, refresh: { await gateRefresh.wait(); return .updated(pricingInfo()) })
        await s.loadUsage(.h24)
        let refreshing = Task { @MainActor in await s.refreshPrices() }
        for _ in 0..<30 { await Task.yield() }
        let switched = Task { @MainActor in await s.loadUsage(.d7) } // 用户切 7 天：清掉 24h 快照并挂起
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNil(s.usage, "7d 请求挂起，旧窗口快照已清")
        await gateRefresh.release() // 价格刷新成功 → 按意图（7d）重拉
        for _ in 0..<30 { await Task.yield() }
        await gate7.release()
        await refreshing.value
        _ = await switched.value
        XCTAssertEqual(s.usage?.window, "7d", "最终窗口是 7d，不是推断出的 24h")
        XCTAssertFalse(s.usageLoading)
        XCTAssertNotNil(s.visibleUsage, "内容可见，不停在骨架")
        XCTAssertEqual(s.usageWindowIntent, .d7)
        XCTAssertEqual(s.visiblePriceNote, .updated)
    }

    // 设置窗口与主窗口并存：设置按当前窗口意图补拉（用量页 7d 挂起、usage 为空时），不把意图抢回 24h
    func testSettingsStyleLoadWithCurrentIntentDoesNotStealThePendingWindow() async {
        let gate7 = Gate()
        let s = session({ w in
            if w == .d7 { await gate7.wait() }
            return usage(w.rawValue, estimate: estimateJSON())
        })
        await s.loadUsage(.h24)
        let page = Task { @MainActor in await s.loadUsage(.d7) }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNil(s.visibleUsage)
        let settings = Task { @MainActor in await s.loadUsage(s.usageWindowIntent) } // 设置页 .task 的写法
        for _ in 0..<30 { await Task.yield() }
        await gate7.release()
        _ = await page.value; _ = await settings.value
        XCTAssertEqual(s.usage?.window, "7d")
        XCTAssertEqual(s.usageWindowIntent, .d7)
        XCTAssertNotNil(s.visibleUsage)
    }

    func testForgetResetsTheWindowIntent() async {
        let s = session()
        await s.loadUsage(.d7)
        s.forget()
        XCTAssertEqual(s.usageWindowIntent, .h24)
    }

    func testForgetClearsUsageAndInFlightRequests() async {
        let gate = Gate()
        let s = session { w in await gate.wait(); return usage(w.rawValue, estimate: estimateJSON()) }
        let task = Task { @MainActor in await s.loadUsage(.h24) }
        for _ in 0..<30 { await Task.yield() }
        s.forget()
        await gate.release()
        _ = await task.value
        XCTAssertNil(s.usage)
        XCTAssertNil(s.visibleUsage)
        XCTAssertFalse(s.usageLoading)
    }

    func testLoadFailureKeepsPreviousSnapshotAndRecordsError() async {
        let fail = Box(false)
        let s = session { w in if fail.value { throw URLError(.timedOut) }; return usage(w.rawValue, estimate: estimateJSON()) }
        await s.loadUsage(.h24)
        fail.value = true
        let ok = await s.loadUsage(.h24)
        XCTAssertFalse(ok)
        XCTAssertNotNil(s.usageError)
        XCTAssertNotNil(s.visibleUsage, "保留上次结果")
    }

    // MARK: D5

    func testRefreshUpdatedReloadsUsageFromTheNewResponse() async {
        let loads = Box(0)
        let s = session({ w in loads.value += 1; return usage(w.rawValue, estimate: estimateJSON()) })
        await s.loadUsage(.h24)
        await s.refreshPrices()
        XCTAssertEqual(s.visiblePriceNote, .updated)
        XCTAssertEqual(loads.value, 2, "200 后对原连接重拉用量")
        XCTAssertFalse(s.priceRefreshBusy)
    }

    func testRefreshCurrentAlsoReloads() async {
        let s = session(refresh: { .current(pricingInfo()) })
        await s.loadUsage(.h24)
        await s.refreshPrices()
        XCTAssertEqual(s.visiblePriceNote, .current)
    }

    func testReloadFailureAfterSuccessShowsPriceUpdatedButUsageNotRefreshedAndKeepsOldSnapshot() async {
        let fail = Box(false)
        let s = session({ w in if fail.value { throw URLError(.timedOut) }; return usage(w.rawValue, estimate: estimateJSON(todayCost: "9.9")) })
        await s.loadUsage(.h24)
        let before = s.usage
        fail.value = true
        await s.refreshPrices()
        XCTAssertEqual(s.visiblePriceNote, .usageNotRefreshed)
        XCTAssertEqual(PricingSection.noteText(.usageNotRefreshed, now: Date()), "价格已更新，用量暂未刷新")
        XCTAssertEqual(s.usage, before, "保留旧快照")
        XCTAssertFalse(s.priceRefreshBusy)
    }

    func testRateLimitedShowsDeadlineCountdownAndNeverRetriesAutomatically() async {
        let calls = Box(0)
        let s = session(refresh: { calls.value += 1; return .rateLimited(retryAfterMs: 30_000) })
        await s.loadUsage(.h24)
        await s.refreshPrices()
        guard case .rateLimited(let until)? = s.visiblePriceNote else { return XCTFail("应是 429 状态") }
        XCTAssertEqual(until.timeIntervalSinceNow, 30, accuracy: 2)
        let now = Date()
        XCTAssertTrue(s.priceRefreshBlocker(now: now)?.contains("秒后再试") == true, "冷却中禁用并说明")
        XCTAssertEqual(PricingSection.noteText(.rateLimited(until: now.addingTimeInterval(12.2)), now: now), "更新太频繁，13 秒后可再试")
        await s.refreshPrices() // 冷却中再点：被拦下，不发请求
        XCTAssertEqual(calls.value, 1)
        XCTAssertNil(s.priceRefreshBlocker(now: until.addingTimeInterval(1)), "到点自动解除禁用，但不自动重试")
        XCTAssertEqual(calls.value, 1)
    }

    func testEveryFixedFailureCodeAndTransportMapToText() async {
        for code in ["timeout", "fetch_failed", "invalid_table", "too_large", "redirect_refused", "cache_write_failed", "unavailable", "shutting_down", "read_only", "unauthorized", "unsupported"] {
            let s = session(refresh: { .failed(code: code) })
            await s.loadUsage(.h24)
            await s.refreshPrices()
            XCTAssertEqual(s.visiblePriceNote, .failed(code))
            XCTAssertNotEqual(UsageCopy.refreshFailure(code), code, "\(code) 要有人话")
            XCTAssertFalse(s.priceRefreshBusy)
        }
        let s = session(refresh: { throw URLError(.notConnectedToInternet) })
        await s.loadUsage(.h24)
        await s.refreshPrices()
        XCTAssertEqual(s.visiblePriceNote, .failed("transport"))
        XCTAssertFalse(s.priceRefreshBusy)
    }

    func testBlockersOfflineReadonlyLegacyAndPaired() async {
        let s = session()
        await s.loadUsage(.h24)
        XCTAssertNil(s.priceRefreshBlocker())
        s.link = .offline("x")
        XCTAssertNotNil(s.priceRefreshBlocker())
        s.link = .connected
        s.device = decode(#"{"id":"d","name":"mac","paused":false,"permission":"readonly"}"#)
        XCTAssertEqual(s.priceRefreshBlocker(), MacSession.readOnlyNote)
        s.device = decode(#"{"id":"d","name":"mac","paused":false}"#)
        let legacy = session({ w in usage(w.rawValue) })
        await legacy.loadUsage(.h24)
        XCTAssertEqual(legacy.priceRefreshBlocker(), UsageCopy.refreshFailure("unsupported"), "旧版 Bridge 不显示更新入口")
    }

    func testSingleFlightAcrossEntryPointsAndBusyAlwaysReleased() async {
        let gate = Gate()
        let calls = Box(0)
        let s = session(refresh: { calls.value += 1; await gate.wait(); return .updated(pricingInfo()) })
        await s.loadUsage(.h24)
        let first = Task { @MainActor in await s.refreshPrices() } // 用量页入口
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(s.priceRefreshBusy)
        XCTAssertEqual(s.priceRefreshBlocker(), "正在更新…", "设置页入口看到同一个 busy")
        await s.refreshPrices() // 设置页入口：被单飞拦下
        XCTAssertEqual(calls.value, 1)
        await gate.release()
        await first.value
        XCTAssertFalse(s.priceRefreshBusy)
    }

    func testLateRefreshResultFromAnotherConnectionIsNotWrittenAndBusyReleases() async {
        let gate = Gate()
        let s = session(refresh: { await gate.wait(); return .updated(pricingInfo()) })
        await s.loadUsage(.h24)
        let task = Task { @MainActor in await s.refreshPrices() }
        for _ in 0..<30 { await Task.yield() }
        s.state = state(bridge: "other")
        await gate.release()
        await task.value
        XCTAssertNil(s.visiblePriceNote, "不写到另一个连接")
        XCTAssertFalse(s.priceRefreshBusy)
        s.state = state(bridge: "b1")
        XCTAssertNil(s.visiblePriceNote)
    }

    func testForgetDuringRefreshReleasesBusyAndDropsResult() async {
        let gate = Gate()
        let s = session(refresh: { await gate.wait(); return .updated(pricingInfo()) })
        await s.loadUsage(.h24)
        let task = Task { @MainActor in await s.refreshPrices() }
        for _ in 0..<30 { await Task.yield() }
        s.forget()
        XCTAssertFalse(s.priceRefreshBusy)
        await gate.release()
        await task.value
        XCTAssertNil(s.priceNote)
    }
}

private func pricingInfo() -> UsagePricingInfo {
    decode(#"{"source":"models.dev","origin":"downloaded","freshness":"current","versionHash":"abcdef123456","asOfT":1761270000000,"lastValidatedT":1761273600000,"lastCheckT":null,"autoUpdate":true,"updatePolicy":"startup_if_older_than_3d"}"#)
}

/// D6：自动更新开关 → 环境、迁移、导入。
@MainActor
final class PricingAutoUpdateSettingsTests: XCTestCase {
    private func settings(extra: String = "", stored: Bool? = nil) -> (EngineSettings, String) {
        let suite = "palmhelm.test.pricing.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        if !extra.isEmpty { d.set(extra, forKey: "engine.extraEnv") }
        if let stored { d.set(stored, forKey: "engine.pricingAutoUpdate") }
        return (EngineSettings(defaults: d, secretsReady: true), suite)
    }

    func testDefaultOnAndEnvironmentIsExplicit() {
        let (s, suite) = settings(); defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertTrue(s.pricingAutoUpdate)
        XCTAssertEqual(s.environment()["BRIDGE_PRICING_AUTO_UPDATE"], "1")
        s.pricingAutoUpdate = false
        XCTAssertEqual(s.environment()["BRIDGE_PRICING_AUTO_UPDATE"], "0", "关闭时明确输出 0，不依赖 Bridge 缺省")
    }

    func testPersistedValueSurvivesRestart() {
        let (s, suite) = settings(stored: false); defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertFalse(s.pricingAutoUpdate)
    }

    func testExistingExtraEnvZeroIsMigratedIntoTheSwitchAndRemovedFromExtra() {
        let (s, suite) = settings(extra: "BRIDGE_TARGET_GROUP_X=1\nBRIDGE_PRICING_AUTO_UPDATE=0\nFOO=bar\nBRIDGE_ROUTING=1"); defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertFalse(s.pricingAutoUpdate, "此前它就是生效值：先尊重")
        XCTAssertFalse(s.extraEnv.contains("BRIDGE_PRICING_AUTO_UPDATE"), "之后只有开关一个权威")
        XCTAssertFalse(s.extraEnv.contains("BRIDGE_TARGET_GROUP_X") || s.extraEnv.contains("FOO="), "未知键在装载时移除")
        XCTAssertTrue(s.extraEnv.contains("BRIDGE_ROUTING=1"), "已知键的值保留")
        XCTAssertEqual(s.environment()["BRIDGE_PRICING_AUTO_UPDATE"], "0")
    }

    func testMigrationParsingFollowsBridgeSemantics() {
        XCTAssertEqual(EngineSettings.migratePricing(extraEnv: "BRIDGE_PRICING_AUTO_UPDATE= 0 ").value, false)
        XCTAssertEqual(EngineSettings.migratePricing(extraEnv: "BRIDGE_PRICING_AUTO_UPDATE=\"0\"").value, false)
        XCTAssertEqual(EngineSettings.migratePricing(extraEnv: "BRIDGE_PRICING_AUTO_UPDATE=1").value, true)
        XCTAssertEqual(EngineSettings.migratePricing(extraEnv: "BRIDGE_PRICING_AUTO_UPDATE=false").value, true, "Bridge 只认 0 为关")
        XCTAssertNil(EngineSettings.migratePricing(extraEnv: "# BRIDGE_PRICING_AUTO_UPDATE=0").value, "注释不算")
        XCTAssertNil(EngineSettings.migratePricing(extraEnv: "FOO=1").value)
    }

    func testSameKeyInOtherVariablesIsIgnoredAfterwardsNoDoubleAuthority() {
        let (s, suite) = settings(); defer { UserDefaults().removePersistentDomain(forName: suite) }
        s.extraEnv = "BRIDGE_PRICING_AUTO_UPDATE=0"
        XCTAssertEqual(s.environment()["BRIDGE_PRICING_AUTO_UPDATE"], "1", "其他变量里的同名键不再生效")
        XCTAssertTrue(EngineSettings.ownKeys.contains("BRIDGE_PRICING_AUTO_UPDATE"))
    }

    func testEnvImportZeroIsRespectedAndNotKeptInExtra() throws {
        let (s, suite) = settings(); defer { UserDefaults().removePersistentDomain(forName: suite) }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)")
        try "BRIDGE_PRICING_AUTO_UPDATE=0\nBRIDGE_OTHER=x\nBRIDGE_ROUTING=1\n".write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        try s.importEnvFile(at: f.path)
        XCTAssertFalse(s.pricingAutoUpdate)
        XCTAssertFalse(s.extraEnv.contains("BRIDGE_OTHER"))
        XCTAssertEqual(EngineSettings.parseEnvLines(s.extraEnv), ["BRIDGE_ROUTING": "1"])
    }
}
