import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #30 R1（Mac）：零桶进入分类域，拿到真实 ChartProxy 坐标；选中零桶时其他柱子位置不变。坐标来自渲染后的真实 Chart，不靠 bar(at:) / bar(key:) 单测。
@MainActor
final class UsageBarChartGeometryTests: XCTestCase {
    private let t0 = 1_792_252_800_000
    private func usage(_ values: [Int]) throws -> (UsageResponse, UsageEstimateWindow, UsageChartData) {
        let buckets = values.enumerated().map { i, v in
            #"{"t":\#(t0 + i * 3_600_000),"byModel":{"claude-a":{"input":\#(v),"output":0,"cacheRead":0,"cacheWrite":0,"activity":1}}}"#
        }.joined(separator: ",")
        let json = #"{"window":"24h","timeZone":"Asia/Shanghai","generatedT":1,"partial":false,"reasons":[],"quality":{},"bucketMs":3600000,"buckets":[\#(buckets)],"recent":{"today":{"from":"a","to":"a","byModel":{}},"d7":{"from":"a","to":"a","byModel":{}},"d30":{"from":"a","to":"a","byModel":{}}},"heatmap":{"days":[],"activity":[]},"prices":{},"agents":{"claude":{"candidates":0,"parsed":0,"complete":0},"codex":{"candidates":0,"parsed":0,"complete":0}}}"#
        let u = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        let w = try JSONDecoder().decode(UsageEstimateWindow.self, from: Data(#"{"from":"2026-10-18","to":"2026-10-18","rows":[],"totals":{"tokens":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0},"costUsd":null,"hasUnpriced":false,"partial":false,"priceStale":false}}"#.utf8))
        return (u, w, UsageChartData.make(u, from: "2026-10-18", to: "2026-10-18", daily: false))
    }

    private func render(_ values: [Int], selected: Int? = nil) throws -> (ChartProbe, UsageChartData) {
        let (u, w, d) = try usage(values)
        let probe = ChartProbe()
        let view = ChartCard(u: u, w: w, segment: .today, data: d, plotHeight: 170, probe: probe, initialSelection: selected).frame(width: 520)
        let r = ImageRenderer(content: view)
        r.scale = 1
        _ = r.nsImage
        return (probe, d)
    }

    func testZeroBucketsGetChartCoordinatesInOrder() throws {
        for values in [[0, 9, 0], [5, 0, 9]] {
            let (probe, d) = try render(values)
            let xs = d.bars.map { probe.position?(UsageChartData.key($0)) }
            XCTAssertTrue(xs.allSatisfy { $0 != nil }, "零桶必须拿到 position（values \(values)）")
            let v = xs.compactMap { $0 }
            XCTAssertEqual(v, v.sorted(), "类目顺序不被零桶打乱")
            XCTAssertEqual(Set(v).count, 3)
        }
    }

    func testHoverPositionsResolveToTheRightKey() throws {
        let (probe, d) = try render([0, 9, 0])
        for b in d.bars {
            let x = try XCTUnwrap(probe.position?(UsageChartData.key(b)))
            XCTAssertEqual(probe.key?(x), UsageChartData.key(b), "悬停在该柱中心 → 选中它自己（含首尾零桶）")
        }
    }

    func testSelectingABucketDoesNotMoveOtherBars() throws {
        let (base, d) = try render([5, 0, 9])
        let positions = d.bars.map { base.position?(UsageChartData.key($0)) }
        for b in d.bars {
            let (after, _) = try render([5, 0, 9], selected: b.id)
            for (i, bar) in d.bars.enumerated() {
                XCTAssertEqual(after.position?(UsageChartData.key(bar)), positions[i], "选中 \(b.title) 时 \(bar.title) 不移动")
            }
        }
    }
    func testAxisWidthIsMeasuredOnceInRealChartLayout() throws {
        let (u, w, data) = try usage(Array(repeating: 9, count: 24))
        let probe = ChartProbe()
        var measured: [String] = []
        let chart = ChartCard(u: u, w: w, segment: .today, data: data, plotHeight: 170, probe: probe, axisLabelMeasured: { measured.append($0) }).frame(width: 520)
        let renderer = ImageRenderer(content: chart)
        XCTAssertNotNil(renderer.nsImage)
        XCTAssertNotNil(probe.position?(UsageChartData.key(data.bars[0])), "必须经过真实 Chart 布局")
        XCTAssertEqual(measured.count, 1, "一轮真实轴布局只估计一次最大标签宽度，背景和标签层复用同一份结果")
    }

}
