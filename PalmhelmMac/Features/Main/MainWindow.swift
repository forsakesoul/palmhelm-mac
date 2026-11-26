import SwiftUI
import PalmhelmKit

// 主窗口（h10c M1）：顶部「会话｜用量」自绘分段；会话页 = 左侧统一侧栏（收件箱｜空间，320–360pt，可折叠）+ 右侧宽工作区（线程 / 请求详情）。
// 窄窗（< 900pt）默认收起侧栏，但始终保留「展开收件箱」入口与带数铃铛。
struct MainWindow: View {
    @Environment(MacSession.self) private var session
    @Environment(BridgeEngine.self) private var engine
    @Environment(EngineSettings.self) private var settings
    @Environment(UpdateChecker.self) private var updates: UpdateChecker? // 可选：只读宿主（视图测试）不必注入
    @Environment(\.openWindow) private var openWindow
    enum Page: Int { case conversation = 0, usage = 1 }
    // 关掉主窗口再从菜单栏打开时保持在原来的页面（@State 会随窗口销毁重置）
    @AppStorage("palmhelm.mainPage") private var pageRaw = ProcessInfo.processInfo.arguments.contains("-palmhelmPage") && ProcessInfo.processInfo.arguments.contains("stats") ? 1 : 0
    @AppStorage("palmhelm.sidebarShown") private var sidebarUserWants = true // 宽窗里的用户意图
    @State private var sidebarTemp = false // 窄窗里的临时展开（回宽窗即清）
    @State private var alertsShown = false
    @State private var issueShown = false // #21：新任务…（派发 Issue / 需求）
    @State private var issueNoteShown = false // 派发 sheet 放弃结果未知的请求后的固定说明
    @State private var issueNote = ""
    @State private var proxyWidth: CGFloat = 1200
    /// 侧栏宽度（#29）：拖分隔条调整，存在 AppDefaults（SidebarWidth），重启后恢复；显示时再按可用宽度夹取。
    @State private var sidebarWidth: CGFloat = SidebarWidth.load(AppDefaults.standard) // 保存的意图宽度：只在松手时改写
    @State private var sidebarPreview: CGFloat? // 拖动中的预览宽度（不保存）；为 nil 时显示夹取后的意图宽度

    private var page: SwiftUI.Binding<Page> { Binding(get: { Page(rawValue: pageRaw) ?? .conversation }, set: { pageRaw = $0.rawValue }) }
    private var narrow: Bool { SidebarState.isNarrow(proxyWidth) }
    private var sidebar: SidebarState {
        get { SidebarState(userWants: sidebarUserWants, tempOpen: sidebarTemp) }
        nonmutating set { sidebarUserWants = newValue.userWants; sidebarTemp = newValue.tempOpen }
    }
    private var sidebarShown: Bool { sidebar.shown(narrow: narrow) }
    private var showsSidebar: Bool { page.wrappedValue == .conversation && sidebarShown }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if page.wrappedValue == .conversation, session.state == nil, phase != .connected {
                    // 首份权威 state 到达前不露出两栏空壳：整窗只显示启动状态（失败时给设置入口）
                    LaunchView(phase: phase, keychainStalled: settings.keychainStalled).transition(.opacity)
                } else if page.wrappedValue == .conversation { // 用量页是全局视图，不需要侧栏
                    if showsSidebar {
                        let shown = sidebarPreview ?? SidebarWidth.clamp(sidebarWidth, available: proxyWidth) // 显示 = 夹取后的意图宽度（或拖动预览）；窗口变窄只改显示，不改保存值
                        InboxSidebar().frame(width: shown)
                        SidebarDivider(width: shown, available: proxyWidth,
                                       onPreview: { sidebarPreview = $0 },
                                       onCommit: { w in sidebarWidth = w; sidebarPreview = nil; SidebarWidth.save(w, to: AppDefaults.standard) })
                    }
                    Workspace().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MacStatsView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let r = updates?.banner {
                    UpdateBanner(release: r, onDownload: { UpdateLinks.open(r.releaseURL) }, onNotes: { UpdateLinks.open(UpdateRelease.changelogURL) },
                                 onSkip: { updates?.skip() }, onDismiss: { updates?.dismiss() })
                }
            }
            .animation(.easeInOut(duration: 0.45), value: session.state == nil) // 启动页 → 两栏：淡入淡出，不硬切
            .background(GeometryReader { g in Color.clear.onAppear { proxyWidth = g.size.width }.onChange(of: g.size.width) { _, w in proxyWidth = w; var st = sidebar; st.widthChanged(narrow: SidebarState.isNarrow(w)); sidebar = st } })
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-palmhelmShowPairing") { openWindow(id: "pairing") } // 走查用
            applyNavigation() // 冷启动 / 窗口关闭后重开：入口留在 Session 的意图在这里消费
            if session.requestConversation { page.wrappedValue = .conversation; session.requestConversation = false } // 独立搜索窗口请求时主窗口可能尚未 onAppear
        }
        .onChange(of: session.pendingNav) { _, _ in applyNavigation() }
        .onChange(of: session.requestConversation) { _, v in if v { page.wrappedValue = .conversation; session.requestConversation = false } } // 搜索命中：切回对话页（R5）
        // 挂在常驻的窗口根上，不挂在提醒入口的条件宿主里：入口随数据清空消失时，关闭事件也不会丢（A1-001 R4）
        .onChange(of: alertsShown) { _, shown in if shown { session.openReminders() } else { session.closeReminders() } }
        // 身份变化已结束本次展示；弹层仍开着就按新身份重开批次，不依赖再次打开
        .onChange(of: session.reminderIdentity.id) { _, _ in if alertsShown { session.openReminders() } }
        .sheet(isPresented: $issueShown) {
            IssueTaskSheet(preselectedTargetId: session.selectedTarget, onAccepted: { id in session.selectTarget(id) },
                           onAbandoned: { issueNote = $0; issueNoteShown = true })
                .environment(session)
        }
        .onChange(of: session.connectionEpoch) { _, _ in issueShown = false } // 连接切换即关闭派发 sheet
        .alert("派发未确认", isPresented: $issueNoteShown) { Button("好") {} } message: { Text(issueNote) }
        .alert("这份报告会是中文", isPresented: Binding(get: { session.reportLanguageNotice }, set: { if !$0 { session.reportLanguageNotice = false } })) { Button("好") {} } message: { Text("这台 Mac 上的 Bridge 还不能生成英文报告，面板 / 任务的内容会是中文。升级到 Bridge 0.3.12 后即可得到英文。") }
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { PalmhelmAppIcon(size: 22).help("Palmhelm") }.sharedBackgroundVisibility(.hidden) // 品牌位：不套工具栏按钮底框
            } else {
                ToolbarItem(placement: .navigation) { PalmhelmAppIcon(size: 22).help("Palmhelm") }
            }
            // 分段自带圆角底：macOS 26 上不再被工具栏玻璃胶囊多包一层（与品牌位同写法）
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) { pageSwitcher }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { pageSwitcher }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { var st = sidebar; st.toggle(narrow: narrow); sidebar = st } label: { Image(systemName: "sidebar.leading") }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(page.wrappedValue != .conversation)
                    .help(sidebarShown ? String(localized: "收起收件箱 ⌘⌥S") : String(localized: "展开收件箱 ⌘⌥S"))
                    .accessibilityLabel(sidebarShown ? String(localized: "收起收件箱") : String(localized: "展开收件箱"))
                Button { issueShown = true } label: { Image(systemName: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(page.wrappedValue != .conversation || session.state == nil || !session.isPaired)
                    .help("新任务… ⌘N")
                    .accessibilityLabel("新任务")
                Button { openWindow(id: "search") } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(page.wrappedValue != .conversation || session.state == nil)
                    .help("搜索会话 ⌘F")
                    .accessibilityLabel("搜索会话")
                // 铃铛与提醒入口各自是小视图：它们读取的待处理 / 提醒集合只让自己重算，不让整个工具栏随之失效。
                BellToolbarButton {  // 带数入口（待处理请求数）；点开 = 展开收件箱。窄窗收起侧栏时它仍在工具栏里。
                    page.wrappedValue = .conversation; var st = sidebar; st.reveal(narrow: narrow); sidebar = st; NSApp.activate(ignoringOtherApps: true); Task { await session.bellTapped() } // 侧栏已开也要有可见反应：定位到第一条待答（或收件箱顶部）并高亮
                }
                AlertsToolbarButton(shown: $alertsShown)
                SettingsLink {
                    HStack(spacing: 6) {
                        StatusDot(kind: phase == .connected ? .ok : phase.isTransitional ? .warn : .off)
                        Text(engineSummary).font(.caption).lineLimit(1)
                        Image(systemName: "gearshape")
                    }
                }
                .help(engineHelp)
                Button("配对新设备") { openWindow(id: "pairing") }.disabled(!engine.isRunning).help(engine.isRunning ? String(localized: "给手机发 6 位配对码") : String(localized: "Bridge 未运行"))
            }
        }
    }

    private var pageSwitcher: some View {
        PalmhelmSegmented(options: [(Page.conversation, String(localized: "指挥台")), (Page.usage, String(localized: "用量"))], selection: page, segmentWidth: 64)
    }

    /// 消费 Session 里待处理的导航意图：请求 / 收件箱 → 展开侧栏；线程 → 回到会话页。主窗口没出现过时意图一直留着，窗口出现后在 onAppear 消费。
    private func applyNavigation() {
        guard let nav = session.consumeNav() else { return }
        page.wrappedValue = .conversation
        switch nav.destination {
        case .request, .inbox: var st = sidebar; st.reveal(narrow: narrow); sidebar = st
        case .thread: break
        }
    }

    private var phase: ConnectionPhase { currentPhase(engine, settings, session) }
    /// 顶栏只放一句短状态；模式、地址、端口在悬停说明和设置里（A1-109 §2 顶栏）。
    private var engineSummary: String {
        if settings.keychainStalled, !settings.secretsLoaded || !session.credentialsLoaded { return ConnectionPhase.credentialsWaitText(stalled: true) }
        return phase == .connected ? String(localized: "已连接") : phase.label
    }
    private var engineHelp: String {
        guard engine.isRunning, let pf = engine.portFile else { return String(localized: "打开设置启动 Bridge") }
        return String(localized: "Bridge 运行中 · \(engine.mode) · \(pf.transport) \(pf.bind):\(pf.apiPort) · 本机连接\(session.link == .connected ? String(localized: "正常") : String(localized: "未就绪"))。点击打开设置")
    }
}

/// 右侧工作区：请求详情（提问 / 计划 / 长命令）或所选目标的线程。请求详情的有效性由详情自己核对（不在这里读 now，免得每秒重建线程）。
private struct Workspace: View {
    @Environment(MacSession.self) private var session
    var body: some View {
        if session.selectedRequest != nil {
            RequestDetailPane()
        } else {
            ThreadColumn(threadId: session.selectedThread ?? session.threads(for: session.selectedTarget).first?.id)
        }
    }
}

/// 启动页：读取凭据、启动 Bridge、配对 / 同步期间整窗显示；失败或离线时说明并给设置入口。
private struct LaunchView: View {
    let phase: ConnectionPhase
    let keychainStalled: Bool
    @State private var shown = false
    private var text: String { keychainStalled ? ConnectionPhase.credentialsWaitText(stalled: true) : phase.label }
    var body: some View {
        VStack(spacing: 14) {
            PalmhelmAppIcon(size: 72)
                .scaleEffect(shown ? 1 : 0.86).opacity(shown ? 1 : 0) // 图标先“落”进来，文字随后
            Text("Palmhelm").font(.title2.weight(.bold)).opacity(shown ? 1 : 0)
            HStack(spacing: 8) {
                if phase.isTransitional && !keychainStalled { ProgressView().controlSize(.small) }
                Text(text).font(.callout).foregroundStyle(phase.isTransitional ? .secondary : PalmhelmTheme.warn)
                    .contentTransition(.opacity).id(text) // 阶段文案变化时淡入淡出
            }
            .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 6)
            .animation(.easeInOut(duration: 0.3), value: text)
            if !phase.isTransitional || keychainStalled { SettingsLink { Text("打开设置") }.transition(.opacity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(duration: 0.55, bounce: 0.2)) { shown = true } }
    }
}

private struct ThreadColumn: View {
    @Environment(MacSession.self) private var session
    @State private var threadIssueShown = false // #21：线程「⋯」派发任务（预选本线程）
    @State private var threadIssueNoteShown = false
    @State private var threadIssueNote = ""
    /// 只读消息账本（#89 片 B）：捕获打开时的 scope，换目标 / 连接 / Bridge 即关闭。
    @State private var ledger: LedgerScope?
    /// 「解除 Bridge 占用…」确认前捕获的对象（A2-000 #2）：当前线程自己的 targetId + 账本 scope。
    @State private var resetRequest: OwnerResetRequest?
    /// 发送方式浮层打开时捕获的票据（nil = 关闭）；选择与关闭都消费这一份（A2-000 #1，A1-000 B-F1）。
    @State private var sendOptionsOpened: SendOptionsTicket?
    let threadId: String?
    @State private var composerError: LText?
    /// 输入法组字的发送准入：按钮 / 菜单 / Return 经 submit 统一询问它。
    @State private var composerGate = ComposerCompositionGate()
    @Environment(EngineSettings.self) private var settings
    // 编辑草稿 / 附件 / 发送中都在 Session 里（按 连接身份 + 目标）：切线程、切 对话 / 统计、换主题都不丢，也不串目标
    private var busy: Bool { threadId.map { session.isComposerBusy($0) } ?? false }
    private var draftText: String { threadId.map { session.draft($0).text } ?? "" }
    private var draftAttachments: [ComposerAttachment] { threadId.map { session.draft($0).attachments } ?? [] }
    private func draftBinding(_ id: String) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(get: { session.draft(id).text }, set: { var d = session.draft(id); d.text = $0; session.setDraft(d, for: id) })
    }
    private func attachmentsBinding(_ id: String) -> SwiftUI.Binding<[ComposerAttachment]> {
        SwiftUI.Binding(get: { session.draft(id).attachments }, set: { var d = session.draft(id); d.attachments = $0; session.setDraft(d, for: id) })
    }
    @State private var revealing = false
    @State private var detailsShown = false // 线程详情 popover 展示期间头部恒显示
    @State private var revealNote: (ok: Bool, message: LText)?
    @State private var revealGen = 0
    @State private var threadRenameShown = false // 「重命名对话…」弹层（#134）；连接切换即关闭
    @State private var threadRenameScope: LedgerScope? // 打开弹层时捕获的改名范围；提交前由会话层复核
    @State private var windowVisible = true // 窗口未被遮挡（WindowVisibilityReader）：隐藏、最小化或完全遮挡时为假
    @State private var stuck = true // 对话滚动区是否贴底（G：只有贴底才跟随内容增高）
    @State private var userScrolling = false // 用户正在拖动 / 惯性滚动（S2：此时以几何为准）
    @State private var followTask: Task<Void, Never>? // 排队中的滚底（单飞：新计划替换旧计划）
    @State private var footerHeight: CGFloat = 0
    // 头部随滚动收起（规则 A，见 ThreadChromeSupport.swift）：局部引用，只有 hidden 被叶子观察；根与消息行不读它。
    @State private var chrome = MacThreadChrome()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 窗口是否为 key（焦点在本窗口）：激活读取只在它为真时进行（菜单、设置窗口抢焦点时停止）。
    @Environment(\.controlActiveState) private var controlActive
    /// 线程是否在界面上（onAppear / onDisappear）。
    @State private var threadVisible = false
    /// 展开过的长回复、以及刚写完的回复（不当场收起）：本次浏览内保留。
    @State private var expandedItems: Set<String> = []
    @State private var holdUnfolded: Set<String> = []
    /// 离开底部后又有新消息：显示「↓ 回到最新」。
    @State private var hasNewBelow = false
    /// 骨架确认后已在界面上的块：之后新增的块才淡入（#88 S4）。
    @State private var knownIds: Set<String> = []
    private var mode: Int { session.threadMode }
    /// 头部必须显示的其它条件：派发 sheet / 说明 / 反馈、窗口被遮挡 / 最小化、终端页。
    private var chromeForce: Bool { threadIssueShown || threadIssueNoteShown || revealNote != nil || revealing || !windowVisible || mode == 1 || ledger != nil || detailsShown || session.located.map { $0.threadId == threadId } == true }
    /// 当前窗口是否为真正最新：非定位页、窗口下方无行、无被裁掉的较新内容（只有此时的贴底才强制显示）。
    private func latestWindowNow(_ id: String) -> Bool {
        guard let t = session.transcripts[id], t.status == .ok else { return true }
        return session.located?.threadId != id && !t.hasRowsBelowWindow && !t.hasNewer
    } // 对话 / 终端：由 Session 持有，打开搜索命中时强制对话（F4）

    // 稳定层：空选择（A→nil→B）与换线程都经这里重置，不依赖可选分支的生命周期（#60 A1-227 R2）
    var body: some View {
        let _ = MacRenderCounter.bump("root")
        columnBody
            .onChange(of: threadId) { _, _ in chrome.reset() }
            .onAppear { chrome.observeVoiceOver() }
            .onDisappear { chrome.tearDown() } // 离开指挥台 / 卸载：取消恢复任务并显示（空选择也走这里，不依赖可选分支）
    }

    @ViewBuilder private var columnBody: some View {
        if let threadId {
            let target = session.state?.targets.first { $0.id == threadId }
            VStack(spacing: 0) {
                let canShowTerminal = target?.location?.pane != nil
                // 常驻行（#112 方案 A）：⋯ + 标题 + 局部「对话｜终端」切换（有终端页的目标才有）；不随头部收起、不算进 H
                threadTitleRow(threadId, target: target, canShowTerminal: canShowTerminal)
                if mode == 1, target?.location?.pane != nil {
                    MacChromeHeader(chrome: chrome) { threadHeader(threadId, target: target) } // 终端页：头部静态显示（强制显示，不跟手）
                    MacTerminalMirrorView(threadId: threadId).id(threadId).padding(.top, 8) // 换目标重建镜像（A1-145 F1）
                } else {
                ZStack(alignment: .top) { // 固定 viewport + 头部 overlay：进度只改头部的 offset / opacity，不改消息区尺寸与 inset
                ScrollViewReader { proxy in
                    ScrollView {
                        // VStack（非懒加载）：LazyVStack 按估高声明内容高度，底部的行没被计入，最新回复滚不到（O1-336）。
                        VStack(alignment: .leading, spacing: 10) {
                            MacChromeSpacer(chrome: chrome) // 头部叶子的固定占位（高 H，不随进度变）
                            let rows = session.rows(for: threadId)
                            let showingTranscript = session.transcripts[threadId]?.status == .ok
                            if noneOnline {
                                Label("现在没有在线的 agent：在 Herdr 里打开或恢复一个 agent 窗格后会自动出现；离线目标以前的记录仍可翻看", systemImage: "moon.zzz")
                                    .font(.callout).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(PalmhelmTheme.card2.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if rows.isEmpty, !showingTranscript, session.link == .connecting { EmptyView() } // 同步中的骨架改在视口 overlay 显示：不向滚动内容塞占位，也不叠空态
                            else if rows.isEmpty, !showingTranscript { emptyState(target).frame(maxWidth: .infinity).padding(.top, 80) } // 正在显示会话记录时不叠旧空态（A1-121 F7）
                            else if !noneOnline, let t = target, session.targetOnline(t.id) == false {
                                Label("这个 agent 现在不在线，消息暂时送不到；下面是以前的记录", systemImage: "moon.zzz").font(.caption).foregroundStyle(.secondary)
                            }
                            if session.located?.threadId == threadId, session.transcripts[threadId]?.pinnedHit != nil {
                                HStack(spacing: 8) {
                                    Label("正在看搜索命中的记录", systemImage: "scope").font(.caption).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Button("回到最新") { chrome.reset(); Task { await session.returnToLatest(threadId) } }.controlSize(.small) // 显式回最新：先显示并作废旧恢复票据，再发异步请求
                                }
                                .padding(8).background(PalmhelmTheme.card2.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if let t = session.transcripts[threadId], t.status == .ok, t.hasRowsBelowWindow || t.hasNewer, session.located?.threadId != threadId {
                                HStack(spacing: 8) {
                                    Label("只显示较早的 \(TranscriptThread.renderLimit) 行，较新的记录已收起", systemImage: "list.bullet").font(.caption).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Button("回到最新") { chrome.reset(); Task { await session.jumpToLatestTranscript(threadId) } }.controlSize(.small)
                                }
                                .padding(8).background(PalmhelmTheme.card2.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if let n = session.locateNote { Label(n.text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(PalmhelmTheme.warn) }
                            if let t = session.transcripts[threadId], t.stale, t.status == .ok { // 临时失败：保留已核验内容，显示陈旧状态与重试
                                HStack(spacing: 8) {
                                    Text("无法更新，显示的是上次内容").font(.caption).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Button("重试") { Task { await session.loadTranscriptLatest(threadId) } }.controlSize(.small)
                                }
                                .padding(8).background(PalmhelmTheme.card2.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if let t = session.transcripts[threadId], t.status == .ok {
                                TranscriptTopMarker(thread: t) {
                                    // 本地展开：停在新窗口顶部；网络前插：停在原来的第一条（它仍在窗口内）
                                    let local = t.hasRowsAboveWindow
                                    let first = t.visibleItems.first?.id
                                    Task { await session.loadTranscriptOlder(threadId); if let target = local ? session.transcripts[threadId]?.visibleItems.first?.id : first { proxy.scrollTo(target, anchor: .top) } }
                                }
                                // owner 操作按发起位置（transcript 条目锚）渲染，原发送时间与位置不因结果到达而改变；一次投影，数据变化才重算。
                                let ownerPlacement = session.ownerPlacement(threadId: threadId, visibleItemIds: Set(t.visibleItems.map(\.id)))
                                ForEach(Array(t.visibleItems)) { item in let _ = MacRenderCounter.bump("row"); TranscriptItemRow(item: item, highlight: session.located?.highlight(for: threadId), agentWorking: session.targetWorking(threadId), linkedCommand: session.linkedCommand(item.receipt), status: session.recordStatus(item.receipt), folding: foldingFor(item, threadId: threadId, proxy: proxy)).id(item.id).palmhelmReveal().modifier(FadeInOnAppear(enabled: session.transcriptSettled(threadId) && !knownIds.contains(item.id)))
                                    ForEach(ownerPlacement.after[item.id] ?? []) { m in echoRow(m) } }
                                // 尾部一次投影（#89 片 B）：期限行 + 补行 + 本机回显按实际行集合去重；历史 / 定位窗为空。回显的显示规则在 MacSession.pendingEchoes。
                                let tail = session.threadTail(threadId: threadId)
                                ForEach(tail.commandRows) { c in RowView(row: .command(c)).id(c.key) }
                                ForEach(tail.echoes) { m in echoRow(m) } // 刚发、还没进记录的本机消息；面板 / 任务等操作的回执按 replyTo 跟在气泡下面（回执不在会话记录里）
                                // 本机操作记录（owner 操作如解除占用）：锚不在可见窗的旧操作，保留原发送时间，只在最新窗出现（片 A 的 ownerPlacement）。
                                if !ownerPlacement.local.isEmpty {
                                    Text("本机操作记录（原发送时间）").font(.caption2).foregroundStyle(.secondary)
                                    ForEach(ownerPlacement.local) { m in echoRow(m) }
                                }
                                if session.commandWindow.truncated { // 窗口截断是 scope 级事实：不宣称本目标漏了几条
                                    Text("当前只显示部分消息，可查看消息账本").font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                if let t = session.transcripts[threadId], t.status != .loading { TranscriptUnavailableCard(status: t.status, reason: t.unavailableReason) }
                                if let t = session.transcripts[threadId], case .failed = t.status { Button("重试") { Task { await session.loadTranscriptLatest(threadId) } }.controlSize(.small) }
                                ForEach(QueueCardCoverage.visible(rows, cardShown: { session.messageStatus(for: $0).card != nil })) { row in RowView(row: row, onRestore: restore, restoreEnabled: canEdit).id(row.id).palmhelmReveal() }
                            }
                        Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(16)
                        .palmhelmAnimation(session.rows(for: threadId).map(\.id), quick: true)
                    }
                    .defaultScrollAnchor(.bottom) // 打开对话直接停在最新一条，不用手动滑到底
                    .id(threadId) // 换线程重建滚动视图，锚点重新生效
                    .overlay { // 骨架门禁：切换线程后直到当前激活的首个应答（或错误）到达才显示内容，不按计时；减弱动态效果时照样显示
                        // 两个互斥条件各自沿原门禁与原文案（打开会话 / 首次同步），不并成新门禁；骨架是贴底气泡流，铺满有限视口，用 Mac 真实 120 / 12 / bubbleAgent 尺寸。
                        if session.transcriptShowsSkeleton(threadId) {
                            ZStack { Color(nsColor: .windowBackgroundColor); SkeletonThread(userBubble: PalmhelmTheme.bubbleMe, card: PalmhelmTheme.bubbleAgent, metrics: .mac, label: String(localized: "正在打开会话")).padding(16) }
                        } else if session.rows(for: threadId).isEmpty, session.transcripts[threadId]?.status != .ok, session.link == .connecting {
                            ZStack { Color(nsColor: .windowBackgroundColor); SkeletonThread(userBubble: PalmhelmTheme.bubbleMe, card: PalmhelmTheme.bubbleAgent, metrics: .mac, label: String(localized: "正在同步对话")).padding(16) }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { let _ = MacRenderCounter.bump("footer"); footer(threadId, target: target, noneOnline: noneOnline) } // 底栏不占滚动内容，避免盖住最后一条（G）
                    .trackScroll(stuck: $stuck, userScrolling: $userScrolling)
                    #if DEBUG
                    // 宿主无法点击 SwiftUI 按钮：测试经此入口调用与按钮相同的闭包；仅诊断打开时注册，滚动区离场 / 换线程即清，不留旧 scope 的动作
                    .onAppear { if MacDiagnostics.enabled { chrome.jumpToLatestForTest = jumpToLatestAction(proxy, threadId) } }
                    .onChange(of: threadId) { _, id in if MacDiagnostics.enabled { chrome.jumpToLatestForTest = jumpToLatestAction(proxy, id) } }
                    .onDisappear { chrome.jumpToLatestForTest = nil }
                    #endif
                    .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }, action: { old, new in
                        // 布局（内容高度 / 视口 / 内边距）变化是否静默由 Kit 状态的时间门控决定，这里只上报事实；y 标准化为 contentOffset.y + contentInsets.top
                        let layoutChanged = old.contentSize != new.contentSize || old.containerSize != new.containerSize || old.contentInsets != new.contentInsets
                        let rawAtBottom = ThreadFollowRules.atBottom(contentOffsetY: new.contentOffset.y, contentHeight: new.contentSize.height, containerHeight: new.containerSize.height + new.contentInsets.top, contentInsetBottom: 0)
                        #if DEBUG
                        let digest = !MacDiagnostics.enabled ? "" : "c\(Int(new.containerSize.height)) i\(Int(new.contentInsets.top))/\(Int(new.contentInsets.bottom)) s\(Int(new.contentSize.height)) f\(Int(footerHeight)) o\(Int(new.contentOffset.y))"
                        chrome.observeGeometry(offsetY: MacThreadChrome.normalizedOffset(contentOffsetY: new.contentOffset.y, insetTop: new.contentInsets.top, contentHeight: new.contentSize.height, containerHeight: new.containerSize.height, insetBottom: new.contentInsets.bottom), rawAtBottom: rawAtBottom, layoutChanged: layoutChanged, digest: digest)
                        #else
                        chrome.observeGeometry(offsetY: MacThreadChrome.normalizedOffset(contentOffsetY: new.contentOffset.y, insetTop: new.contentInsets.top, contentHeight: new.contentSize.height, containerHeight: new.containerSize.height, insetBottom: new.contentInsets.bottom), rawAtBottom: rawAtBottom, layoutChanged: layoutChanged)
                        #endif
                    })
                    .onScrollPhaseChange { _, phase in chrome.phaseChanged(to: HeaderCollapsePhase(phase)) }
                    .onPreferenceChange(FooterHeightKey.self) { footerHeight = $0 }
                    .onChange(of: footerHeight) { _, _ in followBottom(proxy, threadId) }
                    .onChange(of: session.history.last?.seq) { _, _ in // 看最后一条的 seq 而非条数：历史满 500 条后条数不再变
                        followBottom(proxy, threadId)
                        session.markSeen(threadId) // 开着的线程里新来的回执算已看
                        autoRestore()
                    }
                    .onAppear { // 从搜索进入（或重新打开同一命中）时停在命中那条；否则由最新页接管
                        session.markSeen(threadId)
                        if let l = session.located, l.threadId == threadId { Task { try? await Task.sleep(for: .milliseconds(80)); proxy.scrollTo(l.itemId, anchor: .center) } }
                        Task { await session.loadTranscriptLatest(threadId) }
                        threadVisible = true; syncTranscriptActivity(threadId)
                    }
                    .onChange(of: session.sent) { _, _ in autoRestore() } // eventKey 可能晚于拒绝回执到达，两者任一变化都检查
                    .onChange(of: threadId) { _, id in // 切线程：贴底重新开始，旧的排队滚底失效（S2）
                        stuck = true; followTask?.cancel(); followTask = nil
                        expandedItems = []; holdUnfolded = []; knownIds = [] // 展开、保留与淡入状态按线程重来
                        session.markSeen(id); Task { await session.loadTranscriptLatest(id) }
                        syncTranscriptActivity(id)
                    }
                    .onChange(of: session.transcriptSettled(threadId)) { _, settled in if settled { knownIds = Set(session.transcripts[threadId]?.items.map(\.id) ?? []) } }
                    .onChange(of: session.transcripts[threadId]?.items.last) { _, last in
                        followBottom(proxy, threadId) // 流式增长同 id 也要跟随
                        if !stuck, session.located?.threadId != threadId { hasNewBelow = true }
                        if session.targetWorking(threadId), let id = last?.id { holdUnfolded.insert(id) } // 正在写的回复写完后不当场收起
                    }
                    .onChange(of: stuck) { _, atBottom in if atBottom { hasNewBelow = false } }
                    .onChange(of: userScrolling) { _, scrolling in // 新手势作废排队中的锚定；手势结束停在窗口底部再决定本地展开或回到最新
                        if scrolling { followTask?.cancel() } else { advanceAtWindowBottom(proxy, threadId) }
                    }
                    .onChange(of: controlActive) { _, _ in chrome.reset(); syncTranscriptActivity(threadId) } // 失去 / 恢复 key：显示并作废旧恢复票据（A2-001 §3）；之后全新的滚轮手势仍按规则 A 触发
                    .onChange(of: chromeForce, initial: true) { _, on in chrome.setForced(on) }
                    .onChange(of: latestWindowNow(threadId), initial: true) { _, on in chrome.setLatestWindow(on) }
                    .onChange(of: session.located) { _, _ in chrome.reset() } // 定位到命中：显示并清空
                    .background(MacScrollInputGuard(chrome: chrome)) // knob / 键盘翻页：失败开放（显示头部、不跟手）
                    .background(WindowVisibilityReader { visible in windowVisible = visible; chrome.setForced(chromeForce); syncTranscriptActivity(threadId) }) // 遮挡 / 最小化 / 隐藏也停止激活读取
                    .onChange(of: session.connectionEpoch) { _, _ in chrome.reset(); syncTranscriptActivity(threadId) } // 换连接：激活读取停止
                    .onChange(of: mode) { _, _ in syncTranscriptActivity(threadId) } // 切到终端页：停止激活读取
                    .overlay(alignment: .bottom) {
                        if let t = session.transcripts[threadId], t.status == .ok, backToLatestShown(t) {
                            Button(action: jumpToLatestAction(proxy, threadId)) { // 与 iOS 同口径：直接回到最新页并贴底，不走逐段下移
                                Text("↓ 回到最新").font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(PalmhelmTheme.card, in: Capsule())
                            }
                            .buttonStyle(.plain).frame(minHeight: 28).accessibilityLabel("回到最新记录").padding(.bottom, footerHeight + 8)
                        } else if hasNewBelow && !stuck, session.transcripts[threadId]?.status == .ok {
                            Button { chrome.reset(); stuck = true; hasNewBelow = false; proxy.scrollTo("bottom", anchor: .bottom) } label: {
                                Text("↓ 回到最新").font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(PalmhelmTheme.card, in: Capsule())
                            }
                            .buttonStyle(.plain).frame(minHeight: 28).accessibilityLabel("回到最新记录").padding(.bottom, footerHeight + 8)
                        }
                    }
                    .onChange(of: session.located) { _, l in if let l, l.threadId == threadId { proxy.scrollTo(l.itemId, anchor: .center) } } // 定位：滚到命中并居中
                    .onDisappear { threadVisible = false; syncTranscriptActivity(threadId) }
                }
                MacChromeHeader(chrome: chrome) { threadHeader(threadId, target: target) }
                }
                            }
}
        } else {
            if session.link == .connected, session.state?.targets.isEmpty == true {
                ContentUnavailableView(String(localized: "还没有登记的 agent"), systemImage: "person.crop.circle.badge.questionmark", description: Text("在 Herdr 里启动 agent 并给窗格命名后，会出现在左边。"))
            } else {
                ContentUnavailableView(String(localized: "选择一个对话"), systemImage: "text.bubble")
            }
        }
    }

    /// 长回复的折叠状态（设计 12 第 3 节）：正在写的最新回复不折叠；展开过的与刚写完的（hold）保持展开。
    private func foldingFor(_ item: TranscriptItem, threadId: String, proxy: ScrollViewProxy) -> TranscriptRowFolding? {
        let streaming = item.id == session.transcripts[threadId]?.items.last?.id && session.targetWorking(threadId)
        guard !streaming, TranscriptFolding.isFoldable(item, isLatestStreaming: false) else { return nil }
        let shownFull = expandedItems.contains(item.id) || holdUnfolded.contains(item.id)
        return TranscriptRowFolding(
            folded: !shownFull,
            expansion: session.transcriptExpansions[MacSession.expansionKey(threadId, item.id)],
            expand: {
                expandedItems.insert(item.id)
                session.beginTranscriptExpansion(threadId, item)
            },
            collapse: {
                session.collapseTranscriptText(threadId, item.id) // 收起即作废展开实例（F3）
                expandedItems.remove(item.id)
                holdUnfolded.remove(item.id)
                proxy.scrollTo(item.id, anchor: .top) // 收起后让标题留在可见区
            },
            loadMore: { Task { await session.loadMoreTranscriptText(threadId, item.id) } })
    }

    /// 激活读取只在线程可见、窗口为 key 且显示对话（非终端页）时进行。
    private func syncTranscriptActivity(_ threadId: String) {
        session.setTranscriptActive(ThreadActivityGate.isActive(threadVisible: threadVisible, keyWindow: controlActive == .key, windowVisible: windowVisible, mode: mode) ? threadId : nil)
    }

    /// 对话标题旁的状态 chip（D4）：状态点 + 文字；工作中带时长。
    /// 底栏：活动行、直达提示、输入区、只读说明。挂在滚动区的底部安全区（G）。
    @ViewBuilder private func footer(_ threadId: String, target: TargetSummary?, noneOnline: Bool) -> some View {
        VStack(spacing: 0) {
            Divider()
            switchPrompt(threadId) // 目标切换的结果 / 多候选（迟到的候选也能选）
            // 发送目标与判定一致：绑定线程走飞书绑定；agent 名可直达的其他线程走「派给」（不改绑定）；其余非绑定线程只给切换入口，不给输入框。
            if let t = target, let agent = directAgent(threadId) {
                // 线程≠绑定但可直达：不受飞书绑定的切换/失败状态约束（I3），消息经「派给」发到该线程的 agent
                composer(t, direct: agent)
            } else if session.switching {
                HStack { SkeletonBlock(width: 14, height: 14, cornerRadius: 7); Text("正在切换目标，等 Bridge 确认后再发送。").font(.caption).foregroundStyle(.secondary) }.padding(12)
            } else if case .failed(let why) = session.switchState {
                HStack { Text(why.text).font(.caption).foregroundStyle(PalmhelmTheme.bad); Spacer(); Button("立即同步") { Task { await session.refresh() } } }.padding(12)
            } else if target != nil, noneOnline {
                Text("没有可以接收消息的在线目标：等 agent 上线后再发送。").font(.caption).foregroundStyle(.secondary).padding(12)
            } else if let t = target, session.state?.binding?.targetId != t.id {
                // 不可直达的线程：不给一个看似能发、实际发到别处的输入框，只说明情况并给唯一的切换入口（A1-109 §2 输入区）
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("此线程不支持直接发送，可把当前目标切到这里").font(.callout)
                        Text("切换后，从 Palmhelm 和飞书发的消息都会进入这里").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("把消息目标切换到这里") { Task { await session.switchTo(project: t.projectName, agent: t.agentName, targetId: t.id, inThread: t.id) } }
                        .buttonStyle(.palmhelmProminent).disabled(!session.canControl)
                }
                .padding(12)
            } else if target == nil {
                Text("这个目标已不在 Bridge 的列表里，不能发送。").font(.caption).foregroundStyle(.secondary).padding(12)
            } else if let t = target {
                composer(t, direct: nil)
            }
            // 只读是身份，不是某个状态：与上面任何一种并存，说明为什么操作是灰的（A1-110 F3）
            if !session.canControl {
                Label("这台 Mac 为只读：可以浏览记录，不能发送或操作", systemImage: "lock").font(.caption).foregroundStyle(PalmhelmTheme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(GeometryReader { g in Color.clear.preference(key: FooterHeightKey.self, value: g.size.height) })
    }

    /// 「↓ 回到最新」入口的显示条件：窗口之下有已加载的行，或离开底部且有被裁掉的较新内容。
    private func backToLatestShown(_ t: TranscriptThread) -> Bool {
        LatestWindowRules.showsBackToLatest(stuck: stuck, hasRowsBelowWindow: t.hasRowsBelowWindow, hasNewer: t.hasNewer) && (t.pinnedHit == nil || t.hasRowsBelowWindow)
    }

    /// 「↓ 回到最新」按钮的动作（唯一定义；DEBUG 测试入口取同一个闭包，不复制逻辑）。
    private func jumpToLatestAction(_ proxy: ScrollViewProxy, _ threadId: String) -> () -> Void {
        {
            chrome.reset() // 显式回最新：先显示并作废旧票据；窗口底≠真最新，跳转请求挂起期间不能靠几何强制显示兜底
            stuck = true; hasNewBelow = false
            Task { await session.jumpToLatestTranscript(threadId) }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// 手势结束停在窗口底部：按 LatestWindowRules 本地下移一段（锚点为移窗前的第一条未渲染行，顶部对齐），
    /// 只有已在缓存尾端才恢复为最新页。延迟执行前复核选中线程、对话页、可见性、定位身份、线程快照与锚点。
    private func advanceAtWindowBottom(_ proxy: ScrollViewProxy, _ threadId: String) {
        guard let t = session.transcripts[threadId], t.status == .ok else { return }
        let action = LatestWindowRules.actionAtWindowBottom(stuck: stuck, userScrolling: userScrolling, pinned: t.pinnedHit != nil, hasRowsBelowWindow: t.hasRowsBelowWindow, hasNewer: t.hasNewer)
        switch action {
        case .none:
            return
        case .resumeLatest:
            Task { await session.jumpToLatestTranscript(threadId) }
        case .showNewerRows:
            guard let anchor = session.transcripts[threadId]?.showNewerRows() else { return }
            let locate = session.locateGen
            let snapshot = session.transcripts[threadId]?.snapshot
            followTask?.cancel()
            followTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, !userScrolling, session.selectedThread == threadId, session.threadMode == 0, threadVisible,
                      session.locateGen == locate, session.transcripts[threadId]?.snapshot == snapshot,
                      session.transcripts[threadId]?.visibleItems.contains(where: { $0.id == anchor }) == true else { return }
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    /// 贴底时排队一次跟随到底部锚点（G）。单飞：新计划替换旧计划；执行前复核当前意图（S2），
    /// 上翻、定位、终端页或切线程都会放弃这次滚动。
    private func followBottom(_ proxy: ScrollViewProxy, _ threadId: String) {
        guard ThreadFollow.follows(stuck: stuck, pinnedHit: session.transcripts[threadId]?.pinnedHit, threadMode: session.threadMode) else { return }
        followTask?.cancel()
        followTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, ThreadFollow.runsQueued(stuck: stuck, pinnedHit: session.transcripts[threadId]?.pinnedHit, threadMode: session.threadMode, selectedThread: session.selectedThread, threadId: threadId) else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// 线程头部（#112 方案 A）= 常驻行 `threadTitleRow` + 可收起行 `threadHeader`。
    /// 常驻行：⋯ + 标题 + 局部「对话｜终端」切换，不随头部收起、不算进 H；标题在窄宽下先截断，⋯ 与切换不被挤掉。
    @ViewBuilder private func threadTitleRow(_ threadId: String, target: TargetSummary?, canShowTerminal: Bool) -> some View {
        HStack(spacing: 10) {
            threadMoreMenu(threadId, target: target).accessibilitySortPriority(1)
            Text(ThreadIdentity.conversationTitle(target)).font(.title3.weight(.bold)).lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader).accessibilitySortPriority(3)
            Spacer(minLength: 12)
            if canShowTerminal {
                Picker("视图", selection: Binding(get: { session.threadMode }, set: { session.threadMode = $0 })) { Text(ScreenCopy.tabChat).tag(0); Text(ScreenCopy.tabTerminal).tag(1) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().frame(minHeight: 28).layoutPriority(2).accessibilitySortPriority(2)
            }
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
    }

    /// 线程「⋯」预选入口（#21 S2）：打开派发 sheet，预选当前会话；只读设备禁用并写明原因。sheet / 对话框挂在这里：常驻行永远在，头部收起时也能弹。
    @ViewBuilder private func threadMoreMenu(_ threadId: String, target: TargetSummary?) -> some View {
        Menu {
            Button("派发任务…") { threadIssueShown = true }.disabled(!session.canControl)
            if !session.canControl { Text("此设备只有查看权限，不能派发任务") }
            // 只读设备也能查看；不包在 canControl 禁用里。
            Button("消息账本") { ledger = session.ledgerScope(threadId) }.disabled(session.ledgerScope(threadId) == nil)
            Button("重命名对话…") { threadRenameScope = session.titleScope(threadId); threadRenameShown = true }.disabled(!session.canControl)
            if !session.canControl { Text("此设备只有查看权限，不能改名") }
            if let t = target {
                // 对象是这个线程自己（稳定 targetId），与飞书当前绑定无关；只读 / 离线 / 暂停时禁用并给原因。
                Divider()
                Text("当前会话：\(ThreadIdentity.conversationTitle(t))")
                let req = session.ownerResetRequest(threadId: threadId)
                Button("解除 Bridge 占用…") { resetRequest = req }.disabled(req == nil || session.sendBlocker() != nil)
                if let why = session.sendBlocker() { Text(why) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.body)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("线程更多")
        .sheet(isPresented: $threadIssueShown) {
            IssueTaskSheet(preselectedTargetId: threadId, onAccepted: { id in session.selectTarget(id) },
                           onAbandoned: { threadIssueNote = $0; threadIssueNoteShown = true }).environment(session)
        }
        .sheet(isPresented: $threadRenameShown) {
            ConversationRenameSheet(current: target?.customTitle, onSave: { value in
                threadRenameShown = false
                if let scope = threadRenameScope { saveTitle(scope, value) }
            }, onCancel: { threadRenameShown = false })
        }
        .onChange(of: session.connectionEpoch) { _, _ in threadIssueShown = false; threadRenameShown = false; threadRenameScope = nil } // 连接切换即关闭派发 sheet 与改名弹层
        .sheet(item: $ledger) { scope in ThreadLedgerSheet(scope: scope, title: ThreadIdentity.conversationTitle(target), onClose: { ledger = nil }).environment(session) }
        .onChange(of: session.ledgerScope(threadId)) { _, now in if let l = ledger, l != now { ledger = nil } }
        #if DEBUG
        // 测试入口（仅 DEBUG）：与菜单“消息账本”按钮同一个动作。SwiftUI 菜单项只在真正弹出时才被填充，宿主里无法收束 NSMenu 跟踪。
        .onAppear { MacLedgerTestHook.open = { ledger = session.ledgerScope(threadId) } }
        .onDisappear { MacLedgerTestHook.open = nil }
        #endif
        .alert("派发未确认", isPresented: $threadIssueNoteShown) { Button("好") {} } message: { Text(threadIssueNote) }
        .confirmationDialog(resetRequest.map { String(localized: "解除 \($0.displayName) 的 Bridge 占用？") } ?? "", isPresented: Binding(get: { resetRequest != nil }, set: { if !$0 { resetRequest = nil } }), titleVisibility: .visible, presenting: resetRequest) { req in
            Button("解除占用", role: .destructive) {
                resetRequest = nil
                // 复核（同一 scope / 守卫）与发送都在 Session.confirmOwnerReset；取消与失效零发送，被拒原因显示在输入区提示。
                // 页面生命周期守卫：确认只对当前可见线程里捕获的那个请求有效（离页 / 换线程 / 换连接时已被清掉）；Session 的 scope / 权限复核不能代替它。
                guard req.scope.targetId == threadId else { return }
                Task { if case .refused(let why) = await session.confirmOwnerResetDeferred(req) { composerError = why } }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这会停止 Bridge 对该目标在途消息的跟踪，不会停止终端，也不会撤销已经执行的操作。尚未发出的队列仍保留，解除后可能继续派发。不确定是否已执行时，请先到终端确认。")
        }
        .onChange(of: threadId) { _, _ in resetRequest = nil }
        .onChange(of: session.connectionEpoch) { _, _ in resetRequest = nil }
        .onDisappear { resetRequest = nil }
    }

    /// 可收起行：状态 / 模型胶囊 ……… [详情][在 Herdr 中显示]。始终构造展开态，收起只是整块淡出（保占位）。
    /// 窄宽下先把「在 Herdr 中显示」收成图标（读屏与悬停仍是原文字），仍放不下时胶囊尾部截断，按钮不换行、不溢出。
    @ViewBuilder private func threadHeader(_ threadId: String, target: TargetSummary?) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if let t = target {
                    ViewThatFits(in: .horizontal) {
                        threadStatusRow(t, compactReveal: false)
                        threadStatusRow(t, compactReveal: true)
                    }
                } else {
                    Text("这个目标已不在 Bridge 的列表里").font(.caption).foregroundStyle(.secondary)
                }
                if let n = revealNote { Text(n.message.text).font(.caption).foregroundStyle(n.ok ? PalmhelmTheme.ok : PalmhelmTheme.bad).palmhelmReveal() }
            }
            .padding(.leading, 44).padding(.trailing, 16).padding(.bottom, 10) // 左缘与标题对齐（16 + ⋯ 宽 18 + 间距 10）
            Divider().onChange(of: threadId) { _, _ in session.threadMode = 0 } // 换线程回到对话页（A1-145 F2）
                .onChange(of: mode) { _, m in chrome.setForced(chromeForce || m == 1) } // 终端页没有这套滚动：切过去时头部显示并保持显示
        }
    }

    private func threadStatusRow(_ t: TargetSummary, compactReveal: Bool) -> some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in // 状态文字每 30 秒刷新
                ThreadHeaderBar(statusText: session.activityText(t, at: ctx.date), statusTone: activityTone(session.activityKind(t)), durationText: nil,
                                modelText: ModelText.short(t, offline: session.link != .connected),
                                modelAccessibility: ModelText.accessibility(t, offline: session.link != .connected))
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 30)) { _ in // 详情里的状态文字同样每 30 秒刷新
                ThreadDetailsButton(details: threadDetails(t), secondaryAction: feishuSwitchAction(t), onDetailsShownChange: { detailsShown = $0 })
            }
            .layoutPriority(1)
            revealButton(t, compact: compactReveal).layoutPriority(1)
        }
    }

    /// 改名结果与「在 Herdr 中显示」共用同一条信息栏提示（4 秒后只清自己这一次的提示）。
    private func saveTitle(_ scope: LedgerScope, _ value: String?) {
        Task {
            let r = await session.setTitle(scope, value)
            revealGen += 1
            let gen = revealGen
            revealNote = r
            try? await Task.sleep(for: .seconds(4))
            if revealGen == gen { revealNote = nil }
        }
    }

    private func revealButton(_ t: TargetSummary, compact: Bool) -> some View {
        let title = revealing ? String(localized: "切换中…") : String(localized: "在 Herdr 中显示")
        return Button {
            revealing = true
            Task {
                let r = await session.reveal(t.id)
                revealGen += 1
                let gen = revealGen
                revealNote = r; revealing = false
                try? await Task.sleep(for: .seconds(4))
                if revealGen == gen { revealNote = nil } // 只清自己这次的提示
            }
        } label: {
            Label(title, systemImage: "arrow.up.forward.app").labelStyle(CompactRevealLabelStyle(compact: compact))
        }
        .help(title)
        .disabled(revealing || !session.canControl)
    }

    private func threadDetails(_ t: TargetSummary) -> [ThreadDetail] {
        var rows = [ThreadDetail(label: String(localized: "状态"), value: session.activityText(t, at: Date()))]
        if let place = ThreadIdentity.location(t) { rows.append(.init(label: String(localized: "位置"), value: place)) }
        let agentModel = [t.agentName, ModelText.thread(t, offline: session.link != .connected)].compactMap { $0 }.joined(separator: " · ")
        rows.append(.init(label: String(localized: "智能体与模型"), value: agentModel))
        rows.append(.init(label: String(localized: "飞书消息发往"), value: session.state?.binding.map { "「\($0.projectName)」" } ?? String(localized: "还没有选定飞书目标")))
        return rows
    }

    /// 详情里的飞书切换（#101 P3，条件同 iOS）：已登录、已有飞书绑定、本线程不是绑定目标、且可直达（有 agent 名）。
    private func feishuSwitchAction(_ t: TargetSummary) -> ThreadDetailsButton.Action? {
        guard session.canControl, session.state?.binding != nil, session.state?.binding?.targetId != t.id, directAgent(threadId) != nil else { return nil }
        return .init(title: String(localized: "把飞书消息也发到这里"), disabled: session.switching || !session.canControl) {
            Task { await session.switchTo(project: t.projectName, agent: t.agentName, targetId: t.id, inThread: t.id) }
        }
    }

    private func activityTone(_ kind: ActivityKind) -> Color {
        switch kind {
        case .working: PalmhelmTheme.accent
        case .idle: PalmhelmTheme.ok
        case .waiting: PalmhelmTheme.warn
        case .offline: .secondary
        }
    }

    @ViewBuilder private func stateChip(_ t: TargetSummary) -> some View {
        let kind = session.activityKind(t)
        // 活动点在时间线之外（O1-337）：只有文字随 30 秒时间线更新。
        HStack(spacing: 5) {
            ActivityDot(kind: kind, size: 7, accent: PalmhelmTheme.accent, ok: PalmhelmTheme.ok, warn: PalmhelmTheme.warn)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(session.activityText(t, at: ctx.date)).font(.caption).foregroundStyle(kind == .waiting ? PalmhelmTheme.accent : .secondary)
            }
        }
    }

    /// 权威快照里登记了目标且全部已确认离线（断流时的缓存、在线状态未知都不算）。
    private var noneOnline: Bool { session.link == .connected && MacSession.allConfirmedOffline(session.state?.targets ?? []) }

    @ViewBuilder private func emptyState(_ target: TargetSummary?) -> some View {
        if session.link != .connected {
            ContentUnavailableView(String(localized: "还没连上 Bridge"), systemImage: "bolt.horizontal.circle", description: Text("连上后这里会显示记录。状态见左下角。"))
        } else if target == nil {
            ContentUnavailableView(String(localized: "这个目标已不在列表里"), systemImage: "questionmark.folder", description: Text("在 Herdr 里恢复它后会自动回来。"))
        } else if noneOnline {
            ContentUnavailableView(String(localized: "没有以前的记录"), systemImage: "moon.zzz", description: Text("这个 agent 不在线，也还没有通过 Palmhelm 或飞书的记录。"))
        } else if session.targetOnline(target?.id) == false {
            ContentUnavailableView(String(localized: "这个 agent 现在不在线"), systemImage: "moon.zzz", description: Text("在 Herdr 里恢复它的窗格后会自动上线。"))
        } else {
            ContentUnavailableView(String(localized: "这里还没有记录"), systemImage: "text.bubble", description: Text("能读到会话记录时，这里会显示 agent 的完整对话；读不到时只显示通过 Palmhelm 或飞书发的消息和回执。"))
        }
    }

    /// 一条本机发出的消息 / 操作：气泡 + 按 replyTo 关联的回执（状态行与回执过滤共用一次解析）。
    @ViewBuilder private func echoRow(_ m: MacSession.Sent) -> some View {
        let st = session.outgoingStatus(m) // 一次解析：状态行与回执过滤共用，RowView 不再自行推进 tracker
        VStack(alignment: .leading, spacing: 6) {
            RowView(row: .mine(m), status: st, onRestore: restore, restoreEnabled: canEdit)
            if let reply = session.outcome(of: m.id, statusPhase: st.phase).flatMap({ $0.display ?? $0.reply }) {
                Text(inlineMarkdown(ReceiptText.summary(reply))).font(.caption).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(PalmhelmTheme.card2.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .id(ThreadRow.mine(m).id).palmhelmReveal()
    }

    /// 线程≠绑定且 agent 名可直达时返回该 agent 名（I4）；绑定线程、系统线程、目录目标等返回 nil。
    private func directAgent(_ threadId: String?) -> String? {
        SendOptionsRoute.directAgent(threadId: threadId, bindingTargetId: session.state?.binding?.targetId, agentName: session.state?.targets.first { $0.id == threadId }?.agentName)
    }

    /// 输入区：直达线程额外说明飞书现在发给谁，并给次要动作「把飞书也切到这里」。
    @ViewBuilder private func composer(_ t: TargetSummary, direct agent: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let key = session.identityPauseKey(t.id) {
                IdentityPauseBanner(canRecover: session.canControl && session.link == .connected && ReceiptText.identityRecoverCommand(eventKey: key) != nil && session.device?.paused != true,
                                    onRecover: { Task { await session.recoverIdentityPause(eventKey: key) } })
            }
            if session.withdrawnOffer(t.id) != nil {
                // 撤回的原文没有直接回填（输入框已有内容）：只提示，由用户选择替换或忽略（O1-327）。
                WithdrawnOfferBanner(canReplace: canEdit && !busy, onReplace: { session.replaceWithWithdrawnOffer(t.id) }, onDismiss: { session.dismissWithdrawnOffer(t.id) })
            }
            // #101 发送提示：一行，说明这次发送会怎样；判定由 Kit（ThreadSendHintRules），与主按钮同一个 mode。
            // 支持发送时机的 Bridge 上整行是发送方式入口；待答提示独立保留（它不是发送方式）。
            let hint = ThreadSendHintRules.hint(mode: primaryMode(agent, kind: t.kind),
                                                queuedAhead: ThreadSendHintRules.queuedAhead(session.commands.values.filter { $0.targetId == t.id }),
                                                pendingAnswers: session.approvals(for: t).count)
            let agentName = t.agentName ?? String(localized: "智能体")
            if session.supportsSendTiming && canEdit {
                if case .pendingAnswers? = hint, let hint { ComposerSendHint(hint: hint, agentName: agentName) }
                let entry: String = { switch hint { case .directInsert?, .queued?: return ThreadSendHintRules.text(hint!, agentName: agentName); default: return String(localized: "发送方式：普通发送") } }()
                ComposerSendOptionsEntry(text: entry, open: sendOptionsOpened != nil, choice: currentSendChoice(agent, kind: t.kind)) { sendOptionsOpened = sendOptionsOpened == nil ? sendOptionsTicket() : nil }
            } else if let hint {
                ComposerSendHint(hint: hint, agentName: agentName)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ComposerView(draft: draftBinding(t.id), attachments: attachmentsBinding(t.id), enabled: canEdit, placeholder: agent.map { String(localized: "直接发给 \($0)…") } ?? String(localized: "发给 \(t.projectName)…"), onSubmit: { submit(mode: primaryMode(agent, kind: t.kind)) }, onError: { composerError = $0 }, onSubmitCommand: { Task { composerError = nil; composerError = await session.commandReturn(threadId: t.id, agent: agent) } }, scope: session.draftKey(t.id), gate: composerGate)
                SendControls(busy: busy, canSubmit: canSubmit(agent: agent), menuShown: sendMenuShown, steer: session.steerAvailability(threadId), direct: agent != nil, nativeSteer: session.nativeSteerEnabled(threadId), nativeSendNow: session.nativeSendNow(threadId), queueDeadline: t.capabilities?.queueDeadline == true, onDeadline: { submit(mode: .queue, queueTTLSeconds: $0) },
                             onPrimary: { submit(mode: primaryMode(agent, kind: t.kind)) }, onChoose: { submit(mode: $0) })
            }
            if let e = composerError ?? session.composerNote(t.id) { Text(e.text).font(.caption).foregroundStyle(PalmhelmTheme.bad) }
            if !session.isPaired || session.link != .connected { Text("未连接 Bridge，暂时不能发送。").font(.caption).foregroundStyle(PalmhelmTheme.warn) }
            else if session.device?.paused == true { Text("这台设备已暂停接收任务，发送会被拒绝。").font(.caption).foregroundStyle(PalmhelmTheme.warn) }
        }
        .padding(12)
        // 对齐参考线必须挂在 overlay 的直接子视图上（挂在内部 if 里的视图上外层读不到，浮层会盖住输入框）：面板底边贴在输入区上沿。
        .overlay(alignment: .topLeading) { sendOptionsLayer(t, agent: agent).alignmentGuide(.top) { $0[.bottom] + 4 } }
        // 票据（线程 / 连接代次 / 直达路由 / 连接状态）变化：旧浮层立即关闭；离页同样。
        .onChange(of: sendOptionsTicket()) { _, now in if let o = sendOptionsOpened, o != now { sendOptionsOpened = nil } }
        .onDisappear { sendOptionsOpened = nil }
    }

    /// 票据只由「当前 Session 的事实」构造：路由（直达 agent）每次从当前绑定 / 目标重读，不用渲染闭包里捕获的旧值。
    @ViewBuilder private func sendOptionsLayer(_ t: TargetSummary, agent: String?) -> some View {
        if sendOptionsOpened != nil && session.supportsSendTiming && canEdit {
            ComposerSendOptionsPanel(items: SendTimingRules.menu(steer: session.steerAvailability(threadId), direct: agent != nil, nativeSteer: session.nativeSteerEnabled(threadId), nativeSendNow: session.nativeSendNow(threadId), queueDeadline: t.capabilities?.queueDeadline == true),
                                     direct: agent != nil, canSubmit: canSubmit(agent: agent), current: currentSendChoice(agent, kind: t.kind),
                                     onChoose: { item in chooseSendOption(item.choice) },
                                     onClose: { sendOptionsOpened = nil })
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }

    /// 浮层 / 入口里带勾的当前默认方式：主按钮的 mode 映射。
    private func currentSendChoice(_ agent: String?, kind: String?) -> SendMenuChoice? {
        switch primaryMode(agent, kind: kind) { case .queue?: .queueAfterTurn; case .steer?: .steerNow; case .sendNow?: .sendNow; case nil: nil }
    }

    private func sendOptionsTicket() -> SendOptionsTicket {
        SendOptionsRoute.ticket(threadId: threadId, epoch: session.connectionEpoch, linkConnected: session.link == .connected,
                                bindingTargetId: session.state?.binding?.targetId, agentName: session.state?.targets.first { $0.id == threadId }?.agentName)
    }

    /// 选择即发送。先核打开时的票据仍等于选择当刻重读的票据、仍支持发送时机，且选择当刻重取的目标 / 路由 / 能力算出的菜单里该项仍可用；
    /// 否则零发送（打开后绑定改变的旧动作不能按新路由发送，也不能让 submit 把不再支持的显式 mode 降成普通发送）。通过后走原 submit。
    private func chooseSendOption(_ choice: SendMenuChoice) {
        let opened = sendOptionsOpened
        sendOptionsOpened = nil
        guard let t = session.state?.targets.first(where: { $0.id == threadId }) else { return }
        let direct = directAgent(threadId) != nil
        let items = SendTimingRules.menu(steer: session.steerAvailability(threadId), direct: direct, nativeSteer: session.nativeSteerEnabled(threadId), nativeSendNow: session.nativeSendNow(threadId), queueDeadline: t.capabilities?.queueDeadline == true)
        guard SendOptionsGate.permits(opened: opened, current: sendOptionsTicket(), supportsSendTiming: session.supportsSendTiming, items: items, choice: choice) else { return }
        if let ttl = choice.queueTTLSeconds { submit(mode: .queue, queueTTLSeconds: ttl) } else { submit(mode: choice.mode) }
    }

    /// 发送守卫：只读、未连接、设备暂停、busy、无内容都挡住；直达不受飞书绑定的切换状态约束（I3）；⌘↩ 的入口见 MacSession.commandReturn。
    private func canSubmit(agent: String?) -> Bool {
        let hasContent = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty
        return !busy && session.canControl && (agent != nil || session.switchState == .idle) && session.device?.paused != true && session.isPaired && session.link == .connected && hasContent
    }

    // 按钮与 Return 共用同一守卫；入账（成功或失败都有记录）即清本次快照，失败的正文与附件留在那条失败记录里供重试（行上会显示错误）。
    // 快照 → 发送 → 收尾都在 Session 里（submitComposer）：发送期间输入区冻结；守卫拦下（没有记录）保留草稿；视图中途被撤掉也不丢结果。
    private func submit(mode: SendMode? = nil, queueTTLSeconds: Int? = nil) {
        guard composerGate.admitsSend() else { return } // 组字中：无操作；用输入法确认候选后再操作才发送
        let agent = directAgent(threadId)
        guard canSubmit(agent: agent), let threadId else { return }
        composerError = nil
        Task {
            await session.submitComposer(threadId: threadId, agent: agent, mode: mode, queueTTLSeconds: queueTTLSeconds)
            autoRestore() // 冻结期间到达的拒绝事件在这里补做一次恢复检查
        }
    }

    /// 下拉箭头只在目标工作中出现；直达与绑定目标一样（O1-325）。直达的「立即插入」按 Bridge 的 nativeSteer 判定，缺省灰掉。
    private var sendMenuShown: Bool {
        session.supportsSendTiming && SendTimingRules.showsMenu(targetStatus: session.targetStatus(threadId))
    }
    /// 主按钮与回车的 mode（#77）：直达 Claude 工作中且支持原生插入时默认立即插入；其余直达不传 mode（请求形状与以前的直达发送一致）。
    private func primaryMode(_ agent: String?, kind: String?) -> SendMode? {
        session.supportsSendTiming
            ? SendTimingRules.primaryMode(direct: agent != nil, targetStatus: session.targetStatus(threadId), kind: kind, nativeSteer: session.nativeSteerEnabled(threadId))
            : nil
    }


    /// 把业务被拒的发送恢复到输入框：正文与缩略图（附件文件仍在）。
    private var canEdit: Bool { ComposerRules.canEdit(canControl: session.canControl, busy: busy) }

    private func restore(_ m: MacSession.Sent) {
        guard let threadId else { return }
        session.restoreRejected(m, threadId: threadId)
    }

    // 输入框为空时自动恢复一条被业务拒绝的发送；有内容时不覆盖，由错误行上的按钮显式恢复。
    private func autoRestore() {
        guard canEdit, let threadId, draftText.isEmpty, draftAttachments.isEmpty, let m = session.restorableSend(threadId: threadId) else { return }
        restore(m)
    }

    /// 目标切换的结果与候选：只显示发起它的线程里的这次切换。多候选（含迟到的回执）随时可选；选择即发起新的切换，旧候选随之作废。
    @ViewBuilder private func switchPrompt(_ threadId: String) -> some View {
        if let r = session.switchOutcome(for: threadId) {
            let cands = session.switchCandidates
            let rejected = r.reply?.contains("rejected:") == true
            if r.error != nil || rejected || !cands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let e = r.error { Text(e.text).font(.caption).foregroundStyle(PalmhelmTheme.bad) }
                    if let reply = r.display ?? r.reply, rejected { Text(inlineMarkdown(ReceiptText.summary(reply))).font(.caption).textSelection(.enabled) }
                    if !cands.isEmpty {
                        Text("匹配到多个 agent，选一个：").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(cands, id: \.self) { name in
                                Button(name) { Task { await session.chooseSwitchCandidate(name) } }
                                    .controlSize(.small).disabled(session.switching || !session.canControl)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
        }
    }
}

struct RowView: View {
    /// 排队消息的操作（与行内按钮、点击对话框、辅助功能操作同一来源）：权威指令 + 本机 + 可控 + 支持时机；按原消息的路由判定（直达看原目标的 nativeSteer / nativeSendNow）。灰显项保留原因。
    fileprivate func queuedActionItems(_ c: ApiCommand) -> [QueuedActionItem] {
        let mine = c.origin == "api" && c.device?.id == session.device?.id && session.canControl
        guard mine && session.supportsSendTiming else { return [] }
        return SendTimingRules.queuedActionItems(state: c.state, reason: c.reason, steer: session.steerAvailability(c.targetId), direct: c.directAgent != nil, nativeSteer: session.nativeSteerEnabled(c.targetId), nativeSendNow: session.nativeSendNow(c.targetId))
    }

    /// 当前可执行的操作（灰显的不算）。
    fileprivate func queuedActionList(_ c: ApiCommand) -> [QueuedAction] {
        queuedActionItems(c).filter(\.enabled).map(\.action)
    }

    fileprivate func run(_ action: QueuedAction, _ c: ApiCommand) {
        // 灰显或已不可用的操作一律不发请求（行内、对话框、AX 共用这一道复核）。
        guard queuedActionList(c).contains(action) else { return }
        Task {
            switch action {
            case .withdraw: await session.withdrawQueued(c)
            case .promote: await session.promoteQueued(c)
            case .promoteSendNow: await session.promoteQueued(c, mode: .sendNow)
            case .resend: await session.resendExpired(c)
            }
        }
    }

    /// 排队消息的状态与可用操作：撤回、改为立即插入（只对本机发出的消息、可控设备显示）；直达只给撤回；失败只给固定提示。
    @ViewBuilder fileprivate func queuedStatus(_ c: ApiCommand) -> some View {
        // 排队状态族用统一的排队文案；其余状态用当前活动的诚实文案。身份行只写来源，不重复状态（O1-327）。
        // 状态值带片 A 已采纳的送达证据（同一 tracker）：started / 暂停 / 未知用解析后的文案，不只用 raw 当前活动文案。
        let family = SendTimingRules.isQueuedFamily(state: c.state, reason: c.reason)
        let ms = session.messageStatus(for: c)
        let resolved = [CommandState.started.rawValue, CommandState.paused.rawValue, CommandState.unknown.rawValue].contains(c.state)
        let label = family ? SendTimingCopy.commandStatus(state: c.state, reason: c.reason, lane: c.lane, direct: c.directAgent != nil, queueDeadlineT: c.queueDeadlineT) : (resolved ? ms.label : session.commandLabel(c))
        QueuedStatusView(label: label, tone: family ? QueuedTone.of(reason: c.reason) : .muted,
                         items: queuedActionItems(c),
                         note: session.commandNotes[c.key]?.text,
                         onWithdraw: { run(.withdraw, c) },
                         onPromote: { run(.promote, c) },
                         onPromoteSendNow: { run(.promoteSendNow, c) },
                         onResend: { run(.resend, c) },
                         card: ms.card)
    }

    /// 排队气泡的点击与辅助功能操作（#69 Mac）：单击弹出与行内同源的确认对话框；没有可用操作时无副作用。
    @ViewBuilder fileprivate func queuedInteractive<V: View>(_ bubble: V, _ c: ApiCommand?) -> some View {
        let items = c.map { queuedActionItems($0) } ?? []
        if let c, !items.isEmpty {
            bubble
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { queuedDialog = true }
                .accessibilityActions { ForEach(items, id: \.action) { item in Button(item.title) { run(item.action, c) }.disabled(!item.enabled) } }
                .confirmationDialog("排队中的消息", isPresented: $queuedDialog, titleVisibility: .visible) {
                    ForEach(items, id: \.action) { item in Button(item.title) { run(item.action, c) }.disabled(!item.enabled) }
                    Button("取消", role: .cancel) {}
                }
        } else {
            bubble
        }
    }

    let row: ThreadRow
    /// 父级已解析的有效状态（与回执过滤共用）；没给（兜底分支、补行）时本行自行解析一次。
    var status: (phase: OutgoingPhase, label: String)? = nil
    var onRestore: ((MacSession.Sent) -> Void)? = nil
    var restoreEnabled = false
    @State private var queuedDialog = false
    @Environment(MacSession.self) private var session

    var body: some View {
        switch row {
        case .mine(let m):
            // 一行状态（O1-365）：阶段与文案由 Kit 的 OutgoingStatus 统一给出，只前进；排队族且有权威指令时由排队行接管（同一时刻只有一条状态）
            let st = status ?? session.outgoingStatus(m)
            // 服务端已给出排队卡（含发送中、已送达、处理中）时同样由排队行接管（#89 S3）。
            let queued = m.eventKey.flatMap { session.commands[$0] }.flatMap { c in ([OutgoingPhase.queued, .queuedSteer, .queuedNative].contains(st.phase) || QueueStatusPresentation.card(for: c, phase: st.phase) != nil) ? c : nil }
            HStack(alignment: .bottom) { Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("我 · 这台 Mac").font(.caption2).foregroundStyle(.secondary)
                    queuedInteractive(MarkdownText(text: m.text).foregroundStyle(PalmhelmTheme.emphasis).padding(10).background(PalmhelmTheme.bubbleMe, in: RoundedRectangle(cornerRadius: 12)), queued)
                    if let queued {
                        queuedStatus(queued)
                    } else {
                        Text(st.label).font(.caption2).foregroundStyle(st.phase == .failed || st.phase == .rejected ? PalmhelmTheme.bad : PalmhelmTheme.warn)
                    }
                    if st.phase == .failed, queued == nil, let target = m.targetId { // 失败：按原文与原附件重新发送（#57）；未归属的失败只给「恢复到输入框」
                        Button("重试") { Task { await session.resendFailed(m, threadId: target) } }.buttonStyle(.link).font(.caption2).disabled(!session.canControl)
                    }
                    if let onRestore, m.error != nil, m.eventKey != nil, !m.restored, !m.draft.isEmpty || !m.attachmentPaths.isEmpty {
                        Button("恢复到输入框") { onRestore(m) }.buttonStyle(.link).font(.caption2).disabled(!restoreEnabled)
                    }
                }
            }
        case .command(let c):
            HStack(alignment: .bottom) { Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 3) {
                    queuedStatus(c)
                    Text("我 · \(InboundOrigin(rawValue: c.origin)?.label ?? c.origin)").font(.caption2).foregroundStyle(.secondary)
                    queuedInteractive(MarkdownText(text: c.text).foregroundStyle(PalmhelmTheme.emphasis).padding(10).background(PalmhelmTheme.bubbleMe, in: RoundedRectangle(cornerRadius: 12)), c)
                }
            }
        case .receipt(let r):
            if ReceiptText.isSystem(r) {
                // 系统回执：居中小字，标明 Palmhelm；不冒充 agent 消息（O1-327）。
                SystemReceiptLine(summary: ReceiptText.summary(r))
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Text("A").font(.caption.weight(.bold)).foregroundStyle(.white).frame(width: 22, height: 22).background(Color.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(r.target?.projectName ?? String(localized: "系统")).font(.subheadline.weight(.semibold))
                            if let a = r.target?.agentName { Text(a).font(.caption2).foregroundStyle(.secondary) }
                            Text("agent").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 1).background(PalmhelmTheme.card2, in: Capsule())
                        }
                        MarkdownText(text: r.text).font(.body)
                        Text([r.t.map { Date(timeIntervalSince1970: Double($0) / 1000).shown(date: .omitted, time: .shortened) }, "#\(r.seq)"].compactMap { $0 }.joined(separator: " · ")).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PalmhelmTheme.bubbleAgent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer(minLength: 120)
                }
            }
        }
    }
}

/// 连接阶段（顶栏、左栏底部、统计页共用的唯一投影）。
@MainActor func currentPhase(_ engine: BridgeEngine, _ settings: EngineSettings, _ session: MacSession) -> ConnectionPhase {
    ConnectionPhase.from(
        engineStatus: engine.status,
        portFileReady: engine.portFile != nil,
        credentialsLoaded: session.credentialsLoaded,
        secretsLoaded: settings.secretsLoaded,
        link: session.link
    )
}


/// 目标栏自动收起（窗口太窄）：由主窗口按宽度注入。
private struct RailAutoCollapseKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var railAutoCollapse: Bool { get { self[RailAutoCollapseKey.self] } set { self[RailAutoCollapseKey.self] = newValue } } }

/// 工具栏铃铛：自己读取待处理请求，让它们的变化（含分钟 / 到期）只重算这个按钮。
struct BellToolbarButton: View {
    @Environment(MacSession.self) private var session
    let action: () -> Void

    var body: some View {
        let _ = { RailProbe.bellBodies += 1 }()
        let count = session.pendingApprovals.count
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: count == 0 ? "bell" : "bell.badge.fill").foregroundStyle(count == 0 ? Color.secondary : PalmhelmTheme.accent)
                if count > 0 { Text("\(count)").font(.caption2).foregroundStyle(PalmhelmTheme.onAccent).padding(.horizontal, 6).padding(.vertical, 1).background(PalmhelmTheme.accent, in: Capsule()) }
            }
        }
        .help("收件箱：待答与工作中")
        .accessibilityLabel(count == 0 ? String(localized: "收件箱") : String(localized: "收件箱，\(count) 条待答"))
    }
}

/// 提醒入口：只在有提醒时出现（不计数）；点开是原生 popover，操作与原卡片相同。
struct AlertsToolbarButton: View {
    @Environment(MacSession.self) private var session
    let shown: SwiftUI.Binding<Bool>

    var body: some View {
        let _ = { RailProbe.alertsBodies += 1 }()
        let sum = session.reminderSummary // 判变后才写的摘要：稳定的 targets 帧不使入口重算
        if shown.wrappedValue || AlertsPresentation.showsMarker(reminders: sum.reminders, alerts: sum.alerts) { // 弹层开着时入口保持，过滤后为空也不会因锚点消失而关闭
            Button { shown.wrappedValue.toggle() } label: { Image(systemName: sum.unread > 0 ? "exclamationmark.circle.fill" : "exclamationmark.circle").foregroundStyle(PalmhelmTheme.warn) }
                .help("提醒（超时 / 失败），不计数")
                .accessibilityLabel(sum.unread > 0 ? String(localized: "有 \(sum.unread) 条未读提醒") : String(localized: "提醒"))
                .popover(isPresented: shown, arrowEdge: .bottom) { AlertsPopover().environment(session) }
        }
    }
}

#if DEBUG
/// 宿主测试打开“消息账本”的入口（与线程“更多”菜单里的按钮同一动作）；线程列视图出现时登记、消失时清除。
@MainActor enum MacLedgerTestHook { static var open: (() -> Void)? }
#endif
