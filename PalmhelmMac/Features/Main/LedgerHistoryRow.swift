import SwiftUI
import AppKit
import PalmhelmKit

/// 账本一条的展示 / 复制规则（与 iOS 同一份规则；Kit 不由本片改，故两端各一份）。复制源是原 Markdown 源文，折叠只影响显示。
enum LedgerRowText {
    /// 默认预览：超过 8 行或 400 字折叠，只影响显示、不改源文。预算复用 Kit 的 TranscriptFolding（有界扫描）；
    /// 它按 "\n" 数行，所以 CRLF / 单独的 CR 先按换行统一（仅在含 CR 时做一次，复制仍用原文）。
    static func preview(_ text: String) -> (shown: String, isLong: Bool) {
        let basis = text.utf8.contains(0x0D) ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : text
        let shown = TranscriptFolding.previewText(basis)
        return (shown, shown != basis)
    }

    static func copySource(_ text: String) -> String? { text.isEmpty ? nil : text }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "inbox": String(localized: "消息")
        case "outbox": String(localized: "Bridge 回执")
        default: String(localized: "记录")
        }
    }
}

/// 一条历史：来源 · 时间 + 显式「复制」（右键同一动作），正文按 Markdown 渲染并保留文字选择（⌘C 仍复制选区），长条目折叠 +「阅读」逐页。
/// `isCurrent` 在复制 / 阅读前复核（scope 仍有效且条目仍属当前页）；只读设备也可复制。
/// 复制 / 阅读 / 翻页前的内容复核（与 iOS 同一规则）：打开时捕获的 scope 仍等于当前 scope，且该 id 的条目仍在当前页、正文未被替换。
enum LedgerRowGuard {
    static func permits(opened: LedgerScope?, now: LedgerScope?, captured: TargetHistoryRow, current: TargetHistoryRow?) -> Bool {
        guard let opened, opened == now, let current, current.id == captured.id, current.text == captured.text else { return false }
        return true
    }
}

/// 阅读页的整篇切页结果：同一正文只构建一次，翻页 / 复制反馈不重切（引用语义、不被观察）。
final class LedgerDocumentMemo {
    private var text: String?
    private var cached: ReaderDocument?
    func document(for text: String) -> ReaderDocument {
        if let cached, self.text == text { return cached }
        let fresh = TranscriptReaderPaging.document(for: text, markdown: true)
        self.text = text; cached = fresh
        return fresh
    }
}

struct TargetHistoryRowView: View {
    let item: TargetHistoryRow
    /// 消息状态：由账本入口按当前会话事实求出（`session.ledgerMessageStatus`）；视图不再自行套一套“独立求值”规则。nil = 不显示。
    let status: MessageStatus?
    /// 由账本入口接线（打开时捕获的 scope + 当前页同 id 条目的正文）；没有默认值，不能绕过。
    let isCurrent: (TargetHistoryRow) -> Bool
    @State private var copied = false
    @State private var reading = false

    private var meta: String {
        let time = item.t.map { Date(timeIntervalSince1970: Double($0) / 1000).shown(date: .abbreviated, time: .shortened) }
        return [LedgerRowText.sourceLabel(item.source), time].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let preview = LedgerRowText.preview(item.text)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(meta).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if LedgerRowText.copySource(item.text) != nil {
                    Button(copied ? String(localized: "已复制") : String(localized: "复制"), action: copy)
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "复制消息正文，\(meta)"))
                        .accessibilityIdentifier("ledger.copy")
                }
            }
            MarkdownText(text: preview.shown).font(.callout).textSelection(.enabled)
            if preview.isLong {
                HStack(spacing: 10) {
                    Text("已折叠").font(.caption2).foregroundStyle(.secondary)
                    Button("阅读") { if isCurrent(item) { reading = true } }.controlSize(.small)
                }
            }
            if let ms = status {
                if let card = ms.card { QueueCardLine(card: card, alignment: .leading) } else { Text(ms.label).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .contextMenu { Button("复制消息正文", action: copy).disabled(LedgerRowText.copySource(item.text) == nil) }
        .sheet(isPresented: $reading) { LedgerTextReader(item: item, isCurrent: isCurrent, onClose: { reading = false }) }
    }

    private func copy() {
        guard isCurrent(item), let text = LedgerRowText.copySource(item.text) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

/// 账本条目的本地逐页阅读：正文已在页中，只做本地分页与渲染，不联网；一次只挂当前页，窗口宽度变化只重排当前页。
struct LedgerTextReader: View {
    let item: TargetHistoryRow
    let isCurrent: (TargetHistoryRow) -> Bool
    let onClose: () -> Void
    @State private var index = 0
    @State private var copied = false
    @State private var memo = LedgerDocumentMemo()

    var body: some View {
        let valid = isCurrent(item) // 只供失效监听 / 显示；动作内另行复核
        let actions = LedgerReaderActions(item: item, isCurrent: isCurrent, onClose: onClose)
        let doc = memo.document(for: item.text)
        let last = max(0, doc.pages.count - 1)
        let i = min(max(0, index), last)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("全文").font(.title3.weight(.semibold))
                Spacer()
                Button(copied ? "已复制" : "复制") {
                    guard let t = actions.copyText() else { return } // 失效：动作内复核失败即关闭，无动作
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string); copied = true
                }
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                switch doc.pages[i].content {
                case .plain(let s, _): Text(s).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                case .markdown(let blocks): PalmhelmMarkdownPageText(blocks: blocks, codeBackground: PalmhelmTheme.codeBlock).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .id(i)
            HStack {
                Button { if let n = actions.page(from: i, delta: -1, count: doc.pages.count) { index = n } } label: { Image(systemName: "chevron.left") }.disabled(i == 0).accessibilityLabel("上一页")
                Spacer()
                Text("\(i + 1) / \(doc.pages.count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { if let n = actions.page(from: i, delta: 1, count: doc.pages.count) { index = n } } label: { Image(systemName: "chevron.right") }.disabled(i >= last).accessibilityLabel("下一页")
            }
        }
        .padding(14)
        .frame(minWidth: 460, minHeight: 360)
        // scope 变化 / 条目被替换或删除：关闭，不再展示或翻旧文本
        .onChange(of: valid) { _, ok in if !ok { onClose() } }
        .onAppear { if !valid { onClose() } }
    }
}

/// 阅读页按钮的动作：每次执行当刻重新复核 `isCurrent(item)`（A1-003）。body 里算出的 valid 只供失效监听与显示，不作动作授权——
/// 旧按钮闭包在 scope / 正文变化之后、下一次 body / onChange 关闭之前到达，也必须拒绝：返回 nil 并关闭阅读页，不翻页、不写剪贴板。
struct LedgerReaderActions {
    let item: TargetHistoryRow
    let isCurrent: (TargetHistoryRow) -> Bool
    let onClose: () -> Void

    /// 翻页：返回新页下标；失效 / 越界返回 nil（失效时已关闭）。
    func page(from index: Int, delta: Int, count: Int) -> Int? {
        guard isCurrent(item) else { onClose(); return nil }
        let next = index + delta
        return (0..<max(1, count)).contains(next) ? next : nil
    }

    /// 复制：返回要写入剪贴板的原文；失效或无内容返回 nil（失效时已关闭）。
    func copyText() -> String? {
        guard isCurrent(item) else { onClose(); return nil }
        return LedgerRowText.copySource(item.text)
    }
}
