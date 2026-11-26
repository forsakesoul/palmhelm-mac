import SwiftUI

/// 「重命名对话…」弹层（#134）。macOS 的 alert 不支持文本框，故用 sheet。空白保存无效；清除以 nil 交给调用方。
struct ConversationRenameSheet: View {
    let current: String?
    let onSave: (String?) -> Void
    let onCancel: () -> Void
    @State private var draft: String

    init(current: String?, onSave: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self.current = current
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: current ?? "")
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名对话").font(.headline)
            TextField("名字", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmed.isEmpty { onSave(trimmed) } }
            Text("最多 60 个字，只能是一行。Herdr 窗口名会一起更新。").font(.caption).foregroundStyle(.secondary)
            HStack {
                if current != nil { Button("清除名字", role: .destructive) { onSave(nil) } }
                Spacer()
                Button("取消", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(trimmed) }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
