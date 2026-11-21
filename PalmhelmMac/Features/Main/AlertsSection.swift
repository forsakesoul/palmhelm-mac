import SwiftUI
import PalmhelmKit

/// 面板 / 任务这类长回执里常带行内 Markdown；解析失败就按原文显示。
func inlineMarkdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// 提醒列表（工具栏「!」popover 里）：当前可操作的超时提醒与可恢复失败在前，没有恢复入口的拒绝在后；每条带相对时间。只显示 72 小时内、未处理的项（ReminderRules）；可恢复失败在恢复成功前一直可达。
/// 不按文本合并、不提供清除、不删原始数据。侧栏收件箱不再显示提醒。
struct AlertsSection: View {
    @Environment(MacSession.self) private var session

    var body: some View {
        let reminders = session.blockedReminders
        let alerts = AlertsPresentation.ordered(session.inboxAlerts)
        VStack(alignment: .leading, spacing: 8) {
            Text("提醒 · 不计数").font(.headline)
            if reminders.isEmpty && alerts.isEmpty { Text("没有提醒。").font(.caption).foregroundStyle(.secondary) }
            ForEach(reminders) { ReminderCard(item: $0) }
            ForEach(alerts) { AlertRow(alert: $0) }
        }
    }
}

/// 工具栏「!」点开的原生 popover。
struct AlertsPopover: View {
    var body: some View {
        ScrollView { AlertsSection().padding(14) }
            .frame(width: 400, height: 480)
    }
}

/// 相对时间（缺失就不显示）。
private func relativeTime(_ ms: Int?) -> Text? {
    ms.map { Text(Date(timeIntervalSince1970: Double($0) / 1000), format: Date.relativeStyle(.numeric)) }
}

private struct ReminderCard: View {
    @Environment(MacSession.self) private var session
    let item: HistoryItem
    @State private var confirming = false

    // 本次发送的编号与在途状态在 Session（按稳定提醒 id）：卡重建、侧栏关闭重开后仍能恢复，迟到的回执照常归到这张卡。
    private var send: MacSession.ReminderSend { session.reminderSend(item) }
    private var status: ReminderStatus { session.reminderStatus(item) }
    // 只有「当前」的提醒才能重置；历史 / 待核只给原因，入口同步禁用。
    private var blocker: String? { status.allowsReset ? session.resetOccupancyBlocker() : (status.label ?? String(localized: "不是当前状态")) }

    private var resultText: String? {
        if send.interrupted { return String(localized: "连接中断，结果未知（没有自动重发）；确认后可再次操作") }
        if let why = send.blocked { return String(localized: "解除占用没发出去 · \(why)") }
        guard let id = send.sendId, let o = session.outcome(of: id) else { return nil }
        if let e = o.error { return String(localized: "解除占用没发出去 · \(e)") }
        return (o.display ?? o.reply).map(ReceiptText.summary) ?? String(localized: "已发送，等待 Bridge 回执…")
    }

    // Bridge 文案以「[目标名] 」开头；标题已带目标名，正文去掉前缀；目标名优先取该前缀（与「重置占用 X」指令一致）。
    private var parsed: (name: String, text: String) {
        if let m = item.text.wholeMatch(of: /\[([^\]]+)\]\s*(.*)/.dotMatchesNewlines()) { return (String(m.1), String(m.2)) }
        return (item.target?.projectName ?? String(localized: "目标"), item.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // 等待分钟只在这个叶子里按分钟刷新，不让整张提醒卡随时钟重画。
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    Text(status.label.map { "\(parsed.name) · \($0)" } ?? "\(parsed.name) · " + (session.waitedMinutes(item, at: ctx.date).map { String(localized: "已等待 \($0) 分钟") } ?? String(localized: "等待已超过 10 分钟"))).font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 4)
                relativeTime(item.t)?.font(.caption2).foregroundStyle(.secondary)
            }
            Text(parsed.text).font(.caption).foregroundStyle(.secondary)
            Text("agent 仍在终端等待你处理，Bridge 解除占用不会替你回答。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("停止跟踪并解除占用…") { confirming = true }.controlSize(.small).disabled(send.busy || blocker != nil)
                if send.busy { Text("提交中…").font(.caption).foregroundStyle(.secondary) }
            }
            if let blocker { Text(blocker).font(.caption2).foregroundStyle(PalmhelmTheme.warn) } // 入口同步给原因，不是默默禁用
            if let resultText { Text(inlineMarkdown(resultText)).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Text("不会停止终端；可能已执行，不会自动重发旧输入。尚未发出的排队消息仍保留，解除后可能继续派发。").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(PalmhelmTheme.card2.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("停止跟踪 \(parsed.name) 的在途消息并解除占用？", isPresented: $confirming, titleVisibility: .visible) {
            Button("解除占用", role: .destructive) { Task { await session.resetOccupancy(for: item, name: parsed.name) } }
            Button("取消", role: .cancel) {}
        } message: { Text("仅当这条提醒仍对应当前受阻消息时执行。不会停止终端，也不会撤销已经执行的操作；可能已执行，不会自动重发旧输入；尚未发出的队列仍保留，解除后可能继续派发。") }
    }
}

private struct AlertRow: View {
    @Environment(MacSession.self) private var session
    let alert: MacSession.InboxAlert
    @State private var note: LText?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(inlineMarkdown(alert.text)).font(.caption).textSelection(.enabled)
                Spacer(minLength: 4)
                relativeTime(alert.t)?.font(.caption2).foregroundStyle(.secondary)
            }
            if let id = alert.restoreSendId {
                // 未归属：没有目标的发送留下的输入快照；只在这里显式点击才恢复，恢复到当前选中线程的输入框，不会自动投递
                HStack {
                    Button("恢复到输入框") { note = session.restoreUnattributed(id) }.controlSize(.small)
                    Text("未归属的内容会放进当前所选线程的输入框").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let note { Text(note.text).font(.caption2).foregroundStyle(PalmhelmTheme.warn) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(PalmhelmTheme.card2.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
