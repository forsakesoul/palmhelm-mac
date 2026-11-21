import SwiftUI

/// 新版提示的打开动作：只有 Release 页 / CHANGELOG 两个固定入口，由用户手动下载替换。
enum UpdateLinks {
    @MainActor static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// 主窗口顶部的非模态横幅：可关闭（本次运行内不再出现）、可“跳过此版本”（再有更新的版本才再提示）。
struct UpdateBanner: View {
    let release: UpdateRelease
    let onDownload: () -> Void
    let onNotes: () -> Void
    let onSkip: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(PalmhelmTheme.accent)
            Text("Palmhelm \(release.title) 已发布").font(.callout.weight(.medium))
            Spacer(minLength: 8)
            Button("下载新版", action: onDownload).buttonStyle(.palmhelmProminent).controlSize(.small)
            Button("更新内容", action: onNotes).controlSize(.small)
            Button("跳过此版本", action: onSkip).controlSize(.small)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(Text("关闭"))
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(PalmhelmTheme.accentSoft)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// 设置 › 关于：自动检查开关 + 立即检查 + 结果。
struct UpdateSettingsRows: View {
    @Bindable var checker: UpdateChecker

    var body: some View {
        VStack(spacing: 8) {
            Toggle("自动检查更新", isOn: $checker.autoCheck).disabled(!checker.networkEnabled)
            HStack(spacing: 8) {
                Button("立即检查") { Task { await checker.checkNow() } }
                    .disabled(!checker.networkEnabled || checker.status == .checking)
                result
            }
            Text(checker.networkEnabled ? "只会向 GitHub 查询是否有新版本，请求不含任何个人数据；不会自动下载或安装。" : "开发构建不检查更新。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder private var result: some View {
        switch checker.status {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Label("已是最新版本", systemImage: "checkmark.circle").foregroundStyle(PalmhelmTheme.ok).font(.callout)
        case .failed: Label("检查失败，请稍后再试", systemImage: "exclamationmark.triangle").foregroundStyle(PalmhelmTheme.warn).font(.callout)
        case .available(let r):
            HStack(spacing: 8) {
                Text("有新版本 \(r.title)").font(.callout.weight(.medium))
                Button("下载新版") { UpdateLinks.open(r.releaseURL) }.buttonStyle(.palmhelmProminent).controlSize(.small)
                Button("更新内容") { UpdateLinks.open(UpdateRelease.changelogURL) }.controlSize(.small)
            }
        }
    }
}
