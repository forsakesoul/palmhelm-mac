import Foundation
import SwiftUI
import PalmhelmKit

/// 侧栏「收件箱」的数据（纯函数，便于测试）：需要你处理（请求卡 + 没有可靠卡的 blocked 线程）→ 工作中。提醒区由 Session 的 inboxAlerts / blockedReminders 提供。
struct InboxModel: Equatable {
    /// 待答请求（按到期时间，最紧的在前）。请求卡以 approvals 为权威，不从 history 重造。
    var requests: [ApprovalView]
    /// blocked 但没有可靠卡的目标：仍然可见，标「需到终端处理」。
    var blockedWithoutCard: [String]
    /// 工作中（不含上面的 blocked 目标）：钉住的在前，再按最近活动。
    var working: [String]

    var needsYouCount: Int { requests.count + blockedWithoutCard.count }
    var isEmpty: Bool { requests.isEmpty && blockedWithoutCard.isEmpty && working.isEmpty }
    /// 侧栏收件箱只有两区：「需要你处理」只在有请求卡或无卡 blocked 时出现（空时整区不显示）；「工作中」有才显示；两区都空才显示一行空态。提醒不在侧栏（在工具栏的提醒标记里）。
    var showsNeedsYou: Bool { needsYouCount > 0 }
    var showsWorking: Bool { !working.isEmpty }
    var showsEmptyState: Bool { isEmpty }

    /// 「有可靠卡」= 有 exact 归属的待答，且目标 ID 匹配（旧 Bridge 的项目名需唯一）（同名项目下候选 / 未登记的卡不能算是这个目标的卡，A1-103 F4 同口径）。
    static func hasReliableCard(_ t: TargetSummary, approvals: [ApprovalView], targets: [TargetSummary]) -> Bool {
        approvals.contains { $0.attribution == ApprovalAttribution.exact.rawValue && ApprovalText.target(of: $0, in: targets)?.id == t.id }
    }

    static func build(approvals: [ApprovalView], targets: [TargetSummary], pinned: (String) -> Bool, lastActivity: (String) -> Int) -> InboxModel {
        let reqs = approvals.sorted { ($0.expiresT, $0.id) < ($1.expiresT, $1.id) }
        let blocked = targets.filter { ThreadIdentity.status($0) == .blocked && !hasReliableCard($0, approvals: approvals, targets: targets) }
        let blockedIds = Set(blocked.map(\.id))
        let working = targets.filter { ThreadIdentity.status($0) == .working && !blockedIds.contains($0.id) }
            .sorted { a, b in
                if pinned(a.id) != pinned(b.id) { return pinned(a.id) }
                let la = lastActivity(a.id), lb = lastActivity(b.id)
                return la != lb ? la > lb : a.id < b.id
            }
        return InboxModel(requests: reqs, blockedWithoutCard: blocked.map(\.id).sorted(), working: working.map(\.id))
    }
}

/// 请求卡该在侧栏就地办完，还是点开到右侧工作区完整显示：
/// 提问、计划、长命令 / 多行命令 / 被截断的命令到右侧；短审批在卡上直接办。
enum RequestPlacement: Equatable {
    case inline, detail

    static let shortSummaryLimit = 100

    static func of(_ a: ApprovalView) -> RequestPlacement {
        switch a.pendingKind {
        case .question, .plan: return .detail
        case .approval:
            return a.truncated || a.summary.count > shortSummaryLimit || a.summary.contains("\n") ? .detail : .inline
        }
    }
}

/// 自绘分段控件的纯规则：固定几何、方向键移动、减弱动态效果时不做选中底动画。
enum SegmentedRules {
    static func indicatorOffset(index: Int, segmentWidth: CGFloat) -> CGFloat { CGFloat(index) * segmentWidth }
    static func moved(from index: Int, count: Int, by delta: Int) -> Int { min(max(index + delta, 0), max(count - 1, 0)) }
    static func animates(reduceMotion: Bool) -> Bool { !reduceMotion }
    /// 焦点交互：只响应键盘激活（点击不聚焦，避免点一下就出现焦点环）。
    static let focusInteractions: FocusInteractions = .activate
}

/// 侧栏显示规则（F6）：宽窗按用户意图；窄窗（< 900pt）默认收起，铃铛 / 展开按钮可临时展开；回到宽窗恢复用户意图。窄窗里的临时展开不改写用户意图。
struct SidebarState: Equatable {
    static let narrowBelow: CGFloat = 900
    /// 用户在宽窗里的意图（持久化）。
    var userWants = true
    /// 窄窗里的临时展开（不持久化，回宽窗即清）。
    var tempOpen = false

    static func isNarrow(_ width: CGFloat) -> Bool { width < narrowBelow }
    func shown(narrow: Bool) -> Bool { narrow ? tempOpen : userWants }
    mutating func toggle(narrow: Bool) { if narrow { tempOpen.toggle() } else { userWants.toggle() } }
    /// 铃铛 / 导航到收件箱：保证看得见，窄窗只临时展开。
    mutating func reveal(narrow: Bool) { if narrow { tempOpen = true } else { userWants = true } }
    mutating func widthChanged(narrow: Bool) { if !narrow { tempOpen = false } }
}

/// 提醒呈现（工具栏提醒 popover）：可恢复失败在前，历史拒绝在后。
enum AlertsPresentation {
    static func split(_ alerts: [MacSession.InboxAlert]) -> (live: [MacSession.InboxAlert], history: [MacSession.InboxAlert]) {
        (alerts.filter { $0.restoreSendId != nil }, alerts.filter { $0.restoreSendId == nil })
    }
    /// 提醒入口（工具栏「!」标记）只在有提醒时出现；提醒不计数。
    static func showsMarker(reminders: Int, alerts: Int) -> Bool { reminders > 0 || alerts > 0 }
    /// popover 里的顺序：当前可操作的超时提醒与可恢复失败在前，没有恢复入口的历史拒绝在后。
    static func ordered(_ alerts: [MacSession.InboxAlert]) -> [MacSession.InboxAlert] { let p = split(alerts); return p.live + p.history }
}
