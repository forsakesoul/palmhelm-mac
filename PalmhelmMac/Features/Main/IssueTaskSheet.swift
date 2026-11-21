import AppKit
import PalmhelmKit
import SwiftUI

// #21 S2（Mac）：派发 Issue / 需求。规则与文案来自 Kit（IssueTaskRules / IssueTaskDraft / IssueTaskFlow）；
// 正文只由服务端生成，这里展示预览返回的 text。结果只在发起时的连接上生效；受理后回显并定位到实际受理的线程。
struct IssueTaskSheet: View {
    @Environment(MacSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var preselectedTargetId: String?
    /// 受理成功（sheet 仍在界面上且连接未变化）时回调：实际受理的目标。
    var onAccepted: (String) -> Void
    /// 放弃未知结果的请求时回调（关闭、连接变化）：由呈现方显示固定说明。
    var onAbandoned: (String) -> Void = { _ in }

    /// 固定说明：旧请求可能已受理，以会话里的回显为准。
    static var abandonedNote: String { String(localized: "之前那条可能已受理，请以会话里的回显为准") }

    @State private var options: IssueTaskOptions?
    @State private var unsupported = false
    @State private var loadError: LText?
    @State private var draft: IssueTaskDraft
    @State private var issues: [IssueTaskListItem] = []
    @State private var page = 1
    @State private var filter = ""
    @State private var pasteLink = ""
    @State private var linkNote: LText?
    @State private var busy = false
    @State private var notice: LText?
    /// sheet 是否仍在界面上：取消后迟到的成功只落账，不导航。
    @State private var alive = true
    /// 结果未知的请求：只在本 sheet 内保存，原样重投核对，不跨 sheet、不进 session（A1-192 R2）。
    @State private var pending: IssueTaskPendingSubmission?
    /// 最新一次点选的序号：只采纳最新选择的结果（A1-192 R1）。
    @State private var selection = IssueTaskSelectionGate()

    /// 初值（默认空）：截图与预览用于直接给出已读取的选项或草稿，生产路径不传。
    init(preselectedTargetId: String? = nil, initialOptions: IssueTaskOptions? = nil, initialDraft: IssueTaskDraft = IssueTaskDraft(),
         onAccepted: @escaping (String) -> Void, onAbandoned: @escaping (String) -> Void = { _ in }) {
        self.preselectedTargetId = preselectedTargetId
        self.onAccepted = onAccepted
        self.onAbandoned = onAbandoned
        _options = State(initialValue: initialOptions)
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("新任务…").font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !session.canControl {
                        Text("此设备只有查看权限，不能派发任务；仍可查看来源与已受理的任务。").foregroundStyle(.secondary)
                    }
                    if unsupported {
                        Text("这台 Bridge 还不支持从 Palmhelm 派发任务，请先升级 Bridge。")
                    } else if let loadError {
                        Text(loadError.text).foregroundStyle(.secondary)
                    } else if let options {
                        targetSection(options)
                        sourceSection(options)
                        instructionsSection
                        previewSection
                    } else {
                        ProgressView(String(localized: "正在读取…"))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(busy)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        .task { syncLanguage(); await loadOptions() }
        .onChange(of: resourceLanguage) { _, _ in syncLanguage() } // 界面语言变化：作废预览（有未知提交时保持原请求原语言）
        .onChange(of: draft.revision) { _, _ in
            // 草稿被改过：结果未知的旧请求不再可重投，给出固定说明。
            if pending != nil { abandon() }
        }
        .onDisappear {
            alive = false
            if pending != nil { onAbandoned(Self.abandonedNote) } // 关闭即放弃
        }
    }

    // MARK: 模板语言

    /// 读取处登记 DisplayLanguage 依赖；只看资源语言，不看地区。
    private var resourceLanguage: String { DisplayLanguage.shared.context.resourceLanguage }

    /// 未知提交悬而未决时不改草稿语言（规则在 Kit 的 syncTemplateLanguage）。
    private func syncLanguage() {
        draft.syncTemplateLanguage(options: options, resource: resourceLanguage, pending: pending != nil)
    }

    // MARK: 执行会话

    private func targetSection(_ o: IssueTaskOptions) -> some View {
        group(String(localized: "执行会话"), footer: String(localized: "任务交给选中的现有会话执行，不会新建会话。")) {
            if o.targets.isEmpty { Text("没有登记的原生会话。").foregroundStyle(.secondary) }
            ForEach(o.targets, id: \.targetId) { t in
                Button {
                    draft.targetId = t.targetId
                    draft.destinationVersion = t.destinationVersion
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.displayLabel)
                            if !t.usable, let reason = t.reason {
                                Text(IssueTaskRules.targetReasonCopy(reason)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if draft.targetId == t.targetId { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!t.usable)
                .accessibilityLabel(t.usable ? String(localized: "执行会话 \(t.displayLabel)") : String(localized: "执行会话 \(t.displayLabel)，不可用：\(IssueTaskRules.targetReasonCopy(t.reason))"))
                .accessibilityAddTraits(draft.targetId == t.targetId ? .isSelected : [])
            }
        }
    }

    // MARK: 来源

    private func sourceSection(_ o: IssueTaskOptions) -> some View {
        group(String(localized: "需求来源"), footer: String(localized: "来源仓库与执行会话分别选择，不会自动匹配。来源只读取，不会写回 GitHub。")) {
            IssueSourceSegment(source: $draft.source, githubEnabled: IssueTaskRules.githubAvailable(o))
            if draft.source == .github {
                githubSource(o)
            } else {
                manualSource
            }
        }
    }

    @ViewBuilder private func githubSource(_ o: IssueTaskOptions) -> some View {
        if !IssueTaskRules.githubAvailable(o) {
            Text(IssueTaskRules.githubUnavailableCopy(reason: o.github.reason))
                .foregroundStyle(.secondary)
                .accessibilityLabel("GitHub 来源不可用。\(IssueTaskRules.githubUnavailableCopy(reason: o.github.reason))")
        } else {
            Picker("来源仓库", selection: Binding(
                get: { draft.sourceId ?? "" },
                set: { id in
                    draft.sourceId = id.isEmpty ? nil : id
                    issues = []; page = 1
                })) {
                Text("选择仓库").tag("")
                ForEach(o.sources, id: \.sourceId) { s in Text(s.repo).tag(s.sourceId) }
            }
            if draft.sourceId != nil, issues.isEmpty {
                Button("读取开放的 Issue") { Task { await loadPage(1) } }
            }
            if !issues.isEmpty {
                TextField("筛选已加载的标题", text: $filter)
                ForEach(filteredIssues) { item in
                    Button {
                        Task { await selectIssue(number: item.number) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(item.number) \(item.displayTitle)").lineLimit(2)
                            Text(item.isClosed ? String(localized: "已关闭 · 更新于 \(item.updatedAt.prefix(10))") : String(localized: "开放 · 更新于 \(item.updatedAt.prefix(10))"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Issue \(item.number)，\(item.displayTitle)，\(item.isClosed ? String(localized: "已关闭") : String(localized: "开放"))")
                }
                if page < 5 {
                    Button("加载更多（第 \(page + 1) 页，最多 5 页）") { Task { await loadPage(page + 1) } }
                }
            }
            HStack {
                TextField("粘贴 Issue 链接", text: $pasteLink)
                Button("定位") { Task { await locateLink(options: o) } }.disabled(pasteLink.isEmpty)
            }
            if let linkNote { Text(linkNote.text).font(.caption).foregroundStyle(.secondary) }
            if let issue = draft.issue { issueDetail(issue) }
        }
    }

    private var filteredIssues: [IssueTaskListItem] {
        filter.isEmpty ? issues : issues.filter { $0.title.localizedCaseInsensitiveContains(filter) || String($0.number).contains(filter) }
    }

    private func issueDetail(_ issue: IssueTaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("#\(issue.number) \(issue.displayTitle)").font(.headline)
            DisclosureGroup(String(localized: "查看来源正文（只读）")) {
                Text(issue.displayBody).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if issue.isClosed {
                Text("这个 Issue 已关闭。").foregroundStyle(PalmhelmTheme.warn)
                Toggle("仍要处理这个已关闭的 Issue（不会重新打开 GitHub 上的 Issue）", isOn: $draft.ackClosed)
            }
        }
    }

    private var manualSource: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("任务标题（必填，200 字以内）", text: $draft.title)
            TextField("需求描述与验收（必填）", text: $draft.description, axis: .vertical).lineLimit(3...8)
            TextField("参考链接（可选，GitHub Issue 链接）", text: $draft.referenceUrl)
            if !draft.referenceUrl.isEmpty, !IssueTaskRules.validReferenceURL(draft.referenceUrl) {
                Text("参考链接需要是 https://github.com/owner/repo/issues/编号 的形式。").font(.caption).foregroundStyle(.red)
            }
            Text("标为用户提供，不会被当成已读取的 Issue。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var instructionsSection: some View {
        group(String(localized: "本次补充与验收（可选）"), footer: nil) {
            TextField("例如：只处理小屏布局；验收：375pt 下不截字", text: $draft.instructions, axis: .vertical).lineLimit(2...6)
        }
    }

    // MARK: 预览与确认

    private var previewSection: some View {
        group(String(localized: "预览确认"), footer: nil) {
            if let blocker = session.issueTaskBlocker() {
                Text(blocker).foregroundStyle(.secondary).accessibilityLabel("暂不能派发：\(blocker)")
            }
            if let pending {
                // 结果未知：只能原样重投核对，或放弃（放弃会给出固定说明）。
                Text("有一条结果未知的派发：\(pending.summary)。它可能已受理，原样重投核对不会产生第二条。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("放弃", role: .destructive) { abandon() }
                    Spacer()
                    Button("重新核对") { Task { await submit(pending.request, summary: pending.summary, targetId: pending.targetId) } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(session.issueTaskBlocker() != nil)
                }
            } else if let preview = draft.preview {
                Text(preview.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("待发送内容：\(preview.text)")
                Text("服务端按固定模板生成；确认后会话忙时排队，空闲后发送。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("重新预览") { Task { await makePreview() } }
                        .disabled(session.issueTaskBlocker() != nil)
                    Spacer()
                    Button("确认并发送") { Task { await confirm() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!IssueTaskRules.canConfirm(preview: preview) || session.issueTaskBlocker() != nil)
                }
            } else {
                if draft.templateNeedsNewerBridge { Text(IssueTaskRules.templateUpgradeCopy).font(.caption).foregroundStyle(.secondary) }
                Button("预览待发内容") { Task { await makePreview() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.readyForPreview || session.issueTaskBlocker() != nil)
            }
            if let notice { Text(notice.text).foregroundStyle(.red) }
        }
    }

    private func group<Content: View>(_ title: String, footer: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 网络（每个异步结果都先经 IssueTaskFlow.resolve 核对连接代次）

    /// 把异步操作的结果收成 Result（Result 的同步初始化器不接受异步闭包）。
    private func attempt<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    private func loadOptions() async {
        guard options == nil, let client = session.issueTaskClient() else { return }
        let started = scope()
        let result = await attempt { try await client.issueTaskOptions() }
        switch IssueTaskFlow.resolve(result, started: started, current: scope()) {
        case let .value(o):
            options = o
            syncLanguage()
            draft.source = IssueTaskRules.defaultSource(o)
            if let preselectedTargetId, let t = o.targets.first(where: { $0.targetId == preselectedTargetId && $0.usable }) {
                draft.targetId = t.targetId; draft.destinationVersion = t.destinationVersion
            }
        case let .failed(failure):
            if failure == .legacyBridge { unsupported = true } else { loadError = LText(IssueTaskRules.errorCopy(failure)) }
        case .discarded:
            return
        }
    }

    private func loadPage(_ n: Int) async {
        guard let client = session.issueTaskClient(), let sourceId = draft.sourceId else { return }
        busy = true; defer { busy = false }
        let started = scope()
        let result = await attempt { try await client.issueTaskList(sourceId: sourceId, page: n) }
        switch IssueTaskFlow.resolve(result, started: started, current: scope()) {
        case let .value(p):
            issues = n == 1 ? p.items : issues + p.items
            page = n
            notice = nil
        case let .failed(failure): notice = LText(IssueTaskRules.errorCopy(failure))
        case .discarded: return
        }
    }

    /// 点选一个 Issue：只采纳最新一次点选的结果（A1-192 R1）。
    private func selectIssue(number: Int) async {
        guard let client = session.issueTaskClient(), let sourceId = draft.sourceId else { return }
        busy = true; defer { busy = false }
        let sequence = selection.next()
        let started = scope()
        let result = await attempt { try await client.issueTaskDetail(sourceId: sourceId, number: number) }
        guard selection.isLatest(sequence) else { return }
        switch IssueTaskFlow.resolve(result, started: started, current: scope()) {
        case let .value(d):
            draft.ackClosed = false
            draft.issue = d
            notice = nil
        case let .failed(failure): notice = LText(IssueTaskRules.errorCopy(failure))
        case .discarded: return
        }
    }

    /// 粘贴的规范链接：仓库必须在允许列表里，否则不读取（也不暴露存在性）。
    private func locateLink(options o: IssueTaskOptions) async {
        linkNote = nil
        guard IssueTaskRules.validReferenceURL(pasteLink) else { linkNote = LText(String(localized: "请粘贴 https://github.com/owner/repo/issues/编号 形式的链接。")); return }
        let parts = pasteLink.dropFirst("https://github.com/".count).split(separator: "/")
        guard let n = Int(parts[3]) else { return }
        let repo = "\(parts[0])/\(parts[1])"
        guard let source = o.sources.first(where: { $0.repo == repo }) else { linkNote = LText(String(localized: "这个仓库不在允许的来源里。")); return }
        draft.source = .github
        draft.sourceId = source.sourceId
        await selectIssue(number: n)
        if draft.issue == nil { linkNote = LText(String(localized: "找不到这个 Issue，或它不在允许的来源里。")) }
    }

    private func makePreview() async {
        syncLanguage()
        guard let req = draft.previewRequest(), session.issueTaskBlocker() == nil else { return }
        busy = true; defer { busy = false }
        let started = scope()
        let result = await attempt { try await session.issueTaskPreviewChecked(req) }
        switch IssueTaskFlow.resolve(result, started: started, current: scope()) {
        case let .value(p):
            draft.acceptPreview(p, startedAt: started.draft) // 草稿在途被改过则丢弃（A1-190 F1）
            notice = nil
        case let .failed(failure):
            draft.setPreview(nil) // 失败即作废：旧正文不得继续表示为已核验
            notice = LText(IssueTaskRules.errorCopy(failure))
            await apply(recovery: failure, started: started)
        case .discarded: return
        }
    }

    /// 当前草稿与连接的作用域：读取结果必须与发起时一致（A1-190 F1）。
    private func scope() -> IssueTaskScope { IssueTaskScope(epoch: session.connectionEpoch, draft: draft.revision) }

    /// 放弃结果未知的请求：清除并给出固定说明（在 sheet 内显示）。
    private func abandon() {
        pending = nil
        notice = LText(Self.abandonedNote)
    }

    /// 确认：生成新的完整请求并提交一次。
    private func confirm() async {
        guard session.issueTaskBlocker() == nil else { return }
        syncLanguage()
        let id = UUID().uuidString.lowercased()
        guard let req = draft.createRequest(clientMsgId: id), let targetId = draft.targetId,
              let summary = draft.preview?.text.components(separatedBy: "\n").first else { return }
        await submit(req, summary: summary, targetId: targetId)
    }

    /// 提交一个完整、不可变的请求。写入只核对连接代次：请求已发出，草稿变化不改变其结果（已受理的回显照常落账）。
    private func submit(_ req: IssueTaskRequest, summary: String, targetId: String) async {
        busy = true; defer { busy = false }
        let started = session.connectionEpoch
        let clientMsgId = req.clientMsgId ?? ""
        let result = await attempt { try await session.issueTaskCreateChecked(req) }
        switch IssueTaskFlow.resolve(result, started: IssueTaskScope(epoch: started, draft: 0), current: IssueTaskScope(epoch: session.connectionEpoch, draft: 0)) {
        case let .value(created):
            pending = nil
            session.recordIssueAccepted(clientMsgId: clientMsgId, summary: summary, targetId: targetId, eventKey: created.eventKey, epoch: started)
            // sheet 已离开界面（alive=false）时不再回调与关闭；受理结果已在上面落账。
            if alive { onAccepted(targetId); dismiss() }
        case .failed(.unknown):
            // 结果未知：保存完整请求，只能原样重投核对（服务端对完全相同的重投给出同一身份）。
            let kept = IssueTaskPendingSubmission(request: req, summary: summary, targetId: targetId)
            if alive {
                pending = kept
                notice = LText(String(localized: "网络结果未知，消息可能已发出。可以原样重投核对，不会产生第二条。"))
            } else {
                onAbandoned(Self.abandonedNote) // 已关闭：没有界面可以核对，直接给出说明
            }
        case let .failed(failure):
            pending = nil
            draft.setPreview(nil) // 确认被拒：作废预览，重新预览后才能再发
            notice = LText(IssueTaskRules.errorCopy(failure))
            await apply(recovery: failure, started: IssueTaskScope(epoch: started, draft: draft.revision))
        case .discarded: return
        }
    }

    /// 失败后的恢复（R4）：需要更新的版本先重新读取，用户仍须重新预览并显式确认。
    private func apply(recovery failure: IssueTaskFailure, started: IssueTaskScope) async {
        guard case let .refused(_, recovery) = failure, let client = session.issueTaskClient() else { return }
        switch recovery {
        case .none, .repreview:
            return
        case .refreshDetail:
            guard let issue = draft.issue, let sourceId = draft.sourceId else { return }
            let result = await attempt { try await client.issueTaskDetail(sourceId: sourceId, number: issue.number) }
            if case let .value(d) = IssueTaskFlow.resolve(result, started: started, current: scope()) {
                draft.issue = d
                notice = LText(String(localized: "Issue 已更新，请确认新内容后重新预览。"))
            }
        case .refreshOptions:
            let result = await attempt { try await client.issueTaskOptions() }
            if case let .value(o) = IssueTaskFlow.resolve(result, started: started, current: scope()) {
                options = o
                syncLanguage()
                draft.targetId = nil
                draft.destinationVersion = nil
                notice = LText(String(localized: "执行会话已变化，请重新选择。"))
            }
        }
    }
}

/// 来源分段：GitHub 不可用时该段真正禁用（不可点、读屏说明原因），手工需求始终可用。
private struct IssueSourceSegment: View {
    let source: SwiftUI.Binding<IssueTaskDraft.Source>
    let githubEnabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            segment("GitHub Issue", .github, enabled: githubEnabled)
            segment(String(localized: "手工需求"), .manual, enabled: true)
        }
        .padding(3)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity)
    }

    private func segment(_ title: String, _ value: IssueTaskDraft.Source, enabled: Bool) -> some View {
        let selected = source.wrappedValue == value
        return Button { source.wrappedValue = value } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(enabled ? title : String(localized: "\(title)，不可用"))
        .accessibilityHint(enabled ? "" : String(localized: "GitHub 来源不可用，请到 Mac 终端检查 gh 登录状态；手工需求仍可用"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
