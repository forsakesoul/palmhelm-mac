import SwiftUI
import PalmhelmKit

// 用量页「账户额度」卡（O1-368）：上半部是账户摘要列表（每账户两行），下半部是所选账户的真实窗口。
// 宽窗固定 416pt（fixedHeight），窄窗自然高度。默认选中已用百分比最高的有效订阅账户；选择按 provider + accountId 保持。
// 倒计时与过期判断由 TimelineView 的本地时钟驱动（不做后台网络轮询）。旧快照始终保留并标注采集时间。
struct AccountsSection: View {
    @Environment(MacSession.self) private var session
    /// 宽窗固定高度；窄窗传 nil 使用自然高度。
    var fixedHeight: CGFloat? = nil

    var body: some View {
        if let r = session.visibleAccounts {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                let selected = AccountSelection.resolve(selectedKey: session.usageAccountKey, accounts: r.accounts, now: ctx.date)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("账户额度").font(.headline)
                        Text("共 \(r.accounts.count) 个").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        RefreshButton(loading: session.accountsLoading, help: String(localized: "刷新额度"), label: String(localized: "刷新额度")) { Task { await session.loadAccounts(refresh: true) } }
                    }
                    if r.throttled == true { Text(QuotaCopy.throttledNote).font(.caption2).foregroundStyle(.secondary) }
                    if r.accounts.isEmpty {
                        Text("还没有账户信息").font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        // 摘要列表：可滚动，最高 140pt；溢出只在列表内部滚动
                        let summaries = VStack(alignment: .leading, spacing: 4) {
                            ForEach(r.accounts) { a in
                                AccountSummaryRow(account: a, now: ctx.date, connected: session.link == .connected, selected: selected.map { AccountSelection.key($0) == AccountSelection.key(a) } ?? false) {
                                    session.usageAccountKey = AccountSelection.key(a)
                                }
                            }
                        }
                        // 少量账户时不预留滚动区（避免空白）；超过 3 个才限制高度并在列表内滚动
                        if r.accounts.count > 3 {
                            ScrollView { summaries }.frame(maxHeight: 140)
                        } else {
                            summaries
                        }
                        Divider()
                        // 所选账户的全部真实窗口：可滚动主体，状态与采集时刻在底部
                        if let s = selected {
                            ScrollView { AccountDetail(account: s, now: ctx.date, connected: session.link == .connected, refreshError: session.accountsError?.text) }
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    Text(QuotaCopy.footnote).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: fixedHeight == nil ? nil : .infinity, alignment: .topLeading)
                .card()
                .frame(height: fixedHeight)
            }
        } else {
            // 没有账户快照：卡位不变，卡内说明加载 / 失败 / 未连接（O1-368 追加）
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("账户额度").font(.headline)
                    Spacer()
                    RefreshButton(loading: session.accountsLoading, help: String(localized: "刷新额度"), label: String(localized: "刷新额度")) { Task { await session.loadAccounts(refresh: true) } }
                }
                if let e = session.accountsError {
                    Text("账户额度加载失败 · \(e.text)").font(.caption).foregroundStyle(PalmhelmTheme.bad)
                    Button("重试") { Task { await session.loadAccounts(refresh: true) } }.controlSize(.small).disabled(session.accountsLoading)
                } else if session.link == .connected {
                    SkeletonLines(count: 3)
                } else {
                    Text("未连接这台 Mac，连上后自动加载。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: fixedHeight == nil ? nil : .infinity, alignment: .topLeading)
            .card()
            .frame(height: fixedHeight)
        }
    }
}

/// 摘要行（两行）：第一行「服务商 · 套餐 · 标签」；第二行「最紧窗口 · 已用 · 重置」。账户状态异常（stale / error 等）优先于旧窗口百分比，
/// 失败不会被旧缓存掩盖（A1-194 R3）。AX 标签包含第二行的全部事实。
private struct AccountSummaryRow: View {
    let account: AccountSnapshot
    let now: Date
    let connected: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let a = QuotaCopy.displayAccount(account, now: now)
        let windows = QuotaWindowPolicy.windows(of: a)
        let tight = a.status == "ok" ? windows.filter { !QuotaCopy.windowExpired($0, now: now) && $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) } : nil
        let note = QuotaCopy.note(a, now: now, connected: connected, refreshError: nil, observedText: AccountDetail.timeText)
        let line2: String = {
            if let note { return note }
            if let tight { return "\(QuotaCopy.shortWindowTitle(tight)) · \(QuotaCopy.usedText(tight)) · \(QuotaCopy.resetText(tight, now: now))" }
            return String(localized: "不适用订阅窗口")
        }()
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(QuotaCopy.providerTitle(a.provider)).font(.subheadline.weight(.semibold))
                    Text((a.provider == "claude" ? "· " : "") + QuotaCopy.planTitle(a)).font(.caption).foregroundStyle(.secondary)
                    if let label = a.label { Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                }
                Text(line2)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(note != nil ? PalmhelmTheme.warn : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? PalmhelmTheme.card2 : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([QuotaCopy.providerTitle(a.provider), a.label, QuotaCopy.planTitle(a), line2, selected ? String(localized: "已选中") : nil].compactMap { $0 }.joined(separator: DisplayList.separator))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 进度条：主题 accent 填充（正常）；窗口已重置（过期）时改为次要色并弱化。自绘，不依赖系统样式对 tint 的处理（A1-194 R1）。
struct UsageBar: View {
    let fraction: Double
    var expired = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(PalmhelmTheme.card2)
                Capsule().fill(expired ? Color.secondary.opacity(0.5) : PalmhelmTheme.accent)
                    .frame(width: g.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// 所选账户详情：全部真实窗口（白名单内）；没有窗口时说明原因，不画假进度条。每窗口一行：窗口名 · 重置 · 百分比，下面是进度条。
/// 每窗口的来源与采集时刻放在 help 与 AX 中（不删除，A1-194 R3）。
private struct AccountDetail: View {
    let account: AccountSnapshot
    let now: Date
    let connected: Bool
    let refreshError: String?

    var body: some View {
        let a = QuotaCopy.displayAccount(account, now: now)
        let windows = QuotaWindowPolicy.windows(of: a)
        VStack(alignment: .leading, spacing: 8) {
            if let note = QuotaCopy.note(a, now: now, connected: connected, refreshError: refreshError, observedText: Self.timeText) {
                Text(note).font(.caption).foregroundStyle(PalmhelmTheme.warn)
            }
            if windows.isEmpty {
                Text(["claude", "codex", "agy", "qoder"].contains(a.provider) ? String(localized: "暂无可显示的订阅窗口：等待新读数，或此账户不提供订阅窗口。") : String(localized: "不适用订阅窗口。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(windows) { w in
                let expired = QuotaCopy.windowExpired(w, now: now)
                let evidence = QuotaCopy.windowEvidence(w, time: Self.timeText)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(QuotaCopy.shortWindowTitle(w)).font(.caption.weight(.semibold))
                        Text(QuotaCopy.resetText(w, now: now)).font(.caption2).foregroundStyle(expired ? PalmhelmTheme.warn : .secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(QuotaCopy.usedText(w)).font(.caption.monospacedDigit())
                    }
                    if let f = QuotaCopy.fraction(w) { UsageBar(fraction: f, expired: expired) }
                }
                .help(evidence ?? "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(QuotaCopy.windowTitle(w))，\(QuotaCopy.usedText(w))，\(QuotaCopy.resetText(w, now: now))\(evidence.map { "，\($0)" } ?? "")")
            }
            if let t = a.observedAt { Text("采集于 \(Self.timeText(t))").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static func timeText(_ ms: Int) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).shown(date: .omitted, time: .shortened)
    }
}
