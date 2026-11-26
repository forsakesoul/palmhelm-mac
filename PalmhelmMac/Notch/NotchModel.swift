import Foundation
import CoreGraphics
import AppKit
import Observation

// 刘海岛的纯逻辑（无 UI；只为读取真实屏幕度量 NotchMetrics.of 引入 AppKit，其余全是纯值）：档位判定、几何、悬停意图、瞬时提示合并、事件差分。便于单测；视图与宿主只消费这里的结果。

/// 底层状态：待答优先于工作（工作 = 有在途命令，待答 = 有未超时的待答）。
enum NotchBase: Equatable { case idle, working, waiting }

/// 当前呈现：展开（悬停）> 瞬时提示 > 紧凑。
enum NotchMode: Equatable { case compact(NotchBase), toast, expanded }

enum NotchRules {
    static func base(pending: Int, running: Int) -> NotchBase { pending > 0 ? .waiting : running > 0 ? .working : .idle }

    static func mode(base: NotchBase, hasToast: Bool, expanded: Bool) -> NotchMode { expanded ? .expanded : hasToast ? .toast : .compact(base) }

    /// 待答的剩余秒数（向下取整，不为负）：读取时刻的值，外层无障碍标签每秒由局部节点重新生成（O1-343 ⑤）。
    static func remainingSeconds(expiresT: Int, now: Date) -> Int { max(0, Int((Double(expiresT) / 1000 - now.timeIntervalSince1970).rounded(.down))) }

    static func accessibilitySummary(base: NotchBase, pending: Int, running: Int, remaining: Int?) -> String {
        switch base {
        case .idle: return "Palmhelm"
        case .working: return String(localized: "工作中 \(running) 个")
        case .waiting:
            guard let r = remaining else { return String(localized: "待答") }
            return String(localized: "\(pending) 条待答，\(r / 60) 分 \(r % 60) 秒后超时") + (pending > 1 ? String(localized: "，最近一条") : "")
        }
    }

    /// 无刘海的屏幕：空闲（无提示、没在悬停）时整个隐藏；有刘海的屏幕空闲时只剩硬件刘海（面板仍在，用来接收悬停）。
    static func isHidden(hasNotch: Bool, base: NotchBase, hasToast: Bool, expanded: Bool) -> Bool {
        !hasNotch && base == .idle && !hasToast && !expanded
    }
}

/// 屏幕上的刘海度量：notchWidth = 0 表示没有刘海；barHeight = 菜单栏 / 刘海高度。
struct NotchMetrics: Equatable {
    var notchWidth: CGFloat
    var barHeight: CGFloat
    var hasNotch: Bool { notchWidth > 0 }
    /// 真实屏幕的度量（安全区顶部 > 0 即有刘海；宽 = 屏宽 − 左右辅助区）。
    @MainActor static func of(_ screen: NSScreen) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        guard top > 0 else { return NotchMetrics(notchWidth: 0, barHeight: 34) }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0, right = screen.auxiliaryTopRightArea?.width ?? 0
        return NotchMetrics(notchWidth: max(0, screen.frame.width - left - right), barHeight: top)
    }
}

enum NotchGeometry {
    /// 顶部两角内凹的小耳朵宽度（与屏幕上沿融合）。
    static let ear: CGFloat = 8
    /// 左翼内边距：角色离形状左缘至少 8pt（耳朵内侧），尾巴 / 后腿不被裁。
    static let leadingInset: CGFloat = 8
    static let characterWidth: CGFloat = 30 // 20 格 × 1.5pt（含右侧「!」的位置）
    /// 左翼宽 = 内边距 + 角色宽 + 2pt 余量；右翼：工作放数量，待答放「+N」与倒计时。内容各自在翼内按这些宽度排，三段之和恰好等于紧凑宽。
    static let wingLeftWidth: CGFloat = leadingInset + characterWidth + 2
    static let wingRightWorking: CGFloat = 38
    static let wingRightWaiting: CGFloat = 64
    static let trailingInset: CGFloat = 8
    static func wingLeft(_ base: NotchBase) -> CGFloat { base == .idle ? 0 : wingLeftWidth }
    static func wingRight(_ base: NotchBase) -> CGFloat { base == .idle ? 0 : base == .working ? wingRightWorking : wingRightWaiting }
    static let expandedWidth: CGFloat = 400  // 展开宽 360–420
    static let toastWidth: CGFloat = 380
    static let compactRadius: CGFloat = 10
    static let expandedRadius: CGFloat = 22
    static let expandedBottomPadding: CGFloat = 16
    static let maxHeightFraction: CGFloat = 0.4 // 展开高度上限约屏高 40%，超出部分内部滚动

    /// 紧凑档尺寸（不含耳朵）。有刘海：两翼包住刘海；无刘海：宽度由内容决定，夹在 100–160，高 28–32。
    static func compactSize(_ m: NotchMetrics, base: NotchBase) -> CGSize {
        if m.hasNotch {
            return CGSize(width: m.notchWidth + wingLeft(base) + wingRight(base), height: m.barHeight)
        }
        let h = min(32, max(28, m.barHeight))
        switch base {
        case .idle: return CGSize(width: 100, height: h)
        case .working: return CGSize(width: 100, height: h)
        case .waiting: return CGSize(width: 150, height: h) // 有倒计时与「+N」更宽
        }
    }

    /// 有刘海时提示分两行：第一行（刘海高度）只放两翼的图标 / 倒计时，中间让出刘海；文字放到刘海下缘新增的一行，不会画进硬件遮挡区。
    static let toastTextRow: CGFloat = 24
    static func toastSize(_ m: NotchMetrics) -> CGSize {
        m.hasNotch ? CGSize(width: max(toastWidth, m.notchWidth + 120), height: m.barHeight + toastTextRow) : CGSize(width: 280, height: min(32, max(28, m.barHeight)))
    }
    /// 提示里各元素在形状内的 frame（原点在形状左上，不含耳朵）：测试据此校验任何文字都不与刘海矩形相交。
    /// 有刘海：左翼图标、右翼倒计时在第一行刘海两侧，文字在第二行整行；无刘海：单行，没有硬件遮挡。
    static func toastLayout(_ m: NotchMetrics) -> (icon: CGRect, countdown: CGRect, text: CGRect) {
        let s = toastSize(m)
        guard m.hasNotch else {
            return (CGRect(x: 12, y: 0, width: 30, height: s.height), CGRect(x: s.width - 12 - 40, y: 0, width: 40, height: s.height), CGRect(x: 12 + 30 + 8, y: 0, width: s.width - 24 - 30 - 8 - 40 - 8, height: s.height))
        }
        let wing = (s.width - m.notchWidth) / 2
        return (CGRect(x: leadingInset, y: 0, width: characterWidth, height: m.barHeight),
                CGRect(x: s.width - wing, y: 0, width: wing - trailingInset, height: m.barHeight),
                CGRect(x: 12, y: m.barHeight, width: s.width - 24, height: toastTextRow))
    }
    /// 刘海矩形（形状坐标，原点在形状左上）。
    static func notchRect(_ m: NotchMetrics, shapeWidth: CGFloat) -> CGRect {
        CGRect(x: (shapeWidth - m.notchWidth) / 2, y: 0, width: m.notchWidth, height: m.barHeight)
    }

    /// 展开尺寸：宽 400；高 = 顶部让出（有刘海要避开刘海那一条）+ 内容高 + 底边距，上限屏高 40%。
    static func expandedSize(_ m: NotchMetrics, contentHeight: CGFloat, screenHeight: CGFloat) -> CGSize {
        let top = (m.hasNotch ? m.barHeight : 0) + 8
        let raw = top + contentHeight + expandedBottomPadding
        return CGSize(width: expandedWidth, height: min(raw, max(top + 80, screenHeight * maxHeightFraction)))
    }

    static func radius(for mode: NotchMode) -> CGFloat { mode == .expanded ? expandedRadius : compactRadius }

    /// 目标形状（不含耳朵）。
    static func size(for mode: NotchMode, _ m: NotchMetrics, contentHeight: CGFloat, screenHeight: CGFloat) -> CGSize {
        switch mode {
        case .compact(let b): compactSize(m, base: b)
        case .toast: toastSize(m)
        case .expanded: expandedSize(m, contentHeight: contentHeight, screenHeight: screenHeight)
        }
    }

    /// 面板（含耳朵）的尺寸。
    static func panelSize(shape: CGSize) -> CGSize { CGSize(width: shape.width + 2 * ear, height: shape.height) }
}

/// 紧凑 / 提示层与展开层的混合：由明确的 reveal（展开过渡值）驱动，不是形状高度比例。
enum NotchBlend {
    static func reveal(for mode: NotchMode) -> CGFloat { mode == .expanded ? 1 : 0 }
    static func progress(reveal: CGFloat) -> CGFloat { max(0, min(1, reveal)) }
    /// 紧凑 / 提示层不透明度（减少动态效果：按目标二选一）。
    static func compactOpacity(progress p: CGFloat, reduceMotion: Bool, expanded: Bool) -> CGFloat {
        reduceMotion ? (expanded ? 0 : 1) : max(0, 1 - p * 3)
    }
    static func expandedOpacity(progress p: CGFloat, reduceMotion: Bool, expanded: Bool) -> CGFloat {
        reduceMotion ? (expanded ? 1 : 0) : max(0, min(1, (p - 0.12) / 0.45))
    }
}

/// 命中区：鼠标在「当前动画中的形状」（含两侧耳朵、圆角）里才接收；形状以外的透明区一律穿透到下方 App。
/// 形状路径与视图里画的是同一条（NotchShape），所以圆角和耳朵的透明区也穿透。
enum NotchHit {
    /// mouse 与 screenFrame 都是屏幕坐标（原点在左下）；shape 是此刻形状的宽 / 高 / 圆角（不含耳朵）。tolerance 向外放宽，避免边缘闪烁。
    static func inside(mouse: CGPoint, screenFrame: CGRect, shape: CGSize, radius: CGFloat, tolerance: CGFloat = 0) -> Bool {
        // 容差 = 把形状向两侧和下方放大 tolerance 再判（同一条路径），避免边缘处来回闪烁
        let w = shape.width + 2 * tolerance, h = shape.height + tolerance
        let full = w + 2 * NotchGeometry.ear
        let local = CGPoint(x: mouse.x - (screenFrame.midX - full / 2), y: screenFrame.maxY - mouse.y)
        return NotchShape(w: w, h: h, r: radius + tolerance).path(in: CGRect(x: 0, y: 0, width: full, height: h)).contains(local)
    }
}

/// 固定卡的公共尾部（三种待答类型——审批 / 提问 / 计划——都用）：失效说明 + 「另 N 条」+「下一条 / 知道了」。
struct NotchCardFooter: Equatable {
    enum Action: Equatable { case next, dismiss }
    var note: String?
    var others: Int
    var action: Action?
    var isEmpty: Bool { note == nil && others == 0 && action == nil }
    static func make(pinId: String?, pending: [String], live: Bool, goneNote: String) -> NotchCardFooter {
        let others = pending.filter { $0 != pinId }.count
        return NotchCardFooter(note: live ? nil : goneNote, others: others, action: others > 0 ? .next : (live ? nil : .dismiss))
    }
}

/// 展开期间固定显示「当次」的待答 id：A 失效后禁用并说明，新来的 B 只更新「另 N 条」；换下一条必须明确操作。
struct NotchCardPin: Equatable {
    private(set) var id: String?
    /// expanded 为 false（收起）清空；展开后第一次有待答时取第一条，之后不再被列表变化带走。
    mutating func sync(expanded: Bool, pending: [String]) {
        if !expanded { id = nil; return }
        if id == nil { id = pending.first }
    }
    /// 明确切到下一条：取列表里排在当前之后的第一条（没有就取第一个不同的）；都没有 → 清空。
    mutating func advance(pending: [String]) {
        let after = id.flatMap { pending.firstIndex(of: $0) }.map { Array(pending[($0 + 1)...]) } ?? pending
        id = after.first ?? pending.first { $0 != id }
    }
    func isLive(pending: [String]) -> Bool { id.map(pending.contains) ?? false }
    func others(pending: [String]) -> Int { pending.filter { $0 != id }.count }
}

/// 展开 / 收起的弹簧参数（质量 1）：展开 k300 c29（约 0.8% 过冲，约 0.45s 稳定）；收起临界阻尼 c = 2√k。
enum NotchSpring {
    static let stiffness = 300.0
    static let expandDamping = 29.0
    static var collapseDamping: Double { 2 * stiffness.squareRoot() }
    /// 是否「长大」：面积变大用展开弹簧，否则用收起弹簧。
    static func grows(from a: CGSize, to b: CGSize) -> Bool { b.width * b.height > a.width * a.height }
}

enum NotchExpansionTrigger: String, CaseIterable, Identifiable {
    case hover, click
    var id: String { rawValue }
    var label: String { self == .hover ? String(localized: "悬停展开") : String(localized: "点击展开") }
}

@MainActor
@Observable
final class NotchInteractionStore {
    static let shared = NotchInteractionStore()
    static let key = "palmhelm.notchExpansionTrigger"
    static let enabledKey = "palmhelm.notchEnabled"
    static let aboveOthersKey = "palmhelm.notchAboveOthers"
    private let defaults: UserDefaults
    var trigger: NotchExpansionTrigger { didSet { defaults.set(trigger.rawValue, forKey: Self.key) } }
    /// 「在刘海显示 Palmhelm」（#12）：关掉后把刘海让给 Vibe Island 等别的刘海 App，待答走菜单栏和主窗口。默认开。
    var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey); if enabled != oldValue { onEnabledChange?() } } }
    @ObservationIgnored var onEnabledChange: (() -> Void)?
    /// 「刘海岛显示在其他刘海应用之上」（h29c）：开 = 面板层级高于普通状态栏窗口，关 = 普通状态栏层级。默认开。只改层级，不拆窗。
    var aboveOthers: Bool { didSet { defaults.set(aboveOthers, forKey: Self.aboveOthersKey); if aboveOthers != oldValue { onLevelChange?() } } }
    @ObservationIgnored var onLevelChange: (() -> Void)?
    init(defaults: UserDefaults = AppDefaults.standard) {
        self.defaults = defaults
        trigger = defaults.string(forKey: Self.key).flatMap(NotchExpansionTrigger.init(rawValue:)) ?? .hover
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        aboveOthers = defaults.object(forKey: Self.aboveOthersKey) as? Bool ?? true
    }
}

/// 悬停模式连续停留 0.4s 展开、离开 0.35s 收回；点击模式只接受明确开关，离开不收回。
struct NotchHoverState: Equatable {
    static let enterDelay: TimeInterval = 0.4
    static let leaveGrace: TimeInterval = 0.35
    private(set) var expanded = false
    private var insideSince: Date?
    private var outsideSince: Date?
    private var suppressedUntilExit = false

    @discardableResult
    mutating func update(inside: Bool, now: Date, trigger: NotchExpansionTrigger = .hover) -> Bool {
        if !inside { suppressedUntilExit = false }
        guard trigger == .hover else { insideSince = nil; outsideSince = nil; return expanded }
        if inside {
            outsideSince = nil
            if insideSince == nil { insideSince = now }
            if !expanded, !suppressedUntilExit, let s = insideSince, now.timeIntervalSince(s) >= Self.enterDelay { expanded = true }
        } else {
            insideSince = nil
            if outsideSince == nil { outsideSince = now }
            if expanded, let s = outsideSince, now.timeIntervalSince(s) >= Self.leaveGrace { expanded = false }
        }
        return expanded
    }

    mutating func collapseNow() { expanded = false; insideSince = nil; outsideSince = nil; suppressedUntilExit = false }
    /// 明确收回后，光标仍停在岛内不能立刻触发下一次悬停展开。
    mutating func dismiss() { collapseNow(); suppressedUntilExit = true }
    /// 明确展开 / 诊断，不经过停留计时。
    mutating func force(expanded on: Bool) { expanded = on; insideSince = nil; outsideSince = nil; suppressedUntilExit = false }
}

// MARK: 瞬时提示

enum NotchEventKind: Equatable { case newRequest, done, connectionError }

/// 一个待提示的事件：目标 + 种类决定合并键。
struct NotchEvent: Equatable {
    let kind: NotchEventKind
    let target: String   // 项目名 / 目标名；连接错误写「Bridge」
    var mergeKey: String { "\(kind)|\(target)" }
    var text: String {
        switch kind {
        case .newRequest: String(localized: "\(target) · 等你处理")
        case .done: String(localized: "\(target) · 任务完成")
        case .connectionError: String(localized: "\(target) · 连接中断")
        }
    }
}

struct NotchToast: Equatable {
    let event: NotchEvent
    var count: Int
    /// 创建时刻：完成点头只以它为起点点一次；合并同一事件只延长文字与计时，不改它（不重播点头）。
    let born: Date
    var text: String { count > 1 ? "\(event.text)（\(count)）" : event.text }
}

/// 瞬时提示的状态机：约 3 秒后缩回；同一目标同一类事件合并计数（并重新计时），不同事件不排队——
/// 正在悬停 / 操作（held）时既不收回，也不替换正在看的那张，新事件直接丢（待答数仍在紧凑档里）。
struct NotchToastState: Equatable {
    static let duration: TimeInterval = 3
    static let heldGrace: TimeInterval = 1
    private(set) var current: NotchToast?
    private var deadline: Date?

    mutating func post(_ e: NotchEvent, now: Date, held: Bool) {
        if let c = current, c.event.mergeKey == e.mergeKey {
            current = NotchToast(event: c.event, count: c.count + 1, born: c.born)
            deadline = now.addingTimeInterval(Self.duration)
            return
        }
        guard !held else { return }
        current = NotchToast(event: e, count: 1, born: now)
        deadline = now.addingTimeInterval(Self.duration)
    }

    mutating func tick(now: Date, held: Bool) {
        guard current != nil, let d = deadline else { return }
        if held { deadline = max(d, now.addingTimeInterval(Self.heldGrace)); return } // 悬停 / 操作中不收回；离开后至少再留 1 秒
        if now >= d { current = nil; deadline = nil }
    }

    mutating func clear() { current = nil; deadline = nil }
}

/// 一次观测：用于差分出需要提示的事件（只有这三类，progress 不弹）。
struct NotchSnapshot: Equatable {
    enum Link: Equatable { case connected, offline, other }
    var pending: [String: String] = [:]   // 待答 id → 目标名
    var running: [String: String] = [:]   // 在途命令 key → 目标名
    var finished: [String: String] = [:]  // 已完成命令 key → 目标名
    var link: Link = .other
}

enum NotchEvents {
    /// old 为 nil（首次观测）不产生事件：启动同步 / 重连灌进来的旧数据不算新事件。
    static func diff(old: NotchSnapshot?, new: NotchSnapshot) -> [NotchEvent] {
        guard let old else { return [] }
        var out: [NotchEvent] = []
        for id in new.pending.keys.sorted() where old.pending[id] == nil { out.append(NotchEvent(kind: .newRequest, target: new.pending[id] ?? "")) }
        for key in new.finished.keys.sorted() where old.running[key] != nil && old.finished[key] == nil { out.append(NotchEvent(kind: .done, target: new.finished[key] ?? "")) } // 明确完成：之前在途、现在 finished
        if old.link == .connected, new.link == .offline { out.append(NotchEvent(kind: .connectionError, target: "Bridge")) }
        return out
    }
}

/// 刘海「工作中」的合并列表（O1-414 / #56）：在途指令 ∪ 没有对应在途指令的工作中目标。纯逻辑，不依赖 MacSession。
/// 指令行键保持原样；目标行键为 `target:<id>`，与指令键不冲突，NotchEvents.diff 不会把目标离开 working 当成完成。
enum NotchWorking {
    static let targetKeyPrefix = "target:"

    struct Command: Equatable {
        let key: String
        let targetId: String?
        let name: String    // 目标名（项目名）
        let text: String    // 指令原文（展开行的主文字）
        let label: String   // 指令状态文案（展开行右侧）
    }

    struct Target: Equatable {
        let id: String
        let name: String     // 线程标题
        let activity: String // 活动文案（session.activityText）
    }

    static func rows(commands: [Command], working: [Target]) -> [NotchWorkingRow] {
        var out = commands.map { c in
            NotchWorkingRow(key: c.key, targetId: c.targetId, name: c.name, title: "\(c.name) · \(c.text)", trailing: c.label)
        }
        let covered = Set(commands.compactMap(\.targetId))
        for t in working where !covered.contains(t.id) {
            out.append(NotchWorkingRow(key: targetKeyPrefix + t.id, targetId: t.id, name: t.name, title: t.name, trailing: t.activity))
        }
        return out
    }
}

/// 展开面板与刘海计数共用的一行。key 同时用于快照差分与列表身份。
struct NotchWorkingRow: Equatable, Identifiable {
    let key: String
    let targetId: String?
    let name: String
    let title: String
    let trailing: String
    var id: String { key }
}
