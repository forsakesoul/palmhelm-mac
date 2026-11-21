import SwiftUI
import AppKit

@main
struct PalmhelmMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Palmhelm", id: "main") {
            MainWindow()
                .environment(delegate.session)
                .environment(delegate.engine)
                .environment(delegate.settings)
                .environment(delegate.updates)
                .displayLanguage()
                .frame(minWidth: 820, minHeight: 680) // 1b：允许缩到 820，目标栏在 < 900 时自动收起
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .hostQuiet()
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button(delegate.notch.isExpanded ? String(localized: "收起刘海") : String(localized: "展开刘海")) { delegate.notch.toggleExpansion() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!NotchInteractionStore.shared.enabled) // 刘海关掉时快捷键不能把它叫出来
            }
        }

        Window(String(localized: "已归档会话"), id: "archived") {
            ArchivedThreadsWindow()
                .environment(delegate.session)
                .displayLanguage()
        }
        .windowResizability(.contentSize)
        .hostQuiet()

        Window(String(localized: "搜索会话"), id: "search") {
            SearchWindow()
                .environment(delegate.session)
                .displayLanguage()
        }
        .windowResizability(.contentSize)
        .hostQuiet()

        Window(String(localized: "配对新设备"), id: "pairing") {
            PairingWindow()
                .environment(delegate.session)
                .environment(delegate.engine)
                .displayLanguage()
        }
        .windowResizability(.contentSize)
        .hostQuiet()

        MenuBarExtra(isInserted: .constant(!RuntimeEnvironment.isTestHost)) {
            MenuBarMenu()
                .environment(delegate.session)
                .environment(delegate.engine)
                .environment(delegate.settings)
                .environment(delegate.updates)
                .displayLanguage()
        } label: {
            MenuBarLabel().environment(delegate.session).displayLanguage()
        }

        Settings {
            SettingsView()
                .environment(delegate.settings)
                .environment(delegate.engine)
                .environment(delegate.session)
                .environment(delegate.updates)
                .displayLanguage()
                .frame(width: 860, height: 620)
        }
    }
}

extension Scene {
    /// 测试宿主下窗口不自动打开、不恢复；生产保持 automatic。
    func hostQuiet() -> some Scene {
        let quiet = RuntimeEnvironment.isTestHost
        return defaultLaunchBehavior(quiet ? .suppressed : .automatic)
            .restorationBehavior(quiet ? .disabled : .automatic)
    }
}

/// 自动配对的重试判定（纯函数）：引擎运行中、端点就绪、退避已过，且
/// ① 该端点尚未配对成功（首次或换端点），或 ② 曾配对成功的同一端点上会话已变回未配对（重配缺口：如 forget 之后）。
enum PairingRetry {
    static func shouldAttempt(
        isRunning: Bool,
        endpoint: BridgeEngine.PalmhelmEndpoint?,
        paired: BridgeEngine.PalmhelmEndpoint?,
        link: MacSession.Link,
        now: Date,
        nextTry: Date
    ) -> Bool {
        guard isRunning, endpoint != nil, now >= nextTry else { return false }
        if endpoint != paired { return true }
        return link == .notPaired
    }
}

// 启动：随 App 启动 Bridge，运行后自动配对并打开刘海浮层；之后轮询端口文件保持同步。挂在 App 生命周期上，不挂在主窗口。
enum AppBoot {
    @MainActor
    static func run(settings: EngineSettings, engine: BridgeEngine, session: MacSession, notch: NotchController) async {
        // 单测宿主不启动 Bridge，不留孤儿子进程。测试包是在 didFinishLaunching 之后注入的，不能只看 XCTest 类是否已加载。
        if RuntimeEnvironment.isTestHost { return }
        AppEventLog.shared.mark(.launch)
        notch.attach(session: session)
        Task.detached(priority: .utility) { AttachmentCache.cleanup() } // 启动时清理本 App 位图缓存里超过 7 天的 <UUID>.png（只此一处，不扫旧 Bridge attachments）
        session.diagnostics = { [weak engine] stage in engine?.diagnose(stage) }
        // 开发/迁移用：-palmhelmImportEnv <path> 启动时从 .env 导入配置（不打印值），导入后照常启动。
        let args = ProcessInfo.processInfo.arguments
        // 钥匙串在后台线程读；超过 8 秒没回来就标记“无响应”（界面照常可用），回来后再按设置启动 Bridge。
        let loader = Task { @MainActor in
            if let line = await LegacyImport.importSecretsOnLaunch() { engine.diagnose(line) } // 先把旧钥匙串条目导入新服务名，再装载
            AppEventLog.shared.mark(.legacyImportDone)
            await settings.loadSecrets()
            AppEventLog.shared.mark(.secretsLoaded)
            await session.loadCredentials()
            AppEventLog.shared.mark(.credentialsLoaded)
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if !(settings.secretsLoaded && session.credentialsLoaded) {
                settings.keychainStalled = true
                AppEventLog.shared.mark(.keychainStalled, .stalled)
            }
        }
        await loader.value // 卡住就一直等：界面照常可用，状态栏显示“钥匙串无响应”
        watchdog.cancel()
        settings.keychainStalled = false
        if Task.isCancelled { AppEventLog.shared.mark(.credentialsLoaded, .cancelled); return } // 退出中：晚到的装载不是新的启动授权
        if let i = args.firstIndex(of: "-palmhelmImportEnv"), i + 1 < args.count { try? settings.importEnvFile(at: args[i + 1]) }
        await engine.bootOnLaunch() // 先接管上次退出后仍在后台运行的 Bridge（身份相符才接管；版本不同则替换），再按「随 App 启动」设置自动启动
        // 截图/走查用：-palmhelmPage stats 打开统计页；-palmhelmShowPairing 打开配对窗口（主窗口 onAppear 处理）；-palmhelmShowSettings 打开设置窗口。
        if args.contains("-palmhelmShowSettings") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        var paired: BridgeEngine.PalmhelmEndpoint? // 只记成功建立会话的端点
        var nextTry = Date.distantPast // 失败后退避 10 秒再重试，避免每 2 秒重新签码
        while !Task.isCancelled {
            if engine.isRunning {
                if engine.portFile == nil { engine.readPortFile() }
                if PairingRetry.shouldAttempt(isRunning: true, endpoint: engine.selfEndpoint, paired: paired, link: session.link, now: Date(), nextTry: nextTry), let ep = engine.selfEndpoint {
                    engine.diagnose("AppBoot 进入配对分支")
                    if ep == paired { paired = nil } // 同端点但会话已未配对：清空记录，按同一退避重新配对
                    await session.ensurePaired(engine: engine)
                    if session.link == .connected { paired = ep } else { nextTry = Date().addingTimeInterval(10) }
                } else if paired != nil, case .offline = session.link, Date() >= nextTry {
                    await session.refresh() // 重连后同步失败等离线态：每 10 秒重试一次
                    nextTry = Date().addingTimeInterval(10)
                }
            } else if paired != nil {
                paired = nil
                session.disconnect(reason: LText(String(localized: "Bridge 已停止")))
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { break }
        }
    }
}

struct MenuBarLabel: View {
    @Environment(MacSession.self) private var session
    var body: some View {
        let waiting = session.pendingApprovals.count
        let running = session.runningCommands.count
        HStack(spacing: 3) {
            if waiting > 0 { Image(systemName: "bell.badge.fill") } else { Image("MenuGlyph").renderingMode(.template) }
            if waiting > 0 { Text("\(waiting)") } else if running > 0 { Text("\(running)") }
        }
    }
}

/// 菜单栏第一行计数：整句交给 Catalog（不拼接已是 String 的中文，否则 Text 按 verbatim 显示、选 English 也不会翻译）。
enum MenuBarCountLine {
    static func text(pending: Int, running: Int, unresolved: Int, pendingSync: Bool) -> String {
        // 分隔符放在代码里：Catalog 值首尾空白在编译后不一定保留，不能让译文带前导空格。
        var parts = [String(localized: "待答 \(pending) · 在途 \(running)")]
        if unresolved > 0 { parts.append(String(localized: "结果未知 \(unresolved)")) }
        if pendingSync { parts.append(String(localized: "状态待同步")) }
        return parts.joined(separator: " · ")
    }
}

struct MenuBarMenu: View {
    @Environment(MacSession.self) private var session
    @Environment(BridgeEngine.self) private var engine
    @Environment(EngineSettings.self) private var settings
    @Environment(UpdateChecker.self) private var updates: UpdateChecker? // 可选：只读宿主（视图测试）不必注入
    private var credentialsPending: Bool { !settings.secretsLoaded || !session.credentialsLoaded }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Bridge · \(credentialsPending ? ConnectionPhase.credentialsWaitText(stalled: settings.keychainStalled) : engine.displayStatus) · \(engine.mode)")
        Text(MenuBarCountLine.text(pending: session.pendingApprovals.count, running: session.runningCommands.count, unresolved: session.unresolvedCommandCount, pendingSync: session.activityPendingSync))
        Divider()
        if let r = updates?.banner { Button("有新版本 \(r.title)…") { UpdateLinks.open(r.releaseURL) } }
        Button("打开 Palmhelm") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        @Bindable var notch = NotchInteractionStore.shared
        Toggle("在刘海显示", isOn: $notch.enabled) // 与设置 › 外观 › 刘海的开关是同一个值，方便临时让出刘海
        Button("配对新设备…") { openWindow(id: "pairing"); NSApp.activate(ignoringOtherApps: true) }.disabled(!engine.isRunning)
        Divider()
        switch engine.status {
        case .running:
            Button("停止 Bridge") { Task { await engine.stop() } }
            Button("重启 Bridge") { Task { await engine.restart() } }
        case .starting, .stopping:
            Text(engine.status.label + "…")
        case .stopped, .failed:
            Button("启动 Bridge") { engine.start() }.disabled(!engine.settings.secretsLoaded)
        }
        Divider()
        Button("退出 Palmhelm") { NSApp.terminate(nil) }
    }
}
