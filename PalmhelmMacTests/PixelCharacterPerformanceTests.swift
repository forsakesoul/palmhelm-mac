import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import PalmhelmMac

/// 显式启用的宿主基准；默认跳过，不挂真实刘海、不激活窗口。
@MainActor
final class PixelCharacterPerformanceTests: XCTestCase {
    func testPixelAnimationCPU() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["REINS_PIXEL_PERF_OUTPUT"] else { throw XCTSkip("按需运行像素角色 CPU 对照") }
        var animated: [Double] = [], still: [Double] = []
        for i in 0..<5 {
            // 交替顺序，避免初始化或温度变化一直偏向一组。
            if i.isMultiple(of: 2) {
                still.append(try await cpu(animating: false))
                animated.append(try await cpu(animating: true))
            } else {
                animated.append(try await cpu(animating: true))
                still.append(try await cpu(animating: false))
            }
        }
        let result: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "sampleSeconds": 5, "warmupSeconds": 1,
            "animated": animated, "still": still,
            "animatedMedian": animated.sorted()[2], "stillMedian": still.sorted()[2],
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }

    func testOtherAnimationModesCPU() async throws {
        guard let output = ProcessInfo.processInfo.environment["REINS_PIXEL_PERF_OUTPUT"] else { throw XCTSkip("按需运行像素角色 CPU 对照") }
        var result: [String: Any] = [:]
        for (character, mode) in [(NotchCharacter.robot, PixelMode.run), (.cat, .run), (.bars, .run), (.horse, .wait), (.horse, .done)] {
            var animated: [Double] = [], still: [Double] = []
            for _ in 0..<3 {
                still.append(try await cpu(animating: false, character: character, mode: mode, seconds: 3))
                animated.append(try await cpu(animating: true, character: character, mode: mode, seconds: 3))
            }
            result["\(character.rawValue)-\(mode)"] = ["animated": animated, "still": still, "animatedMedian": animated.sorted()[1], "stillMedian": still.sorted()[1]]
        }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output + ".other-modes.json"))
    }

    private func cpu(animating: Bool, character: NotchCharacter = .horse, mode: PixelMode = .run, seconds: Double = 5) async throws -> Double {
        let host = NSHostingView(rootView: PixelCharacterView(character: character, mode: mode, animating: animating, since: mode == .done ? Date().addingTimeInterval(-1) : nil))
        host.frame = NSRect(x: 0, y: 0, width: 30, height: 21)
        let panel = NSPanel(contentRect: NSRect(x: -3000, y: -3000, width: 30, height: 21), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderBack(nil)
        defer {
            // 显式撤掉时间线，不能让上一轮的 SwiftUI 图继续计入下一轮 CPU。
            host.rootView = PixelCharacterView(character: .horse, mode: .run, animating: false)
            host.layoutSubtreeIfNeeded()
            panel.contentView = nil
            panel.close()
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.isVisible)
        try await Task.sleep(for: .seconds(1))
        let start = ProcessInfo.processInfo.systemUptime, usage = cpuSeconds()
        try await Task.sleep(for: .seconds(seconds))
        return (cpuSeconds() - usage) / (ProcessInfo.processInfo.systemUptime - start) * 100
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
