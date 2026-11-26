import Foundation
import Observation

/// 连接模式（单一权威）：local 托管本机 Bridge；remote 只连接已配对的远程 Mac，不启动本机子进程。缺省 local，旧安装零迁移。
enum ConnectionMode: String, Sendable {
    case local, remote
}

// 内置 Bridge 的配置：非机密进 UserDefaults，App Secret 进钥匙串。启动时转成子进程环境变量（Bridge 只从进程环境读配置）。
@MainActor
@Observable
final class EngineSettings {
    private let d: UserDefaults
    /// 当前网卡快照的来源（测试注入）；生产为 getifaddrs。
    @ObservationIgnored var interfaceProvider: @Sendable () -> [NetInterface] = { ListenResolver.currentInterfaces() }

    var autoStart: Bool { didSet { d.set(autoStart, forKey: "engine.autoStart") } }
    /// 退出 Palmhelm 后 Bridge 继续在后台运行（默认关）。只影响下次启动 Bridge 时传给它的环境：不带 BRIDGE_PARENT_PID，退出时不停它。
    var keepBridgeAfterQuit: Bool { didSet { d.set(keepBridgeAfterQuit, forKey: "engine.keepAfterQuit") } }
    /// 退出前确认（默认开）。「不再询问」即关闭它；设置里可重新打开。
    var confirmQuit: Bool { didSet { d.set(confirmQuit, forKey: "app.confirmQuit") } }
    /// 连接模式：只经 ConnectionModeSwitcher 改写（先清理再落盘）。
    var connectionMode: ConnectionMode { didSet { d.set(connectionMode.rawValue, forKey: "palmhelm.mac.connectionMode") } }
    var binaryPath: String { didSet { d.set(binaryPath, forKey: "engine.binaryPath") } }
    var dataDir: String { didSet { d.set(dataDir, forKey: "engine.dataDir") } }
    var tls: Bool { didSet { d.set(tls, forKey: "engine.tls") } }
    // 监听意图（h8）：回环恒开；局域网 / Tailscale 只存开关，具体 IP 每次启动时从当前网卡解析，不再落盘。
    var listenLan: Bool { didSet { d.set(listenLan, forKey: "listen.lan") } }
    var listenTailscale: Bool { didSet { d.set(listenTailscale, forKey: "listen.tailscale") } }
    var hostnames: String { didSet { d.set(hostnames, forKey: "engine.hostnames") } } // Tailscale MagicDNS 主机名（.ts.net），手机用它连 Tailscale
    var port: Int { didSet { d.set(port, forKey: "engine.port") } }
    var dispatchEnabled: Bool { didSet { d.set(dispatchEnabled, forKey: "engine.dispatch") } }
    /// #21：允许读取 Issue 的 owner/repo 列表（BRIDGE_GITHUB_ISSUE_REPOS，逗号分隔，缺省空）。只在本机生效，重启 Bridge 后生效。
    var githubIssueRepos: [String] { didSet { d.set(githubIssueRepos.joined(separator: ","), forKey: "engine.githubIssueRepos") } }
    var targetGroup: String { didSet { d.set(targetGroup, forKey: "engine.targetGroup") } }
    // 飞书（可选）：开启即组合模式；关闭即独立模式（只有设备直连）。
    var feishuEnabled: Bool { didSet { d.set(feishuEnabled, forKey: "feishu.enabled") } }
    var feishuAppId: String { didSet { d.set(feishuAppId, forKey: "feishu.appId") } }
    var feishuOwnerOpenId: String { didSet { d.set(feishuOwnerOpenId, forKey: "feishu.ownerOpenId") } }
    var feishuChatId: String { didSet { d.set(feishuChatId, forKey: "feishu.chatId") } }
    // 其他受支持的非机密变量，每行 KEY=VALUE；说明由 extraEnvComments 统一维护。
    var extraEnv: String { didSet { d.set(extraEnv, forKey: "engine.extraEnv") } }
    /// 定价自动更新（Bridge 启动时缓存超 3 天才查 models.dev）：默认开；环境变量 BRIDGE_PRICING_AUTO_UPDATE 只由这个开关输出（不再接受其他变量里的同名键，避免双重权威）。
    /// 关闭不禁手动更新。运行中真正生效的值看 /v1/usage 的 pricing.autoUpdate。
    var pricingAutoUpdate: Bool { didSet { d.set(pricingAutoUpdate, forKey: "engine.pricingAutoUpdate") } }
    var claudeQuotaEnabled: Bool { didSet { d.set(claudeQuotaEnabled, forKey: "engine.claudeOAuthQuotaEnabled") } }
    var feishuAppSecret: String {
        didSet {
            guard !restoringSecret else { return }
            secretEdits += 1 // 用户编辑/导入/清空：之后回来的旧读取不能覆盖
            if feishuAppSecret.isEmpty { KeychainStore.delete(account: "feishu-app-secret") } else { KeychainStore.save(feishuAppSecret, account: "feishu-app-secret") }
        }
    }
    /// 钥匙串里的 App Secret 异步装载：装好前不启动 Bridge（否则飞书四值缺一会退成独立模式）。
    private(set) var secretsLoaded = false
    /// 钥匙串整体（App Secret + 设备令牌）是否无响应；由 AppBoot 的看门狗按完整装载状态设置/清除。
    var keychainStalled = false
    private var restoringSecret = false
    private var secretEdits = 0

    func loadSecrets() async {
        guard !secretsLoaded else { return }
        let edits = secretEdits
        let v = await KeychainStore.loadAsync(account: "feishu-app-secret")
        if edits == secretEdits { restoringSecret = true; feishuAppSecret = v ?? ""; restoringSecret = false } // 装载期间用户已改过：保留用户的值
        secretsLoaded = true
    }

    /// 正式版（Bundle ID = com.forsakesoul.palmhelm.mac）：数据目录 ~/.palmhelm-bridge、端口 47821；其余（含 .dev）：独立的 Palmhelm-dev 目录与 47831。
    /// 过渡期回退：正式版的新目录不存在而旧目录 ~/.remote-herdr-bridge/bridge.db 存在时沿用旧目录，不在新位置静默建空库（与 Go Bridge 的缺省规则一致）。
    static func defaults(for bundleIdentifier: String?, home: String = NSHomeDirectory(), fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (dataDir: String, port: Int) {
        guard bundleIdentifier == "com.forsakesoul.palmhelm.mac" else {
            return ((home as NSString).appendingPathComponent("Library/Application Support/Palmhelm-dev/bridge"), 47831)
        }
        let fresh = (home as NSString).appendingPathComponent(".palmhelm-bridge")
        let legacy = (home as NSString).appendingPathComponent(".remote-herdr-bridge")
        if !fileExists(fresh), fileExists((legacy as NSString).appendingPathComponent("bridge.db")) { return (legacy, 47821) }
        return (fresh, 47821)
    }
    static var defaultDataDir: String { defaults(for: Bundle.main.bundleIdentifier).dataDir }
    static var defaultPort: Int { defaults(for: Bundle.main.bundleIdentifier).port }

    /// 一次性迁移旧 `engine.bind`（具体 IP 列表）→ 意图。先写新值并回读核对，**一致才删旧值**；任何一步不一致就清掉半写入的新值、保留旧值，下次启动重试。
    /// 返回本次启动应使用的意图（迁移失败时直接由旧值折算，不丢勾选）。
    nonisolated static func loadIntent(_ d: UserDefaults) -> ListenIntent {
        let lan = d.object(forKey: "listen.lan") as? Bool
        let ts = d.object(forKey: "listen.tailscale") as? Bool
        if let lan, let ts { return ListenIntent(lan: lan, tailscale: ts) }
        guard let old = d.string(forKey: "engine.bind") else { return ListenIntent(lan: lan ?? false, tailscale: ts ?? false) }
        let i = ListenMigration.intent(fromLegacyBind: old)
        d.set(i.lan, forKey: "listen.lan")
        d.set(i.tailscale, forKey: "listen.tailscale")
        if d.object(forKey: "listen.lan") as? Bool == i.lan, d.object(forKey: "listen.tailscale") as? Bool == i.tailscale {
            d.removeObject(forKey: "engine.bind")
        } else {
            d.removeObject(forKey: "listen.lan")
            d.removeObject(forKey: "listen.tailscale")
        }
        return i
    }

    /// secretsReady：测试用，跳过钥匙串异步装载（生产恒为 false，由 loadSecrets() 装载后置真）。
    init(defaults: UserDefaults = AppDefaults.standard, secretsReady: Bool = false) {
        d = defaults
        secretsLoaded = secretsReady
        let intent = Self.loadIntent(defaults)
        listenLan = intent.lan
        listenTailscale = intent.tailscale
        autoStart = d.object(forKey: "engine.autoStart") as? Bool ?? true
        keepBridgeAfterQuit = d.object(forKey: "engine.keepAfterQuit") as? Bool ?? false
        confirmQuit = d.object(forKey: "app.confirmQuit") as? Bool ?? true
        connectionMode = ConnectionMode(rawValue: d.string(forKey: "palmhelm.mac.connectionMode") ?? "") ?? .local
        binaryPath = d.string(forKey: "engine.binaryPath") ?? ""
        dataDir = d.string(forKey: "engine.dataDir") ?? Self.defaultDataDir
        tls = d.object(forKey: "engine.tls") as? Bool ?? false
        hostnames = d.string(forKey: "engine.hostnames") ?? ""
        port = d.object(forKey: "engine.port") as? Int ?? Self.defaultPort
        dispatchEnabled = d.object(forKey: "engine.dispatch") as? Bool ?? true
        githubIssueRepos = (d.string(forKey: "engine.githubIssueRepos") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        targetGroup = d.string(forKey: "engine.targetGroup") ?? ""
        feishuEnabled = d.bool(forKey: "feishu.enabled")
        feishuAppId = d.string(forKey: "feishu.appId") ?? ""
        feishuOwnerOpenId = d.string(forKey: "feishu.ownerOpenId") ?? ""
        feishuChatId = d.string(forKey: "feishu.chatId") ?? ""
        feishuAppSecret = "" // 真值由 loadSecrets() 在后台线程装入
        extraEnv = d.string(forKey: "engine.extraEnv") ?? ""
        pricingAutoUpdate = d.object(forKey: "engine.pricingAutoUpdate") as? Bool ?? true
        claudeQuotaEnabled = d.object(forKey: "engine.claudeOAuthQuotaEnabled") as? Bool ?? false
        // 迁移：「其他变量」里已有的 BRIDGE_PRICING_AUTO_UPDATE（此前它就是生效值）折算进开关并从其他变量里去掉，之后只有开关一个权威。
        let m = Self.migratePricing(extraEnv: extraEnv)
        if let v = m.value { pricingAutoUpdate = v; d.set(v, forKey: "engine.pricingAutoUpdate") }
        extraEnv = Self.normalizeExtraEnv(m.rest)
        d.set(extraEnv, forKey: "engine.extraEnv")
    }

    /// 在「其他变量」文本里找 BRIDGE_PRICING_AUTO_UPDATE：返回它的开关值（Bridge 口径：去空白后不等于 "0" 即开；多行取最后一个）与去掉该行后的文本。
    static func migratePricing(extraEnv: String) -> (value: Bool?, rest: String) {
        var value: Bool?
        var kept: [Substring] = []
        for raw in extraEnv.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), line[..<eq].trimmingCharacters(in: .whitespaces) == "BRIDGE_PRICING_AUTO_UPDATE" {
                var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
                value = v != "0"
            } else { kept.append(raw) }
        }
        return (value, kept.joined(separator: "\n"))
    }

    /// 飞书四项（按 Bridge 同样的 trim 口径）齐全才会以组合模式启动；缺项的名字给设置页提示。
    var feishuValues: [(String, String)] {
        [("App ID", feishuAppId), ("App Secret", feishuAppSecret), ("Owner Open ID", feishuOwnerOpenId), (String(localized: "私聊 Chat ID"), feishuChatId)].map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    var feishuMissing: [String] { feishuEnabled ? feishuValues.filter { $0.1.isEmpty }.map(\.0) : [] }
    var feishuConfigured: Bool { feishuEnabled && feishuMissing.isEmpty }

    enum Reach: Equatable { case loopback, tailscale, lan }
    /// 监听地址对手机的可达性：回环只有本机能连（Tailscale 也不能把 Mac 的回环端口送出去）；100.64/10 视为 Tailscale；其余按局域网。
    nonisolated static func reach(of bind: String) -> Reach {
        // 列表取对手机最可达的一项：局域网 > Tailscale > 回环
        let items = binds(bind)
        if items.contains(where: { reachOne($0) == .lan }) { return .lan }
        if items.contains(where: { reachOne($0) == .tailscale }) { return .tailscale }
        return .loopback
    }
    nonisolated static func reachOne(_ bind: String) -> Reach {
        if bind.hasPrefix("127.") || bind == "::1" || bind == "localhost" { return .loopback }
        if isTailscale(bind) { return .tailscale }
        return .lan
    }
    nonisolated static func isTailscale(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { Int($0) }
        return o.count == 4 && o[0] == 100 && (64...127).contains(o[1])
    }
    nonisolated static func isRfc1918(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }
    /// 账户来源文件的当前指纹（摘要，或 absent / unreadable）。Bridge 启动时记录它，之后与当前值比较判断「待重启」。
    var sourcesFingerprint: String {
        switch AccountSourcesStore.fileState(dataDir: dataDir) {
        case .absent: return "absent"
        case .readable(let digest): return digest
        case .unreadable: return "unreadable"
        }
    }
    /// 只用于「设置有更改」的比较（不进入子进程环境）：环境变量加上来源指纹。
    static let sourcesFingerprintKey = "PALMHELM_ACCOUNT_SOURCES_FINGERPRINT"
    func fingerprintEnvironment(resolution: ListenResolution? = nil) -> [String: String] {
        var env = environment(resolution: resolution)
        env[Self.sourcesFingerprintKey] = sourcesFingerprint
        return env
    }

    /// 按当前意图与网卡解析出的监听地址（局域网取不到就是 nil，不退化到 0.0.0.0）。
    /// 当前的监听意图（设置页的两个开关）。
    var intent: ListenIntent { ListenIntent(lan: listenLan, tailscale: listenTailscale) }
    func resolvedListen(_ ifaces: [NetInterface]? = nil) -> ListenResolution {
        ListenResolver.resolve(intent: intent, ifaces ?? interfaceProvider())
    }
    /// 传给 Bridge 的监听列表（逗号分隔，回环在最前）：每次取值都按当前网卡解析。
    var bind: String { resolvedListen().bind }

    /// 配置自检（A1-153 F3）：返回阻止 Bridge 启动或让手机连不上的问题；nil 为正常。
    /// 局域网地址由解析保证是 RFC1918，不再需要检查；「暂时没有局域网地址」不是错误（只在状态区提示，Bridge 照常启动）。
    var listenProblem: String? { listenProblem(for: resolvedListen()) }
    func listenProblem(for r: ListenResolution) -> String? { listenProblemCode(for: r).map(Self.listenProblemText) }
    /// 原因码（稳定，日志用）；界面文案由 listenProblemText 本地化。
    func listenProblemCode(for r: ListenResolution) -> String? {
        if (listenLan || listenTailscale) && !tls { return "tls_required" }
        if r.tailscale != nil {
            let h = hostnames.trimmingCharacters(in: .whitespaces)
            if h.isEmpty { return "tailscale_hostname_missing" }
            if !Self.validHostname(h) { return "tailscale_hostname_invalid" }
        }
        return nil
    }
    static func listenProblemText(_ code: String) -> String {
        switch code {
        case "tls_required": String(localized: "选了局域网或 Tailscale 必须开启 https 直连，否则 Bridge 不会启动")
        case "tailscale_hostname_missing": String(localized: "勾选 Tailscale 后必须填写 MagicDNS 主机名，否则手机无法通过 Tailscale 连接")
        case "tailscale_hostname_invalid": String(localized: "MagicDNS 主机名须以 .ts.net 结尾，只含小写字母、数字和连字符")
        default: code
        }
    }
    /// 自动检测这台 Mac 的 MagicDNS 全名（用户反馈：不该让人去查域名）。只读调用 Tailscale CLI `status --json`，argv 直传；没装或未登录返回 nil。
    nonisolated static func detectTailscaleDNSName() -> String? {
        let bin = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = ["status", "--json"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = j["Self"] as? [String: Any], var name = me["DNSName"] as? String else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        name = name.lowercased()
        return validHostname(name) ? name : nil
    }
    nonisolated static func binds(_ s: String) -> [String] {
        var seen = Set<String>()
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    /// MagicDNS 主机名白名单（与 Bridge 一致）：小写字母数字与连字符的标签，以 .ts.net 结尾。
    nonisolated static func validHostname(_ h: String) -> Bool {
        let v = h.lowercased()
        guard v.count <= 253, v.hasSuffix(".ts.net") else { return false }
        return v.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.ts\.net$"#, options: .regularExpression) != nil
    }

    static let secretKeys: Set<String> = ["FEISHU_APP_SECRET"]
    static let ownKeys: Set<String> = ["BRIDGE_LOCAL_API", "BRIDGE_DATA_DIR", "BRIDGE_LOCAL_API_BIND", "BRIDGE_LOCAL_API_HOSTNAMES", "BRIDGE_LOCAL_API_PORT", "BRIDGE_LOCAL_API_TLS", "BRIDGE_DISPATCH_ENABLED", "BRIDGE_GITHUB_ISSUE_REPOS", "BRIDGE_TARGET_GROUP", "BRIDGE_PRICING_AUTO_UPDATE", "BRIDGE_CLAUDE_QUOTA_ENABLED", "BRIDGE_ACCOUNT_SOURCES_FILE", "FEISHU_APP_ID", "FEISHU_OWNER_OPEN_ID", "FEISHU_PRIVATE_CHAT_ID"]

    // 用户配置以 Bridge config.ts / targets.ts / lock.ts 和 configuration.md 为准；不接收 hook 进程的 SPOOL_DIR 或测试预算等内部变量。
    static var extraEnvComments: [String: String] { [
        "FEISHU_GROUP_CHAT_IDS": String(localized: "允许使用的飞书群 chat_id，多个用逗号分隔；默认不开放群聊；独立模式下忽略。"),
        "FEISHU_GROUP_TARGETS": String(localized: "群内可用的项目名白名单，多个用逗号分隔；默认不允许群内操作目标；独立模式下忽略。"),
        "FEISHU_GROUP_ALLOW_SUMMARY": String(localized: "群内 Owner 的回复正文：1=发送，其他值=只发完成状态（默认）；成员问答不受此开关影响；独立模式下忽略。"),
        "FEISHU_GROUP_PANEL_ROOT": String(localized: "群面板可展示的现有目录绝对路径；默认或路径无效时关闭群面板；独立模式下忽略。"),
        "BRIDGE_ROUTING": String(localized: "逻辑入口偏好与同一终端自动接续：1=开启，其他值=关闭（默认）；不会绕过派发总开关。"),
        "BRIDGE_STEER_ENABLED": String(localized: "运行中补充：1=开启，其他值=关闭（默认）；还须开启派发，且目标是已绑定的 Claude 钩子会话。"),
        "BRIDGE_NATIVE_STEER_ENABLED": String(localized: "原生直达立即插入：1=开启，其他值=关闭（默认）；还须开启派发。只在工作中的 Claude Code 原生目标可用，送达不保证并入当前回合，详见 Bridge 文档风险说明。"),
        "BRIDGE_USAGE_PI_DIR": String(localized: "Pi 会话根目录的绝对路径，须已存在；默认 ~/.pi/agent/sessions；无效路径回退默认目录。"),
        "BRIDGE_TARGETS_ROOT": String(localized: "目标父目录的绝对路径，多个用冒号 : 分隔；各根的直接子目录成为目标，默认不扫描；路径不能含冒号；与目标文件同设时合并。"),
        "BRIDGE_TARGETS_FILE": String(localized: "多目标 JSON 数组文件绝对路径；条目填 projectName+agentName，或 projectName+cwd+origin；默认不用，须本人所有、0600、非符号链接、≤64KB，父目录不可被他人写；与目标根合并，同名以文件为准。"),
        "BRIDGE_TARGET_PROJECT_NAME": String(localized: "兼容单目标的项目名，默认不登记；须配套填写 CWD 和 ORIGIN；已设置 TARGETS_FILE 或 TARGETS_ROOT 时忽略。"),
        "BRIDGE_TARGET_CWD": String(localized: "兼容单目标的现有项目目录绝对路径，默认不登记；配套 PROJECT_NAME 和 ORIGIN；已设置 TARGETS_FILE 或 TARGETS_ROOT 时忽略。"),
        "BRIDGE_TARGET_ORIGIN": String(localized: "兼容单目标的仓库 origin 字符串，默认不登记；配套 PROJECT_NAME 和 CWD；已设置 TARGETS_FILE 或 TARGETS_ROOT 时忽略。"),
        "BRIDGE_TARGET_AGENT_NAME": String(localized: "兼容单目标的 Herdr agent 名，默认按目录匹配，多个 agent 时应指定；已设置 TARGETS_FILE 或 TARGETS_ROOT 时忽略。"),
        "BRIDGE_TARGET_SPOOL_DIR": String(localized: "兼容单目标的已有专用钩子 spool 目录绝对路径；原生模式留空（默认）；已设置 TARGETS_FILE 或 TARGETS_ROOT 时忽略。"),
        "BRIDGE_LOCK_PORT": String(localized: "应用锁的回环端口，填 1024–65535 的整数；默认由应用身份派生为 20000–44999；仅默认锁端口冲突时设置，勿与直连端口相同。"),
        "BRIDGE_HOOK_RUNTIME": String(localized: "钩子运行程序的绝对路径（Go 迁移期指向 palmhelm-bridge）：须本人所有、可执行、他人不可写；默认留空，此时用 Bridge 自身；无效时钩子安装或自动修复失败，并记 runtime_publish_failed。"),
    ] }

    private static func envLine(_ raw: Substring) -> (key: String, value: String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
        return (key, value)
    }

    /// 刷新已知键的说明、删除未知/内部/机密及已有独立字段；赋值行不重写，保留引号、空格、# 和最后一次赋值的语义。
    static func normalizeExtraEnv(_ text: String) -> String {
        text.split(separator: "\n").compactMap { raw -> String? in
            guard let (key, _) = envLine(raw), let comment = extraEnvComments[key], !secretKeys.contains(key), !ownKeys.contains(key) else { return nil }
            return "# \(comment)\n\(raw)"
        }.joined(separator: "\n")
    }

    /// 解析 KEY=VALUE 行：注释不进入环境；仅接受说明表中的键，机密与已有独立字段始终忽略。
    static func parseEnvLines(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            guard let (key, value) = envLine(raw), extraEnvComments[key] != nil, !secretKeys.contains(key), !ownKeys.contains(key) else { continue }
            out[key] = value
        }
        return out
    }

    /// 从 .env 文件导入：已有字段进各自位置（Secret 只进钥匙串），其余只保留说明表支持的配置。不打印任何值。
    func importEnvFile(at path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var rest: [String] = []
        for raw in text.split(separator: "\n") {
            guard let (key, value) = Self.envLine(raw) else { continue }
            switch key {
            case "FEISHU_APP_ID": feishuAppId = value
            case "FEISHU_APP_SECRET": feishuAppSecret = value
            case "FEISHU_OWNER_OPEN_ID": feishuOwnerOpenId = value
            case "FEISHU_PRIVATE_CHAT_ID": feishuChatId = value
            case "BRIDGE_DATA_DIR": dataDir = value
            case "BRIDGE_LOCAL_API_PORT": port = Int(value) ?? port
            case "BRIDGE_LOCAL_API_BIND": // 旧版 .env 里的具体 IP 只折算成意图，不再保存
                let i = ListenMigration.intent(fromLegacyBind: value)
                listenLan = i.lan; listenTailscale = i.tailscale
            case "BRIDGE_LOCAL_API_HOSTNAMES": hostnames = value
            case "BRIDGE_LOCAL_API_TLS": tls = value == "1"
            case "BRIDGE_DISPATCH_ENABLED": dispatchEnabled = value == "1"
            case "BRIDGE_GITHUB_ISSUE_REPOS": githubIssueRepos = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "BRIDGE_TARGET_GROUP": targetGroup = value
            case "BRIDGE_PRICING_AUTO_UPDATE": pricingAutoUpdate = value.trimmingCharacters(in: .whitespaces) != "0" // 导入的 =0 先尊重：折进开关，不进其他变量
            case "BRIDGE_CLAUDE_QUOTA_ENABLED": claudeQuotaEnabled = value.trimmingCharacters(in: .whitespaces) == "1"
            case "BRIDGE_LOCAL_API": break
            default: rest.append(String(raw))
            }
        }
        extraEnv = Self.normalizeExtraEnv(rest.joined(separator: "\n"))
        feishuEnabled = !feishuAppId.isEmpty && !feishuAppSecret.isEmpty && !feishuOwnerOpenId.isEmpty && !feishuChatId.isEmpty
    }

    /// #21 来源仓库的形状（与 Bridge 的 config 解析同一规则）：owner/repo，不接受 URL、查询或 ..。非法值不得保存：Bridge 会整体拒绝启动。
    nonisolated static func validGitHubRepo(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        return parts.count == 2 && parts.allSatisfy { (1...100).contains($0.count) && $0.unicodeScalars.allSatisfy(ok.contains) && !$0.contains("..") }
    }

    /// 从 Finder/登录项启动时 PATH 只有系统目录，而 herdr、node 装在用户目录：把常见安装目录补到末尾。
    nonisolated static func childPath(base: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        let home = NSHomeDirectory()
        var parts = (base ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for p in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.homebrew/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin"] where !parts.contains(p) { parts.append(p) } // 追加在系统目录之后，不改变既有优先级；gh 的信任由 Bridge 的祖先链校验把关
        return parts.joined(separator: ":")
    }

    /// 实际使用的二进制：设置里指定的路径，否则 App 包内 Resources/palmhelm-bridge。
    var resolvedBinary: String? {
        if !binaryPath.isEmpty { return binaryPath }
        if let url = Bundle.main.url(forResource: "palmhelm-bridge", withExtension: nil) { return url.path }
        return nil
    }

    /// 子进程环境：只传白名单变量；飞书四值要么全给要么全不给（Bridge 侧全有/全无判定）。
    func environment(resolution: ListenResolution? = nil) -> [String: String] {
        var env: [String: String] = [
            "PATH": Self.childPath(),
            "HOME": NSHomeDirectory(),
            "BRIDGE_LOCAL_API": "1",
            "BRIDGE_DATA_DIR": dataDir,
            "BRIDGE_LOCAL_API_BIND": (resolution ?? resolvedListen()).bind,
            "BRIDGE_LOCAL_API_PORT": String(port),
        ]
        // 后台运行：不交出父进程号，Bridge 的父进程守护不生效，退出 App 时它留下
        if !keepBridgeAfterQuit { env["BRIDGE_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier) }
        if tls { env["BRIDGE_LOCAL_API_TLS"] = "1" }
        env["BRIDGE_LOG_FILE"] = "1" // 持久日志 logs/bridge.log（Bridge 自己轮转，App 退出后仍有上限）
        let hs = hostnames.trimmingCharacters(in: .whitespaces).lowercased()
        if Self.validHostname(hs) { env["BRIDGE_LOCAL_API_HOSTNAMES"] = hs } // 非法主机名不送给 Bridge（它会整份拒绝）
        if dispatchEnabled { env["BRIDGE_DISPATCH_ENABLED"] = "1" }
        if !githubIssueRepos.isEmpty { env["BRIDGE_GITHUB_ISSUE_REPOS"] = githubIssueRepos.joined(separator: ",") }
        if !targetGroup.isEmpty { env["BRIDGE_TARGET_GROUP"] = targetGroup }
        // #49：账户来源文件存在（含损坏、悬空或不合格的节点）即输出固定路径，由 Bridge 按 config_invalid 拒绝启动；只有确认不存在才不输出。
        if let sourcesFile = AccountSourcesStore.configuredPath(dataDir: dataDir) { env[AccountSourcesFile.envKey] = sourcesFile }
        env["BRIDGE_PRICING_AUTO_UPDATE"] = pricingAutoUpdate ? "1" : "0" // 明确输出，不依赖 Bridge 缺省
        env["BRIDGE_CLAUDE_QUOTA_ENABLED"] = claudeQuotaEnabled ? "1" : "0"
        for (k, v) in Self.parseEnvLines(extraEnv) { env[k] = v }
        env[ManagedProcessGroup.envKey] = "1" // #107：Bridge 自建独立进程组，强杀时一次结束整组；放在 extraEnv 之后，用户不能覆盖
        if feishuConfigured {
            let v = feishuValues.map(\.1)
            env["FEISHU_APP_ID"] = v[0]
            env["FEISHU_APP_SECRET"] = v[1]
            env["FEISHU_OWNER_OPEN_ID"] = v[2]
            env["FEISHU_PRIVATE_CHAT_ID"] = v[3]
        }
        return env
    }
}
