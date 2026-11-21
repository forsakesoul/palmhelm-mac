import SwiftUI
import PalmhelmKit

// 发送时机的纯视图（#23）：只接收值，不读 Session；行为由调用方决定，截图测试直接构造这些视图。

/// 发送钮与下拉箭头。箭头只在工作中出现；菜单两项的可用性与灰掉的原因来自 SendTimingRules。
struct SendControls: View {
    let busy: Bool
    let canSubmit: Bool
    let menuShown: Bool
    let steer: SteerAvailability
    /// 直达线程：立即插入只在目标声明 nativeSteer 时可用（缺省灰掉并写原因）。
    var direct = false
    var nativeSteer = false
    /// 直达线程：立即发送三态（nil 隐藏、false 灰显带原因、true 可选）；只来自目标自己的 nativeSendNow。
    var nativeSendNow: Bool? = nil
    var queueDeadline = false
    var onDeadline: ((Int) -> Void)? = nil
    let onPrimary: () -> Void
    let onChoose: (SendMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(busy ? String(localized: "发送中…") : String(localized: "发送")) { onPrimary() }
                .buttonStyle(.palmhelmProminent).disabled(!canSubmit)
            if menuShown {
                Menu {
                    ForEach(SendTimingRules.menu(steer: steer, direct: direct, nativeSteer: nativeSteer, nativeSendNow: nativeSendNow, queueDeadline: queueDeadline), id: \.choice) { item in
                        Button(Self.title(item, direct: direct)) {
                            if let ttl = item.choice.queueTTLSeconds { onDeadline?(ttl) } else { onChoose(item.choice.mode) }
                        }
                        .disabled(!item.enabled || !canSubmit)
                        .help(item.disabledReason ?? "")
                    }
                } label: { Image(systemName: "chevron.down").frame(width: 16) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("发送方式")
            }
        }
    }

    /// 灰掉的项写明原因（不只靠悬停提示）。
    /// 直达菜单不写 ⌘↩：⌘↩ 对直达只是普通排队（立即插入只从菜单显式选择）。
    static func title(_ item: SendMenuItem, direct: Bool = false) -> String {
        let base = item.choice == .steerNow ? (direct ? String(localized: "立即插入当前回合") : String(localized: "立即插入当前回合 ⌘↩")) : (item.choice == .queueAfterTurn ? String(localized: "本轮结束后发送 ↩") : item.choice.title)
        guard !item.enabled, let reason = item.disabledReason else { return base }
        return "\(base) — \(reason)"
    }
}

/// 状态语气：琥珀色只留给「排队中」；已并入是成功态；已撤回是次要态。
@MainActor
enum QueuedTone: Equatable {
    case queued, merged, muted

    var color: Color {
        switch self {
        case .queued: PalmhelmTheme.warn
        case .merged: PalmhelmTheme.ok
        case .muted: .secondary
        }
    }

    static func of(reason: String?) -> QueuedTone {
        switch reason {
        case "withdrawn", "queue_expired", "queue_expired_uncertain": .muted
        case "merged": .merged
        default: .queued
        }
    }
}

/// 排队消息的状态行与操作（撤回、改为立即插入 / 立即发送）；灰显项写明原因，失败提示只是文字。
struct QueuedStatusView: View {
    let label: String
    let tone: QueuedTone
    let items: [QueuedActionItem]
    let note: String?
    let onWithdraw: () -> Void
    let onPromote: () -> Void
    var onPromoteSendNow: () -> Void = {}
    var onResend: () -> Void = {}
    /// 排队卡（#89 S3）：服务端给出扩展组时以卡为准（标题 + 说明，文案来自 Kit）；否则沿用 label。
    var card: QueueStatusCard? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                statusText
                button(.resend, onResend)
                button(.withdraw, onWithdraw)
                button(.promote, onPromote)
                button(.promoteSendNow, onPromoteSendNow)
            }
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var statusText: some View {
        if let card {
            QueueCardLine(card: card)
        } else {
            Text(label).font(.caption2).foregroundStyle(tone.color)
                .accessibilityLabel("消息状态：\(label)")
        }
    }

    @ViewBuilder private func button(_ action: QueuedAction, _ perform: @escaping () -> Void) -> some View {
        if let item = items.first(where: { $0.action == action }) {
            Button(item.title, action: perform).buttonStyle(.link).font(.caption2).disabled(!item.enabled).help(item.disabledReason ?? "")
        }
    }
}

/// #89 排队卡：位置或阶段（标题）加原因、观察时间与排队期限（说明）。文案只来自 Kit 的 QueueStatusPresentation；无值不留空行，AX 组合含期限。
struct QueueCardLine: View {
    let card: QueueStatusCard
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(card.title).font(.caption2).foregroundStyle(card.uncertain ? PalmhelmTheme.warn : .secondary)
            if let detail = card.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            if let deadline = card.deadlineText { Text(deadline).font(.caption2).foregroundStyle(.secondary) } // 服务端期限（Kit 文案）；不按本地时钟改状态
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("消息状态：" + [card.title, card.detail, card.deadlineText].compactMap { $0 }.joined(separator: "，"))
        .accessibilityIdentifier("queue.status")
    }
}

/// 回执被排队卡覆盖（#89 S3）：只看实际渲染出卡的指令行；`cardShown` 由父级按有效阶段（tracker 之后）判断，缺省按原始指令。旧 Bridge 指令不覆盖，回执保留。
enum QueueCardCoverage {
    static func visible(_ rows: [ThreadRow], cardShown: (ApiCommand) -> Bool = { QueueStatusPresentation.rendersCard($0, folded: false) }) -> [ThreadRow] {
        let covered = Set(rows.compactMap { row -> String? in
            if case .command(let c) = row, cardShown(c) { return c.key }
            return nil
        })
        guard !covered.isEmpty else { return rows }
        return rows.filter { row in
            if case .receipt(let r) = row { return !QueueStatusPresentation.receiptCovered(uuid: r.uuid, replyTo: r.replyTo, coveredKeys: covered) }
            return true
        }
    }
}

/// 系统回执：居中小字，标明 Palmhelm；不冒充 agent 消息（O1-327）。
struct SystemReceiptLine: View {
    let summary: String
    var body: some View {
        Text("Palmhelm · \(summary)").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center).textSelection(.enabled)
    }
}

/// 撤回的原文没有直接回填（输入框已有内容）：只提示，替换或忽略由用户决定（O1-327）。附件缺失时替换不可用。
struct WithdrawnOfferBanner: View {
    let canReplace: Bool
    let onReplace: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text("刚撤回的消息还没放回输入框：输入框已有内容，没有覆盖。").font(.caption).foregroundStyle(.secondary)
            Button("放回输入框（替换当前内容）", action: onReplace).buttonStyle(.link).font(.caption).disabled(!canReplace)
            Button("忽略", action: onDismiss).buttonStyle(.link).font(.caption)
            Spacer()
        }
    }
}

/// 身份暂停：说明 + 「确认是同一个会话，恢复」（只读、离线、名字不合法时禁用，O1-332 B）。
struct IdentityPauseBanner: View {
    let canRecover: Bool
    let onRecover: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(ReceiptText.identityPauseCopy).font(.caption).foregroundStyle(PalmhelmTheme.warn)
            Button("确认是同一个会话，恢复", action: onRecover).buttonStyle(.link).font(.caption).disabled(!canRecover)
            Spacer()
        }
    }
}

