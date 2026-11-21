import AppKit
import Observation
import PalmhelmKit
import SwiftUI

// 线程局部头部随滚动方向连续收起 / 恢复（方向进度）：线程标题 / 状态与模型 / 详情 / 更多 / 在 Herdr 中显示作为一个头部叶子，
// 向内容末尾滚动按行程 H 逐点隐藏（平移 −H·p 并淡出），向开头滚动立即逐点恢复，idle 保持当前进度，没有计时与阈值。
// 到顶、真底、VoiceOver、各类上下文（切会话 / 连接 / 终端 / 失焦 / 遮挡 / 定位 / 弹层）强制显示，且条件解除后要新的手势才继续收起。
// 窗口标题栏、全局工具栏、局部「对话｜终端」切换条常驻，不算进 H。纯状态在 Kit（HeaderCollapseState 的 directionalProgress 模式）。

/// Mac 局部头部的状态：逐帧进度只经 `progressSink` 推给头部叶子；只有 `extent`（H）被观察，只在测量变化时写。
@MainActor
@Observable
final class MacThreadChrome {
    /// 头部自然总高度 H：只有顶部占位叶子读它（逐帧进度不经过它）。
    private(set) var extent: CGFloat = 0
    @ObservationIgnored private var state = HeaderCollapseState(behavior: .directionalProgress)
    @ObservationIgnored private var userScrolling = false
    @ObservationIgnored private var voiceOver = false
    /// 其它必须显示的条件（派发 sheet / 反馈 / 账本 / 详情 / 定位 / 窗口被遮挡 / 终端页等）：为真时恒显示。
    @ObservationIgnored private var forced = false
    /// 当前窗口是否为真正最新（非定位页、窗口下方无行、无被裁掉的较新内容）；只有它为真时“贴底”才算真底。
    @ObservationIgnored private var latestWindow = true
    @ObservationIgnored private var lastOffset: CGFloat = 0
    @ObservationIgnored private var published: CGFloat = 0
    /// 头部叶子的唯一接收者；登记带代次，离页只清自己那份。
    @ObservationIgnored private var sink: (generation: Int, apply: (CGFloat) -> Void)?
    @ObservationIgnored private var sinkGeneration = 0
    /// 离散输入（滚动条 knob / 键盘翻页）：F0-M 无法证明它们不产生 interacting 相位，所以失败开放——
    /// 显示头部，并把紧随其后的那一次相位序列（直到 idle）整体判为非用户，不跟手。
    @ObservationIgnored private var discreteArmed = false
    @ObservationIgnored private var discreteEpisode = false
    /// 相位轨迹（测试读取：生产 onScrollPhaseChange 的实际序列与时刻）。
    @ObservationIgnored private(set) var phaseLog: [(t: Double, phase: String)] = []

    init() {
        #if DEBUG
        Self.latestForTest = self
        #endif
    }

    #if DEBUG
    /// 测试读取：最近构造的实例（宿主测试里只有一个 ThreadColumn）。
    nonisolated(unsafe) static weak var latestForTest: MacThreadChrome?
    var debugState: String { "forced=\(forced) vo=\(voiceOver) latest=\(latestWindow) y=\(lastOffset) geo=\(geoCount) p=\(published) H=\(extent)" }
    @ObservationIgnored private(set) var geoCount = 0
    /// 进度写入次数与极值（逐帧进度的观察口；不被观察、不回写视图）。
    @ObservationIgnored private(set) var progressWrites = 0
    @ObservationIgnored private(set) var maxProgress: CGFloat = 0
    @ObservationIgnored private(set) var resetLog: [(t: Double, caller: String)] = []
    /// 最近一次几何的校准摘要与底边判定，测试读取。
    @ObservationIgnored private(set) var lastDigest = ""
    @ObservationIgnored private(set) var lastRawAtBottom = false
    var discreteStateForTest: String { "armed=\(discreteArmed) episode=\(discreteEpisode)" }
    #endif

    static var uptime: Double { ProcessInfo.processInfo.systemUptime }

    /// 当前进度（0 显示 … 1 隐藏）与仍遮挡顶部的高度。
    var progress: CGFloat { state.progress }
    var topOcclusion: CGFloat { state.visibleExtent }

    /// 规范化偏移（0 = 内容顶）：先按实际可滚范围夹紧（含底部内边距），弹性过冲 / 回弹不是方向反转。
    nonisolated static func normalizedOffset(contentOffsetY: CGFloat, insetTop: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat, insetBottom: CGFloat) -> CGFloat {
        min(max(contentOffsetY + insetTop, 0), max(0, contentHeight - containerHeight + insetBottom))
    }

    /// 登记头部叶子；返回代次，注销时凭它只清自己的登记。
    func attachProgressSink(_ apply: @escaping (CGFloat) -> Void) -> Int {
        sinkGeneration += 1
        sink = (sinkGeneration, apply)
        apply(published)
        return sinkGeneration
    }
    func detachProgressSink(_ generation: Int) { if sink?.generation == generation { sink = nil } }

    /// 几何（y 为规范化偏移）；rawAtBottom 为可见底边到内容尾的判定（未计窗口条件）。
    func observeGeometry(offsetY y: CGFloat, rawAtBottom: Bool, layoutChanged: Bool, digest: String = "", now: Double = MacThreadChrome.uptime) {
        lastOffset = y
        #if DEBUG
        lastDigest = digest
        lastRawAtBottom = rawAtBottom
        geoCount += 1
        #endif
        let force = forced || voiceOver || y <= 0 || (rawAtBottom && latestWindow)
        state.moved(to: y, user: userScrolling, layoutChanged: layoutChanged, force: force, at: now, chromeExtent: extent)
        publish()
    }

    func phaseChanged(to phase: HeaderCollapsePhase, now: Double = MacThreadChrome.uptime) {
        var effective = phase
        if phase == .interacting, discreteArmed { discreteArmed = false; discreteEpisode = true }
        if discreteEpisode, phase == .interacting || phase == .decelerating { effective = .animating } // 离散输入引起的滚动：不取得资格
        if phase == .idle { discreteEpisode = false }
        userScrolling = effective == .interacting || effective == .decelerating
        state.phaseChanged(to: effective, at: now)
        phaseLog.append((now, "\(phase)"))
        if phaseLog.count > 200 { phaseLog.removeFirst(100) }
        publish()
    }

    /// knob 拖动 / 滚动条轨道点击 / 键盘翻页（PageUp / PageDown / Home / End / 空格）：显示头部、清进度，随后那次滚动不跟手。
    func discreteInput() {
        reset()
        discreteArmed = true
    }
    /// 命中本滚动区的滚轮 / 触控板新事件：之前登记的离散输入作废（它们属于另一次输入）。
    func wheelInput() { discreteArmed = false }

    /// 换线程、离页、切终端、窗口失焦 / 被遮挡、换连接、定位 / 回到最新等：显示并清空旧进度、参考点与手势资格（孤立惯性不再复活旧进度）。
    func reset() {
        #if DEBUG
        if MacDiagnostics.enabled { resetLog.append((Self.uptime, Thread.callStackSymbols.dropFirst().prefix(3).map { String(String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first ?? "?").prefix(48)) }.joined(separator: " < "))) }
        if resetLog.count > 50 { resetLog.removeFirst(25) }
        #endif
        state.reset()
        userScrolling = false
        discreteArmed = false; discreteEpisode = false
        publish()
    }

    /// 头部测量高度：写前比较；变化先重置并立即同步 Kit 的行程，遮挡高度读到的立即是新 H。
    func setExtent(_ h: CGFloat) {
        let v = h.isFinite && h > 0 ? h : 0
        guard v != extent else { return }
        extent = v
        state.reset()
        state.setChromeExtent(v)
        userScrolling = false
        publish()
    }

    func setVoiceOver(_ on: Bool) { guard on != voiceOver else { return }; voiceOver = on; reset() }
    func setLatestWindow(_ on: Bool) { guard on != latestWindow else { return }; latestWindow = on; reset() }
    /// 派发 sheet / 反馈 / 账本 / 详情 / 定位 / 窗口被遮挡 / 终端页：强制显示；条件解除不恢复旧进度，要新手势。
    func setForced(_ on: Bool) { guard on != forced else { return }; forced = on; reset() }

    #if DEBUG
    /// 测试入口：与「↓ 回到最新」按钮同一个闭包（见 MainWindow.jumpToLatestAction）。
    @ObservationIgnored var jumpToLatestForTest: (() -> Void)?
    #endif

    /// 进度变化才推给接收者（写前比较）。
    private func publish() {
        let p = state.progress
        guard p != published else { return }
        published = p
        sink?.apply(p)
        #if DEBUG
        progressWrites += 1; maxProgress = max(maxProgress, p)
        #endif
    }

    /// 读屏开启时头部恒显示（NSWorkspace.isVoiceOverEnabled 可 KVO）；离页时 tearDown 释放。
    func observeVoiceOver() {
        guard voiceOverObservation == nil else { return }
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.initial, .new]) { [weak self] ws, _ in
            let on = ws.isVoiceOverEnabled
            Task { @MainActor in self?.setVoiceOver(on) }
        }
    }
    @ObservationIgnored private var voiceOverObservation: NSKeyValueObservation?

    /// 离页 / 卸载：显示并释放观察与测试动作。
    func tearDown() {
        #if DEBUG
        jumpToLatestForTest = nil // 测试动作捕获了列视图（含本对象）：离页即断开，避免引用环
        #endif
        voiceOverObservation?.invalidate(); voiceOverObservation = nil
        voiceOver = false
        reset()
    }
}

extension HeaderCollapsePhase {
    init(_ phase: ScrollPhase) {
        switch phase {
        case .idle: self = .idle
        case .tracking: self = .tracking
        case .interacting: self = .interacting
        case .decelerating: self = .decelerating
        case .animating: self = .animating
        @unknown default: self = .animating
        }
    }
}

struct MacChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 文档顶的固定占位：不随进度变化，只在 H 测量变化时重算；只有它读 `extent`。减去的 10 是外层 VStack 的行距，使首行落在 H + 内边距处，与改前版式一致。
struct MacChromeSpacer: View {
    let chrome: MacThreadChrome
    var body: some View { Color.clear.frame(height: max(0, chrome.extent - 10)).accessibilityHidden(true) }
}

/// 线程头部叶子：整块随进度平移 −H·p 并淡出，消息视口与输入框不动。进度只存在本叶子的本地状态（逐帧由 MacThreadChrome 推送），
/// 线程根页与消息行不读它。命中与读屏随可见区域：容器固定高 H 并裁剪，完全隐藏时整体不可命中、不入读屏树。
struct MacChromeHeader<Content: View>: View {
    let chrome: MacThreadChrome
    @ViewBuilder let content: Content
    @State private var p: CGFloat = 0
    @State private var generation = 0

    var body: some View {
        let h = chrome.extent
        content
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .background(GeometryReader { Color.clear.preference(key: MacChromeHeightKey.self, value: $0.size.height) })
            .offset(y: -h * p)
            .opacity(1 - p)
            .frame(height: h > 0 ? h : nil, alignment: .top)
            .clipped()
            .allowsHitTesting(p < 1)
            .accessibilityHidden(p >= 1)
            .animation(nil, value: p)
            .onPreferenceChange(MacChromeHeightKey.self) { chrome.setExtent($0) }
            .onAppear { // 接收者只捕获本地 Binding（不强持本 View / chrome）：生命周期不依赖 onDisappear 才断环
                let local = $p
                generation = chrome.attachProgressSink { local.wrappedValue = $0 }
            }
            .onDisappear { chrome.detachProgressSink(generation) }
    }
}

/// 离散输入探测（滚动条 knob / 键盘翻页）：F0-M 证明合成事件无法区分它们与用户手势，所以用只读的本地事件监视器登记它们——
/// 只匹配本消息滚动区所在窗口与位置（key 事件要求本窗口为 key 且不在文本编辑中），不吞事件、不监听其他窗口。
struct MacScrollInputGuard: NSViewRepresentable {
    let chrome: MacThreadChrome
    func makeNSView(context: Context) -> GuardView { let v = GuardView(); v.chrome = chrome; return v }
    func updateNSView(_ v: GuardView, context: Context) { v.chrome = chrome }

    @MainActor final class GuardView: NSView {
        weak var chrome: MacThreadChrome?
        nonisolated(unsafe) private var monitor: Any?
        /// 本消息滚动区的 NSScrollView：只在挂载 / 尺寸变化 / 视图更新这些低频时机解析一次并弱持；事件热路径不搜索视图树。
        /// 解析不到（尚未挂载 / 已离窗）时按失败开放处理：本区域内的按下一律当作离散输入，不静默获得隐藏资格。
        private(set) weak var scroll: NSScrollView?
        /// 结构搜索次数（测试读取：连续事件不得增加它）。
        private(set) var resolveCount = 0
        nonisolated private static let pageKeys: Set<UInt16> = [116, 121, 115, 119] // PageUp / PageDown / Home / End
        /// 翻页类按键：PageUp / PageDown / Home / End 与空格（纯函数，单测直接消费）。
        nonisolated static func isPageKey(keyCode: UInt16, chars: String?) -> Bool { pageKeys.contains(keyCode) || (keyCode == 49 && chars == " ") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            scroll = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { [weak self] e in
                MainActor.assumeIsolated { self?.observe(e) }
                return e // 只观察，不吞事件
            }
            resolveScrollView()
            DispatchQueue.main.async { [weak self] in if self?.scroll == nil { self?.resolveScrollView() } } // SwiftUI 可能在本视图之后才挂上 NSScrollView：补一次，不无限重试
        }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); resolveScrollView() } // 尺寸变化是低频布局事件
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// 窗口内与本背景视图同位置同大小的 NSScrollView（背景与 SwiftUI ScrollView 同框）；只由低频入口调用。
        func resolveScrollView() {
            resolveCount += 1
            scroll = nil
            var root: NSView = self
            while let up = root.superview { root = up }
            let mine = convert(bounds, to: root)
            var stack: [NSView] = [root]
            while let v = stack.popLast() {
                if let sv = v as? NSScrollView {
                    let r = sv.convert(sv.bounds, to: root)
                    if abs(r.minX - mine.minX) < 1.5, abs(r.minY - mine.minY) < 1.5, abs(r.width - mine.width) < 1.5, abs(r.height - mine.height) < 1.5 { scroll = sv; return }
                }
                stack.append(contentsOf: v.subviews)
            }
        }

        /// 事件入口：先 O(1) 过滤事件所属窗口，再解码交给归属判断；不做任何视图树遍历。
        func observe(_ e: NSEvent) {
            guard e.window === window, window != nil else { return }
            handle(e, editingText: window?.firstResponder is NSText)
        }

        /// 真实 NSEvent 的解码（无窗口也可调用，单测直接消费）。keyCode / charactersIgnoringModifiers 是键盘专用访问器，
        /// 鼠标 / 滚轮事件上读取会抛 NSInternalInconsistencyException，所以只在 keyDown 分支读取。
        func handle(_ e: NSEvent, editingText: Bool) {
            if e.type == .keyDown {
                route(type: .keyDown, locationInWindow: .zero, keyCode: e.keyCode, chars: e.charactersIgnoringModifiers, editingText: editingText)
            } else {
                route(type: e.type, locationInWindow: e.locationInWindow, keyCode: 0, chars: nil, editingText: editingText)
            }
        }

        /// 归属判断（O(1)：弱引用身份 + 命中矩形 + 键分类）。调用者已保证事件属于本窗口。
        func route(type: NSEvent.EventType, locationInWindow p: NSPoint, keyCode: UInt16, chars: String?, editingText: Bool) {
            guard let chrome else { return }
            if let sv = scroll, sv.window !== window { scroll = nil } // 旧视图已离窗：不再使用
            switch type {
            case .scrollWheel:
                if let sv = scroll, sv.bounds.contains(sv.convert(p, from: nil)) { chrome.wheelInput() }
            case .leftMouseDown:
                if let sv = scroll {
                    if let sc = sv.verticalScroller, !sc.isHidden, sc.bounds.contains(sc.convert(p, from: nil)) { chrome.discreteInput() }
                } else if bounds.contains(convert(p, from: nil)) {
                    chrome.discreteInput() // 尚未解析到滚动区：本区域内的按下失败开放
                }
            case .keyDown:
                guard !editingText, Self.isPageKey(keyCode: keyCode, chars: chars) else { return }
                chrome.discreteInput()
            default: break
            }
        }
    }
}

/// 测试用：消息正文在窗口坐标里的位置（按正文前 24 个字符识别；发布版不存在，普通 Debug 也默认不上报）。只在诊断打开时由 MarkdownText 上报，不被观察、不回写任何视图。
enum MacRowFrames {
    #if DEBUG
    nonisolated(unsafe) private static var frames: [String: (rect: CGRect, stamp: Double)] = [:]
    private static let lock = NSLock()
    static func set(_ key: String, _ r: CGRect) { guard MacDiagnostics.enabled else { return }; lock.lock(); frames[key] = (r, ProcessInfo.processInfo.systemUptime); lock.unlock() }
    /// 行离场（视图消失）即移除：表里只有当前仍存在的行，不留已销毁行 / 前一个宿主的记录。
    static func remove(_ key: String) { lock.lock(); frames[key] = nil; lock.unlock() }
    static func snapshot() -> [String: CGRect] { lock.lock(); defer { lock.unlock() }; return frames.mapValues(\.rect) }
    /// 该行最近一次上报的时刻（systemUptime）：采样据此确认记录属于本次宿主。
    static func stamp(_ key: String) -> Double? { lock.lock(); defer { lock.unlock() }; return frames[key]?.stamp }
    static func clear() { lock.lock(); frames = [:]; lock.unlock() }
    #endif
}

/// 测试诊断的总开关（DEBUG 才存在）：测试显式打开，普通 Debug 默认关闭。关闭时不装行 geometry 回调、不算几何摘要 / 调用栈、
/// 不计数、不注册测试动作；发布版没有这些代码。
enum MacDiagnostics {
    #if DEBUG
    nonisolated(unsafe) static var enabled = false
    #endif
}

/// 测试用渲染计数（线程页 body、消息正文 body、输入区 body、底栏构造各计一次；发布版为空操作）。不被观察、不回写任何视图。
enum MacRenderCounter {
    #if DEBUG
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private static let lock = NSLock()
    static func bump(_ key: String) { guard MacDiagnostics.enabled else { return }; lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
    static func value(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
    #else
    @inline(__always) static func bump(_ key: String) {}
    #endif
}
