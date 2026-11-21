import SwiftUI
import PalmhelmKit

// 会话搜索窗口（独立 Window，⌘F 打开，Esc / ⌘W 关闭）：上半是目标的本地筛选（点击直接打开线程），下半是会话内容搜索（回车提交）。
// 查询、结果与定位都在 MacSession；这里只渲染与转发。与 PairingWindow 同样不用 sheet（sheet 挂在主窗口上会挡退出）。
struct SearchWindow: View {
    @Environment(MacSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var text = ""
    @FocusState private var focused: Bool

    private var targets: [TargetSummary] {
        Array((session.state?.targets ?? []).filter { TargetFilter.matches($0, query: text) }.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜目标，或按回车搜会话内容", text: $text)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { Task { await session.runSearch(text) } }
                    .accessibilityLabel("搜索目标或会话内容")
                if session.searching { ProgressView().controlSize(.small) }
                Button("搜索") { Task { await session.runSearch(text) } }
                    .disabled(session.searching || SearchText.normalizedQuery(text) == nil)
                    .help("搜索会话内容（回车同样有效）")
            }
            .padding(12)
            Divider()
            List {
                Section("目标") {
                    if targets.isEmpty { Text("没有匹配的目标").foregroundStyle(.secondary) }
                    ForEach(targets) { t in
                        Button { session.openFromSearch(targetId: t.id); close(); openMain() } label: { targetRow(t) }.buttonStyle(.plain)
                    }
                }
                Section("记录") { recordsSection }
            }
        }
        .frame(width: 560, height: 520)
        .onAppear { focused = true }
        .onExitCommand { close() }
    }

    private func close() { dismissWindow(id: "search") }

    /// 打开主窗口并把它拉到前面（定位结果在主窗口的对话页里）。
    private func openMain() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }

    private func targetRow(_ t: TargetSummary) -> some View {
        HStack(spacing: 8) {
            ActivityDot(kind: session.activityKind(t), size: 7, accent: PalmhelmTheme.accent, ok: PalmhelmTheme.ok, warn: PalmhelmTheme.warn)
            VStack(alignment: .leading, spacing: 1) {
                Text(ThreadIdentity.title(t)).font(.callout.weight(.medium)).lineLimit(1)
                Text([ThreadIdentity.line(t), ThreadIdentity.location(t)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var recordsSection: some View {
        if let e = session.searchError {
            Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(PalmhelmTheme.bad)
        } else if let r = session.searchResponse {
            if r.partial { Label(SearchText.partial, systemImage: "info.circle").foregroundStyle(.secondary) }
            if r.results.isEmpty { ContentUnavailableView.search(text: session.searchQuery) }
            ForEach(r.results) { hit in
                Button { close(); Task { await session.openSearchHit(hit); openMain() } } label: { hitRow(hit) }.buttonStyle(.plain)
            }
        } else {
            Text("输入至少 2 个字符，按回车搜索会话内容").foregroundStyle(.secondary)
        }
    }

    private func hitRow(_ hit: SearchHit) -> some View {
        let t = session.state?.targets.first { $0.id == hit.targetId }
        return HStack(alignment: .top, spacing: 8) {
            ActivityDot(kind: t.map(session.activityKind) ?? .offline, size: 7, accent: PalmhelmTheme.accent, ok: PalmhelmTheme.ok, warn: PalmhelmTheme.warn)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(t.map(ThreadIdentity.title) ?? hit.targetId).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let ms = hit.t { Text(Date(timeIntervalSince1970: Double(ms) / 1000), style: .relative).font(.caption).foregroundStyle(.secondary) }
                }
                Text(SearchText.highlighted(hit: hit)).font(.callout).lineLimit(2)
            }
        }
        .contentShape(Rectangle())
    }
}
