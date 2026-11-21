import AppKit
import PalmhelmKit
import SwiftUI

// #49：账户来源列表（Codex / Claude 配置目录）。固定文件 <数据目录>/account-sources.json，保存后需要重启 Bridge 才生效。
// 编辑与操作都经 AccountSourcesSession 的代次门禁（R2/R4）：数据目录、本机 engine 或连接变化后，保存与操作被拒绝，直到重新读取。
struct AccountSourcesRows: View {
    @Environment(EngineSettings.self) private var settings
    @Environment(BridgeEngine.self) private var engine
    @Environment(MacSession.self) private var session
    @State private var gate = AccountSourcesSession()
    @State private var busy = false

    /// 当前代次：本机数据目录、端口、本次启动时刻与当前连接。
    private var current: SourcesGeneration {
        SourcesGeneration(dataDir: settings.dataDir, port: settings.port,
                          engineStartedAt: engine.startedAt?.timeIntervalSince1970, connection: session.connectionId)
    }
    private var stale: Bool { gate.loaded != current }

    var body: some View {
        Group {
            Text("这里列出要采集额度的 Codex 或 Claude 配置目录。每个目录都是一个独立账户；同一账户的多个目录会合并显示，额度不相加。保存后需要重启 Bridge 才生效。")
                .font(.caption).foregroundStyle(.secondary)
            if let loadError = gate.loadError {
                Text(loadError).font(.caption).foregroundStyle(PalmhelmTheme.bad)
                Button("删除损坏的来源文件") { deleteBroken() }.controlSize(.small).disabled(busy || !gate.canDeleteBroken(current: current))
            }
            if stale, gate.loadError == nil {
                HStack {
                    Text("Bridge 或数据目录已变化，请先重新读取列表。").font(.caption).foregroundStyle(PalmhelmTheme.warn)
                    Button("重新读取") { reload() }.controlSize(.small)
                }
            }
            if gate.draft.isEmpty, gate.loadError == nil {
                Text("尚未添加。未添加时 Bridge 只读默认的 Codex 与 Claude 目录。").foregroundStyle(.secondary)
            }
            ForEach(gate.draft.indices, id: \.self) { i in
                row(i)
            }
            HStack {
                Button("添加 Codex 目录") { add(.codex) }
                Button("添加 Claude 目录") { add(.claude) }
                Spacer()
                if gate.dirty { Text("未保存").font(.caption).foregroundStyle(PalmhelmTheme.warn) }
                Button("保存") { save() }.disabled(!gate.dirty || busy || !gate.canSave(current: current))
            }
            if engine.isRunning, gate.saved.contains(where: { $0.provider == .claude }) {
                Button("刷新状态") { refreshAccounts(force: true) }
                    .controlSize(.small)
                    .disabled(busy)
            }
            if let message = gate.message { Text(message).font(.caption).foregroundStyle(PalmhelmTheme.warn) }
        }
        // 数据目录变化 → 按新目录重载（草稿丢弃）。Bridge 重启等身份变化：没有未保存草稿时自动重载，有草稿则由「重新读取」处理。
        .task(id: settings.dataDir) { reload() }
        .task(id: current) {
            if !gate.dirty || gate.loaded?.dataDir != current.dataDir { reload() }
            refreshAccounts(force: false)
        }
    }

    @ViewBuilder private func row(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("类型", selection: $gate.draft[i].provider) {
                    Text("Codex").tag(AccountSourceProvider.codex)
                    Text("Claude").tag(AccountSourceProvider.claude)
                }
                .labelsHidden()
                .frame(width: 110)
                Text(gate.draft[i].path.isEmpty ? String(localized: "未选择目录") : gate.draft[i].path)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("选择…") { choose(i) }.controlSize(.small)
                Button("移除", role: .destructive) { gate.draft.remove(at: i) }.controlSize(.small)
            }
            TextField(gate.draft[i].provider == .claude ? String(localized: "显示名（必填且唯一）") : String(localized: "显示名（可空，最多 64 个字符）"), text: $gate.draft[i].label)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            if gate.draft[i].provider == .claude {
                HStack {
                    Button("安装状态行") { run(.install, i) }
                    Button("卸载状态行") { run(.uninstall, i) }
                }
                .controlSize(.small)
                .disabled(busy || !gate.canAct(current: current) || gate.draft[i].path.isEmpty)
                let states = gate.claudeStates(current: current, running: engine.isRunning, pendingRestart: engine.pendingRestart)
                if !gate.dirty, let state = states[i] {
                    Text(ClaudeRootStatus.text(state)).font(.caption).foregroundStyle(state == .installed ? Color.secondary : PalmhelmTheme.warn)
                }
                Text("先保存列表再操作；只写这个目录的 settings.json 与 Palmhelm 自己的状态行记录，不改其它配置。安装或卸载后会刷新一次账户。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 读取与刷新

    private func reload() {
        let origin = current
        do {
            let entries = try AccountSourcesStore.load(dataDir: origin.dataDir)
            gate.reload(at: origin, entries: entries, error: nil)
        } catch {
            // 读取失败不当成空列表：保留错误并禁止保存（否则会覆盖无法校验的文件）。
            gate.reload(at: origin, entries: [], error: String(localized: "无法读取账户来源文件（权限不合格、内容损坏或格式不对）。Bridge 启动时会拒绝它；请修复，或删除该文件。"))
        }
    }

    private func refreshAccounts(force: Bool) {
        let origin = current
        guard engine.isRunning else { return }
        Task {
            let ok = await session.loadAccounts(refresh: force)
            guard ok, let accounts = session.visibleAccounts?.accounts else { return }
            // 代次变了（数据目录、Bridge 重启、连接变化）：结果不属于当前界面，不采用。
            _ = gate.acceptAccounts(accounts, from: origin, current: current)
        }
    }

    // MARK: 编辑

    private func add(_ provider: AccountSourceProvider) {
        gate.draft.append(AccountSourceEntry(provider: provider, path: "", label: ""))
    }

    private func choose(_ i: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选择 Codex 或 Claude 的配置目录（例如 ~/.codex 或 ~/.claude）")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 保留系统返回的路径原始字节（不规范化、不 trim）。
        gate.draft[i].path = url.path
    }

    private func save() {
        let origin = current
        guard gate.canSave(current: origin) else {
            _ = gate.deliverMessage(String(localized: "列表已变化，请先重新读取"), from: origin, current: origin)
            return
        }
        let cleaned = gate.draft.map {
            AccountSourceEntry(provider: $0.provider, path: $0.path, label: $0.label.trimmingCharacters(in: .whitespaces))
        }
        if let first = AccountSourcesFile.problems(cleaned).first {
            _ = gate.deliverMessage(first, from: origin, current: origin)
            return
        }
        do {
            if cleaned.isEmpty {
                try AccountSourcesStore.clear(dataDir: origin.dataDir)
            } else {
                _ = try AccountSourcesStore.save(cleaned, dataDir: origin.dataDir)
            }
            gate.committed(at: origin, entries: cleaned, message: cleaned.isEmpty ? String(localized: "已清空列表。重启 Bridge 后生效。") : String(localized: "已保存。重启 Bridge 后生效。"))
        } catch {
            _ = gate.deliverMessage(String(localized: "保存失败，请检查数据目录的权限"), from: origin, current: origin)
        }
    }

    private func deleteBroken() {
        let origin = current
        // 与按钮共用同一门禁：数据目录已切换但尚未重载时拒绝，不删除新目录里的文件。
        guard gate.canDeleteBroken(current: origin) else {
            _ = gate.deliverMessage(String(localized: "列表已变化，请先重新读取"), from: origin, current: current)
            return
        }
        let removed = gate.deleteBroken(at: origin) {
            try AccountSourcesStore.clear(dataDir: origin.dataDir)
        }
        if removed {
            reload()
            _ = gate.deliverMessage(String(localized: "已删除损坏的来源文件。重启 Bridge 后生效。"), from: origin, current: current)
        } else {
            _ = gate.deliverMessage(String(localized: "无法删除该文件，请在 Finder 中检查它"), from: origin, current: current)
        }
    }

    // MARK: 操作

    private func run(_ action: StatuslineSourceCommand.Action, _ i: Int) {
        let origin = current
        guard let binary = settings.resolvedBinary else {
            _ = gate.deliverMessage(String(localized: "找不到内置的 Bridge"), from: origin, current: origin)
            return
        }
        guard gate.canAct(current: origin) else {
            _ = gate.deliverMessage(String(localized: "列表已变化或有未保存的修改，请先保存或重新读取"), from: origin, current: origin)
            return
        }
        guard let sourcesFile = AccountSourcesStore.configuredPath(dataDir: origin.dataDir) else {
            _ = gate.deliverMessage(String(localized: "请先保存列表"), from: origin, current: origin)
            return
        }
        let root = gate.draft[i].path
        busy = true
        Task {
            let outcome = await StatuslineSourceCommand.run(binary: binary, action: action, root: root,
                                                            dataDir: origin.dataDir, sourcesFile: sourcesFile, home: NSHomeDirectory())
            busy = false
            let text = outcome.ok
                ? (action == .install ? String(localized: "状态行已安装到这个目录") : String(localized: "状态行已卸载"))
                : StatuslineSourceCommand.message(for: outcome.reason)
            // 结果只在发起时的代次仍有效时显示；旧界面的结果直接丢弃。
            guard gate.deliverMessage(text, from: origin, current: current), outcome.ok else { return }
            refreshAccounts(force: true)
        }
    }
}
