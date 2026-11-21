import SwiftUI
import AppKit

/// 侧栏与工作区之间的拖拽分隔条（#29）。命中区 SidebarWidth.dividerWidth（可见线 1pt），光标为左右调整。
/// 拖动以「当前显示的宽度」为起点（不是保存的意图宽度）；拖动中只通过 onPreview 预览；松手 / 取消 / 视图消失时统一收尾：
/// 宽度 → onCommit（保存）；拖到最窄停在最小宽度，不收起。拖动不经过收件箱行，不影响悬停。
struct SidebarDivider: View {
    /// 当前显示的侧栏宽度（已按可用宽度夹取）。
    let width: CGFloat
    let available: CGFloat
    var onPreview: (CGFloat) -> Void
    var onCommit: (CGFloat) -> Void

    @State private var drag = SidebarWidth.Drag() // 拖动状态机（起点 / 预览 / 收尾只一次）
    @State private var hovering = false
    @State private var cursorOn = false         // 光标栈是否已压入 resizeLeftRight（push / pop 必须成对）
    @GestureState private var dragging = false

    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            .frame(width: SidebarWidth.dividerWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if !dragging { setCursor(inside) } // 拖动中保持调整光标，即使指针离开了命中区
            }
            .onChange(of: dragging) { _, active in
                if active { setCursor(true) } else { cancelOrFinish(); setCursor(hovering) } // 没有 onEnded 的结束（切走 App、窗口失焦）也在这里收尾
            }
            .onDisappear { cancelOrFinish(); setCursor(false) }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { v in
                        onPreview(drag.changed(shown: width, delta: v.translation.width, available: available))
                    }
                    .onEnded { v in
                        if let w = drag.finish(delta: v.translation.width, shown: width, available: available) { onCommit(w) }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("调整侧栏宽度")
            .accessibilityValue(String(localized: "\(Int(width)) 点"))
            .accessibilityAdjustableAction { direction in
                onCommit(SidebarWidth.adjust(from: width, increment: direction == .increment, available: available))
            }
    }

    private func cancelOrFinish() {
        if let w = drag.finish(delta: nil, shown: width, available: available) { onCommit(w) }
    }

    private func setCursor(_ on: Bool) {
        guard on != cursorOn else { return }
        cursorOn = on
        if on { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
}
