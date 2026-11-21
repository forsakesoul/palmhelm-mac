import SwiftUI
import PalmhelmKit

// 统一侧栏（M1 / M2）：顶部「收件箱｜空间」自绘分段；收件箱 = 需要你处理（有才出现）→ 工作中（提醒在工具栏的「!」popover，不占侧栏）；空间 = 本机按工作区列全部 agent。
// 短审批在卡上直接办；提问 / 计划 / 长命令点「回答… / 查看计划 / 查看详情」到右侧工作区完整显示（草稿在 Session，不丢）。
struct InboxSidebar: View {
    @Environment(MacSession.self) private var session
    @Environment(BridgeEngine.self) private var engine
    @Environment(EngineSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var flashing: InboxFocusFlash?
    /// 测试钩子：每消费一次脉冲回报一次（视图树的无障碍内容在测试里读不到，用它证明首次挂载就消费了）。
    var onConsumed: (MacSession.InboxFocus) -> Void = { _ in }
    private func flash(_ f: MacSession.InboxFocus, _ anim: Animation?) {
        withAnimation(anim) { flashing = InboxFocusFlash(target: f.target, serial: f.serial) }
        Task {
            try? await Task.sleep(for: .seconds(f.target == .top ? MacSession.flashSeconds.top : MacSession.flashSeconds.request))
            if flashing?.serial == f.serial { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { flashing = nil } } // 只清自己这一次；带一次淡出
        }
    }

    private func consumeFocus(_ proxy: ScrollViewProxy) {
        guard let f = session.takeInboxFocus() else { return }
        let anim: Animation? = reduceMotion ? nil : .easeOut(duration: 0.2)
        switch f.target {
        case .request(let id): withAnimation(anim) { proxy.scrollTo("req-\(id)", anchor: .center) }
        case .top: withAnimation(anim) { proxy.scrollTo("inbox-top", anchor: .top) }
        }
        flash(f, anim)
        onConsumed(f)
    }

    private var lensBinding: SwiftUI.Binding<ThreadLens> {
        Binding(get: { session.lens }, set: { v in
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { session.lens = v }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            PalmhelmSegmented(options: ThreadLens.allCases.map { ($0, $0.label) }, selection: lensBinding)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            if flashing?.target == .top, session.inboxModel.requests.isEmpty { // 有待答但没能打开（离线等）时不说「没有」，由导航说明讲原因
                // 铃铛点了但没有待答：一行明确提示（约 2 秒后淡出；减少动态效果时直接出现再消失）
                Text(MacSession.noPendingText).font(.callout.weight(.medium)).foregroundStyle(PalmhelmTheme.onAccent)
                    .padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(PalmhelmTheme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .transition(reduceMotion ? .identity : .opacity)
                    .accessibilityLabel(MacSession.noPendingText)
            }
            if let n = session.navNotice {
                Text(n.text).font(.caption).foregroundStyle(PalmhelmTheme.warn).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 6)
            }
            if let note = session.lastDecisionNote {
                Text(note.text).font(.caption).foregroundStyle(session.lastDecisionWarn ? PalmhelmTheme.warn : PalmhelmTheme.ok).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 6).palmhelmReveal()
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        Color.clear.frame(height: 0).id("inbox-top")
                        recommendation
                        if session.lens == .inbox { InboxContent() } else { SpacesContent() }
                    }
                    .padding(.bottom, 10)
                    // 同步骨架显示期间，底下的内容只保留布局占位：不绘制、不进辅助功能树、不接收点按（谓词与下面的 overlay 完全相同），骨架才是一个独立加载元素。
                    .opacity(session.state == nil && session.link == .connecting ? 0 : 1)
                    .allowsHitTesting(!(session.state == nil && session.link == .connecting))
                    .accessibilityHidden(session.state == nil && session.link == .connecting)
                }
                .overlay(alignment: .topLeading) { // 同步中的列表骨架铺满视口（不进滚动内容，不造假滚动高度）
                    if session.state == nil, session.link == .connecting {
                        SkeletonRows(label: String(localized: "正在同步"), fill: true, style: .sidebar).padding(.horizontal, 12).allowsHitTesting(false)
                    }
                }
                .onChange(of: session.selectedRequest) { _, id in
                    if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("req-\(id)", anchor: .center) } } // 从刘海 / 提醒点进来：定位到这张卡
                }
                .onAppear { if let id = session.selectedRequest { proxy.scrollTo("req-\(id)", anchor: .center) } }
                .onChange(of: session.inboxFocus) { _, _ in consumeFocus(proxy) } // 铃铛：滚到目标并短暂高亮（侧栏已开、目标没变时也会触发——脉冲带递增的 serial）
                .onAppear { consumeFocus(proxy) } // 侧栏挂载前脉冲就到了（窄窗收起、用量页）：挂载时补消费一次
            }
            Divider()
            HStack(spacing: 6) {
                StatusDot(kind: phase == .connected ? .ok : phase.isTransitional ? .warn : .off)
                Text(connectionLine).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .help(connectionHelp)
        }
        .background(PalmhelmTheme.card2.opacity(0.45))
        .environment(\.inboxFlash, flashing)
    }

    @ViewBuilder private var recommendation: some View {
        if let rec = session.lensRecommendation {
            HStack(spacing: 6) {
                Button { session.acceptRecommendation() } label: {
                    HStack(spacing: 4) { Text(LensPreferenceStore.bannerText(rec)).font(.caption2); Text("切换").font(.caption2.weight(.semibold)).foregroundStyle(PalmhelmTheme.accent) }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button("忽略") { session.ignoreRecommendation() }.font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(8).background(PalmhelmTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 12)
            .id(session.lensRecommendationSignature)
            .onAppear { session.markRecommendationShown() }
        }
    }

    private var phase: ConnectionPhase { currentPhase(engine, settings, session) }
    private var connectionLine: String {
        let link = phase.label
        guard let pf = engine.portFile else { return String(localized: "这台 Mac \(link)") }
        let reach: String = switch engine.reach {
        case .loopback: String(localized: "回环 http")
        case .tailscale: "Tailscale \(pf.transport)"
        case .lan: String(localized: "局域网 \(pf.transport)")
        case nil: ""
        }
        return String(localized: "这台 Mac \(link) · \(reach)")
    }
    private var connectionHelp: String {
        var lines: [String] = []
        if let pf = engine.portFile {
            lines.append(engine.reach == .loopback ? String(localized: "回环监听：只有这台 Mac 能连") : engine.reach == .lan && pf.transport == "https" ? String(localized: "局域网 https · 证书已固定 · 会尝试 Bonjour 广播") : String(localized: "手机需在同一网络"))
            if let spki = pf.tls?.spkiSha256, let short = SPKI.shortFingerprint(spkiSha256: spki) { lines.append(String(localized: "短指纹 \(short)")) }
        }
        if session.link != .connected, let t = session.lastSync { lines.append(String(localized: "目标状态为上次同步 \(t.shown(date: .omitted, time: .shortened)) 的缓存")) }
        return lines.joined(separator: "\n")
    }
}

@MainActor private func sectionHeader(_ title: String, count: Int? = nil, note: String? = nil) -> some View {
    HStack(spacing: 6) {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if let count, count > 0 { Text("\(count)").font(.caption2.weight(.bold)).foregroundStyle(PalmhelmTheme.onAccent).padding(.horizontal, 6).background(PalmhelmTheme.accent, in: Capsule()) }
        if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.top, 8)
}

// MARK: 收件箱

/// 铃铛定位后的短暂高亮状态（由侧栏持有，经环境传给收件箱内容）。
struct InboxFocusFlash: Equatable { let target: MacSession.InboxFocusTarget; let serial: Int }
private struct InboxFlashKey: EnvironmentKey { static let defaultValue: InboxFocusFlash? = nil }
extension EnvironmentValues { var inboxFlash: InboxFocusFlash? { get { self[InboxFlashKey.self] } set { self[InboxFlashKey.self] = newValue } } }

struct InboxContent: View {
    @Environment(MacSession.self) private var session
    @Environment(\.inboxFlash) private var flash

    var body: some View {
        let snap = session.railSnapshot // 分区与行只取这一份快照，不在 body 里各自重算投影
        let m = snap.inbox
        if m.showsNeedsYou {
            sectionHeader(String(localized: "需要你处理"), count: m.needsYouCount)
            ForEach(m.requests) { a in
                RequestRowCard(approval: a).padding(.horizontal, 10).id("req-\(a.id)").palmhelmReveal()
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PalmhelmTheme.accent, lineWidth: 3).padding(.horizontal, 10).opacity(flash?.target == .request(a.id) ? 1 : 0)) // 铃铛定位后明显高亮（3pt accent，淡出一次）
            }
            ForEach(m.blockedWithoutCard, id: \.self) { id in
                if let r = snap.rows[id] { TargetRowView(row: r, subtitleOverride: String(localized: "需到终端处理"), subtitleTint: PalmhelmTheme.warn).equatable() }
            }
        }
        if m.showsWorking {
            sectionHeader(String(localized: "工作中"), count: m.working.count)
            ForEach(m.working, id: \.self) { id in
                if let r = snap.rows[id] { TargetRowView(row: r).equatable() }
            }
        }
        if m.showsEmptyState { // 三区都空才显示一行空态
            Text(session.link == .connected ? String(localized: "暂时无需处理") : session.link == .connecting ? String(localized: "正在同步待答事项…") : String(localized: "未连接 Bridge，待答事项尚未同步。")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 4)
        }
    }
}

/// 收件箱里的一张请求卡：短审批在卡上直接办；其余是样式 A 的摘要卡，按钮到右侧完整显示。
struct RequestRowCard: View {
    @Environment(MacSession.self) private var session
    let approval: ApprovalView

    var body: some View {
        if RequestPlacement.of(approval) == .inline {
            PendingCard(approval: approval)
        } else {
            RequestSummaryCard(approval: approval)
        }
    }
}

/// 请求类型到样式 A 的符号 / 文字 / 色调。
enum RequestStyle {
    static func kind(_ a: ApprovalView) -> RequestCardKind {
        switch a.pendingKind { case .approval: .approval; case .question: .question; case .plan: .plan }
    }
    @MainActor static func tint(_ k: RequestCardKind) -> Color {
        switch k.tone { case .warn: PalmhelmTheme.warn; case .accent: PalmhelmTheme.accent; case .bad: PalmhelmTheme.bad }
    }
}

private struct RequestSummaryCard: View {
    @Environment(MacSession.self) private var session
    let approval: ApprovalView
    private var kind: RequestCardKind { RequestStyle.kind(approval) }
    private var selected: Bool { session.selectedRequest == approval.id }
    private var buttonTitle: String {
        switch approval.pendingKind { case .question: String(localized: "回答…"); case .plan: String(localized: "查看计划"); case .approval: String(localized: "查看详情") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RequestHeader(approval: approval)
            Text(approval.summary.isEmpty ? String(localized: "（内容在详情里）") : approval.summaryDisplayed).font(.caption).lineLimit(3).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(buttonTitle) { Task { await session.openRequest(approval.id) } }.controlSize(.small).buttonStyle(.palmhelmProminent)
                    .accessibilityLabel("\(kind.label)：\(buttonTitle)")
            }
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PalmhelmTheme.accent, lineWidth: selected ? 1.5 : 0))
    }
}

/// 样式 A 的头：SF Symbol（tone 色）+ 类型文字（primary）+ 右侧时间；第二行身份。
struct RequestHeader: View {
    @Environment(MacSession.self) private var session
    let approval: ApprovalView
    private var kind: RequestCardKind { RequestStyle.kind(approval) }
    private var attribution: ApprovalAttribution? { ApprovalAttribution(rawValue: approval.attribution ?? "") }
    private var identity: String {
        let base: String
        if attribution == .exact || attribution == .candidate, let t = session.target(forApproval: approval) { base = ThreadIdentity.line(t) }
        else { base = attribution == .unregistered ? String(localized: "来源未匹配") : ApprovalText.displayLabel(approval.targetLabel) }
        return ApprovalText.identityLine(approval, base: base)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbolName).foregroundStyle(RequestStyle.tint(kind)).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(kind.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if attribution == .candidate { Text(RequestCardBadge.inferredOwner.label).font(.caption2).foregroundStyle(PalmhelmTheme.warn) } // 推测归属，不是身份认证
                    if !session.canControl { Text(RequestCardBadge.readOnly.label).font(.caption2).foregroundStyle(.secondary) }
                }
                Group {
                    if attribution == .exact, let t = session.target(forApproval: approval) {
                        Button(identity) { session.selectTarget(t.id) }.buttonStyle(.link).accessibilityHint("查看该会话")
                    } else { Text(identity) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(Date(timeIntervalSince1970: Double(approval.createdT) / 1000), format: Date.relativeStyle(.numeric)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: 空间

struct SpacesContent: View {
    @Environment(MacSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 分组菜单（右键、⋯ 按钮共用）：置顶/取消置顶，边界位置不提供移动项（#98 h91）。
    @ViewBuilder
    private func spaceGroupMenu(_ sec: LensSection, visible: [String]) -> some View {
        Button(session.isSpaceGroupPinned(sec.id) ? String(localized: "取消置顶") : String(localized: "置顶")) { session.setSpaceGroupPinned(sec.id, !session.isSpaceGroupPinned(sec.id)) }
        if session.spaceCanMove(sec.id, delta: -1, visible: visible) { Button("上移") { moveSpace(sec.id, -1) } }
        if session.spaceCanMove(sec.id, delta: 1, visible: visible) { Button("下移") { moveSpace(sec.id, 1) } }
    }

    /// 移动后播报新位置；焦点仍在被移动的组（同一稳定身份的段头）。
    private func moveSpace(_ sectionId: String, _ delta: Int) {
        guard let message = session.moveSpaceGroup(sectionId, delta: delta) else { return }
        MacSession.announce(message)
    }

    var body: some View {
        // 每次 body 只取一份快照；表头的移动权限用同一份可见顺序判定。
        let snap = session.railSnapshot
        let sections = snap.sections
        let visible = sections.compactMap { SpaceOrderSession.groupId(sectionId: $0.id) }
        return Group {
            ForEach(Array(sections.enumerated()), id: \.element.id) { i, sec in
                HStack(spacing: 6) {
                    Text(sec.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    UrgencyPill(sec.urgency, accent: PalmhelmTheme.accent)
                    Spacer(minLength: 0)
                    // 键盘入口（#98 h91）：可 Tab 聚焦的 ⋯ 按钮，打开与右键相同的菜单。
                    Menu { spaceGroupMenu(sec, visible: visible) } label: {
                        Image(systemName: "ellipsis.circle").font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("分组菜单：\(sec.title)")
                    .help("分组菜单")
                }
                .padding(.horizontal, 14).padding(.top, i > 0 ? 10 : 2)
                .contentShape(Rectangle())
                // 拖动整组（只携带组键，不触发会话派发）；放到另一组的标题上即移到它之前（#98）。
                .draggable(sec.id)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first else { return false }
                    session.dropSpaceGroup(dragged, before: sec.id)
                    return true
                }
                .contextMenu { spaceGroupMenu(sec, visible: visible) }
                .accessibilityActions {
                    Button(session.isSpaceGroupPinned(sec.id) ? String(localized: "取消置顶") : String(localized: "置顶")) { session.setSpaceGroupPinned(sec.id, !session.isSpaceGroupPinned(sec.id)) }
                    if session.spaceCanMove(sec.id, delta: -1, visible: visible) { Button("上移") { moveSpace(sec.id, -1) } }
                    if session.spaceCanMove(sec.id, delta: 1, visible: visible) { Button("下移") { moveSpace(sec.id, 1) } }
                }
                ForEach(sec.keys, id: \.self) { id in
                    if let r = snap.rows[id] { TargetRowView(row: r).equatable() } else if let h = snap.historical[id] { HistoricalRowView(row: h).equatable() }
                }
                if let f = sec.footer { Text(f).font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14) }
            }
            if session.state != nil, sections.isEmpty { Text("这台 Mac 上没有 Herdr 目标").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14) }
            if snap.archivedCount > 0 {
                Button { openWindow(id: "archived") } label: { Label("已归档（\(snap.archivedCount)）", systemImage: "archivebox") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 10)
            }
        }
        // 排序的重排只随数据变化：开启“减少动态效果”时不做位移动画（显式分支，#98 h91）。
        .animation(reduceMotion ? nil : .default, value: session.spaceVersion)
        .onAppear { session.setSpaceListVisible(true) } // 目标栏可见：冻结排序（#98）
        .onDisappear { session.setSpaceListVisible(false) } // 离开再回来才静默应用
    }
}

/// 一行 agent：角色徽章 + 主题、身份行、「状态 · 工作区 › 标签 · 分支」；右侧待答角标。点击打开它的线程。
/// 只消费一份展示值（RailRow）：行内不读 approvals / 活动 / 全局状态；值不变时父视图重算也不重建（Equatable，闭包不参与比较）。
struct TargetRowView: View, Equatable {
    @Environment(MacSession.self) private var session
    let row: RailRow
    @State private var confirmDelete = false
    var subtitleOverride: String?
    var subtitleTint: Color?

    nonisolated static func == (l: Self, r: Self) -> Bool { l.row == r.row && l.subtitleOverride == r.subtitleOverride && l.subtitleTint == r.subtitleTint }

    var body: some View {
        let _ = { RailProbe.rowBodies += 1 }()
        let r = row
        let kind = r.activity // 运行中标识只经 session 推导，与对话 chip、底部提示同一口径
        let thirdAt = { (now: Date) in subtitleOverride ?? [ThreadActivity.describe(kind: kind, since: r.workingSince, now: now), r.place.isEmpty ? nil : r.place, r.branch].compactMap { $0 }.joined(separator: " · ") }
        Button { session.selectTarget(r.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(r.badgeText).font(.system(size: 10, weight: .bold)).foregroundStyle(.white) // 角色色固定，字固定白
                    .frame(width: 28, height: 28).background(r.badgeRole != nil ? PalmhelmIdentityPalette.role(r.badgeRole) : Self.color(for: r.badgeColorSource), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PalmhelmTheme.accent, lineWidth: r.current ? 2 : 0).padding(-2))
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    Text([r.identityLine, r.modelShort].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) // 模型只在身份行末尾简写，不占状态行（待处理状态优先）
                    // 活动点在时间线之外：呼吸动画不让 30 秒的时间线内容每次重算（O1-337）。
                    HStack(spacing: 4) {
                        ActivityDot(kind: kind, size: 6, accent: PalmhelmTheme.accent, ok: PalmhelmTheme.ok, warn: PalmhelmTheme.warn)
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Text(thirdAt(ctx.date)).font(.caption2).foregroundStyle(subtitleTint ?? (kind == .waiting ? PalmhelmTheme.accent : .secondary)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: 0)
                if r.pending > 0 {
                    Text("\(r.pending)").font(.system(size: 10, weight: .bold)).foregroundStyle(PalmhelmTheme.onAccent).padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17).background(PalmhelmTheme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(r.selected ? PalmhelmTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 6)
        .contextMenu {
            Button(r.pinned ? String(localized: "取消钉住") : String(localized: "钉住（收件箱置顶）")) { session.setPinned(r.id, !r.pinned) }
            Button("标为未读") { session.markUnread(r.id) }
            if r.canArchive {
                Button("归档", systemImage: "archivebox") { session.archiveThread(r.id) }
                Button("删除…", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("删除这个历史会话？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { session.deleteThread(r.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅从这台 Mac 的列表移除并清理本地缓存，Bridge 上的历史记录不受影响。")
        }
        .accessibilityLabel([r.title, r.identityLine, r.modelAccessibility, thirdAt(Date()), r.pending > 0 ? String(localized: "\(r.pending) 条待答") : nil, r.selected ? String(localized: "正在浏览") : nil, r.current ? String(localized: "消息发往这里") : nil].compactMap { $0 }.joined(separator: DisplayList.separator))
    }

    static func color(for name: String) -> Color {
        let palette: [UInt32] = [0x8C6F3A, 0x5A6E8C, 0x6C8A5F, 0x7A5F8A, 0x8A5F5F, 0x5F8A86, 0x8A7A5F, 0x6A6A8A, 0x7D8A5F, 0x5F7A8A]
        let h = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        let v = palette[abs(h) % palette.count]
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
