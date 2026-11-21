import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #89 S3 排队卡离屏截图（默认跳过）。TEST_RUNNER_REINS_QUEUE_SHOTS=1 时渲染到 TEST_RUNNER_REINS_QUEUE_SHOTS_DIR（缺省 /tmp/W1-h35-shots）。
// 输入全是合成的指令 JSON，经真实的 ApiCommand 解码与 QueueStatusPresentation.card(for:) 得到卡片。
@MainActor
final class QueueCardShotTests: XCTestCase {
    private func render<V: View>(_ view: V, dark: Bool, size: NSSize) -> Data? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: host.frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)).cgColor
        container.addSubview(host)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        host.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// 合成指令：queue 片段为空即旧 Bridge（无扩展组）。
    private func command(state: String, lane: String = "ordinary", queue: String, reason: String? = nil) throws -> ApiCommand {
        let reasonJSON = reason.map { #","reason":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"api:d:1","inboxSeq":2,"text":"顺便补一下截图","truncated":false,"origin":"api","state":"\#(state)","lane":"\#(lane)","targetId":"t1","createdT":100\#(reasonJSON)\#(queue)}"#.utf8))
    }

    private func card(_ c: ApiCommand) -> some View {
        let label = QueueStatusPresentation.card(for: c) == nil ? SendTimingCopy.commandStatus(state: c.state, reason: c.reason, lane: c.lane) : ""
        return VStack(alignment: .trailing, spacing: 3) {
            QueuedStatusView(label: label, tone: .queued, items: [], note: nil, onWithdraw: {}, onPromote: {}, card: QueueStatusPresentation.card(for: c))
            Text("顺便补一下截图").font(.subheadline).foregroundStyle(PalmhelmTheme.emphasis)
                .padding(10).background(PalmhelmTheme.bubbleMe, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(16)
        .frame(width: 420)
    }

    func testRenderQueueCardShots() throws {
        guard ProcessInfo.processInfo.environment["REINS_QUEUE_SHOTS"] == "1" else { throw XCTSkip("set TEST_RUNNER_REINS_QUEUE_SHOTS=1 to render queue-card shots") }
        let path = ProcessInfo.processInfo.environment["REINS_QUEUE_SHOTS_DIR"] ?? "/tmp/W1-h35-shots"
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cases: [(String, ApiCommand)] = try [
            ("draft-pos1", command(state: "queued", queue: #","queueReason":"draft","queuePosition":1,"observedAt":1000,"phase":null"#)),
            ("wait-turn-pos2", command(state: "queued", queue: #","queueReason":"wait_turn","queuePosition":2,"observedAt":null,"phase":null"#)),
            ("unconfirmed-with-time", command(state: "queued", queue: #","queueReason":"unconfirmed","queuePosition":1,"observedAt":2000,"phase":null"#)),
            ("unconfirmed-no-time", command(state: "queued", queue: #","queueReason":"unobserved","queuePosition":1,"observedAt":null,"phase":null"#)),
            ("phase-dispatch", command(state: "started", queue: #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"dispatch""#)),
            ("phase-awaiting", command(state: "started", queue: #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"awaiting""#)),
            ("phase-running", command(state: "started", queue: #","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"running""#)),
            ("queued-deadline-with-meta", command(state: "queued", queue: #","queueDeadlineT":1790000000000,"queueReason":"wait_turn","queuePosition":1,"observedAt":null,"phase":null"#)),
            ("queued-deadline-no-meta", command(state: "queued", queue: #","queueDeadlineT":1790000000000"#)),
            ("use-lane", command(state: "queued", lane: "use", queue: #","queueReason":"wait_turn","queuePosition":1,"observedAt":null,"phase":null"#)),
            ("legacy-bridge", command(state: "queued", queue: "")),
        ]
        for dark in [false, true] {
            for (name, c) in cases {
                let data = render(card(c), dark: dark, size: NSSize(width: 460, height: 120))
                try XCTUnwrap(data).write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
