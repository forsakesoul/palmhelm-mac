import Foundation
import Security

/// 旧版（Reins）偏好域与钥匙串服务名的一次性导入。旧标识只在这个文件出现。
/// 两个阶段：偏好（同步、很快，必须早于 EngineSettings / MacSession 构造）与机密（后台线程，可能弹钥匙串授权框）。
/// 只读不删：旧域与旧钥匙串条目原样保留，回退到旧 App 时仍可用；新值已存在的键不覆盖。
/// 不导入路径类偏好（engine.dataDir、engine.binaryPath）与其他变量里的 BRIDGE_DATA_DIR / BRIDGE_HOOK_RUNTIME：
/// 这些值指向旧位置，原样导入会让新 App 在旧路径新建空库或钉住旧二进制。
enum LegacyImport {
    static let legacyDomain = "com.forsakesoul.reins.mac"
    static let legacyKeychainService = "com.forsakesoul.reins.mac"
    /// 完成标志（写在新域）。偏好阶段导入一次即写；机密阶段只有每个账户都处理完（含“旧条目不存在”）才写，任一项失败不写，下次启动重试。
    static let defaultsDoneKey = "import.legacy.defaults.v1"
    static let secretsDoneKey = "import.legacy.secrets.v1"
    /// 钥匙串里要导入的账户（以代码实际使用的账户名为准）：飞书 App Secret 与本机设备令牌。
    static let secretAccounts = ["feishu-app-secret", KeychainStore.tokenAccount]

    static let importedPrefixes = ["engine.", "feishu.", "listen.", "bridge.", "app.", "reins."]
    static let neverImported: Set<String> = ["engine.dataDir", "engine.binaryPath"]
    static let strippedEnvKeys: Set<String> = ["BRIDGE_DATA_DIR", "BRIDGE_HOOK_RUNTIME"]

    // MARK: 偏好

    /// 旧键 → 新键；不在白名单的键返回 nil。`reins.` 前缀改为 `palmhelm.`。
    static func mappedKey(_ old: String) -> String? {
        guard !neverImported.contains(old), importedPrefixes.contains(where: old.hasPrefix) else { return nil }
        return old.hasPrefix("reins.") ? "palmhelm." + old.dropFirst("reins.".count) : old
    }

    /// 去掉其他变量文本里的 BRIDGE_DATA_DIR / BRIDGE_HOOK_RUNTIME 行（容忍行首空白与 `export `），其余行（含注释）原样保留。
    static func sanitizedExtraEnv(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { raw in
            var line = raw.drop(while: { $0 == " " || $0 == "\t" })
            if line.hasPrefix("export ") { line = line.dropFirst("export ".count).drop(while: { $0 == " " }) }
            guard let eq = line.firstIndex(of: "=") else { return true }
            return !strippedEnvKeys.contains(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
        }.joined(separator: "\n")
    }

    struct DefaultsReport: Equatable { var imported: Int, skippedExisting: Int, skippedNotAllowed: Int }

    /// 把旧域的持久域字典导入 target；target 已有同名新键则保留新值。已完成（标志已写）时返回 nil。
    @discardableResult
    static func importDefaults(from old: [String: Any]?, into target: UserDefaults) -> DefaultsReport? {
        if target.bool(forKey: defaultsDoneKey) { return nil }
        var report = DefaultsReport(imported: 0, skippedExisting: 0, skippedNotAllowed: 0)
        for (key, value) in (old ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let newKey = mappedKey(key) else { report.skippedNotAllowed += 1; continue }
            if target.object(forKey: newKey) != nil { report.skippedExisting += 1; continue }
            if key == "engine.extraEnv", let text = value as? String {
                target.set(sanitizedExtraEnv(text), forKey: newKey)
            } else {
                target.set(value, forKey: newKey)
            }
            report.imported += 1
        }
        target.set(true, forKey: defaultsDoneKey)
        return report
    }

    // MARK: 钥匙串

    enum SecretRead: Equatable { case found(String), notFound, failed(Int32) }

    /// 钥匙串读写的接缝：生产是真实钥匙串，测试注入假实现（测试宿主绝不碰真实钥匙串）。
    struct Vault: Sendable {
        var read: @Sendable (_ service: String, _ account: String) -> SecretRead
        var write: @Sendable (_ value: String, _ service: String, _ account: String) -> Bool
    }

    enum SecretOutcome: Equatable { case imported, alreadyPresent, nothingToImport, failed(Int32) }
    struct SecretsReport: Equatable { var outcomes: [String: SecretOutcome]; var completed: Bool }

    /// 逐项导入。新服务名下已有该账户则不动；旧条目不存在算处理完；读到旧值就写新服务名（写失败算失败）；
    /// 读失败（用户拒绝授权、钥匙串不可用等）算失败。全部处理完才写完成标志。已完成时返回 nil。
    static func importSecrets(vault: Vault, newService: String, flags: UserDefaults) -> SecretsReport? {
        if flags.bool(forKey: secretsDoneKey) { return nil }
        var outcomes: [String: SecretOutcome] = [:]
        for account in secretAccounts {
            switch vault.read(newService, account) {
            case .found: outcomes[account] = .alreadyPresent; continue
            case .failed(let s): outcomes[account] = .failed(s); continue
            case .notFound: break
            }
            switch vault.read(legacyKeychainService, account) {
            case .notFound: outcomes[account] = .nothingToImport
            case .failed(let s): outcomes[account] = .failed(s)
            case .found(let v): outcomes[account] = vault.write(v, newService, account) ? .imported : .failed(errSecIO)
            }
        }
        let completed = !outcomes.values.contains { if case .failed = $0 { true } else { false } }
        if completed { flags.set(true, forKey: secretsDoneKey) }
        return SecretsReport(outcomes: outcomes, completed: completed)
    }

    /// 真实钥匙串。读：SecItemCopyMatching；写：先删再加（与 KeychainStore.save 同一做法，只作用于新服务名）。
    static let systemVault = Vault(
        read: { service, account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
                return .found(s)
            case errSecItemNotFound: return .notFound
            default: return .failed(status)
            }
        },
        write: { value, service, account in
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
            var add = query
            add[kSecValueData as String] = Data(value.utf8)
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        })

    // MARK: 启动入口（测试宿主一律不执行）

    /// 只有正式 bundle id 运行导入（#100）。非正式构建（演示、开发）直接标记为无需导入，不读旧域，也不读写正式钥匙串命名空间。
    static func isFormal(bundleID: String?) -> Bool { bundleID == KeychainStore.formalBundleID }

    /// 偏好阶段的决策，可注入（测试用）。非正式构建只写完成标志，不调用 readLegacy。
    static func runDefaultsImport(bundleID: String?, into target: UserDefaults, readLegacy: () -> [String: Any]?) -> DefaultsReport? {
        guard isFormal(bundleID: bundleID) else { target.set(true, forKey: defaultsDoneKey); return nil }
        return importDefaults(from: readLegacy(), into: target)
    }

    /// 早于 EngineSettings / MacSession 构造调用。旧域读取走持久域字典，不写旧域。
    static func importDefaultsOnLaunch(into target: UserDefaults = UserDefaults.standard, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard !RuntimeEnvironment.isTestHost else { return }
        _ = runDefaultsImport(bundleID: bundleID, into: target) { UserDefaults.standard.persistentDomain(forName: legacyDomain) }
    }

    /// 机密阶段的决策，可注入（测试用）。非正式构建只写完成标志，不调用 vault。
    static func runSecretsImport(bundleID: String?, flags: UserDefaults, vault: Vault) -> SecretsReport? {
        guard isFormal(bundleID: bundleID) else { flags.set(true, forKey: secretsDoneKey); return nil }
        return importSecrets(vault: vault, newService: KeychainStore.formalBundleID, flags: flags)
    }

    /// 后台线程执行；返回一行固定格式的摘要（只含账户名与结果类别，不含任何值），无事可做时返回 nil。
    static func importSecretsOnLaunch() async -> String? {
        guard !RuntimeEnvironment.isTestHost else { return nil }
        let bundleID = Bundle.main.bundleIdentifier
        let flags = UserDefaults.standard
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let report = runSecretsImport(bundleID: bundleID, flags: flags, vault: systemVault) else { return nil }
            let parts = report.outcomes.sorted { $0.key < $1.key }.map { "\($0.key)=\(label($0.value))" }
            return "legacy-import secrets \(report.completed ? "完成" : "未完成，下次启动重试"): " + parts.joined(separator: ", ")
        }.value
    }

    private static func label(_ o: SecretOutcome) -> String {
        switch o {
        case .imported: "imported"
        case .alreadyPresent: "present"
        case .nothingToImport: "none"
        case .failed(let s): "failed(\(s))"
        }
    }
}
