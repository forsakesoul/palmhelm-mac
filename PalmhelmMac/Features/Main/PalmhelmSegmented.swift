import SwiftUI

/// 自绘分段控件（顶部「会话｜用量」与侧栏「收件箱｜空间」共用）。
/// 为什么不用原生 .segmented Picker：切换时 NSSegmentedControl 整体重绘导致抖动。这里外框与文字几何固定（每段等宽、文字不随选中变粗），
/// 只有「选中底」这一层在移动，并且动画只挂在这一层上，内容与周围布局不参与动画；减弱动态效果时选中底直接跳变。
struct PalmhelmSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var segmentWidth: CGFloat?        // nil = 撑满父视图、等分
    var height: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private var index: Int { options.firstIndex { $0.value == selection } ?? 0 }

    var body: some View {
        GeometryReader { g in
            let w = segmentWidth ?? g.size.width / CGFloat(max(options.count, 1))
            ZStack(alignment: .leading) {
                // 选中底：唯一会动的层
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(PalmhelmTheme.card)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                    .frame(width: w - 4, height: height - 4)
                    .offset(x: SegmentedRules.indicatorOffset(index: index, segmentWidth: w) + 2)
                    .animation(SegmentedRules.animates(reduceMotion: reduceMotion) ? .easeOut(duration: 0.14) : nil, value: selection)
                HStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                        Button { selection = o.value } label: {
                            Text(o.label).font(.callout.weight(.medium)) // 字重固定：选中不换粗，文字几何不变
                                .foregroundStyle(o.value == selection ? Color.primary : Color.secondary)
                                .frame(width: w, height: height)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(o.label)
                        .accessibilityAddTraits(o.value == selection ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .transaction { $0.animation = nil } // 内容层不参与动画
            }
            .frame(width: g.size.width, height: height, alignment: .leading)
            .background(PalmhelmTheme.card2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // 键盘聚焦环：画在和外框同一个圆角矩形上（系统自带的直角焦点环已关掉）
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PalmhelmTheme.accent, lineWidth: focused ? 2 : 0))
        }
        .frame(width: segmentWidth.map { $0 * CGFloat(options.count) }, height: height)
        .focusable(true, interactions: SegmentedRules.focusInteractions) // 只在键盘导航时可聚焦：点击 / 启动不抢焦点
        .focusEffectDisabled() // 去掉系统直角焦点环
        .focused($focused)
        .onMoveCommand { dir in // 键盘：聚焦后左右方向键换段
            let delta = dir == .left ? -1 : dir == .right ? 1 : 0
            guard delta != 0 else { return }
            selection = options[SegmentedRules.moved(from: index, count: options.count, by: delta)].value
        }
        .accessibilityElement(children: .contain)
    }
}
