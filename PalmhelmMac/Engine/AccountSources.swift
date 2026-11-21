import Foundation
import PalmhelmKit

// #49：多账户来源（Codex / Claude 配置目录）的模型、校验、命令调用与状态映射。文件存取见 AccountSourcesStore（R1）。
// 列表保存在这台 Mac 的数据目录，Bridge 启动时经 BRIDGE_ACCOUNT_SOURCES_FILE 读取；改动后需重启 Bridge 才生效。
// Bridge 是最终校验者；这里挡明显错误，保证 Claude 根有可唯一匹配的标签（R2）。

enum AccountSourceProvider: String, Codable, CaseIterable, Sendable {
    case codex, claude
}

/// 文件里的一项（字段名与 Bridge 的 SourceConfig 相同）。path 保留原始字节，不做 trim（R3）；label 只用于显示与匹配。
struct AccountSourceEntry: Codable, Sendable, Equatable {
    var provider: AccountSourceProvider
    var path: String
    var label: String
}

enum AccountSourcesFile {
    static let maxEntries = 4
    static let maxLabelLength = 64
    static let envKey = "BRIDGE_ACCOUNT_SOURCES_FILE"

    /// 保存前的明显错误（中文提示）。空列表合法（即清空、不输出环境变量）。
    /// 路径：绝对、非空、无 ..、. 或空段、无末尾斜杠，且是目录；原始字节比较，不 trim（R3）。
    /// Claude 根：标签必须非空、去空白后唯一（R2，状态按标签唯一匹配）。
    static func problems(_ entries: [AccountSourceEntry], isDirectory: (String) -> Bool = AccountSourcesFile.directoryExists) -> [String] {
        var out: [String] = []
        if entries.count > maxEntries { out.append(String(localized: "最多保存 \(maxEntries) 个账户来源")) }
        var seenPaths = Set<String>()
        var claudeLabels = Set<String>()
        for e in entries {
            let p = e.path
            if p.isEmpty { out.append(String(localized: "有一项还没有选择目录")); continue }
            let parts = p.split(separator: "/", omittingEmptySubsequences: false)
            let badSegment = parts.dropFirst().contains { $0.isEmpty || $0 == "." || $0 == ".." }
            if !p.hasPrefix("/") || badSegment || (p.count > 1 && p.hasSuffix("/")) {
                out.append(String(localized: "目录必须是绝对路径，且不含 .、.. 或空段：\(p)"))
                continue
            }
            if !isDirectory(p) { out.append(String(localized: "目录不存在或不是文件夹：\(p)")) }
            if !seenPaths.insert(p).inserted { out.append(String(localized: "同一个目录只能保存一次：\(p)")) }
            let label = e.label.trimmingCharacters(in: .whitespaces)
            if label.count > maxLabelLength { out.append(String(localized: "显示名最多 \(maxLabelLength) 个字符")) }
            if e.provider == .claude {
                if label.isEmpty {
                    out.append(String(localized: "Claude 目录需要填写显示名（用于区分各个根）"))
                } else if !claudeLabels.insert(label).inserted {
                    out.append(String(localized: "Claude 目录的显示名必须唯一：\(label)"))
                }
            }
        }
        return out
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// 调用内置 Bridge 的 `statusline-source` 子命令。失败只保留已知的固定原因码；其余一律 failed，不回显原文（R5）。
enum StatuslineSourceCommand {
    enum Action: String, Sendable { case install, uninstall }

    struct Outcome: Equatable, Sendable {
        let ok: Bool
        let reason: String?
    }

    /// Bridge 对该子命令给出的固定原因码（与 internal/accounts/claude_sources.go、RunStatusline 的错误键一致）。
    static let knownReasons: Set<String> = [
        "usage", "source_not_listed", "registry_unavailable", "statusline_owned_elsewhere", "statusline_state_missing",
        "data_dir_missing", "data_dir_untrusted", "data_dir_invalid", "claude_source_dir_invalid", "source_untrusted",
        "config_invalid:BRIDGE_ACCOUNT_SOURCES_FILE", "settings_locked", "settings_link_changed", "settings_dir_missing",
        "unsupported_platform", "failed",
    ]

    static func arguments(_ action: Action, root: String) -> [String] {
        ["statusline-source", action.rawValue, root]
    }

    static func environment(dataDir: String, sourcesFile: String, home: String) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": home, "BRIDGE_DATA_DIR": dataDir, AccountSourcesFile.envKey: sourcesFile]
    }

    /// 退出码 0 即成功；否则从标准错误取一行 {"ok":false,"reason":…}，原因码只在已知集合内才保留，其余为 failed。
    static func parse(status: Int32, stderr: Data) -> Outcome {
        if status == 0 { return Outcome(ok: true, reason: nil) }
        let object = (try? JSONSerialization.jsonObject(with: stderr)) as? [String: Any]
        let reason = object?["reason"] as? String
        return Outcome(ok: false, reason: reason.flatMap { knownReasons.contains($0) ? $0 : nil } ?? "failed")
    }

    /// 固定原因码翻成给用户看的话；未知码统一为「失败（未知原因）」，不回显任何原文（R5）。
    static func message(for reason: String?) -> String {
        switch reason {
        case "source_not_listed": return String(localized: "这个目录还没有保存到列表，请先保存")
        case "registry_unavailable": return String(localized: "请先启动一次 Bridge（它会创建账户注册表）")
        case "statusline_owned_elsewhere": return String(localized: "状态行属于另一个来源目录，请先卸载它")
        case "statusline_state_missing": return String(localized: "状态行的原始记录缺失，需要手工处理")
        case "data_dir_missing", "data_dir_untrusted", "data_dir_invalid": return String(localized: "数据目录不可用，请检查设置里的数据目录")
        case "claude_source_dir_invalid", "source_untrusted": return String(localized: "来源目录的权限不合格（组或他人可写，或含符号链接）")
        case "config_invalid:BRIDGE_ACCOUNT_SOURCES_FILE": return String(localized: "来源文件不合格，请检查列表")
        case "settings_locked": return String(localized: "Claude 设置正被占用，请稍后重试")
        case "settings_link_changed": return String(localized: "Claude 设置在操作期间被改动，已放弃，请重试")
        case "unsupported_platform": return String(localized: "只支持 macOS")
        case "usage": return String(localized: "命令参数不对")
        case "failed", nil: return String(localized: "失败（未知原因）")
        default: return String(localized: "失败（未知原因）")
        }
    }

    /// 在后台运行内置 Bridge（argv 直传，不经 shell）。
    static func run(binary: String, action: Action, root: String, dataDir: String, sourcesFile: String, home: String) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = arguments(action, root: root)
            p.environment = environment(dataDir: dataDir, sourcesFile: sourcesFile, home: home)
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            do { try p.run() } catch { return Outcome(ok: false, reason: "failed") }
            let data = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return parse(status: p.terminationStatus, stderr: data)
        }.value
    }
}

/// 编辑代次（R4）：本机 engine 的身份（数据目录、端口、本次启动时刻）与连接。任一变化都视为另一份配置或另一个 Bridge。
struct SourcesGeneration: Equatable, Sendable {
    let dataDir: String
    let port: Int
    let engineStartedAt: TimeInterval?
    let connection: String
}

/// 一次成功刷新得到的账户，只在它的代次内有效。
struct SourcesVerified: Equatable {
    let generation: SourcesGeneration
    let accounts: [AccountSnapshot]
}

/// 来源编辑会话的门禁（纯类型，可测，R2/R4）。草稿与已保存列表都属于加载时的代次：
/// 代次不符（数据目录切换但未重载、Bridge 重启、连接变化）时保存与操作一律拒绝；异步结果只在代次仍相同时被采用。
struct AccountSourcesSession: Equatable {
    private(set) var loaded: SourcesGeneration?
    private(set) var saved: [AccountSourceEntry] = []
    var draft: [AccountSourceEntry] = []
    private(set) var loadError: String?
    private(set) var verified: SourcesVerified?
    private(set) var message: String?

    var dirty: Bool { draft != saved }

    /// 以当前代次重载（成功或失败都重载，门禁随之回到可判断的状态）。草稿、状态与消息都丢弃。
    mutating func reload(at current: SourcesGeneration, entries: [AccountSourceEntry], error: String?) {
        loaded = current
        saved = entries
        draft = entries
        loadError = error
        verified = nil
        message = nil
    }

    /// 保存成功后在新代次上重载：草稿与已保存列表相同，附带结果消息。
    mutating func committed(at current: SourcesGeneration, entries: [AccountSourceEntry], message text: String) {
        reload(at: current, entries: entries, error: nil)
        message = text
    }

    /// 保存只在加载代次与当前代次相同、且没有加载错误时允许。
    func canSave(current: SourcesGeneration) -> Bool {
        loaded == current && loadError == nil
    }

    /// 操作（安装 / 卸载）还要求草稿与已保存列表一致。
    func canAct(current: SourcesGeneration) -> Bool {
        canSave(current: current) && !dirty
    }

    /// 删除损坏的文件：只在当前加载代次且确有加载错误时允许。按钮可用性与执行点共用这一个判断。
    func canDeleteBroken(current: SourcesGeneration) -> Bool {
        loaded == current && loadError != nil
    }

    /// 执行删除：门禁不通过时不调用 remove，返回 false。成功返回 true；失败或被拒绝都不改变列表。
    func deleteBroken(at current: SourcesGeneration, _ remove: () throws -> Void) -> Bool {
        guard canDeleteBroken(current: current) else { return false }
        do {
            try remove()
            return true
        } catch {
            return false
        }
    }

    /// 异步结果的消息：只有仍处于加载代次时才写入。
    mutating func deliverMessage(_ text: String?, from origin: SourcesGeneration, current: SourcesGeneration) -> Bool {
        guard origin == current, loaded == current else { return false }
        message = text
        return true
    }

    /// 账户刷新结果：只有发起时的代次仍是当前代次，且仍是加载代次，才采用。连接不同的旧响应因此不会被采用。
    mutating func acceptAccounts(_ accounts: [AccountSnapshot], from origin: SourcesGeneration, current: SourcesGeneration) -> Bool {
        guard origin == current, loaded == current else { return false }
        verified = SourcesVerified(generation: origin, accounts: accounts)
        return true
    }

    /// Claude 根的状态：只有 Bridge 运行、没有待重启的更改、草稿与保存一致、且有当前代次内的一次成功刷新；否则一律 unknown。
    func claudeStates(current: SourcesGeneration, running: Bool, pendingRestart: Bool) -> [Int: ClaudeRootState] {
        let claudeIndices = saved.indices.filter { saved[$0].provider == .claude }
        guard running, !pendingRestart, !dirty, canSave(current: current), let v = verified, v.generation == current else {
            return Dictionary(uniqueKeysWithValues: claudeIndices.map { ($0, ClaudeRootState.unknown) })
        }
        return ClaudeRootStatus.states(entries: saved, accounts: v.accounts)
    }
}

/// 一个 Claude 根的状态，只从 GET /v1/accounts 派生（不新增接口）。
enum ClaudeRootState: Equatable, Sendable {
    case installed
    case notInstalled
    case failed(String) // 已知的固定错误码
    case unknown
}

enum ClaudeRootStatus {
    /// 第 i 个 Claude 根的状态：只在 Bridge 账户的 sources 恰好一项、且该项标签与根的标签相等时才关联；
    /// 没有匹配、多个匹配、标签为空或重复、默认根（没有 sources）一律 unknown（R2）。键为 entries 的下标。
    static func states(entries: [AccountSourceEntry], accounts: [AccountSnapshot]) -> [Int: ClaudeRootState] {
        let claudeLabels = entries.filter { $0.provider == .claude }.map { $0.label.trimmingCharacters(in: .whitespaces) }
        var out: [Int: ClaudeRootState] = [:]
        for i in entries.indices where entries[i].provider == .claude {
            let label = entries[i].label.trimmingCharacters(in: .whitespaces)
            let labelUnique = !label.isEmpty && claudeLabels.filter { $0 == label }.count == 1
            let matches = accounts.filter { account in
                account.provider == "claude" && account.sources?.count == 1 && account.sources?.first?.label == label
            }
            out[i] = (labelUnique && matches.count == 1) ? state(of: matches[0]) : .unknown
        }
        return out
    }

    static func state(of account: AccountSnapshot) -> ClaudeRootState {
        if account.errorCode == "statusline_not_installed" { return .notInstalled }
        if account.status == "error" { return .failed(account.errorCode ?? "failed") }
        switch account.status {
        case "ok", "stale", "awaiting_refresh": return .installed
        default: return .unknown
        }
    }

    static func text(_ state: ClaudeRootState) -> String {
        switch state {
        case .installed: return String(localized: "状态行已安装，额度来自状态行")
        case .notInstalled: return String(localized: "状态行未安装")
        case .failed(let code):
            switch code {
            case "source_changed": return String(localized: "读取失败：来源目录已变化，请重启 Bridge")
            case "source_untrusted", "claude_source_dir_invalid": return String(localized: "读取失败：来源目录的权限不合格")
            case "statusline_state_missing": return String(localized: "读取失败：状态行的原始记录缺失，需要手工处理")
            case "status_unreadable": return String(localized: "读取失败：状态行无法读取")
            default: return String(localized: "读取失败：未知原因")
            }
        case .unknown: return String(localized: "状态未知：保存、重启 Bridge 并刷新后可见")
        }
    }
}
