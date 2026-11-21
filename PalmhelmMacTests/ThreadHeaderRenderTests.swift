import XCTest
import SwiftUI
import AppKit
import PalmhelmKit
@testable import PalmhelmMac

/// #101 线程头部与输入区提示的渲染检查（浅色/深色各一张）。设置 W2_SHOT_DIR 时把 PNG 写到该目录。
@MainActor
final class ThreadHeaderRenderTests: XCTestCase {
    private func sample(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ThreadHeaderBar(statusText: "工作中", statusTone: .green, durationText: "· 刚开始", modelText: "haiku 5.5 · medium")
                Spacer()
                ThreadDetailsButton(details: [
                    .init(label: "状态", value: "工作中"),
                    .init(label: "位置", value: "demo › 1 · 窗格 p1"),
                    .init(label: "智能体与模型", value: "Claude · claude-haiku-5-5"),
                ])
                Button("在 Herdr 中显示") {}
            }
            ComposerSendHint(hint: .queued(ahead: 2), agentName: "Claude")
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
        .environment(\.colorScheme, scheme)
    }

    func testRendersLightAndDark() throws {
        let dir = ProcessInfo.processInfo.environment["W2_SHOT_DIR"]
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: sample(scheme))
            renderer.scale = 2
            guard let cg = renderer.cgImage else {
                XCTFail("渲染失败：\(scheme)")
                continue
            }
            XCTAssertGreaterThan(cg.width, 0)
            XCTAssertGreaterThan(cg.height, 0)
            if let dir {
                let name = scheme == .dark ? "mac-thread-header-dark.png" : "mac-thread-header-light.png"
                let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                try png?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}

/// 模型胶囊的读屏文字：来源版本优先，缺省读可见文字。
/// 说明：SwiftUI 的 macOS 无障碍树在测试进程里不会生成（实测遍历 NSHostingView 得到空列表），所以这里验证的是选择规则；
/// 接线（MainWindow 传 ModelText.accessibility）靠编译与代码核对。
final class ThreadHeaderAccessibilityTests: XCTestCase {
    func testModelCapsuleSpeaksTheSource() {
        let visible = "claude-opus-5-5 · medium"
        for (basis, source) in [("last_used", "最近使用"), ("last_configured", "最近配置")] {
            let model = try! JSONDecoder().decode(TargetModel.self, from: Data(#"{"id":"claude-opus-5-5","basis":"\#(basis)","effort":"medium"}"#.utf8))
            let spoken = ModelText.accessibility(TargetSummary(projectName: "p", model: model))
            XCTAssertEqual(ThreadHeaderBar.spokenModel(visible: visible, spoken: spoken), spoken, "读屏标签用来源版本")
            XCTAssertTrue(spoken?.contains(source) == true && spoken?.contains("claude-opus-5-5") == true && spoken?.contains("medium") == true, "含来源、完整模型与等级：\(spoken ?? "nil")")
            XCTAssertFalse(visible.contains(source), "可见文字不带来源")
        }
        XCTAssertEqual(ThreadHeaderBar.spokenModel(visible: visible, spoken: nil), visible, "没有来源版本时读可见文字")
    }
}
