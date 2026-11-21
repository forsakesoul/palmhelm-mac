import SwiftUI
import PalmhelmKit

/// 输入区上方的发送提示（#101，设计 12 第 2 节）：只显示一行，文案由 Kit 的 ThreadSendHintRules 产生。
struct ComposerSendHint: View {
    let hint: ThreadSendHint
    let agentName: String

    var body: some View {
        Text(ThreadSendHintRules.text(hint, agentName: agentName))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("composer.sendHint")
    }
}

/// 发送方式入口行（A2-000 #1）：左对齐的紧凑胶囊，整行（含空白处）可点，点开与发送键箭头同一份菜单数据的输入区内浮层。
struct ComposerSendOptionsEntry: View {
    let text: String
    let open: Bool
    var choice: SendMenuChoice? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if let choice { Image(systemName: choice.symbol).font(.caption2) }
                Text(text).font(.caption).lineLimit(2)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(open ? PalmhelmTheme.accent : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(open ? PalmhelmTheme.accent.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "发送方式"))
        .accessibilityValue(text)
        .accessibilityIdentifier("composer.sendOptions.entry")
    }
}

/// 发送方式浮层：选择即发送；灰显项另起一行写原因；当前默认方式带勾；Escape 关闭。不弹窗口级 popover，编辑器保持 key / selection / 组字。
struct ComposerSendOptionsPanel: View {
    let items: [SendMenuItem]
    let direct: Bool
    let canSubmit: Bool
    var current: SendMenuChoice? = nil
    let onChoose: (SendMenuItem) -> Void
    let onClose: () -> Void

    /// 键盘快捷键提示（行尾小字）：直达菜单不写 ⌘↩（⌘↩ 对直达只是普通排队）。
    private func shortcut(_ choice: SendMenuChoice) -> String? {
        switch choice {
        case .queueAfterTurn: "↩"
        case .steerNow: direct ? nil : "⌘↩"
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("发送方式").font(.subheadline.weight(.semibold))
                Text(canSubmit ? "选择后发送当前输入内容" : "输入内容后才能发送；现在只能查看各方式").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("关闭")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ForEach(Array(items.enumerated()), id: \.element.choice) { index, item in
                let usable = item.enabled && canSubmit
                // 不可用行不是 Button：disabled 的 Button 会把具体颜色再淡化一次（iOS 真机上曾近乎消失）；可用行仍是 Button。
                let row = HStack(spacing: 10) {
                    Image(systemName: item.choice.symbol).foregroundStyle(usable ? PalmhelmTheme.accent : Color(nsColor: .tertiaryLabelColor)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.choice.title).multilineTextAlignment(.leading).foregroundStyle(usable ? Color.primary : Color(nsColor: .secondaryLabelColor))
                        if !item.enabled, let why = item.disabledReason { Text(why).font(.caption).foregroundStyle(Color(nsColor: .secondaryLabelColor)).lineLimit(2).multilineTextAlignment(.leading) }
                    }
                    Spacer(minLength: 8)
                    if let key = shortcut(item.choice) { Text(key).font(.caption).foregroundStyle(.secondary) }
                    if item.choice == current { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(PalmhelmTheme.accent) }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                Group {
                    if usable {
                        Button { onChoose(item) } label: { row }.buttonStyle(.plain)
                    } else {
                        row.accessibilityElement(children: .ignore)
                            .accessibilityLabel(item.disabledReason.map { "\(item.choice.title)，\($0)" } ?? item.choice.title)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
                .help(item.disabledReason ?? "")
                .accessibilityIdentifier("composer.sendOptions.\(item.choice)")
                if index < items.count - 1 { Divider().padding(.leading, 42) } // 与文字对齐
            }
        }
        .padding(.bottom, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.sendOptions.panel")
    }
}
