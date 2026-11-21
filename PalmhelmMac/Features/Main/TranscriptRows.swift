import SwiftUI
import PalmhelmKit

// 会话记录线程的行（设计稿 T2a_Mac）：与 iPhone 同一套内容与规则。
struct TranscriptItemRow: View {
    let item: TranscriptItem
    /// 定位视图里的搜索词：命中词加底色（只在定位所在线程传入）。
    var highlight: String? = nil
    /// 搜索命中的显示：Bridge 原子被替换后，只在显示文本与 canonical 命中一一对应时高亮（映射失败不标，不错标）。
    private var hl: String? { SearchText.consistentQuery(raw: item.text, shown: item.displayed, query: highlight) }
    private func hlExpansion(_ e: TranscriptExpansion?) -> String? { e.map { SearchText.consistentQuery(raw: $0.text, shown: $0.displayed, query: highlight) } ?? hl }
    /// 目标当前是否工作中：区分「已送达」与「处理中」（O1-365）。
    var agentWorking: Bool = false
    /// 回执对上的本机权威指令（eventKey 精确相等），用于叠加 native_delivered；没有则按未关联处理。
    var linkedCommand: ApiCommand? = nil
    /// 父级按片 A 的 tracker 解析好的状态（精确 eventKey 关联后）：有卡时卡与来源行不重复同一状态。nil = 未关联，沿用来源行自行求值。
    var status: MessageStatus? = nil
    /// 长回复的折叠与按段展开；nil 表示这一行不参与折叠（用户消息、短回复、正在写的最新回复）。
    var folding: TranscriptRowFolding? = nil

    var body: some View {
        switch TranscriptRole(rawValue: item.role) {
        case .user?:
            HStack(alignment: .bottom) {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 3) {
                    MarkdownText(text: item.displayed.text + (item.truncated ? "…" : ""), highlight: hl).foregroundStyle(PalmhelmTheme.emphasis).padding(10).background(PalmhelmTheme.bubbleMe, in: RoundedRectangle(cornerRadius: 12))
                    HStack(spacing: 4) {
                        if item.receipt != nil { Circle().fill(PalmhelmTheme.accent).frame(width: 6, height: 6) }
                        Text(TranscriptCopy.sourceLine(item, agentWorking: agentWorking, command: linkedCommand, resolvedStatus: status?.label, showsStatus: status?.card == nil))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    if let card = status?.card { QueueCardLine(card: card) }
                }
            }
        case .gap?:
            Text(TranscriptCopy.gapText(item)).font(.caption2).italic().foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
        default:
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if let f = folding {
                        foldedBody(f)
                    } else {
                        MarkdownText(text: item.displayed.text + (item.truncated ? "…" : ""), highlight: hl).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    if let t = item.t, folding == nil { Text(TranscriptCopy.time(t)).font(.caption2).foregroundStyle(.secondary) } // 参与折叠的行：时间在底栏（折叠与展开都与折叠按钮同一行）
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PalmhelmTheme.bubbleAgent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer(minLength: 120)
            }
        }
    }
}

private extension TranscriptItemRow {
    /// 折叠：前几行加渐隐，给「约 N 字」与「展开全文」；展开：全文（已加载的段）；可续读的截断条目始终给「继续加载后文」
    /// （与折叠状态无关，#88 S4 R4）；旧 Bridge 没有令牌的截断条目只说明，不给假按钮。
    /// 折叠底栏的文字：约 N 字（服务端截断时 N 为已显示的字数），并接时间。
    var footerLabel: String {
        [TranscriptFolding.characterLabel(item.text), item.t.map { TranscriptCopy.time($0) }].compactMap { $0 }.joined(separator: " · ")
    }
    @ViewBuilder func foldedBody(_ f: TranscriptRowFolding) -> some View {
        let canContinue = item.truncated && item.continuation != nil
        if f.folded {
            // 预览取前几行且有字数上限，再按显示行 lineLimit 收口（覆盖自动换行的长段落），底部渐隐；底栏「约 N 字 · 时间」+「展开全文」（设计 12 第 3 节）
            MarkdownText(text: TranscriptFolding.previewText(item.displayed.text), highlight: hl).font(.body)
                .lineLimit(TranscriptFolding.foldLines)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .bottom) { LinearGradient(colors: [PalmhelmTheme.bubbleAgent.opacity(0), PalmhelmTheme.bubbleAgent], startPoint: .top, endPoint: .bottom).frame(height: 40).allowsHitTesting(false) }
            HStack(spacing: 8) {
                Text(footerLabel).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: f.expand) { Image(systemName: "chevron.down") }.font(.caption).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle()).accessibilityLabel("展开全文").help("展开全文")
            }
        } else {
            MarkdownText(text: f.expansion?.displayed.text ?? item.displayed.text, highlight: hlExpansion(f.expansion)).font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if item.truncated, item.continuation == nil { // 本地已收到的正文照常可看（R1）；只有续读需要令牌
                Text("旧版 Bridge 不能继续加载后文，以上是已收到的部分。").font(.caption2).foregroundStyle(.secondary)
            }
            if let e = f.expansion {
                if e.needsRefetch { Text("这段内容未能读全，请重新打开会话。").font(.caption2).foregroundStyle(.secondary) }
                else if e.limitReached { Text("已展开到上限，剩余内容请在电脑上查看。").font(.caption2).foregroundStyle(.secondary) }
                else if e.inFlight { Text("正在加载后文…").font(.caption2).foregroundStyle(.secondary) }
                else if e.canLoadMore {
                    HStack(spacing: 8) {
                        Text("已显示 \(e.text.count) 字").font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("继续加载后文", action: f.loadMore).font(.caption).frame(minHeight: 28)
                    }
                }
            } else if canContinue {
                HStack(spacing: 8) {
                    Text("已显示一部分").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("继续加载后文", action: f.loadMore).font(.caption).frame(minHeight: 28)
                }
            }
            // 时间与收起图标同一行：时间在左，图标在右（不再单独占一行）。
            HStack(spacing: 8) {
                if let t = item.t { Text(TranscriptCopy.time(t)).font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button(action: f.collapse) { Image(systemName: "chevron.up") }.font(.caption).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle()).accessibilityLabel("收起全文").help("收起全文")
            }
        }
    }
}

/// 新块淡入（#88 S4）：只对骨架确认之后新增的块生效；减弱动态效果时直接显示。
struct FadeInOnAppear: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(enabled && !shown ? 0 : 1)
            .onAppear {
                guard enabled, !shown else { return }
                if reduceMotion { shown = true } else { withAnimation(.easeOut(duration: 0.25)) { shown = true } }
            }
    }
}

struct TranscriptTopMarker: View {
    let thread: TranscriptThread
    let loadOlder: () -> Void

    var body: some View {
        Group {
            if thread.atStart, !thread.hasRowsAboveWindow {
                Text(TranscriptCopy.startMarker(firstT: thread.items.first?.t)).font(.caption2).foregroundStyle(.secondary)
            } else {
                // 只由点击加载：标记出现（包括打开对话、列表很短时）不自动请求，否则会在没有操作时拉取旧页或上移窗口（O1-341 / O1-344）
                Button(action: loadOlder) {
                    HStack(spacing: 6) {
                        if thread.loadingOlder { ProgressView().controlSize(.mini) }
                        Text(thread.loadingOlder ? TranscriptCopy.loadingOlder : thread.hasRowsAboveWindow ? String(localized: "展开较早的记录") : String(localized: "加载更早的记录")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                .disabled(thread.loadingOlder).accessibilityLabel("加载更早的记录")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

struct TranscriptUnavailableCard: View {
    let status: TranscriptThread.Status
    var reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text({ if case .failed = status { TranscriptCopy.failedTitle } else { TranscriptCopy.unavailableCopy(reason: reason).title } }()).font(.callout.weight(.semibold))
            Text({ if case .failed(let why) = status { why + "。" + TranscriptCopy.unavailableBody } else { TranscriptCopy.unavailableCopy(reason: reason).body } }()).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary.opacity(0.5)))
    }
}
