import PalmhelmKit
import SwiftUI

// #21：GitHub 需求来源（允许读取 Issue 的 owner/repo）。只在这台 Mac 上保存；Bridge 启动时读取，保存后需要重启生效。
// 非法仓库名不保存：Bridge 遇到非法值会整体拒绝启动，这里在输入时就挡住。
struct GitHubSourcesRows: View {
    @Environment(EngineSettings.self) private var settings
    @Environment(MacSession.self) private var session
    @State private var newRepo = ""
    @State private var error: LText?
    @State private var options: IssueTaskOptions?
    @State private var statusNote: LText?

    var body: some View {
        Group {
            Text("这里的仓库可以读取 Issue 作为派发来源；只读取标题、正文与状态，不会扫描整个 GitHub 账号，也不会创建评论、PR 或修改 Issue。").font(.caption).foregroundStyle(.secondary)
            LabeledContent("GitHub CLI") {
                if let github = options?.github {
                    Text(github.available ? String(localized: "可读取") : String(localized: "不可用，请到 Mac 终端执行 gh auth login"))
                        .foregroundStyle(github.available ? Color.secondary : PalmhelmTheme.warn)
                } else {
                    Text(statusNote?.text ?? String(localized: "正在读取…")).foregroundStyle(.secondary)
                }
            }
            if settings.githubIssueRepos.isEmpty {
                Text("尚未允许任何来源仓库。").foregroundStyle(.secondary)
            }
            ForEach(settings.githubIssueRepos, id: \.self) { repo in
                HStack {
                    Text(repo)
                    Spacer()
                    Button("移除", role: .destructive) { settings.githubIssueRepos.removeAll { $0 == repo } }
                        .accessibilityLabel("移除来源仓库 \(repo)")
                }
            }
            HStack {
                TextField("owner/repo", text: $newRepo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityLabel("添加来源仓库")
                Button("添加", action: add).disabled(newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error.text).font(.caption).foregroundStyle(PalmhelmTheme.warn) }
            Text("保存后需要重启 Bridge 才生效；已经受理的任务不会被删除。").font(.caption).foregroundStyle(.secondary)
        }
        .task { await loadStatus() }
    }

    private func add() {
        let repo = newRepo.trimmingCharacters(in: .whitespaces)
        guard EngineSettings.validGitHubRepo(repo) else { error = LText(String(localized: "请输入 owner/repo 形式的仓库名，例如 octo/handoff。")); return }
        guard !settings.githubIssueRepos.contains(repo) else { error = LText(String(localized: "这个仓库已经在列表里。")); return }
        settings.githubIssueRepos.append(repo)
        newRepo = ""
        error = nil
    }

    private func loadStatus() async {
        guard let client = session.issueTaskClient() else { statusNote = LText(String(localized: "未连接 Bridge，无法读取 gh 状态。")); return }
        do { options = try await client.issueTaskOptions() } catch { statusNote = LText(String(localized: "Bridge 未运行或尚未支持此功能。")) }
    }
}
