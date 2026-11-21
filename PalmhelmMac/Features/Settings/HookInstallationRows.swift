import SwiftUI
import PalmhelmKit

struct HookInstallationRows: View {
    @Environment(MacSession.self) private var session
    @State private var repairRequest: MacSession.HookRepairRequest?
    var body: some View {
        ForEach(HookProvider.allCases, id: \.self) { provider in
            let setting = session.hookSetting(provider)
            let blockedByBuild = provider == .claude && !session.isDistribution
            let refusal = MacSession.hookOwnershipRefusal(provider, setting.installation)
            let foreign = refusal != nil && (setting.state == .on || setting.state == .stale || setting.state == .off)
            VStack(alignment: .leading, spacing: 6) {
                Toggle(provider.title, isOn: Binding(
                    get: { setting.state == .on || setting.state == .stale },
                    set: { install in Task { await session.setHookInstallation(provider, install: install) } }
                ))
                .accessibilityValue(stateText(setting.state, provider: provider))
                .disabled(blockedByBuild || foreign || setting.busy || !session.canControl || !(setting.state == .on || setting.state == .stale || setting.state == .off) || session.link != .connected)
                HStack {
                    Text(stateText(setting.state, provider: provider)).font(.caption).foregroundStyle(.secondary)
                    if setting.busy { ProgressView().controlSize(.small).accessibilityLabel("正在更新审批定义") }
                    Spacer()
                    if foreign, let request = session.hookRepairCandidate(provider) {
                        Button("修复到当前正式版") { repairRequest = request }
                            .disabled(setting.busy)
                    } else if setting.state == .on || setting.state == .stale {
                        Button("更新 / 修复") { Task { await session.setHookInstallation(provider, install: true) } }
                            .disabled(blockedByBuild || foreign || setting.busy || !session.canControl || session.link != .connected)
                    } else if setting.state == .unknown {
                        Button("重新读取") { Task { await session.loadHookInstallation(provider) } }
                            .disabled(setting.busy || session.link != .connected)
                    }
                }
                if let failure = setting.installation?.lastFailure ?? setting.unreadable, let line = Self.failureLine(failure) {
                    Text(line).font(.caption).foregroundStyle(PalmhelmTheme.warn)
                }
                if blockedByBuild {
                    Text(MacSession.nonDistributionHookNote.text).font(.caption).foregroundStyle(PalmhelmTheme.warn)
                } else if foreign, let refusal {
                    Text(refusal.text).font(.caption).foregroundStyle(PalmhelmTheme.warn)
                }
                if let note = setting.note { Text(note.text).font(.caption).foregroundStyle(.secondary) }
                if provider == .codex {
                    Text("请在 Codex 里运行 /hooks 信任 Palmhelm 的 hook；更新后需要重新信任。无法核实是否已信任，已安装不等于已生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Text("只支持默认的 ~/.claude/settings.json 与 ~/.codex/hooks.json。保留其他钩子；关闭只卸载 Palmhelm 的定义，不更改审批权限。")
            .font(.caption).foregroundStyle(.secondary)
        .confirmationDialog("将审批钩子改到当前正式版？", isPresented: Binding(get: { repairRequest != nil }, set: { if !$0 { repairRequest = nil } }), titleVisibility: .visible) {
            Button("修复到当前正式版") {
                if let r = repairRequest { Task { await session.confirmHookRepair(r) } }
                repairRequest = nil
            }
            Button("取消", role: .cancel) { repairRequest = nil }
        } message: {
            Text("修复后，新的审批请求将交给当前数据目录对应的 Bridge。其他版本可能不再收到审批。")
        }
        .task(id: "\(session.connectionId)|\(session.link)") {
            guard session.link == .connected else { return }
            for provider in HookProvider.allCases { await session.loadHookInstallation(provider) }
        }
    }
    /// 固定分类的故障文案 + 时间（只读，不回显路径或原文）；没有有效时间或未知分类时不显示。
    static func failureLine(_ failure: HookLaunchFailure) -> String? {
        guard let text = HookFailureCopy.text(for: failure.reason), let date = failure.validDate else { return nil }
        let hint = ["launch_failed", "runtime_publish_failed"].contains(failure.reason)
            ? String(localized: "请更新 / 修复后重试。")
            : String(localized: "请在这台 Mac 上修好配置，重启 Bridge 后故障会清除。")
        return "\(text)：\(date.shown(date: .abbreviated, time: .standard))。\(hint)"
    }
    private func stateText(_ state: MacSession.HookInstallState, provider: HookProvider) -> String {
        switch state {
        case .unknown: String(localized: "安装状态未知")
        case .loading: String(localized: "正在读取安装状态…")
        case .on: String(localized: "已安装定义")
        case .stale: provider == .codex ? String(localized: "需要更新并在 /hooks 重新信任") : String(localized: "需要更新")
        case .off: String(localized: "未安装")
        case .unsupported: String(localized: "当前 Bridge 不支持，请使用新版 Mac 内置 Bridge")
        }
    }
}
