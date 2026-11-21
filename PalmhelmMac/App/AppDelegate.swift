import AppKit
import PalmhelmKit

// App 级对象的唯一持有者：SwiftUI 可能多次构造 App 结构体，引擎/会话放在这里保证只有一份。
// 退出：只要本实例的子进程还活着（启动中/运行中/停止中都算），就先停掉它再退出；SIGTERM 最多等 12 秒，之后 SIGKILL 并等到进程确实消失。
// terminateLater 之后 AppKit 跑的是模态运行循环，Swift 并发任务不一定被调度；用加入 common modes 的定时器轮询。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 声明顺序有意义：偏好导入必须早于 EngineSettings 与 MacSession 构造（它们在构造时读取偏好）。
    let settings: EngineSettings = { LegacyImport.importDefaultsOnLaunch(); DisplayLanguage.shared.attach(defaults: AppDefaults.standard); return EngineSettings() }()
    lazy var engine = BridgeEngine(settings: settings)
    let session = MacSession()
    let notch = NotchController()
    let updates = UpdateChecker.production()
    private var updateTask: Task<Void, Never>?
    private let languageRefresher = LanguageRefresher()
    private var bootTask: Task<Void, Never>?
    private var quitTimer: Timer?
    private var restartWaitTimer: Timer?
    private var deadline = Date()
    /// 退出确认的接缝：生产用原生 NSAlert。
    var quitConfirmer: any QuitConfirming = QuitAlertConfirmer()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 测试宿主不进 Dock；须早于 didFinishLaunching 设置。生产不调用。
        if RuntimeEnvironment.isTestHost { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = PalmhelmThemeStore.shared.appearance.nsAppearance // 按本机保存的外观；之后由 store 即时更新，不重建任何窗口
        updateTask = Task { @MainActor [updates] in await updates.runLoop() } // 非发行构建 / 测试宿主 networkEnabled 为 false，直接返回
        bootTask = Task { @MainActor in await AppBoot.run(settings: settings, engine: engine, session: session, notch: notch) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 确认与「后台运行」判断在 QuitCoordinator：系统注销 / 脚本 quit 不弹；后台运行的 Bridge 不停
        let coordinator = QuitCoordinator(settings: settings, engine: engine, confirmer: quitConfirmer)
        switch coordinator.decide(event: QuitEventInfo.current(probe: SystemProcessProbe())) {
        case .cancel: return .terminateCancel
        case .quitNow: return .terminateNow
        case .stopBridgeThenQuit: return beginStopThenQuit()
        case .deferUntilRestartDone:
            waitForRestartThenQuit()
            return .terminateLater
        }
    }

    private func beginStopThenQuit() -> NSApplication.TerminateReply {
        bootTask?.cancel()
        engine.requestStop()
        deadline = Date().addingTimeInterval(12)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        quitTimer = timer
        return .terminateLater
    }

    /// 后台重启事务（停旧、起新）完成后再退出（R5）。完成后不再弹窗，按当前状态决定：后台 Bridge 直接退出，否则照旧先停。
    private func waitForRestartThenQuit() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.engine.backgroundRestartInFlight else { return }
                self.restartWaitTimer?.invalidate()
                self.restartWaitTimer = nil
                let coordinator = QuitCoordinator(settings: self.settings, engine: self.engine, confirmer: self.quitConfirmer)
                switch coordinator.afterConfirmation() {
                case .stopBridgeThenQuit: _ = self.beginStopThenQuit()
                default: self.finishQuit()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        restartWaitTimer = timer
    }

    private func quitTick() {
        if !engine.childRunning { return finishQuit() }
        if Date() > deadline { engine.forceKill(); deadline = Date().addingTimeInterval(5) } // 强杀后继续等它真的消失
    }

    private func finishQuit() {
        quitTimer?.invalidate()
        quitTimer = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false } // 关窗不退出：刘海与菜单栏常驻
}
