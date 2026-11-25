import SwiftUI
import AppKit
import PalmhelmKit

// 刘海岛的视图：形状（顶部内凹小耳朵）+ 紧凑 / 提示 / 展开三层内容。形状的宽、高、圆角由 Animatable 的 NotchIslandBox 在弹簧动画里一起插值；
// 展开内容按最终尺寸排好、由形状遮罩露出（裁切不重排），与紧凑内容按展开进度交叉淡入淡出；展开内容只位移 4–6pt，文字不缩放。

/// 外形：宽 w 的主体居中，顶部两角向外各延伸 ear（耳朵，内凹圆弧与屏幕上沿融合），下缘圆角 r。
struct NotchShape: Shape {
    var w: CGFloat, h: CGFloat, r: CGFloat
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(w, .init(h, r)) }
        set { w = newValue.first; h = newValue.second.first; r = newValue.second.second }
    }
    func path(in rect: CGRect) -> Path {
        let e = NotchGeometry.ear
        let x0 = rect.midX - w / 2 - e, x1 = rect.midX + w / 2 + e
        let rr = max(0, min(r, (h - e) / 1.2, w / 2))
        var p = Path()
        p.move(to: CGPoint(x: x0, y: 0))
        p.addLine(to: CGPoint(x: x1, y: 0))
        p.addQuadCurve(to: CGPoint(x: x1 - e, y: e), control: CGPoint(x: x1 - e, y: 0))
        p.addLine(to: CGPoint(x: x1 - e, y: h - rr))
        p.addQuadCurve(to: CGPoint(x: x1 - e - rr, y: h), control: CGPoint(x: x1 - e, y: h))
        p.addLine(to: CGPoint(x: x0 + e + rr, y: h))
        p.addQuadCurve(to: CGPoint(x: x0 + e, y: h - rr), control: CGPoint(x: x0 + e, y: h))
        p.addLine(to: CGPoint(x: x0 + e, y: e))
        p.addQuadCurve(to: CGPoint(x: x0, y: 0), control: CGPoint(x: x0 + e, y: 0))
        p.closeSubpath()
        return p
    }
}

/// 可动画的容器：每一帧拿到插值后的 w / h / r / reveal。reveal（0 = 紧凑 / 提示，1 = 展开）是明确的展开过渡值，
/// 与形状高度分开插值（同一条弹簧）——toast 比紧凑档高 24pt 不能被算成「展开了一部分」，否则 toast 层被淡掉、展开层半透明冒出来。
struct NotchIslandBox<Content: View>: View, @preconcurrency Animatable {
    var w: CGFloat, h: CGFloat, r: CGFloat, reveal: CGFloat
    let content: (CGFloat) -> Content
    /// 每个动画帧回报插值后的形状尺寸 / 圆角：控制器的命中区据此跟随（不在 body 里改任何被观察的状态）。
    var onShape: ((CGSize, CGFloat) -> Void)?
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { .init(w, .init(h, .init(r, reveal))) }
        set { w = newValue.first; h = newValue.second.first; r = newValue.second.second.first; reveal = newValue.second.second.second }
    }
    private var progress: CGFloat { NotchBlend.progress(reveal: reveal) }
    var body: some View {
        onShape?(CGSize(width: w, height: h), r)
        return ZStack(alignment: .top) {
            NotchShape(w: w, h: h, r: r).fill(Color.black) // 外壳纯黑：三主题一致，展开时不再另挂一张卡
            content(progress).clipShape(NotchShape(w: w, h: h, r: r))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ControlFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct NotchIslandView: View {
    let controller: NotchController
    @Environment(MacSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    private let characterStore = NotchCharacterStore.shared
    @State private var revealNote: LText?
    @State private var revealGen = 0
    @State private var revealing = false

    private var waiting: [ApprovalView] { session.pendingApprovals }
    /// 工作中的合并列表（指令 ∪ 没有对应指令的工作中目标，#56）：计数、展开行、无障碍摘要共用。
    private var running: [NotchWorkingRow] { controller.workingRows }
    private var metrics: NotchMetrics { controller.metrics }

    var body: some View {
        let L = controller.layout
        let reduce = controller.reduceMotion
        NotchIslandBox(w: L.size.width, h: L.size.height, r: L.radius, reveal: L.reveal, content: { p in
            // 展开层放在 overlay 里：它固定 400×N，若作为 ZStack 的子视图会把整个根视图撑成 400×N，面板只有 32pt 高时 SwiftUI 把这个大视图居中，
            // 可见的就只剩形状下缘一条黑线（实机 R4）。overlay 不参与布局尺寸，超出的部分由形状遮罩裁掉。
            ZStack(alignment: .top) {
                // 紧凑 / 提示层：宽度固定在目标紧凑宽，被形状遮罩裁切；随展开进度淡出（减少动态效果：直接按目标二选一，只留短淡入）
                compactLayer(L)
                    .opacity(NotchBlend.compactOpacity(progress: p, reduceMotion: reduce, expanded: L.mode == .expanded))
                    .allowsHitTesting(L.mode != .expanded)
                    .accessibilityHidden(L.mode == .expanded)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .top) {
                expandedLayer(L)
                    .frame(width: L.expandedSize.width, height: L.expandedSize.height, alignment: .top)
                    .offset(y: reduce ? 0 : (1 - min(1, p * 1.4)) * -6) // 只位移 4–6pt，文字不跟着缩放
                    .opacity(NotchBlend.expandedOpacity(progress: p, reduceMotion: reduce, expanded: L.mode == .expanded))
                    .allowsHitTesting(L.mode == .expanded && p > 0.6)
            }
            .animation(reduce ? .easeOut(duration: 0.12) : nil, value: L.mode) // 减少动态效果：尺寸直接到位，只保留一个短淡入
        }, onShape: { controller.reportShape($0, $1) })
        .animation(controller.layoutAnimation, value: L)
        // 防御：刘海屏上面板盖在安全区（刘海）里，不让 SwiftUI 因安全区把内容整体下推
        .ignoresSafeArea()
        .onPreferenceChange(ContentHeightKey.self) { if $0 > 0 { controller.contentHeight = $0 } }
        .onPreferenceChange(ControlFrameKey.self) { controller.primaryControlFrame = $0 }
        .coordinateSpace(name: "notch")
    }

    // MARK: 紧凑 / 提示

    /// 紧凑按钮是外层可访问元素：待答时它的标签带真实剩余时间。只有这一个节点每秒求值（不是整窗每秒刷新，O1-343 ⑤）；
    /// 没有待答倒计时时不建立时钟。瞬时提示（toast）的文字是事件发生时的一次性播报，不含实时倒计时。
    @ViewBuilder private func compactLayer(_ L: NotchLayout) -> some View {
        if case .compact(.waiting) = L.mode {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in compactButton(L, now: ctx.date) }
        } else {
            compactButton(L, now: Date())
        }
    }

    @ViewBuilder private func compactButton(_ L: NotchLayout, now: Date) -> some View {
        Button { controller.toggleExpansion() } label: {
            Group {
                if case .toast = L.mode, let t = controller.toast.current { toastContent(t, L) } else { compactContent(L, now: now) }
            }
            .frame(width: max(L.compactSize.width, L.mode == .toast ? L.size.width : 0), height: L.mode == .toast ? L.size.height : L.compactSize.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(compactAccessibilityLabel(L, now: now))
        .accessibilityHint("展开刘海")
        .help("展开刘海 ⌘⌥N")
    }

    private func compactAccessibilityLabel(_ L: NotchLayout, now: Date) -> String {
        if case .toast = L.mode, let t = controller.toast.current { return t.text }
        let base = { if case .compact(let b) = L.mode { return b }; return controller.base }()
        return summary(base, now: now)
    }

    private func character(_ mode: PixelMode, since: Date? = nil) -> some View {
        PixelCharacterView(character: characterStore.character, mode: mode, animating: controller.animating, since: since)
    }

    /// 紧凑档：有刘海时左翼角色、右翼数量 / 倒计时，中间让出刘海；无刘海时一个居中胶囊。
    @ViewBuilder private func compactContent(_ L: NotchLayout, now: Date) -> some View {
        let base = { if case .compact(let b) = L.mode { return b }; return controller.base }()
        let left: AnyView = base == .idle ? AnyView(Color.clear) : AnyView(character(base == .waiting ? .wait : .run))
        let right: AnyView = AnyView(rightWing(base))
        if metrics.hasNotch {
            HStack(spacing: 0) {
                // 三段宽度之和恰好等于紧凑宽（内边距在翼宽之内，不额外加）：不会因为超宽被居中后挤出形状而裁掉角色
                left.padding(.leading, NotchGeometry.leadingInset).frame(width: NotchGeometry.wingLeft(base), alignment: .leading)
                Color.clear.frame(width: metrics.notchWidth)
                right.padding(.trailing, NotchGeometry.trailingInset).frame(width: NotchGeometry.wingRight(base), alignment: .trailing)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(summary(base, now: now))
        } else {
            HStack(spacing: 8) { left; right }.padding(.horizontal, 10)
                .accessibilityElement(children: .ignore).accessibilityLabel(summary(base, now: now))
        }
    }

    @ViewBuilder private func rightWing(_ base: NotchBase) -> some View {
        switch base {
        case .idle: EmptyView()
        case .working:
            Text("\(running.count)").font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Color(white: 0.85)) // 数量照常显示：颜色不是唯一信号
        case .waiting:
            HStack(spacing: 4) {
                if waiting.count > 1 { Text("+\(waiting.count - 1)").font(.caption2).foregroundStyle(Color(white: 0.6)) }
                if let a = waiting.first { ApprovalCountdown(expiresT: a.expiresT, font: .system(.caption, design: .monospaced), normal: PalmhelmTheme.notchWarn) }
            }
        }
    }

    private func summary(_ base: NotchBase, now: Date) -> String {
        let remaining = waiting.first.map { NotchRules.remainingSeconds(expiresT: $0.expiresT, now: now) }
        return NotchRules.accessibilitySummary(base: base, pending: waiting.count, running: running.count, remaining: remaining)
    }

    /// 瞬时提示：有刘海时分两行——第一行两翼放图标 / 倒计时、中间让出刘海，文字在刘海下缘新增的一行（不画进硬件遮挡区）；
    /// 无刘海单行。图标 + 文字，颜色不是唯一信号；完成点头只以 toast 创建时刻为起点点一次。
    @ViewBuilder private func toastContent(_ t: NotchToast, _ L: NotchLayout) -> some View {
        let icon: AnyView = switch t.event.kind {
        case .newRequest: AnyView(character(.wait))
        case .done: AnyView(character(.done, since: t.born))
        case .connectionError: AnyView(Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PalmhelmTheme.notchWarn))
        }
        let countdownText: AnyView = (t.event.kind == .newRequest && waiting.first != nil) ? AnyView(ApprovalCountdown(expiresT: waiting.first!.expiresT, font: .system(.caption, design: .monospaced), normal: PalmhelmTheme.notchWarn)) : AnyView(EmptyView())
        if metrics.hasNotch {
            let wing = (L.size.width - metrics.notchWidth) / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    icon.padding(.leading, NotchGeometry.leadingInset).frame(width: wing, alignment: .leading)
                    Color.clear.frame(width: metrics.notchWidth)
                    countdownText.padding(.trailing, NotchGeometry.trailingInset).frame(width: wing, alignment: .trailing)
                }
                .frame(height: metrics.barHeight)
                Text(t.text).font(.caption).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 12).frame(width: L.size.width, height: NotchGeometry.toastTextRow)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(t.text)
        } else {
            HStack(spacing: 8) {
                icon
                Text(t.text).font(.caption).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                countdownText
            }
            .padding(.horizontal, 12)
            .accessibilityElement(children: .ignore).accessibilityLabel(t.text)
        }
    }

    // MARK: 展开

    private func expandedLayer(_ L: NotchLayout) -> some View {
        let top = (metrics.hasNotch ? metrics.barHeight : 0) + 8
        return ScrollView(.vertical, showsIndicators: false) {
            expandedBody
                .padding(.top, top).padding(.horizontal, 18).padding(.bottom, NotchGeometry.expandedBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height - top - NotchGeometry.expandedBottomPadding) })
        }
    }

    @ViewBuilder private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button { controller.dismissExpansion() } label: { Image(systemName: "chevron.up").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(Color(white: 0.85))
                    .accessibilityLabel("收起刘海").help("收起刘海 Esc")
            }
            if let a = controller.pinnedApproval {
                waitingBody(a, live: controller.pinnedIsLive)
            } else if !running.isEmpty {
                ForEach(running.prefix(4)) { r in
                    HStack(spacing: 8) {
                        Text(r.title).font(.caption).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        Text(r.trailing).font(.caption2).foregroundStyle(Color(white: 0.6))
                        if let id = r.targetId {
                            Button { reveal(id) } label: { Image(systemName: "terminal") }
                                .buttonStyle(.plain).foregroundStyle(Color(white: 0.85)).help("在 Herdr 中显示").disabled(!session.canControl || revealing)
                                .accessibilityLabel("在 Herdr 中显示")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open(r.targetId.map { .target($0) } ?? .inbox) }
                }
                Text(revealNote?.text ?? String(localized: "点一行打开对应对话 · 点终端图标切到 Herdr 窗格")).font(.caption2).foregroundStyle(Color(white: 0.6))
            } else {
                Text("没有在途任务，也没有待答事项。").font(.caption).foregroundStyle(Color(white: 0.6))
            }
        }
    }

    /// 三种待答类型共用：卡 + 公共尾部（失效说明、另 N 条、下一条 / 知道了）。
    @ViewBuilder private func waitingBody(_ a: ApprovalView, live: Bool) -> some View {
        cardBody(a, live: live)
        pinFooter(live: live)
    }

    @ViewBuilder private func pinFooter(live: Bool) -> some View {
        let f = NotchCardFooter.make(pinId: controller.pin.id, pending: waiting.map(\.id), live: live, goneNote: controller.pinnedGoneNote)
        if !f.isEmpty {
            HStack(spacing: 12) {
                if let n = f.note { Text(n).foregroundStyle(PalmhelmTheme.notchWarn) }
                Spacer()
                if f.others > 0 { Text("另 \(f.others) 条待答").foregroundStyle(Color(white: 0.6)) }
                if let act = f.action { Button(act == .next ? String(localized: "下一条") : String(localized: "知道了")) { controller.advancePin() }.buttonStyle(.plain).foregroundStyle(Color(white: 0.85)) } // 换条必须明确操作
            }
            .font(.caption2)
        }
    }

    @ViewBuilder private func cardBody(_ a: ApprovalView, live: Bool) -> some View {
        let candidate = a.attribution == ApprovalAttribution.candidate.rawValue
        let identity = ApprovalText.identityLine(a, base: session.target(forApproval: a).map(ThreadIdentity.line) ?? ApprovalText.displayLabel(a.targetLabel))
        if a.pendingKind != .approval {
            // 提问 / 计划内容多，岛里只给入口：打开主窗口里的完整卡片作答
            HStack(spacing: 6) {
                Text(a.pendingKind == .question ? "有问题要你选 · \(identity)" : "计划等你批准 · \(identity)").font(.caption).foregroundStyle(Color(white: 0.85)).lineLimit(1).truncationMode(.middle)
                if candidate { Text("推测").font(.caption2).foregroundStyle(PalmhelmTheme.notchWarn) }
                Spacer(minLength: 4)
                ApprovalCountdown(expiresT: a.expiresT, font: .system(.caption, design: .monospaced), normal: PalmhelmTheme.notchWarn)
            }
            HStack(spacing: 12) {
                Button(a.pendingKind == .question ? String(localized: "打开回答") : String(localized: "打开查看")) { open(.request(a.id)) }.buttonStyle(NotchButtonStyle(fill: PalmhelmTheme.notchAccent))
                if a.attribution == ApprovalAttribution.exact.rawValue, let id = session.target(forApproval: a)?.id { // 只有确定归属才给切焦点入口
                    Button("在 Herdr 中显示") { reveal(id) }.buttonStyle(.plain).foregroundStyle(Color(white: 0.85)).disabled(!session.canControl || revealing)
                }
                if let n = revealNote { Text(n.text).foregroundStyle(Color(white: 0.6)).lineLimit(1) }
            }
            .font(.caption2)
        } else {
            HStack(spacing: 6) {
                Text("\(ApprovalText.actionTitle(toolName: a.toolName)) · \(identity)").font(.caption).foregroundStyle(Color(white: 0.85)).lineLimit(1).truncationMode(.middle)
                if candidate { Text("推测").font(.caption2).foregroundStyle(PalmhelmTheme.notchWarn) }
                Spacer(minLength: 4)
                ApprovalCountdown(expiresT: a.expiresT, font: .system(.caption, design: .monospaced), normal: PalmhelmTheme.notchWarn)
            }
            Text(a.summary.isEmpty ? String(localized: "（内容已隐藏）") : a.summaryDisplayed + (a.truncated ? "…" : "")).font(.system(.caption, design: .monospaced)).foregroundStyle(.white).lineLimit(6)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 8))
            let busy = session.deciding.contains(a.id)
            let ticket = controller.pinEpochTicket // 渲染时捕获的连接代次：点击时与当前连接核对（同 ID 的新卡或新连接不接收）
            HStack {
                Button("拒绝") { Task { await controller.decidePinned(.deny, expectedId: a.id, epoch: ticket) } }.buttonStyle(NotchButtonStyle(fill: PalmhelmTheme.notchBad))
                Button("允许一次") { Task { await controller.decidePinned(.allowOnce, expectedId: a.id, epoch: ticket) } }.buttonStyle(NotchButtonStyle(fill: PalmhelmTheme.notchAccent))
                    .background(GeometryReader { g in Color.clear.preference(key: ControlFrameKey.self, value: g.frame(in: .named("notch"))) })
                if busy { Text("提交中…").font(.caption2).foregroundStyle(Color(white: 0.6)) }
                Spacer()
                // 只读设备不能做决定：禁用并说明原因
                Text(session.decideError[a.id]?.text ?? (session.canControl ? String(localized: "超时退回终端") : String(localized: "只读：在可控设备上处理"))).font(.caption2).foregroundStyle(session.decideError[a.id] == nil ? Color(white: 0.6) : PalmhelmTheme.notchBad)
            }
            .disabled(busy || !session.canControl || !live) // 固定的这条失效后立即禁用
            HStack(spacing: 12) {
                if let id = session.target(forApproval: a)?.id {
                    Button("打开对话") { open(.target(id)) }.buttonStyle(.plain).foregroundStyle(Color(white: 0.85))
                    Button("在 Herdr 中显示") { reveal(id) }.buttonStyle(.plain).foregroundStyle(Color(white: 0.85)).disabled(!session.canControl || revealing)
                } else {
                    Button("查看待答") { open(.request(a.id)) }.buttonStyle(.plain).foregroundStyle(Color(white: 0.85)).help("这条待答找不到对应的已登记目标")
                }
                if let n = revealNote { Text(n.text).foregroundStyle(Color(white: 0.6)).lineLimit(1) }
                Spacer()
            }
            .font(.caption2)
        }
    }

    // MARK: 动作

    private func open(_ d: NotchController.Destination) { controller.open(d, openWindow: openWindow, note: note) }

    private func note(_ text: LText) {
        revealGen += 1
        let gen = revealGen
        revealNote = text
        Task { try? await Task.sleep(for: .seconds(3)); if revealGen == gen { revealNote = nil } } // 只清自己这次的提示
    }

    /// 在 Herdr 里切到该目标的窗格；进行中不重复发起，结果按这次操作显示。
    private func reveal(_ targetId: String) {
        guard !revealing else { return }
        revealing = true
        revealGen += 1
        let gen = revealGen
        Task {
            let r = await session.reveal(targetId)
            revealing = false
            if revealGen == gen { note(r.message) }
        }
    }


    // 非激活面板里系统按钮按「非活动窗口」渲染成灰色，像被禁用；用显式填充样式，字用 onAccent。
    private struct NotchButtonStyle: ButtonStyle {
        let fill: Color
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.caption.weight(.semibold)).foregroundStyle(PalmhelmTheme.notchOnAccent)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
        }
    }
}
