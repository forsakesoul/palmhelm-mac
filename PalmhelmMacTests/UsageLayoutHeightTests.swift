import XCTest
import SwiftUI
import AppKit
import PalmhelmKit
@testable import PalmhelmMac

/// #32：绘图区用 ChartProxy 的真实 plotFrame 验证在 240–420 之间吸收行高（宽窗布局）。
/// 离屏渲染；窗口不显示；默认不需要环境变量（只读布局，不写文件）。
@MainActor
final class UsageLayoutHeightTests: XCTestCase {
    private func plotHeights(width: CGFloat, viewport: CGFloat) async -> [CGFloat] {
        let reporter = PlotReporter()
        let r = UsageShotHarness.make(width: width, height: viewport, dark: false, reporter: reporter)
        await UsageShotHarness.settle(r, segment: .today)
        return reporter.heights
    }

    /// 宽窗（1440）：680 最小窗口高度、820、1400、2200 视口下，真实 plot 高度都在 [240, 420]。
    func testWideLayoutPlotWithinBoundsAtSeveralViewports() async {
        for viewport: CGFloat in [680, 820, 1400, 2200] {
            let hs = await plotHeights(width: 1440, viewport: viewport)
            XCTAssertFalse(hs.isEmpty, "应报告绘图区高度（宽窗，视口 \(Int(viewport))）")
            for h in hs {
                XCTAssertGreaterThanOrEqual(h, 240, "宽窗视口 \(Int(viewport))：绘图区不低于 240（ChartProxy 实测）")
                XCTAssertLessThanOrEqual(h, 420, "宽窗视口 \(Int(viewport))：绘图区不高于 420")
            }
        }
    }

    /// 单列（820 内容宽）：680 与 820 视口下，真实 plot 高度都在 [240, 420]。
    func testSingleColumnPlotWithinBoundsAtSmallViewports() async {
        for viewport: CGFloat in [680, 820] {
            let hs = await plotHeights(width: 820, viewport: viewport)
            XCTAssertFalse(hs.isEmpty, "应报告绘图区高度（单列，视口 \(Int(viewport))）")
            for h in hs {
                XCTAssertGreaterThanOrEqual(h, 240, "单列视口 \(Int(viewport))：绘图区不低于 240（ChartProxy 实测）")
                XCTAssertLessThanOrEqual(h, 420, "单列视口 \(Int(viewport))：绘图区不高于 420")
            }
        }
    }
}
