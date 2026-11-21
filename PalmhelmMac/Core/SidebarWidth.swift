import Foundation
import CoreGraphics

/// Mac 主窗口会话侧栏的宽度（#29）：拖拽分隔条调宽，宽度存在 AppDefaults，重启后恢复。纯逻辑（无视图），便于测试。
/// 与 SidebarState（收起 / 展开、窄窗行为）相互独立：宽度不影响收起规则，收起规则不改宽度。
/// 预算：侧栏 + 分隔条 + 工作区 = 可用宽度（展开时工作区至少 workspaceMinimum；侧栏不低于 minimum）。
enum SidebarWidth {
    /// 主窗口只有一个窗口场景，宽度按它保存（多窗口时再按窗口 id 分键）。
    static let key = "palmhelm.sidebarWidth.main"
    /// 默认宽度（与改动前的固定宽度一致）。
    static let ideal: CGFloat = 340
    /// 最小宽度：卡片标题、副标题与底部状态行在这个宽度下仍完整可读。
    static let minimum: CGFloat = 280
    static let maximum: CGFloat = 520
    /// 侧栏展开时，工作区至少保留的宽度（窗口变窄时侧栏让出空间）。
    static let workspaceMinimum: CGFloat = 360
    /// 分隔条本身占用的宽度（与 SidebarDivider 的命中区一致）。
    static let dividerWidth: CGFloat = 8
    /// 无障碍的增减步长（点）。
    static let step: CGFloat = 16

    /// 在可用宽度里，侧栏最多能占多少：扣掉分隔条与工作区的保留宽度；再小也不低于 minimum（那时由窄窗规则收起）。
    static func maxSidebar(available: CGFloat) -> CGFloat {
        max(minimum, min(maximum, available - dividerWidth - workspaceMinimum))
    }

    /// 显示用的宽度：保存的意图夹取到 [minimum, maxSidebar(available)]。只用于显示 / 拖动起点，不写回保存值。
    static func clamp(_ w: CGFloat, available: CGFloat) -> CGFloat {
        min(max(w, minimum), maxSidebar(available: available))
    }

    /// 展开时的三段宽度预算（侧栏 / 分隔条 / 工作区）。
    static func layout(stored: CGFloat, available: CGFloat) -> (sidebar: CGFloat, divider: CGFloat, workspace: CGFloat) {
        let s = clamp(stored, available: available)
        return (s, dividerWidth, max(0, available - s - dividerWidth))
    }

    /// 拖动结果：起始（显示）宽度 + 位移，夹取到合法范围。拖到最窄只停在 minimum，不收起侧栏（#29 验收：拖不动时松手不能把侧栏藏起来）；收起只走工具栏按钮。
    static func drag(from start: CGFloat, by delta: CGFloat, available: CGFloat) -> CGFloat {
        clamp(start + delta, available: available)
    }

    /// 一次拖动的状态机（纯逻辑）：起点是拖动开始时的显示宽度；拖动中给出预览宽度；收尾（松手 / 取消 / 视图消失）只生效一次。
    struct Drag: Equatable {
        private(set) var start: CGFloat?
        private(set) var last: CGFloat?

        var active: Bool { start != nil }

        /// 拖动中：返回需要预览的宽度。
        mutating func changed(shown: CGFloat, delta: CGFloat, available: CGFloat) -> CGFloat {
            let s = start ?? shown
            start = s
            let w = SidebarWidth.drag(from: s, by: delta, available: available)
            last = w
            return w
        }

        /// 收尾：delta 为松手时的总位移；取消时传 nil，以最近一次拖动结果收尾。不在拖动中返回 nil（不重复保存）。
        mutating func finish(delta: CGFloat?, shown: CGFloat, available: CGFloat) -> CGFloat? {
            guard let s = start else { return nil }
            let w = delta.map { SidebarWidth.drag(from: s, by: $0, available: available) } ?? last ?? shown
            start = nil
            last = nil
            return w
        }
    }

    /// 无障碍增减：与拖动同一套夹取规则。
    static func adjust(from current: CGFloat, increment: Bool, available: CGFloat) -> CGFloat {
        drag(from: current, by: increment ? step : -step, available: available)
    }

    /// 读取：没有保存过（或保存值不合法）时用默认宽度；有值时夹取到合法范围。
    static func load(_ d: UserDefaults) -> CGFloat {
        let v = CGFloat(d.double(forKey: key))
        return v.isFinite && v > 0 ? clamp(v, available: .greatestFiniteMagnitude) : ideal
    }

    static func save(_ w: CGFloat, to d: UserDefaults) {
        d.set(Double(clamp(w, available: .greatestFiniteMagnitude)), forKey: key)
    }
}
