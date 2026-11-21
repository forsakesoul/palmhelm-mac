import SwiftUI

// 对话页的底部跟随（G / S2）：只有原本贴底、且不在定位视图、不在终端页时，内容变高（流式正文、状态行、输入区增高）才跟到底。
// 贴底状态由用户意图决定：用户正在滚动（interacting / decelerating）时以几何为准；否则布局变化（内容或视口高度变化）不改写它。

/// 滚动几何快照：贴底与否，以及判定时的内容 / 视口高度。
struct ScrollSnap: Equatable {
    let atBottom: Bool
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    /// 底部安全区（底栏）遮住的高度：它是布局尺寸，底栏增高与内容 / 视口变化同样不是用户操作（F1）。
    let bottomInset: CGFloat

    /// 距底 40pt 以内算贴底。`contentInsetBottom` 是底部安全区（底栏）遮住的部分，不算可见内容。
    init(contentOffsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat, contentInsetBottom: CGFloat = 0) {
        self.atBottom = contentOffsetY + containerHeight - contentInsetBottom >= contentHeight - 40
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.bottomInset = contentInsetBottom
    }
}

enum ThreadFollow {
    /// 是否跟随到底：贴底、没有定位 pin、对话页（非终端）。
    static func follows(stuck: Bool, pinnedHit: String?, threadMode: Int) -> Bool {
        stuck && pinnedHit == nil && threadMode == 0
    }

    /// 布局尺寸（内容高、视口高、底部 inset）都未变时才允许几何改写贴底状态。
    static func updatesStuck(old: ScrollSnap?, new: ScrollSnap) -> Bool {
        guard let old else { return true }
        return old.contentHeight == new.contentHeight && old.containerHeight == new.containerHeight && old.bottomInset == new.bottomInset
    }

    /// 下一个贴底状态。用户正在滚动时以几何为准（即使内容 / 视口同帧变化，上翻必须生效）；
    /// 否则只在尺寸未变时更新，布局变化沿用当前状态。
    static func nextStuck(current: Bool, old: ScrollSnap?, new: ScrollSnap, userScrolling: Bool) -> Bool {
        if userScrolling || updatesStuck(old: old, new: new) { return new.atBottom }
        return current
    }

    /// 排队的滚底在执行前复核当前意图：仍贴底、无 pin、对话页，且线程未切换。
    static func runsQueued(stuck: Bool, pinnedHit: String?, threadMode: Int, selectedThread: String?, threadId: String) -> Bool {
        follows(stuck: stuck, pinnedHit: pinnedHit, threadMode: threadMode) && selectedThread == threadId
    }
}

/// 输入区等底栏的高度（用于底栏增高后恢复贴底）。
struct FooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// 记录滚动是否贴底（几何 + 滚动阶段，均为 macOS 15 API；部署版本已提到 15）。
    func trackScroll(stuck: Binding<Bool>, userScrolling: Binding<Bool>) -> some View {
        self
            .onScrollGeometryChange(for: ScrollSnap.self, of: { g in
                ScrollSnap(contentOffsetY: g.contentOffset.y, contentHeight: g.contentSize.height, containerHeight: g.containerSize.height, contentInsetBottom: g.contentInsets.bottom)
            }, action: { prev, new in
                // 逐帧回调里值不变即不写：每次写 @State 都会让观察它的整页 body 失效
                let next = ThreadFollow.nextStuck(current: stuck.wrappedValue, old: prev, new: new, userScrolling: userScrolling.wrappedValue)
                if next != stuck.wrappedValue { stuck.wrappedValue = next }
            })
            .onScrollPhaseChange { _, phase in
                let scrolling = phase == .interacting || phase == .decelerating
                if scrolling != userScrolling.wrappedValue { userScrolling.wrappedValue = scrolling }
            }
    }
}
