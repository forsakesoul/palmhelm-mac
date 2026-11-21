import AppKit
import SwiftUI
import PalmhelmKit

/// 终端视图第一片（设计稿 Ttv）：窗格当前视口的只读镜像。只在可见时每 2 秒拉一次，离开或进后台即停；
/// revision 不变不重绘；滚动锚在底部，用户上滑后不抢，显示「回到底部」。不执行命令、不发送按键。
struct MacTerminalMirrorView: View {
    let threadId: String
    @Environment(MacSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dts
    @State private var snapshot: ScreenSnapshot?
    @State private var failures = 0
    @State private var lastAt: Date?
    @State private var poll: Task<Void, Never>?
    @State private var atBottom = true
    @State private var ticks = 0 // 首次绑定后身份核验在途时第一拍常为 unavailable：前两拍按加载中显示

    var body: some View {
        VStack(spacing: 8) {
            statusLine
            if let s = snapshot, s.isOK, let lines = s.lines {
                panel(lines, truncated: s.truncated == true)
            } else if let s = snapshot, !s.isOK, ticks > 2 {
                card(ScreenCopy.unavailableTitle, ScreenCopy.unavailableBody)
            } else if failures >= 3 {
                card(ScreenCopy.failedTitle, String(localized: "连续 3 次没拉到画面。")) // 失败态：重试在状态行
            } else {
                loadingPanel
            }
        }
        .padding(.horizontal)
        .onAppear { start() }
        .onDisappear { stop() }
        .onChange(of: threadId) { _, _ in reset(); start() } // 同位置切目标：清快照、停旧任务、起新任务（A1-145 F1）
        .onChange(of: scenePhase) { _, p in p == .active ? start() : stop() }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(snapshot?.isOK == true && failures == 0 ? PalmhelmTheme.ok : PalmhelmTheme.warn).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(dts.isAccessibilitySize ? nil : 1)
            Spacer()
            if failures >= 3 || (snapshot?.isOK == false && ticks > 2) {
                Button(ScreenCopy.retry) { reset(); start() }.font(.caption).frame(minHeight: 28)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if snapshot?.isOK == false, ticks > 2 { return ScreenCopy.unavailableTitle }
        if failures >= 3 { return ScreenCopy.failedTitle }
        let when = lastAt.map { Date().timeIntervalSince($0) < 5 ? String(localized: "刚刚") : TranscriptCopy.time(Int($0.timeIntervalSince1970 * 1000)) } ?? "…"
        return "\(ScreenCopy.live) · \(when)"
    }

    /// 加载态：与真实面板同一外观（固定深色、圆角 12），铺满剩余高度，条形取同字号等宽字体的行距。
    private var loadingPanel: some View {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        let cap = max(1, font.capHeight)
        let pitch = font.ascender - font.descender + font.leading
        return SkeletonLines(lineHeight: cap, label: String(localized: "正在读取画面"), fill: true, spacing: max(0, pitch - cap),
                             barColor: Color.white.opacity(0.16), shimmerColor: Color.white.opacity(0.10))
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.06, green: 0.07, blue: 0.08), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func panel(_ lines: [String], truncated: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    // 一整块可选中文本：逐行拆视图会让长按选择失效（A1-130 经验）
                    // 按 24 行一块渲染：单个超大 Text 在大字号下会整块空白（A1-145 F5）；每块仍整体可选中
                    ForEach(Array(stride(from: 0, to: lines.count, by: 24)), id: \.self) { i in
                        Text(lines[i..<min(i + 24, lines.count)].joined(separator: "\n")).font(.system(.caption, design: .monospaced)).foregroundStyle(Color(red: 0.84, green: 0.85, blue: 0.87))
                            .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(.horizontal, 12)
                            .accessibilityHint("终端画面，只读")
                    }
                    Color.clear.frame(height: 12)
                    Color.clear.frame(height: 1).id("screen-bottom")
                }
            }
            .defaultScrollAnchor(.bottomLeading) // 横向停在最左，纵向停在底部
            .onChange(of: snapshot?.revision) { _, _ in if atBottom { withAnimation(nil) { proxy.scrollTo("screen-bottom", anchor: .bottomLeading) } } }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button { atBottom = true; proxy.scrollTo("screen-bottom", anchor: .bottomLeading) } label: {
                        Text(ScreenCopy.toBottom).font(.caption).foregroundStyle(.white).padding(.horizontal, 12).frame(minHeight: 28).background(Color(white: 0.18), in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.plain).padding(12)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { v in if v.translation.height > 0 { atBottom = false } })
        }
        .clipShape(RoundedRectangle(cornerRadius: 12)) // 滚动正文不画到面板外（A1-149 F6）
        .background(Color(red: 0.06, green: 0.07, blue: 0.08), in: RoundedRectangle(cornerRadius: 12)) // 固定深色，不随主题
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 4) { // 截断提示放面板下方，不盖住末尾正文与「回到底部」（A1-147 F5-R1）
            if truncated { Text(ScreenCopy.truncated).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    @ViewBuilder private func card(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(Color.secondary.opacity(0.4)))
        Spacer()
    }

    private func start() {
        guard poll == nil else { return }
        poll = Task { @MainActor in
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(for: .seconds(BridgeAPI.screenPollSeconds))
            }
        }
    }
    private func stop() { poll?.cancel(); poll = nil }
    private func reset() { stop(); snapshot = nil; failures = 0; ticks = 0; atBottom = true }

    @MainActor private func tick() async {
        let id = threadId
        ticks += 1
        let result = await session.screen(id)
        guard id == threadId, !Task.isCancelled else { return } // 切目标 / 已停：丢弃旧目标的响应
        guard let s = result else { failures += 1; return }
        failures = 0; lastAt = Date()
        if s.revision != snapshot?.revision || s.status != snapshot?.status { snapshot = s } // revision 不变不重绘
    }
}
