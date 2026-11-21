import SwiftUI

/// 线程头部的详情行（#101）。
struct ThreadDetail: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let value: String

    static func == (lhs: ThreadDetail, rhs: ThreadDetail) -> Bool { lhs.label == rhs.label && lhs.value == rhs.value }
}

/// 线程头部（#101，设计 12 第 1、4 节）：状态胶囊 + 模型胶囊。「详情」按钮是 `ThreadDetailsButton`，与「在 Herdr 中显示」成组放在头部右侧（#112）。
/// 只接收已经算好的显示值，不依赖会话状态，便于预览与测试。
struct ThreadHeaderBar: View {
    let statusText: String
    let statusTone: Color
    let durationText: String?
    let modelText: String?
    /// 模型胶囊的读屏文字（含来源、完整模型、等级）：可见文字只有简写；nil 时读可见文字。
    var modelAccessibility: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            statusCapsule
            if let modelText {
                capsule { Text(modelText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spokenModel(visible: modelText, spoken: modelAccessibility))
                    .accessibilityIdentifier("threadHeader.model")
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("threadHeader")
    }

    /// 模型胶囊的读屏文字：有来源版本就读它，否则读可见文字。
    static func spokenModel(visible: String, spoken: String?) -> String { spoken ?? visible }

    private var statusCapsule: some View {
        capsule {
            Circle().fill(statusTone).frame(width: 7, height: 7)
            Text(statusText).lineLimit(1)
            if let durationText {
                Text(durationText).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("threadHeader.status")
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 「详情」按钮 + popover（位置、智能体与模型、飞书去向）。详情不含「在 Mac 上显示」（本机即 Mac）。
struct ThreadDetailsButton: View {
    let details: [ThreadDetail]
    /// 详情里的一个可点按钮（#101 P3：飞书切换移入详情）；不可用时保留可见但禁用。
    struct Action {
        let title: String
        let disabled: Bool
        let perform: () -> Void
    }
    var secondaryAction: Action? = nil
    /// 详情 popover 展示翻转时通知外部（让线程头部在弹层期间保持显示）；默认无行为。
    var onDetailsShownChange: ((Bool) -> Void)? = nil
    @State private var showDetails = false

    var body: some View {
        Button("详情") { showDetails = true }
            .foregroundStyle(.secondary)
            .accessibilityLabel("会话详情")
            .popover(isPresented: $showDetails, arrowEdge: .bottom) { detailList }
            .onChange(of: showDetails) { _, on in onDetailsShownChange?(on) }
            .accessibilityIdentifier("threadHeader.details")
    }

    private var detailList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(details) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.label).font(.caption).foregroundStyle(.secondary)
                    Text(d.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let secondaryAction {
                Divider()
                Button(secondaryAction.title) {
                    showDetails = false
                    secondaryAction.perform()
                }
                .disabled(secondaryAction.disabled)
                .accessibilityIdentifier("threadHeader.feishuSwitch")
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

/// 「在 Herdr 中显示」按钮的标签：宽窄两档（窄宽只留图标，读屏与悬停仍是原文字）。
struct CompactRevealLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon } else { configuration.title }
    }
}
