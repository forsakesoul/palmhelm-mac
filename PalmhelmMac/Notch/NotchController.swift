import SwiftUI
import AppKit
import PalmhelmKit

// 刘海岛：顶部居中的非激活面板。四档（空闲只剩刘海 / 工作 / 待答 / 悬停展开）+ 瞬时提示；外壳与展开卡是同一块黑色形状，
// 形状由一条可中断的弹簧动画驱动（宽、高、圆角一起变）；内容按最终尺寸排好、由形状遮罩露出，并与紧凑内容交叉淡入淡出。
// 纯逻辑（档位、几何、悬停意图、提示合并、事件差分）在 NotchModel.swift，这里只做宿主、观测与布局。

/// 点击落到可见卡片上的第一下就要生效：非激活面板默认不接收「第一下」，这里明确接收。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 面板尺寸只由控制器按形状设置，不能被 SwiftUI 内容反过来撑住：
    /// NSHostingView 默认会把窗口的最小尺寸设成内容的最小尺寸，而展开层（400×N，哪怕透明）一直在视图树里，
    /// 结果面板收不回到贴着形状的大小，静止时一块 400 宽的透明区一直盖在 Chrome 标签栏上（实机发现）。
    convenience init(rootView: Content, sizingOptions: NSHostingSizingOptions) {
        self.init(rootView: rootView)
        self.sizingOptions = sizingOptions
    }
}

/// 当前要呈现的布局：目标形状（不含耳朵）、圆角、紧凑 / 展开的参考尺寸（内容遮罩与淡入淡出据此算进度）。
struct NotchLayout: Equatable {
    var mode: NotchMode = .compact(.idle)
    var size = CGSize(width: 0, height: 0)
    var radius: CGFloat = NotchGeometry.compactRadius
    /// 紧凑 / 提示 ↔ 展开的混合进度目标（0 / 1）：只由模式决定，与形状高度无关（toast 增高不算展开）。
    var reveal: CGFloat = 0
    var compactSize = CGSize(width: 0, height: 0)
    var expandedSize = CGSize(width: NotchGeometry.expandedWidth, height: 120)
}

/// 只在用户明确展开时取得键盘焦点；不激活主窗口，也不监听其他 App 的键盘。
final class NotchPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var acceptsKeyboardFocus = false
    override var canBecomeKey: Bool { acceptsKeyboardFocus }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let toggle = event.charactersIgnoringModifiers?.lowercased() == "n" && event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option]
            if event.keyCode == 53 || toggle { onDismiss?(); return }
        }
        super.sendEvent(event)
    }
}

@MainActor
@Observable
final class NotchController {
    private var panel: NSPanel?
    private weak var session: MacSession?
    private var pollTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// 形状此刻的实际尺寸 / 圆角（视图每个动画帧回报）：命中区跟随它，而不是目标尺寸或并集面板。
    /// 展开卡上主操作按钮（「允许一次」）在面板窗口内容坐标（左上原点）里的 frame：真实事件测试据此取「可见、可点击控件的中心点」。
    @ObservationIgnored var primaryControlFrame: CGRect?
    @ObservationIgnored private(set) var liveShape: (size: CGSize, radius: CGFloat)?
    /// 形状尺寸变化的回调里立即重算命中区：没有鼠标移动、直接点击，或动画中形状扫过静止的鼠标，都不用等 60ms tick。
    func reportShape(_ size: CGSize, _ radius: CGFloat) {
        liveShape = (size, radius)
        updateHitRegion(mouse: testMouseLocation ?? NSEvent.mouseLocation)
    }
    /// 测试：固定「当前鼠标位置」（nil = 真实位置）。
    @ObservationIgnored var testMouseLocation: CGPoint?
    var mouseMonitorCount: Int { mouseMonitors.count }
    /// 鼠标移动 / 拖动监视器（全局 + 本地）：每次移动立即重算命中区，tick 只是兜底。鼠标事件的全局监视不需要辅助功能权限（键盘事件才需要），这里不监视键盘，也不复制 / 重放任何点击。
    @ObservationIgnored private var mouseMonitors: [Any] = []
    /// 展开期间固定显示的待答（A1-071 F3）：id 与快照；列表变化不会把别的卡顶到同一个按钮位置。
    private(set) var pin = NotchCardPin()
    private(set) var pinnedApproval: ApprovalView?
    private(set) var metrics = NotchMetrics(notchWidth: 0, barHeight: 34)
    private var screenHeight: CGFloat = 900

    private(set) var layout = NotchLayout()
    /// 下一次 layout 变化用的动画：展开弹簧 / 收起临界阻尼 / 减少动态效果时为 nil。
    private(set) var layoutAnimation: Animation?
    private(set) var toast = NotchToastState()
    @ObservationIgnored private var hover = NotchHoverState() // 视图不读它；每拍都会改，不能触发观测
    @ObservationIgnored private var snapshot: NotchSnapshot?
    /// 展开内容的实测高度（由视图回报）：形状高度随内容。
    var contentHeight: CGFloat = 120 { didSet { if abs(oldValue - contentHeight) > 0.5 { refresh() } } }
    /// 角色动画是否运行：减少动态效果、面板不可见、屏幕锁定 / 休眠时停。
    private(set) var animating = true
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var asleep = false
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let interaction: NotchInteractionStore
    init(interaction: NotchInteractionStore = .shared) {
        self.interaction = interaction
        interaction.onEnabledChange = { [weak self] in self?.applyEnabled() }
    }

    /// 开关只决定刘海显不显示：关 = 整个拆掉（面板、鼠标监视、轮询、收回计时、提示一起停，不留看不见的面板抢输入）；
    /// 开 = 重新挂上，从当前状态开始，不补播关掉期间的提示。不碰 Bridge、审批和设备权限。
    private func applyEnabled() {
        if !interaction.enabled { detach() } else if let session { attach(session: session) }
    }
    var isExpanded: Bool { panel != nil && layout.mode == .expanded }

    func toggleExpansion() {
        guard panel != nil else { return }
        if hover.expanded { dismissExpansion(); return }
        hover.force(expanded: true)
        syncPin()
        refresh()
        (panel as? NotchPanel)?.acceptsKeyboardFocus = true
        panel?.makeKeyAndOrderFront(nil)
    }

    func dismissExpansion() {
        guard hover.expanded else { return }
        hover.dismiss()
        syncPin()
        refresh()
        releaseKeyboardFocus()
    }

    private func releaseKeyboardFocus() {
        if panel?.isKeyWindow == true { panel?.resignKey() }
        (panel as? NotchPanel)?.acceptsKeyboardFocus = false
    }

    /// 面板内容容器：宿主视图始终铺满容器（顶部对齐、水平居中由 SwiftUI 根视图负责）；窗口尺寸完全由控制器按形状设置。
    /// 不能只靠 autoresizingMask：容器创建时尺寸为 0，按 0 起算的 autoresizing 会让宿主视图保持自己的理想尺寸，
    /// 窗口缩小后它仍是 400×90、按左下角对齐，上半部分被裁掉，只剩下缘一条黑线（实机 R4）。
    final class ContainerView: NSView {
        let hosting: NSView
        init(hosting: NSView, size: CGSize) {
            self.hosting = hosting
            super.init(frame: NSRect(origin: .zero, size: size))
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
            hosting.frame = bounds
            addSubview(hosting)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); hosting.frame = bounds }
        override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); hosting.frame = bounds }
        /// 容器大小变了之后立刻让宿主视图跟上（setFrame 之后调用）。
        func syncHosting() {
            hosting.frame = bounds
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded() // 同步让 SwiftUI 按新窗口尺寸重排：否则窗口变了之后的一两帧里形状还按旧宽度居中，位置会跳
            hosting.displayIfNeeded()
        }
    }
    static func container(for hosting: NSView, size: CGSize) -> ContainerView { ContainerView(hosting: hosting, size: size) }

    // MARK: 生命周期

    func attach(session: MacSession) {
        self.session = session // 关着也记住会话：之后打开开关时据此挂上
        derivedStale = true // 会话换了：派生数据整体重算
        guard interaction.enabled, panel == nil, let screen = NSScreen.main else { return }
        measure(screen)
        let p = NotchPanel(contentRect: NSRect(x: screen.frame.midX - 100, y: screen.frame.maxY - metrics.barHeight, width: 200, height: metrics.barHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.onDismiss = { [weak self] in self?.dismissExpansion() }
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.appearance = NSAppearance(named: .darkAqua) // 刘海固定深色：外壳黑，颜色取主题的深色 token
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.acceptsMouseMovedEvents = true
        p.ignoresMouseEvents = true // 命中区跟随形状：鼠标在形状外时穿透，进入形状后由 tick 切回接收（updateHitRegion）
        // 宿主视图放在一个普通 NSView 容器里（autoresizing，不用 Auto Layout 约束）：直接把 NSHostingView 当 contentView 时，
        // 窗口会被它的理想尺寸（展开层 400×N，哪怕透明）反复拉回去——实机发现静止时面板一直是 400×91，透明区盖住 Chrome 标签栏。
        p.contentView = Self.container(for: FirstMouseHostingView(rootView: NotchIslandView(controller: self).environment(session).displayLanguage(), sizingOptions: []), size: p.frame.size)
        panel = p
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }))
        let ws = NSWorkspace.shared.notificationCenter
        for (name, value) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false), (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.asleep = value } }))
        }
        let dc = DistributedNotificationCenter.default()
        observers.append((dc, dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = true } }))
        observers.append((dc, dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = false } }))
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHitRegion(mouse: NSEvent.mouseLocation) }
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.updateHitRegion(mouse: NSEvent.mouseLocation) }
            return e
        }) { mouseMonitors.append(l) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                self?.tick()
            }
        }
        refresh(force: true)
    }

    /// 拆除：停轮询与收回计时、移除观察者、关闭并释放面板（测试结束 / 退出时用，避免窗口残留影响后续用例）。
    func detach() {
        pollTask?.cancel(); pollTask = nil
        shrinkTask?.cancel(); shrinkTask = nil
        for o in observers { o.center.removeObserver(o.token) }
        observers = []
        for m in mouseMonitors { NSEvent.removeMonitor(m) }
        mouseMonitors = []
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.isReleasedWhenClosed = false
        panel?.close()
        panel = nil
        liveShape = nil
        forcedExpanded = nil
        hover.collapseNow()
        syncPin()
        toast = NotchToastState()
        snapshot = nil // 重新挂上时第一拍只建基线（diff(old: nil) 不出事件），不补播
        derived = nil
        derivedStale = true
        diffedGeneration = -1
        lastHit = nil
    }

    private func measure(_ screen: NSScreen) {
        screenHeight = screen.frame.height
        metrics = NotchMetrics.of(screen)
        screenFrame = screen.frame
    }
    /// 刘海所在屏幕的 frame：只在 measure（挂载与屏幕参数变化）时取一次。60ms 拍里不再调用 NSScreen.main（它每次都会枚举屏幕）。
    @ObservationIgnored private var screenFrame: CGRect = .zero

    private func screenChanged() {
        guard let screen = NSScreen.main else { return }
        measure(screen)
        hover.collapseNow()
        releaseKeyboardFocus()
        syncPin()
        refresh(force: true)
    }

    // MARK: 观测（60ms 一拍：悬停意图、事件差分、提示到期、布局）

    /// 每拍读缓存（Derived.pending）：稳定的 60ms 拍不再过滤 / 排序全部待答；数据变化、到期（timeValidityVersion）或 30 秒到期后在 currentDerived 里重算。
    private var pending: [ApprovalView] { currentDerived().pending }

    /// 每拍共用的派生数据（#464）：刘海工作行、事件快照、待答 id。只在它们读取的会话数据变化（withObservationTracking）或超过 30 秒（活动时长刷新）时重算；
    /// 60ms 一拍只读缓存，O(1) 返回。generation 只在重算时递增，事件差分据此只在数据变了才做。
    struct Derived {
        var rows: [NotchWorkingRow]
        var snapshot: NotchSnapshot?
        var pending: [ApprovalView] = []
        var at: Date
        var generation: Int
    }
    @ObservationIgnored private var derived: Derived?
    @ObservationIgnored private var derivedStale = true
    @ObservationIgnored private var derivedGeneration = 0
    @ObservationIgnored private var diffedGeneration = -1

    private func currentDerived(now: Date = Date()) -> Derived {
        if let d = derived, !derivedStale, now.timeIntervalSince(d.at) < 30 { return d }
        derivedStale = false
        derivedGeneration += 1
        let next = withObservationTracking({ computeDerived(now: now, generation: derivedGeneration) }, onChange: { [weak self] in
            MainActor.assumeIsolated { self?.derivedStale = true }
        })
        derived = next
        return next
    }

    private func computeDerived(now: Date, generation: Int) -> Derived {
        guard let s = session else { return Derived(rows: [], snapshot: nil, pending: [], at: now, generation: generation) }
        let rows = NotchWorking.rows(
            commands: s.runningCommands.map { NotchWorking.Command(key: $0.key, targetId: $0.targetId, name: targetName($0.targetId), text: $0.text, label: s.commandLabel($0)) },
            working: s.workingTargets.map { NotchWorking.Target(id: $0.id, name: targetName($0.id), activity: s.activityText($0, at: now)) })
        var snap = NotchSnapshot()
        let pending = s.pendingApprovals // 一次：快照与 Derived.pending 同轮
        for a in pending { snap.pending[a.id] = s.target(forApproval: a).map(\.projectName) ?? a.targetLabel }
        for r in rows { snap.running[r.key] = r.name }
        for c in s.commands.values where c.state == CommandState.finished.rawValue { snap.finished[c.key] = targetName(c.targetId) }
        snap.link = s.link == .connected ? .connected : { if case .offline = s.link { return .offline }; return .other }()
        return Derived(rows: rows, snapshot: snap, pending: pending, at: now, generation: generation)
    }

    /// 刘海「工作中」的合并列表：在途指令 ∪ 没有对应在途指令的工作中目标（#56）。计数、展开面板都用它（经缓存）。
    var workingRows: [NotchWorkingRow] { currentDerived().rows }
    var base: NotchBase { NotchRules.base(pending: pending.count, running: workingRows.count) }

    private func tick(now: Date = Date()) {
        guard let panel, screenFrame != .zero else { return }
        // 悬停：鼠标是否在当前可见形状里（带一点容差）。非激活面板收不到 mouseMoved 时也照常判断。
        let shape = layout.size
        let rect = NSRect(x: screenFrame.midX - shape.width / 2 - NotchGeometry.ear, y: screenFrame.maxY - shape.height - 2, width: shape.width + 2 * NotchGeometry.ear, height: shape.height + 2)
        let wasExpanded = hover.expanded
        if forcedExpanded == nil { hover.update(inside: panel.isVisible && rect.contains(NSEvent.mouseLocation), now: now, trigger: interaction.trigger) }
        if wasExpanded && !hover.expanded { releaseKeyboardFocus() }
        let held = hover.expanded
        // 事件差分 → 瞬时提示：只在派生数据换代（会话数据变化）且快照真的变了时做
        let d = currentDerived(now: now)
        let dataChanged = d.generation != diffedGeneration
        if dataChanged {
            diffedGeneration = d.generation
            if let snap = d.snapshot, snap != snapshot {
                var t = toast
                for e in NotchEvents.diff(old: snapshot, new: snap) { t.post(e, now: now, held: held) }
                if t != toast { toast = t }
                snapshot = snap
            }
        }
        let hadToast = toast.current != nil
        var t = toast
        t.tick(now: now, held: held)
        if t != toast { toast = t } // 只在真的变了才写：每 60ms 写一次会让 SwiftUI 不停重绘
        if dataChanged || wasExpanded != hover.expanded { syncPin() }
        updateHitRegion(mouse: NSEvent.mouseLocation)
        let anim = !reduceMotion && !locked && !asleep && panel.isVisible && panel.occlusionState.contains(.visible)
        if anim != animating { animating = anim }
        if wasExpanded != hover.expanded || hadToast != (toast.current != nil) || layoutDirty() { refresh() }
    }

    /// 命中区：鼠标在「形状此刻的实际路径」（含耳朵与圆角）里才接收鼠标，其余透明区穿透。先判断再切换：状态没变不写，避免悬停中途闪烁。
    func updateHitRegion(mouse: CGPoint) {
        guard let panel, screenFrame != .zero else { return }
        let shape = liveShape ?? (layout.size, layout.radius)
        // 鼠标、形状、屏幕、可见性都没变：结论不变，直接返回（#464：60ms 拍里大多数拍都是这一支）
        let key = HitKey(mouse: mouse, size: shape.size, radius: shape.radius, screen: screenFrame, visible: panel.isVisible)
        if key == lastHit { return }
        lastHit = key
        let inside = panel.isVisible && NotchHit.inside(mouse: mouse, screenFrame: screenFrame, shape: shape.size, radius: shape.radius, tolerance: 2)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }
    private struct HitKey: Equatable {
        let mouse: CGPoint
        let size: CGSize
        let radius: CGFloat
        let screen: CGRect
        let visible: Bool
    }
    @ObservationIgnored private var lastHit: HitKey?
    var ignoresMouseEvents: Bool? { panel?.ignoresMouseEvents }

    private func syncPin() {
        var p = pin
        p.sync(expanded: hover.expanded, pending: pending.map(\.id))
        if p != pin { pin = p }
        let live = p.id.flatMap { id in pending.first { $0.id == id } }
        if let live, live != pinnedApproval { pinnedApproval = live }
        if p.id == nil, pinnedApproval != nil { pinnedApproval = nil }
    }
    /// 明确切到下一条（点「下一条」）；新来的待答只更新「另 N 条」，不会自己顶上来。
    func advancePin() {
        var p = pin
        p.advance(pending: pending.map(\.id))
        pin = p
        pinnedApproval = p.id.flatMap { id in pending.first { $0.id == id } }
    }
    var pinnedIsLive: Bool { pin.isLive(pending: pending.map(\.id)) }
    var pinnedGoneNote: String {
        switch pinnedApproval.flatMap({ session?.approvals[$0.id]?.status }) {
        case ApprovalStatus.expired.rawValue?: String(localized: "已过期")
        case ApprovalStatus.withdrawn.rawValue?: String(localized: "已撤回")
        default: String(localized: "已在别处处理 / 已过期")
        }
    }
    /// 决定只落在固定显示的那一条上：它已失效就零操作（按下与抬起之间失效也不会落到别的卡）。
    func decidePinned(_ choice: ApprovalDecision, expectedId: String) async {
        // 执行时复核：卡上按钮对应的 id 必须仍是固定的那条，且它仍在当前待答里
        // 授权不用缓存：按当前待答现算（session.decide 之后还会再复核一次）。
        guard let a = pinnedApproval, a.id == expectedId, pin.id == expectedId, pin.isLive(pending: (session?.pendingApprovals ?? []).map(\.id)) else { return }
        await session?.decide(a, choice)
    }

    private func layoutDirty() -> Bool { desiredLayout() != layout }

    // MARK: 布局与宿主

    private func desiredLayout() -> NotchLayout {
        let mode = NotchRules.mode(base: base, hasToast: toast.current != nil, expanded: hover.expanded)
        let size = NotchGeometry.size(for: mode, metrics, contentHeight: contentHeight, screenHeight: screenHeight)
        return NotchLayout(mode: mode, size: size, radius: NotchGeometry.radius(for: mode), reveal: NotchBlend.reveal(for: mode),
                           compactSize: NotchGeometry.compactSize(metrics, base: base),
                           expandedSize: NotchGeometry.expandedSize(metrics, contentHeight: contentHeight, screenHeight: screenHeight))
    }

    private func refresh(force: Bool = false) {
        guard panel != nil else { return }
        let next = desiredLayout()
        guard force || next != layout else { return }
        let grows = NotchSpring.grows(from: layout.size, to: next.size)
        layoutAnimation = reduceMotion ? nil : .interpolatingSpring(mass: 1, stiffness: NotchSpring.stiffness, damping: grows ? NotchSpring.expandDamping : NotchSpring.collapseDamping)
        // 只有形状 / 模式变了才重排面板：仅仅是展开参考尺寸（内容高度）变化不该把面板再放大一次、重置收回计时
        if force || next.size != layout.size || next.mode != layout.mode {
            placePanel(old: layout.size, new: next.size, hidden: NotchRules.isHidden(hasNotch: metrics.hasNotch, base: base, hasToast: toast.current != nil, expanded: hover.expanded))
        }
        layout = next
    }

    /// 面板宿主：动画期间面板先放大到「旧 / 新形状的并集（含 3% 过冲余量）」，形状在里面做弹簧；动画结束后收回到恰好贴着形状，
    /// 这样静止时透明区不会盖住下方 App 的点击与滚轮。（固定最大透明面板的穿透行为没法在这里实测，见 NOTICE。）
    private func placePanel(old: CGSize, new: CGSize, hidden: Bool) {
        guard let panel, let screen = NSScreen.main else { return }
        shrinkTask?.cancel()
        if hidden { panel.orderOut(nil); return }
        let big = CGSize(width: max(old.width, new.width) * 1.03, height: max(old.height, new.height) * 1.03 + 2)
        frame(panel, screen, NotchGeometry.panelSize(shape: big), animated: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
        let delay: Duration = reduceMotion ? .milliseconds(150) : .milliseconds(900)
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let panel = self.panel, let screen = NSScreen.main else { return }
            self.frame(panel, screen, NotchGeometry.panelSize(shape: self.layout.size), animated: false)
        }
    }

    private func frame(_ panel: NSPanel, _ screen: NSScreen, _ size: CGSize, animated: Bool) {
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        (panel.contentView as? ContainerView)?.syncHosting() // 宿主视图始终铺满容器
    }

    // MARK: 视图用的动作

    enum Destination { case target(String), request(String), inbox }

    /// 打开主窗口并按 Session 的导航意图定位（不只是把 App 带到前台）。目标已不在列表里时在这里也明确提示。
    func open(_ d: Destination, openWindow: OpenWindowAction, note: (LText) -> Void) {
        guard let session else { return }
        switch d {
        case .target(let id):
            guard session.state?.targets.contains(where: { $0.id == id }) == true else { note(LText(String(localized: "这个目标已不在 Bridge 的列表里"))); return }
            session.openThread(id)
        case .request(let id): Task { await session.openRequest(id) }
        case .inbox: session.openInbox()
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 测试 / 诊断用：不经停留计时直接展开 / 收起。
    @ObservationIgnored private var forcedExpanded: Bool?
    func debugSetExpanded(_ on: Bool) { forcedExpanded = on; hover.force(expanded: on); refresh() }
    /// 宿主视图与容器的 frame（测试用）。
    var hostingFrames: (hosting: NSRect, container: NSRect)? {
        guard let c = panel?.contentView as? ContainerView else { return nil }
        return (c.hosting.frame, c.bounds)
    }
    /// 把面板内容渲染成位图（测试用）。
    func renderPanel() -> NSBitmapImageRep? {
        guard let v = panel?.contentView else { return nil }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }
    /// 测试：宿主视图是否接收「第一下」（非激活面板上可见按钮首击要生效）、立即走一拍观测。
    var hostingAcceptsFirstMouse: Bool? { (panel?.contentView as? ContainerView)?.hosting.acceptsFirstMouse(for: nil) }
    func debugTick(now: Date = Date()) { tick(now: now) }
    /// 测试：Derived 换代次数（只在重算时递增）。
    var debugDerivedGeneration: Int { derivedGeneration }
    var panelWindowNumber: Int? { panel?.windowNumber }
    /// 面板当前 frame（测试 / 诊断用）。
    var panelFrame: NSRect? { panel?.frame }
    var panelVisible: Bool { panel?.isVisible ?? false }

    func targetName(_ id: String?) -> String { session?.state?.targets.first { $0.id == id }?.projectName ?? id ?? "Palmhelm" }
}
