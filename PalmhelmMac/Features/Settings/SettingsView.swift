import SwiftUI
import PalmhelmKit

// 设置：Bridge 引擎、连接与直连、飞书（可选）、日志。改动需要重启 Bridge 才生效（环境变量在启动时传入）。
struct SettingsView: View {
    @Environment(EngineSettings.self) private var settings
    @Environment(BridgeEngine.self) private var engine
    @Environment(MacSession.self) private var session
    @Environment(UpdateChecker.self) private var updates: UpdateChecker? // 可选：只读宿主（视图测试）不必注入
    @State private var confirmStop = false
    private var credentialsPending: Bool { !settings.secretsLoaded || !session.credentialsLoaded }

    /// 设置窗口（h10c M5）：原生侧栏 7 区。各区内容原样迁自原来的 Tab，行为不变（监听地址等属 h8）；
    /// 换区 / 换主题都只改本视图的选中项与可观察的主题存储，不重建 EngineSettings / BridgeEngine / Session，也不会产生「引擎待重启」。
    enum Pane: String, CaseIterable, Identifiable {
        case appearance, engine, connection, feishu, usagePrivacy, logs, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .appearance: String(localized: "外观"); case .engine: String(localized: "引擎"); case .connection: String(localized: "连接与设备"); case .feishu: String(localized: "飞书")
            case .usagePrivacy: String(localized: "用量与隐私"); case .logs: String(localized: "日志"); case .about: String(localized: "关于")
            }
        }
        var symbol: String {
            switch self {
            case .appearance: "paintpalette"; case .engine: "cpu"; case .connection: "antenna.radiowaves.left.and.right"; case .feishu: "message"
            case .usagePrivacy: "hand.raised"; case .logs: "doc.text"; case .about: "info.circle"
            }
        }
        /// 远程模式下不适用的区：本机引擎、飞书、本机日志。本机模式显示全部。
        static func visible(for mode: ConnectionMode) -> [Pane] {
            switch mode {
            case .local: allCases
            case .remote: allCases.filter { $0 != .engine && $0 != .feishu && $0 != .logs }
            }
        }
    }
    @State private var section: Pane
    @State private var columns = NavigationSplitViewVisibility.all

    /// initialPane：截图等场景直接打开某一区；默认与原来一致（外观）。
    init(initialPane: Pane = .appearance) { _section = State(initialValue: initialPane) }

    /// 当前模式下可见的区；选中的区被隐藏时回到外观。
    private var visiblePanes: [Pane] { Pane.visible(for: settings.connectionMode) }
    private var effectiveSection: Pane { visiblePanes.contains(section) ? section : .appearance }

    var body: some View {
        // 像系统设置一样侧栏始终在：原生分隔条拖到最窄再松手会把侧栏收起（#28 验收），这里立即恢复成两栏
        NavigationSplitView(columnVisibility: $columns) {
            List(visiblePanes, selection: Binding<Pane?>(get: { effectiveSection }, set: { if let v = $0 { section = v } })) { sec in
                Label(sec.label, systemImage: sec.symbol).tag(sec)
            }
            .frame(minWidth: 240)
            .navigationSplitViewColumnWidth(min: 240, ideal: 250, max: 320) // 英文标签（如 Connection、Usage and…）最窄也要完整显示
            .toolbar(removing: .sidebarToggle) // 设置窗口像系统设置一样不折叠侧边栏：去掉孤零零悬在侧栏顶部的折叠按钮
        } detail: {
            detail.navigationTitle(effectiveSection.label)
        }
        .onChange(of: columns) { _, v in if v != .all { columns = .all } }
    }

    @ViewBuilder private var detail: some View {
        @Bindable var settings = settings
        switch effectiveSection {
        case .appearance: AppearanceSettings()
        case .engine:
        Form {
            Section("Bridge 引擎") {
                HStack {
                    StatusDot(kind: engine.isRunning ? .ok : .off)
                    Text("\(credentialsPending ? ConnectionPhase.credentialsWaitText(stalled: settings.keychainStalled) : engine.displayStatus) · \(engine.mode)")
                    if let at = engine.startedAt, engine.isRunning { Text("· 已运行 \(at, style: .relative)").foregroundStyle(.secondary) }
                    Spacer()
                    switch engine.status {
                    case .running: Button("重启") { Task { await engine.restart() } }; Button("停止") { confirmStop = true }.tint(PalmhelmTheme.bad)
                    case .starting, .stopping: SkeletonBlock(width: 64, height: 20, cornerRadius: 6)
                    case .stopped, .failed: Button("启动") { engine.start() }.buttonStyle(.palmhelmProminent).disabled(!settings.secretsLoaded).help(settings.secretsLoaded ? "" : ConnectionPhase.credentialsWaitText(stalled: settings.keychainStalled))
                    }
                }
                if engine.pendingRestart { restartBanner }
                Toggle("随 App 启动", isOn: $settings.autoStart)
                Toggle("退出 Palmhelm 后 Bridge 继续在后台运行", isOn: $settings.keepBridgeAfterQuit)
                Text("开启后，退出 Palmhelm（⌘Q、菜单或 Dock）不会停止 Bridge，手机仍可连接；下次打开 Palmhelm 会接管它。切换在下次启动 Bridge 时生效。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("退出 Palmhelm 前确认", isOn: $settings.confirmQuit)
                Text("关闭后退出不再询问。系统注销、重启、关机与脚本退出本来就不询问。").font(.caption).foregroundStyle(.secondary)
                TextField("数据目录", text: $settings.dataDir)
                TextField("Bridge 二进制（留空用 App 内置）", text: $settings.binaryPath)
                Text("iPhone 推送：topic 取自数据目录 apns/apns.json 的 bundleId，须与 iPhone App 的 Bundle ID（com.forsakesoul.palmhelm）一致；本页不修改该文件，改完后重启 Bridge 生效。").font(.caption).foregroundStyle(.secondary)
                LabeledContent("版本", value: engine.portFile?.version ?? "—")
                Toggle("允许飞书/设备派发任务到 agent（BRIDGE_DISPATCH_ENABLED）", isOn: $settings.dispatchEnabled)
                TextField("目标分组规则", text: $settings.targetGroup, prompt: Text("留空用默认"))
                Text("正则，一个捕获组；匹配 Herdr agent 名得到编组名。").font(.caption).foregroundStyle(.secondary)
            }
            Section("审批钩子") { HookInstallationRows() }
        }
            .formStyle(.grouped)
            .confirmationDialog("停止 Bridge？", isPresented: $confirmStop) {
                Button("停止", role: .destructive) { Task { await engine.stop() } }
            } message: { Text("手机与飞书会断开，直到再次启动。") }
        case .connection:
        Form {
            ConnectionModeRows()
            if settings.connectionMode == .remote { Section("远程 Mac") { RemoteMacRows() } }
            Section("这台设备") { ThisDeviceNameRows() }
            if settings.connectionMode == .local { Section("连接与直连") {
                Toggle("https 直连（局域网与 Tailscale 都要开；同一 Wi‑Fi 的手机还可自动发现）", isOn: $settings.tls)
                ListenIntentRows(settings: settings, engine: engine)
                TextField("端口", value: $settings.port, format: .number.grouping(.never))
                LabeledContent("Bonjour") { Text(settings.tls && EngineSettings.reach(of: settings.bind) == .lan ? String(localized: "已勾选局域网地址，会广播 _palmhelm._tcp（手机同一 Wi‑Fi 可发现）") : String(localized: "不广播")).foregroundStyle(.secondary) }
                if engine.pendingRestart { restartBanner }
                if let spki = engine.portFile?.tls?.spkiSha256, let short = SPKI.shortFingerprint(spkiSha256: spki) {
                    LabeledContent("证书短指纹", value: short)
                }
            } }
        }
            .formStyle(.grouped)
        case .feishu:
        Form {
            Section("飞书（可选）") {
                Toggle("启用飞书通道（开启即组合模式；关闭即独立模式，只有设备直连）", isOn: $settings.feishuEnabled)
                TextField("App ID", text: $settings.feishuAppId).disabled(!settings.feishuEnabled)
                SecureField(settings.secretsLoaded ? String(localized: "App Secret（存钥匙串）") : String(localized: "App Secret（读取中…）"), text: $settings.feishuAppSecret).disabled(!settings.feishuEnabled || !settings.secretsLoaded)
                TextField("Owner Open ID", text: $settings.feishuOwnerOpenId).disabled(!settings.feishuEnabled)
                TextField("私聊 Chat ID", text: $settings.feishuChatId).disabled(!settings.feishuEnabled)
                if settings.feishuEnabled, !settings.feishuMissing.isEmpty {
                    Text(String(localized: "缺少 \(settings.feishuMissing.joined(separator: "、"))：启动时不会传任何飞书参数，Bridge 会以独立模式运行。")).font(.caption).foregroundStyle(PalmhelmTheme.bad)
                } else {
                    Text("四项齐全才以飞书组合模式启动。").font(.caption).foregroundStyle(.secondary)
                }
                if engine.pendingRestart { restartBanner }
            }
            Section("GitHub 需求来源") { GitHubSourcesRows() }
            Section("其他配置（目标发现、路由与飞书群）") {
                TextEditor(text: $settings.extraEnv).font(.system(.caption, design: .monospaced)).frame(minHeight: 140, maxHeight: 220)
                HStack {
                    Button("从 .env 导入…") { importEnv() }.disabled(!settings.secretsLoaded)
                    Text("每行 KEY=VALUE，上方 # 注释说明用途与默认值。装载和导入时会更新说明、移除不支持的键；App Secret 只进钥匙串。改动需重启 Bridge。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
            .formStyle(.grouped)
        case .usagePrivacy:
            VStack(spacing: 0) {
                if engine.pendingRestart { restartBanner.padding() }
                UsagePrivacySettings()
            }
        case .logs:
        BridgeLogsPane(engine: engine)
        case .about:
        VStack(spacing: 10) {
            PalmhelmAppIcon(size: 96)
            Text("Palmhelm").font(.title.weight(.bold))
            Text("在手机上看住、批准、指挥 Mac 上的 agent").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Text("App 版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")）")
                Text("内置 Bridge \(engine.portFile?.version ?? String(localized: "未运行"))")
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
            if let updates { UpdateSettingsRows(checker: updates).padding(.top, 14) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        }
    }

    private var restartBanner: some View {
        HStack { Text("设置有更改，重启 Bridge 后生效。").font(.caption).foregroundStyle(PalmhelmTheme.warn); Spacer(); Button("立即重启") { Task { await engine.restart() } }.controlSize(.small) }
    }

    private func importEnv() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "选择 Bridge 的 .env 文件")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? settings.importEnvFile(at: url.path)
    }
}


/// 监听意图（h8）：回环常开；局域网与 Tailscale 只是开关，右侧只读显示此刻解析到的地址（换网络后自动更新）。
/// 不再手选 IP：具体地址每次启动、以及网络变化时由 Bridge 引擎按意图重新解析；没有可用局域网地址时不退化到 0.0.0.0，只在这里提示。
private struct ListenIntentRows: View {
    @Bindable var settings: EngineSettings
    let engine: BridgeEngine

    private var hostnameOK: Bool { EngineSettings.validHostname(settings.hostnames.trimmingCharacters(in: .whitespaces)) } // 取到 Tailscale 地址后必填（A1-153 F3）

    var body: some View {
        let _ = engine.networkRevision // 系统网络路径变化后重新读取当前地址
        let res = settings.resolvedListen()
        Toggle("回环 127.0.0.1（只给这台 Mac 自己）", isOn: .constant(true)).disabled(true)
        HStack {
            Toggle("局域网 IPv4（同一 Wi‑Fi 的手机；需 https）", isOn: $settings.listenLan)
            Spacer(minLength: 8)
            Text(res.lan ?? String(localized: "当前无可用局域网地址")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
        HStack {
            Toggle("Tailscale（外出；需 https）", isOn: Binding(get: { settings.listenTailscale }, set: { on in
                settings.listenTailscale = on
                if on, let n = EngineSettings.detectTailscaleDNSName() { settings.hostnames = n }
            }))
            Spacer(minLength: 8)
            Text(res.tailscale ?? String(localized: "未检测到 100.x 地址")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
        if settings.listenTailscale {
            // 主机名自动从 Tailscale 检测（用户反馈：不该让人自己去查域名）；检测不到才手填
            HStack {
                TextField("MagicDNS 主机名（自动检测；检测不到再手填）", text: $settings.hostnames)
                Button("重新检测") { if let n = EngineSettings.detectTailscaleDNSName() { settings.hostnames = n } }.controlSize(.small)
            }
            .onAppear { if let n = EngineSettings.detectTailscaleDNSName() { settings.hostnames = n } } // 每次打开都以 Tailscale 实际值为准，覆盖过期手填值
            if res.tailscale != nil {
                Text(hostnameOK ? String(localized: "手机会用这个主机名连 Tailscale（Bridge 会把它和局域网地址一起告诉手机，手机自动选能连上的）。") : String(localized: "没检测到 Tailscale 主机名：确认 Tailscale 已登录后点「重新检测」，或手填以 .ts.net 结尾的名字")).font(.caption).foregroundStyle(hostnameOK ? .secondary : PalmhelmTheme.bad)
            }
        }
        LabeledContent("监听") {
            Text(listenSummary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        if res.lanUnavailable {
            Text(res.tailscale != nil ? String(localized: "局域网暂不可用（没有同一 Wi‑Fi 的地址），手机可走 Tailscale。") : String(localized: "局域网暂不可用（没有同一 Wi‑Fi 的地址）；连上网络后会自动更新监听。")).font(.caption).foregroundStyle(.secondary)
        }
        if let p = settings.listenProblem(for: res) { Text(p).font(.caption).foregroundStyle(PalmhelmTheme.bad) }
    }

    /// 状态区一行：重启中 / 实际监听的地址（来自 Bridge 写出的 local-api.json）。
    private var listenSummary: String {
        if engine.networkRestarting { return String(localized: "网络变化，正在重新监听…") }
        guard let pf = engine.portFile else { return String(localized: "Bridge 未运行") }
        return pf.allBinds.joined(separator: " · ") + String(localized: "（网络变化时自动更新）")
    }
}


/// 外观：主题（清蓝 / 暖橙 / 松绿，带预览）与明暗外观。即时生效、按本机保存；不碰引擎设置，不需要重启 Bridge。
private struct AppearanceSettings: View {
    @Environment(MacSession.self) private var session
    @State private var confirmResetSpaces = false
    private let store = PalmhelmThemeStore.shared
    @Environment(\.colorScheme) private var scheme
    private let characterStore = NotchCharacterStore.shared
    private let notchInteraction = NotchInteractionStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var store = store
        Form {
            Section("主题") {
                HStack(spacing: 12) {
                    ForEach(PalmhelmThemeFamily.allCases, id: \.self) { f in
                        Button { store.family = f } label: { ThemePreview(family: f, dark: scheme == .dark, selected: store.family == f) }.buttonStyle(.plain) // 原生按钮：键盘可聚焦、可用空格触发，视觉不变
                    }
                }
                .padding(.vertical, 4)
            }
            Section("刘海") {
                @Bindable var cs = characterStore
                @Bindable var interaction = notchInteraction
                Toggle("在刘海显示 Palmhelm", isOn: $interaction.enabled)
                Text("关闭后 Palmhelm 不再占用刘海，适合同时使用 Vibe Island 等刘海 App。待答和进度在菜单栏图标和主窗口里查看。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("刘海岛显示在其他刘海应用之上", isOn: $interaction.aboveOthers)
                    .disabled(!interaction.enabled)
                Text("开启后提高刘海岛的窗口层级；其他应用若使用更高的窗口层级，仍可能盖住它。")
                    .font(.caption).foregroundStyle(.secondary)
                Group {
                    Picker("展开方式", selection: $interaction.trigger) {
                        ForEach(NotchExpansionTrigger.allCases) { Text($0.label).tag($0) }
                    }
                    Text(interaction.trigger == .click ? String(localized: "点击后保持展开，离开不收回；点收起按钮或按 Esc 收回。也可用“窗口”菜单或 ⌘⌥N 展开 / 收起。") : String(localized: "悬停片刻展开，离开后自动收回；也可点击或用“窗口”菜单展开。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("刘海角色", selection: $cs.character) {
                        ForEach(NotchCharacter.allCases) { c in
                            HStack(spacing: 8) { PixelCharacterView(character: c, mode: .run, animating: !reduceMotion); Text(c.label) }.tag(c)
                        }
                    }
                    // 预览：工作（跑 / 敲 / 起伏）与待答（静止 + 「!」闪烁）两种姿态，与刘海里是同一个视图
                    HStack(spacing: 24) {
                        VStack(spacing: 4) { PixelCharacterView(character: cs.character, mode: .run, animating: !reduceMotion, scale: 2); Text("工作中").font(.caption2).foregroundStyle(.secondary) }
                        VStack(spacing: 4) { PixelCharacterView(character: cs.character, mode: .wait, animating: !reduceMotion, scale: 2); Text("待答").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(10).background(Color.black, in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                }
                .disabled(!interaction.enabled) // 关掉时保留原值、不可改，重新打开后照旧
                Text("只影响这台 Mac 的顶部刘海，不同步、不进 Bridge。减少动态效果时角色停在静止帧。").font(.caption).foregroundStyle(.secondary)
            }
            Section("外观") {
                Picker("外观", selection: $store.appearance) { ForEach(PalmhelmAppearance.allCases) { Text($0.label).tag($0) } }
                Text("即时生效、按本机保存，不需要重启 Bridge。角色色与 ok / warn / bad 不随主题变。").font(.caption).foregroundStyle(.secondary)
            }
            LanguageSection()
            // 空间分组排序（#98）：只存在这台 Mac 上；没有合适的分组，放在外观页（最接近“列表显示”）。
            Section("空间分组") {
                Button("重置分组排序", role: .destructive) { confirmResetSpaces = true }
                Text("分组的顺序、置顶与拖动只保存在这台 Mac 上，不影响 iPhone。Herdr 重启后没有 agent 的工作区可能需要重新排序。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("重置分组排序？", isPresented: $confirmResetSpaces, titleVisibility: .visible) {
            Button("重置", role: .destructive) { session.resetSpaceOrder() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有分组回到自动顺序（按名称，“其他”在最后），置顶与拖动记录清除。")
        }
    }
}

private struct ThemePreview: View {
    let family: PalmhelmThemeFamily
    let dark: Bool
    let selected: Bool
    var body: some View {
        let t = PalmhelmThemeTokens.tokens(family)
        let sw = dark ? t.dark : t.light
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(family.label).font(.callout.weight(.semibold))
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: sw.accent)) }
            }
            Text("我的气泡").font(.caption).foregroundStyle(Color(hex: sw.emphasis)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(hex: sw.accentSoft), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 6) {
                Text("设").font(.caption2.weight(.bold)).foregroundStyle(Color(hex: sw.onAccent)).frame(width: 22, height: 22).background(Color(hex: sw.accent), in: RoundedRectangle(cornerRadius: 6))
                Image(systemName: "arrow.up").font(.caption.weight(.bold)).foregroundStyle(Color(hex: sw.onAccent)).frame(width: 22, height: 22).background(Color(hex: sw.accent), in: Circle())
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: sw.card), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: sw.accent), lineWidth: selected ? 2 : 0))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("主题 \(family.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 用量与隐私：参考价格（状态、自动检查开关、立即更新）与剪贴板图片缓存说明。
private struct UsagePrivacySettings: View {
    @Environment(MacSession.self) private var session
    @Environment(EngineSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        Form {
            // 账户额度与账户来源读的是本机的 Codex / Claude 配置，远程模式下不适用
            if settings.connectionMode == .local { Section("账户额度") {
                Toggle("Claude 套餐与补充额度（OAuth 实验性）", isOn: $settings.claudeQuotaEnabled)
                Text("默认关闭。开启并重启 Bridge 后，只读本机 Claude Code 登录钥匙串，首次读取可能弹出系统授权框。向 Anthropic 查询额度，不发送模型消息、不刷新过期令牌、不写回钥匙串；成功缓存 5 分钟，最短间隔 1 分钟。保留状态行的五小时与七天额度。补充 Fable 专属周额度与套餐；仅在返回有效数据时显示，不填入零值。")
                    .font(.caption).foregroundStyle(.secondary)
                if let status = session.visibleAccounts?.claudeExperimental {
                    if !status.enabled { Text("运行中的 Bridge：实验查询已关闭").font(.caption).foregroundStyle(.secondary) }
                    else if let failure = status.lastFailure {
                        Text("最近失败：\(QuotaCopy.claudeFailureText(failure.reason))（\(failure.at > 0 && failure.at <= 100_000_000_000_000 ? Date(timeIntervalSince1970: Double(failure.at) / 1000).shown(date: .omitted, time: .shortened) : String(localized: "时间未知"))）")
                            .font(.caption).foregroundStyle(PalmhelmTheme.warn)
                    } else { Text("运行中的 Bridge：实验查询已开启").font(.caption).foregroundStyle(.secondary) }
                } else { Text("连接 Bridge 并刷新后可查看查询诊断。").font(.caption).foregroundStyle(.secondary) }
                Button("刷新额度与诊断") { Task { await session.loadAccounts(refresh: true) } }
                    .disabled(session.link != .connected || session.accountsLoading)
                // 开关只在状态确定（已开 / 已关）时可操作；未知、加载中、旧 Bridge 都不当作「已关闭」。
                let st = session.claudeStatuslineState
                Toggle("Claude 额度（状态行）", isOn: Binding(
                    get: { st == .on },
                    set: { on in Task { await session.setClaudeStatusline(install: on) } }
                ))
                .disabled(!(st == .on || st == .off) || session.claudeStatuslineBusy || !session.canControl)
                switch st {
                case .unknown: Text("无法读取当前状态，请确认已连接 Bridge。").font(.caption).foregroundStyle(PalmhelmTheme.warn)
                case .loading: Text("正在读取当前状态…").font(.caption).foregroundStyle(.secondary)
                case .unsupported: Text("当前 Bridge 不支持此开关，请升级 Bridge。").font(.caption).foregroundStyle(PalmhelmTheme.warn)
                case .off, .on: EmptyView()
                }
                Text("开启后会把 ~/.claude/settings.json 的状态行换成 Palmhelm 的透传包装：原来的状态行照常显示，只记录五小时与每周两个窗口的已用百分比和重置时间。关闭即恢复原状态行。")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = session.claudeStatuslineNote { Text(note.text).font(.caption).foregroundStyle(.secondary) }
            }
            .task { await session.loadClaudeStatusline(); await session.loadAccounts() }
            Section("账户来源（多个 Codex / Claude 配置目录）") { AccountSourcesRows() }
            } // 本机模式的账户额度与账户来源

            Section("参考价格（models.dev）") { PricingSection() }
            Section("剪贴板图片缓存") {
                LabeledContent("位置") { Text(AttachmentCache.defaultDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Text("粘贴的截图等没有文件的图片会转成 PNG 存在这里（目录仅你自己可读写），启动时自动清理超过 7 天的缓存图片。拖入或粘贴的图片文件按原路径引用，不会被复制，也不会被清理。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { if session.visibleUsage == nil, session.link == .connected { await session.loadUsage(session.usageWindowIntent) } } // 价格状态来自用量响应：没有就拉一次（与用量页共用同一份状态）；按当前窗口意图拉，不抢用量页正在请求的窗口
        .formStyle(.grouped)
    }
}
