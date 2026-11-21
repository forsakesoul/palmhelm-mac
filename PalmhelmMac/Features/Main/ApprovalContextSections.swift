import SwiftUI
import PalmhelmKit

/// 审批卡的「起因 / 改动」两段（设计稿 T2b）：卡片出现时按需拉详情，不阻塞「允许一次 / 拒绝」。
/// 旧 Bridge 的详情没有这两个字段 → 整段不显示；起因取不到 → 「起因没取到 · 重试」。
struct ApprovalContextSections: View {
    @Environment(MacSession.self) private var session
    let approval: ApprovalView
    @State private var detail: ApprovalDetail?
    @State private var loadFailed = false
    @State private var causeOpen = true
    @State private var changeOpen = true
    @State private var noteExpanded = false

    private static let fileTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    private var change: ApprovalChange? { detail?.body?.change }
    private var cause: ApprovalCause? { detail?.cause }
    private var loading: Bool { detail == nil && !loadFailed }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if loading || loadFailed || cause != nil { causeSection }
            if change != nil || (loading && Self.fileTools.contains(approval.toolName)) { changeSection }
        }
        .task(id: approval.id) { await load() }
    }

    // MARK: 起因

    private var causeSection: some View {
        DisclosureGroup(isExpanded: $causeOpen) {
            VStack(alignment: .leading, spacing: 8) {
                if loading {
                    skeleton(0.7); skeleton(0.45)
                } else if let c = cause, c.isAvailable, c.prompt != nil || c.note != nil {
                    if let p = c.prompt {
                        VStack(alignment: .leading, spacing: 2) {
                            // 相对时间只在这个小叶子里按分钟刷新，不让整张卡随时钟重画。
                            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                                Text(ApprovalContextCopy.promptLine(p, now: ctx.date)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(p.textDisplayed).font(.body).textSelection(.enabled)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(PalmhelmTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let n = c.note {
                        Text(n.textDisplayed).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .lineLimit(noteExpanded ? nil : 3)
                        // 是否超过三行取决于宽度与字号，不按字数猜：非空 note 一律给展开/收起（A1-130 F1）
                        Button(noteExpanded ? ApprovalContextCopy.collapse : ApprovalContextCopy.expand) { noteExpanded.toggle() }
                            .font(.caption).tint(PalmhelmTheme.accent).frame(minHeight: 28).contentShape(Rectangle())
                    }
                } else {
                    HStack {
                        Text(ApprovalContextCopy.causeUnavailable).font(.body).foregroundStyle(PalmhelmTheme.warn)
                        Spacer()
                        Button(ApprovalContextCopy.retry) { Task { await load() } }.font(.body).tint(PalmhelmTheme.accent).frame(minHeight: 28)
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            sectionLabel(ApprovalContextCopy.causeTitle)
        }
        .tint(Color(nsColor: .secondaryLabelColor))
    }

    // MARK: 改动

    private var changeSection: some View {
        DisclosureGroup(isExpanded: $changeOpen) {
            if let c = change { changeBlock(c) } else { skeleton(0.8); skeleton(0.6) }
        } label: {
            sectionLabel(change.map { "\(ApprovalContextCopy.changeTitle) · \($0.path)" } ?? ApprovalContextCopy.changeTitle)
        }
        .tint(Color(nsColor: .secondaryLabelColor))
    }

    private func changeBlock(_ c: ApprovalChange) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ApprovalContextCopy.changeHeader(c, toolName: approval.toolName)).font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if c.hidden == true {
                Text(c.pathDisplayed).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).padding(10)
            } else {
                ForEach(Array(c.hunks.enumerated()), id: \.offset) { i, h in
                    if i > 0 { Divider().padding(.vertical, 2) }
                    if let old = h.oldDisplayed, !old.isEmpty { hunkLines(old, sign: "−", tint: PalmhelmTheme.bad) }
                    if !h.new.isEmpty { hunkLines(h.newDisplayed, sign: "+", tint: PalmhelmTheme.ok) }
                }
            }
            if c.truncated {
                Divider()
                Text(ApprovalContextCopy.changeTruncated).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PalmhelmTheme.card2, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 2)
    }

    // 每侧合成一个可选中的 Text（逐行前缀 − / +）：拆成多个 HStack 时长按无法进入选择，读屏也只念符号（A1-130 F2/F3）。
    private func hunkLines(_ text: String, sign: String, tint: Color) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var body = AttributedString()
        for (i, line) in lines.enumerated() {
            var mark = AttributedString(sign + " "); mark.foregroundColor = tint
            body += mark; body += AttributedString(String(line))
            if i < lines.count - 1 { body += AttributedString("\n") }
        }
        return Text(body).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(tint.opacity(0.10))
            .accessibilityLabel((sign == "+" ? String(localized: "新增：") : String(localized: "删除：")) + text)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle()) // 点按区不少于 44pt
    }

    private func skeleton(_ w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(PalmhelmTheme.card2).frame(height: 12).frame(maxWidth: 260 * w, alignment: .leading)
            .accessibilityLabel("加载中")
    }

    private func load() async {
        loadFailed = false
        if let d = await session.approvalDetail(approval.id) { detail = d } else { loadFailed = true }
    }
}
