import SwiftUI
import PalmhelmKit

// 待办卡（审批 / 提问 / 计划，设计稿“待办卡改版 · 方向 A”）：与 iPhone 同一结构（头部 / 阅读区 / 操作区 / 状态区），
// 用 Mac 原生按钮密度。同一套规则：只读本地先拦，正文按需取，计划只能打回、批准回终端。
struct PendingCard: View {
    let approval: ApprovalView
    var body: some View {
        switch approval.pendingKind {
        case .approval: ApprovalCard(approval: approval)
        case .question: MacQuestionCard(approval: approval)
        case .plan: MacPlanCard(approval: approval)
        }
    }
}

// MARK: 共用部件

/// 卡片骨架：样式 A 的头（符号 + 类型文字 + 时间 / 身份），阅读区，分隔线下是操作区与状态区（状态行由调用方给出，Bridge 的失败原因统一跟在后面）。
private struct PendingCardShell<Reading: View, Actions: View>: View {
    @Environment(MacSession.self) private var session
    let approval: ApprovalView
    let status: (text: String, tone: Color)
    @ViewBuilder let reading: Reading
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RequestHeader(approval: approval)
            reading
            Divider()
            actions
            HStack(alignment: .top, spacing: 6) {
                Label { Text(status.text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
                    .font(.caption2).foregroundStyle(status.tone)
                Spacer(minLength: 4)
                ApprovalCountdown(expiresT: approval.expiresT, font: .caption2, urgentBelow: 60, urgent: PalmhelmTheme.bad, normal: .secondary, label: String(localized: "后交回终端"))
            }
            if let e = session.decideError[approval.id] { Text(e.text).font(.caption2).foregroundStyle(PalmhelmTheme.bad) }
        }
        .card()
    }
}

/// 操作行：放得下横排，窄侧栏（272pt）放不下改纵排（A1-107 F2）。
private struct MacActionRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

/// 只读、推测归属等共用的状态行。
@MainActor private func readOnlyStatus(_ session: MacSession) -> (text: String, tone: Color)? {
    session.canControl ? nil : (String(localized: "这台 Mac 当前是只读：可以查看，处理请到可控设备"), PalmhelmTheme.warn)
}

// MARK: 审批卡

/// 允许一次 / 拒绝；没有“始终允许”。最上面一条待答响应 ⌘↩。
struct ApprovalCard: View {
    @Environment(MacSession.self) private var session
    let approval: ApprovalView
    @State private var denying = false
    @State private var rulesOpen = false
    // 拒绝理由在 Session（连接身份 + requestId）：卡在侧栏 / 详情之间切换、重建都不丢
    private var reason: String { session.reason(approval, .approvalDeny) }
    private var reasonBinding: SwiftUI.Binding<String> { SwiftUI.Binding(get: { session.reason(approval, .approvalDeny) }, set: { session.setReason($0, approval, .approvalDeny) }) }
    private var busy: Bool { session.deciding.contains(approval.id) }
    /// 全局最早的待答才响应 ⌘↩，避免多张卡同时绑定同一快捷键。
    private var isTop: Bool { session.pendingApprovals.first?.id == approval.id }
    private var options: ApprovalText.OptionPresentation { ApprovalText.presentation(of: approval.displayOptions) }
    private var rules: [ApprovalOption] { options.rules }

    var body: some View {
        PendingCardShell(approval: approval, status: status) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ApprovalText.actionTitle(toolName: approval.toolName)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(approval.summaryDisplayed + (approval.truncated ? "…" : "")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(PalmhelmTheme.card2, in: RoundedRectangle(cornerRadius: 8))
                ApprovalContextSections(approval: approval) // 起因 / 改动（2b）
                // 记住规则本期不可用：收成一行可展开说明，不挡在决定前面
                if !rules.isEmpty {
                    DisclosureGroup(isExpanded: $rulesOpen) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(rules) { o in
                                Text(ApprovalText.optionLabel(o)).font(.caption.weight(.semibold))
                                if let d = ApprovalText.optionDetail(o) { Text(d).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                                if let why = ApprovalText.optionDisabledReason(o) { Text(why).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    } label: { Text("agent 建议记住 \(rules.count) 条规则（本期只允许一次）").font(.caption).foregroundStyle(.secondary) }
                }
                // 未知类型的选项：只读显示服务端原文，没有动作，也不计入“记住规则”。
                ForEach(options.unknown) { o in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ApprovalText.optionLabel(o)).font(.caption.weight(.semibold))
                        if let d = ApprovalText.optionDetail(o) { Text(d).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let why = ApprovalText.optionDisabledReason(o) { Text(why).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                }
                if approval.optionsVaried == true { Text("不同钩子上报的选项不同，展示首次内容").font(.caption2).foregroundStyle(PalmhelmTheme.warn) }
            }
        } actions: {
            // 到期后不再可点：随有效性版本（精确到期边界）重算，不再每秒重画输入框与按钮行（发送入口另有实时校验，O1-341 R3）。倒计时数字在自己的 Text 叶子里。
            Group {
                let _ = session.timeValidityVersion
                let open = approval.isPending(now: session.currentDate)
                if denying {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("告诉 agent 换个做法（可选）", text: reasonBinding, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
                        Text("\(reason.utf16.count)/\(ApprovalMessage.maxUTF16)").font(.caption2).foregroundStyle(ApprovalMessage.isTooLong(reason) ? PalmhelmTheme.bad : .secondary)
                        MacActionRow {
                            Button("取消") { denying = false; session.setReason("", approval, .approvalDeny) }
                            Button("确认拒绝") { decide(.deny, message: reason) }.buttonStyle(PalmhelmProminentButtonStyle(fill: PalmhelmTheme.bad, label: Color(light: 0xFFFFFF, dark: 0x3A0B08))).disabled(ApprovalMessage.isTooLong(reason) || !session.canControl || !open)
                        }
                    }
                    .disabled(busy || !open)
                } else {
                    MacActionRow {
                        ForEach(options.deny.map { [$0] } ?? []) { o in
                            Button(ApprovalText.optionLabel(o) + "…") { if approval.messageSupported == true { denying = true } else { decide(.deny) } }.disabled(!o.enabled)
                        }
                        ForEach(options.allow.map { [$0] } ?? []) { o in
                            Button(isTop ? "\(ApprovalText.optionLabel(o)) ⌘↩" : ApprovalText.optionLabel(o)) { decide(.allowOnce) }.buttonStyle(.palmhelmProminent).disabled(!o.enabled)
                                .keyboardShortcut(isTop ? KeyboardShortcut(.return, modifiers: .command) : nil) // 最上面一条待答：⌘↩ 允许一次
                        }
                    }
                    .disabled(busy || !session.canControl || !open)
                }
            }
        }
    }

    private var status: (text: String, tone: Color) {
        if busy { return (String(localized: "提交中…"), .secondary) }
        if let r = readOnlyStatus(session) { return r }
        return (String(localized: "超时自动交回终端 · 本期只允许一次，不记住规则"), .secondary)
    }

    private func decide(_ d: ApprovalDecision, message: String? = nil) { denying = false; Task { await session.decide(approval, d, message: message) } } // 失败时理由保留（卡撤下后由 Session 清草稿）
}

// MARK: 提问卡

struct MacQuestionCard: View {
    @Environment(MacSession.self) private var session
    let approval: ApprovalView
    // 作答草稿在 Session（连接身份 + requestId）；这里只留纯视图状态
    private var draft: QuestionDraft? { session.questionDraft(approval) }
    private func edit(_ change: (inout QuestionDraft) -> Void) { guard var d = session.questionDraft(approval) else { return }; change(&d); session.setQuestionDraft(d, for: approval) }
    @State private var loadFailed = false
    @State private var focus = 0 // 正在作答的题；其余收成一行摘要
    @State private var writing: Set<Int> = []
    @State private var note: LText? // 提交前复核给的说明（离线 / 已处理 / 题目变了…）：草稿一律保留
    private var busy: Bool { session.deciding.contains(approval.id) }
    private let purple = Color(red: 0.43, green: 0.29, blue: 0.79)
    private var count: Int { draft?.questions.count ?? approval.questionCount ?? 1 }

    var body: some View {
        PendingCardShell(approval: approval, status: status) {
            if let draft {
                VStack(alignment: .leading, spacing: 8) {
                    Text(count > 1 ? String(localized: "\(count) 个问题要你回答") : String(localized: "有个问题要你回答")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(draft.questions.enumerated()), id: \.offset) { qi, q in
                        if draft.questions.count == 1 || qi == focus { question(qi, q) } else { summary(qi, q, draft) }
                    }
                }
            } else if loadFailed {
                HStack { Text("问题内容没取到").font(.caption).foregroundStyle(PalmhelmTheme.warn); Button("重试") { Task { await load() } }.controlSize(.small) } // 不伪造表单
            } else {
                SkeletonLines(count: 3, label: String(localized: "正在读取问题"))
            }
        } actions: {
            MacActionRow {
                Button("交回终端") { Task { await session.release(approval) } }
                Button(busy ? String(localized: "提交中…") : String(localized: "提交答案")) { submit() }
                    .buttonStyle(.palmhelmProminent).disabled(draft?.answers == nil)
            }
            .disabled(busy || !session.canControl)
        }
        .task(id: approval.id) { await load() }
    }

    private func submit() {
        guard let d = draft else { return }
        note = nil
        Task {
            switch await session.submitQuestion(approval, d) {
            case .submitted: break
            case .busy: break
            case .kept(let why): note = why
            case .changed(let qs):
                session.setQuestionDraft(QuestionDraft(qs), for: approval) // 题目已变：换成新题目，旧答案不套到新题上
                focus = 0; writing = []
                note = LText(String(localized: "问题内容变了，请按新的题目重新作答"))
            }
        }
    }

    private var status: (text: String, tone: Color) {
        if let note { return (note.text, PalmhelmTheme.warn) }
        if let r = readOnlyStatus(session) { return r }
        guard let draft else { return (String(localized: "不答会在倒计时结束后交回终端"), .secondary) }
        if draft.tooLong { return (String(localized: "自己写的答案超过 \(ApprovalMessage.maxUTF16) 字，请缩短"), PalmhelmTheme.bad) }
        let done = draft.questions.indices.filter(draft.isAnswered).count
        if draft.questions.count > 1, done < draft.questions.count { return (String(localized: "已答 \(done)/\(draft.questions.count) · 还差 \(draft.questions.count - done) 题"), .secondary) }
        return (String(localized: "不答会在倒计时结束后交回终端"), .secondary)
    }

    private func load() async {
        loadFailed = false
        guard draft == nil else { return } // 已有草稿（切线程 / 进出详情后）不重取、不覆盖
        if let d = await session.approvalDetail(approval.id), let qs = d.body?.questions, !qs.isEmpty {
            if session.questionDraft(approval) == nil { session.setQuestionDraft(QuestionDraft(qs), for: approval) } // 迟到的加载不覆盖期间写下的草稿
        } else { loadFailed = true }
    }

    private func number(_ qi: Int) -> String { count > 1 ? "\(qi + 1). " : "" }

    private func summary(_ qi: Int, _ q: ProjectedQuestion, _ draft: QuestionDraft) -> some View {
        let answered = draft.isAnswered(qi)
        let answer = draft.texts[qi].isEmpty ? draft.selected[qi].sorted().map { q.options[$0].label }.joined(separator: "、") : draft.texts[qi]
        return Button { focus = qi } label: {
            HStack(spacing: 6) {
                Text(number(qi) + (q.header.isEmpty ? q.questionDisplayed : q.header)).lineLimit(1)
                if answered { Text(answer).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                Text(answered ? String(localized: "已答 · 修改") : String(localized: "未答")).font(.caption2).foregroundStyle(answered ? PalmhelmTheme.ok : .secondary)
            }
            .font(.callout).padding(.horizontal, 8).padding(.vertical, 6)
            .background(answered ? PalmhelmTheme.card2.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(answered ? 0 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func question(_ qi: Int, _ q: ProjectedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if count > 1 || !q.header.isEmpty {
                Text(number(qi) + q.header).font(.caption2.weight(.bold)).foregroundStyle(purple)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
            Text(q.questionDisplayed).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if q.multiSelect { Text("可多选").font(.caption2).foregroundStyle(.secondary) }
            ForEach(Array(q.options.enumerated()), id: \.offset) { oi, o in
                let on = draft?.selected[qi].contains(oi) == true
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        edit { $0.toggle(question: qi, option: oi) }
                        writing.remove(qi)
                        if !q.multiSelect, let d = draft, let next = d.questions.indices.first(where: { !d.isAnswered($0) }) { focus = next } // 单选选完转到下一道未答
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")).foregroundStyle(on ? PalmhelmTheme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.labelDisplayed).font(.callout.weight(.medium)).foregroundStyle(o.selectable ? Color.primary : Color.secondary)
                                if !o.description.isEmpty { Text(o.descriptionDisplayed).font(.caption).foregroundStyle(.secondary) }
                                if !o.selectable { Text("内容已隐藏，不能选").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? PalmhelmTheme.accent : Color.secondary.opacity(0.25), lineWidth: on ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!o.selectable || busy) // 提交中不改答案（A1-107 F1）
                    .accessibilityAddTraits(on ? .isSelected : [])
                    if let p = o.preview, !p.isEmpty {
                        DisclosureGroup { MarkdownText(text: o.previewDisplayed ?? p).font(.caption) } label: { Text("预览").accessibilityLabel("预览：\(o.labelDisplayed)") } // 只标标题，正文保留自己的文字（A1-107 F4）
                            .font(.caption).padding(.leading, 26)
                    }
                }
            }
            if writing.contains(qi) || !(draft?.texts[qi].isEmpty ?? true) {
                TextField("自己写答案", text: Binding(get: { draft?.texts[qi] ?? "" }, set: { v in edit { $0.setText(question: qi, v) } }), axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder).disabled(busy)
            } else {
                Button("自己写答案…") { writing.insert(qi) }.buttonStyle(.link).font(.caption).disabled(busy)
            }
        }
    }
}

// MARK: 计划卡

struct MacPlanCard: View {
    @Environment(MacSession.self) private var session
    let approval: ApprovalView
    @State private var plan: String?
    @State private var planSpans: LossyDisplaySpans?
    @State private var truncated = false
    @State private var reviseCount = 0
    @State private var loadFailed = false
    @State private var expanded = false
    @State private var editing = false // 点了“打回修改…”：操作区换成理由输入
    @State private var note: LText? // 提交前复核给的说明：理由一律保留
    // 打回理由在 Session（连接身份 + requestId）
    private var reason: String { session.reason(approval, .planRevise) }
    private var reasonBinding: SwiftUI.Binding<String> { SwiftUI.Binding(get: { session.reason(approval, .planRevise) }, set: { session.setReason($0, approval, .planRevise) }) }
    @State private var revealNote: (ok: Bool, message: LText)?
    private var busy: Bool { session.deciding.contains(approval.id) }
    // 只有 exact 归属才解析目标：未登记 / 推测的显示名可能和某个登记项目同名（A1-103 F4）
    private var exactTarget: TargetSummary? { approval.attribution == ApprovalAttribution.exact.rawValue ? session.target(forApproval: approval) : nil }

    var body: some View {
        PendingCardShell(approval: approval, status: status) {
            if let plan {
                VStack(alignment: .leading, spacing: 4) {
                    // 长文随外层列表滚动，不再套一个小滚动框；折叠时限高并底部渐隐
                    MarkdownText(text: ApprovalText.planDisplayed(plan, spans: planSpans)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: expanded || !needsExpansion(plan) ? nil : 180, alignment: .top).clipped()
                        .mask {
                            VStack(spacing: 0) {
                                Rectangle()
                                if !expanded && needsExpansion(plan) { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28) }
                            }
                        }
                    if truncated { Text("计划太长，只显示了前面一部分；完整内容在终端里").font(.caption2).foregroundStyle(.secondary) }
                    if needsExpansion(plan) { Button(expanded ? String(localized: "收起") : String(localized: "查看完整计划")) { expanded.toggle() }.buttonStyle(.link).font(.caption) }
                }
                .padding(8).background(PalmhelmTheme.card2.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                if reviseCount > 0 { Text("已打回 \(reviseCount) 次").font(.caption2).foregroundStyle(.secondary) }
            } else if loadFailed {
                HStack { Text("计划内容没取到").font(.caption).foregroundStyle(PalmhelmTheme.warn); Button("重试") { Task { await load() } }.controlSize(.small) }
            } else {
                SkeletonLines(count: 4, label: String(localized: "正在读取计划"))
            }
        } actions: {
            if editing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("修改建议（可选）").font(.caption.weight(.semibold))
                    TextField("比如：第二步写具体点", text: reasonBinding, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                        .disabled(busy) // 提交中锁住：界面内容与已发出的理由一致（A1-107 F1）
                    Text("不填会请 agent 自己复查后重新提交").font(.caption2).foregroundStyle(.secondary)
                    MacActionRow {
                        Button("取消") { editing = false } // 不发请求，草稿留着
                        Button(busy ? String(localized: "提交中…") : String(localized: "提交打回")) { submitRevise() }
                            .buttonStyle(.palmhelmProminent).disabled(ApprovalMessage.isTooLong(reason))
                    }
                    .disabled(busy || !session.canControl)
                }
            } else {
                MacActionRow {
                    Button("交回终端") { Task { await session.release(approval) } }
                    Button("打回修改…") { editing = true }.disabled(plan == nil)
                    // 钩子批不了计划（Claude Code 实测）：Mac 上能直接切到那个窗格，在终端里批准；仅 exact 归属
                    if let t = exactTarget {
                        Button("在 Herdr 中批准") { Task { revealNote = await session.reveal(t.id) } }.buttonStyle(.palmhelmProminent)
                    }
                }
                .disabled(busy || !session.canControl)
                if let n = revealNote { Text(n.message.text).font(.caption2).foregroundStyle(n.ok ? PalmhelmTheme.ok : PalmhelmTheme.bad) }
            }
        }
        .task(id: approval.id) { await load() }
    }

    private func submitRevise() {
        let m = reason
        note = nil
        Task {
            switch await session.submitRevise(approval, message: m) {
            case .submitted: session.setReason("", approval, .planRevise); editing = false
            case .kept(let why): note = why
            case .busy, .changed: break
            }
        }
    }

    private var status: (text: String, tone: Color) {
        if let note { return (note.text, PalmhelmTheme.warn) }
        if ApprovalMessage.isTooLong(reason) { return (String(localized: "理由超过 \(ApprovalMessage.maxUTF16) 字，请缩短"), PalmhelmTheme.bad) }
        if let r = readOnlyStatus(session) { return r }
        switch ApprovalAttribution(rawValue: approval.attribution ?? "") {
        case .exact: return (String(localized: "计划需在终端批准 · 超时自动交回终端"), .secondary)
        case .candidate: return (String(localized: "归属是推测的：请在 Herdr 里找到对应终端批准"), .secondary)
        default: return (String(localized: "没对上登记的窗格：请在 Herdr 里找到对应终端批准"), .secondary)
        }
    }

    // ponytail: 按字数/行数估计是否需要折叠，不量实际高度；同一条件同时控制裁切与展开按钮，不给按钮就不裁
    private func needsExpansion(_ plan: String) -> Bool { plan.count > 240 || plan.split(separator: "\n").count > 8 }

    private func load() async {
        loadFailed = false
        if let d = await session.approvalDetail(approval.id), let p = d.body?.plan { plan = p; planSpans = d.body?.planDisplaySpans; truncated = d.body?.truncated ?? false; reviseCount = d.reviseCount ?? 0 } else { loadFailed = true }
    }
}

/// 待答倒计时（mm:ss）：自己的 1 秒时间线从 ctx.date 计算剩余秒数，不读会话的时钟，所以每秒只更新这一小段（O1-337）。
struct ApprovalCountdown: View {
    let expiresT: Int
    var font: Font = .caption
    var urgentBelow: Int? = nil
    var urgent: Color = PalmhelmTheme.bad
    var normal: Color = PalmhelmTheme.notchWarn
    var label: String = String(localized: "后交回终端")
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let r = max(0, Int((Double(expiresT) / 1000 - ctx.date.timeIntervalSince1970).rounded(.down)))
            let hot = urgentBelow.map { r < $0 } ?? false
            Text(String(format: "%d:%02d", r / 60, r % 60))
                .font(font.monospacedDigit())
                .foregroundStyle(hot ? urgent : normal)
                .accessibilityLabel("\(r / 60) 分 \(r % 60) 秒\(label)")
        }
    }
}

