import XCTest
@testable import PalmhelmMac

// h8 引擎接线（A1-049 H1–H3）：用假子进程 / 可控睡眠与时钟驱动真实的 BridgeEngine，不真启动 Bridge、不读钥匙串、不起系统网络监视。

@MainActor
private final class FakeChild: EngineChild {
    let launch: EngineLaunch
    var isRunning = true
    var terminateCount = 0
    var killCount = 0
    /// true：收到 SIGTERM 后不退出（模拟停机慢），由测试用 exit() 放行。
    var ignoresTerm = false
    init(_ l: EngineLaunch) { launch = l }
    func terminate() {
        terminateCount += 1
        if !ignoresTerm { exit(0) }
    }
    func kill() { killCount += 1; exit(9) }
    func exit(_ code: Int32) {
        isRunning = false
        launch.onExit(code)
    }
    func say(_ line: String) { launch.onStdout(Data((line + "\n").utf8)) }
}

/// 线程安全的小盒子：interfaceProvider 是 @Sendable，不能直接捕获主线程上的对象。
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

@MainActor
private final class Rig {
    let settings: EngineSettings
    let engine: BridgeEngine
    var children: [FakeChild] = []
    var clock = Date(timeIntervalSince1970: 1_000_000)
    private let nicBox = Box([NetInterface(name: "en0", ip: "192.168.1.9")])
    var nics: [NetInterface] { get { nicBox.value } set { nicBox.value = newValue } }
    /// 重启里 stop 之后固定的 300ms 等待：为 true 时挂起，直到 releaseDelay()
    var holdDelay = false
    /// stop 轮询（200ms）：为 true 时挂起，直到 releaseStopPoll()
    var holdStopPoll = false
    private var delayWaiters: [CheckedContinuation<Void, Never>] = []
    private var pollWaiters: [CheckedContinuation<Void, Never>] = []
    private let suite: String

    init(lan: Bool = true, tailscale: Bool = false) {
        suite = "palmhelm.test.wiring.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        settings = EngineSettings(defaults: d, secretsReady: true)
        settings.binaryPath = "/fake/palmhelm-bridge" // 非空即采用，不去找 App 包内二进制
        settings.dataDir = NSTemporaryDirectory() + "palmhelm-wiring-\(UUID().uuidString)"
        settings.tls = true
        settings.listenLan = lan
        settings.listenTailscale = tailscale
        engine = BridgeEngine(settings: settings)
        engine.watchNetwork = false // 不起真实的 NWPathMonitor：用例自己驱动 evaluateListen()
        let box = nicBox
        settings.interfaceProvider = { box.value }
        engine.now = { [unowned self] in self.clock }
        engine.launcher = { [unowned self] l in
            let c = FakeChild(l)
            self.children.append(c)
            return c
        }
        engine.sleep = { [unowned self] d in await self.sleep(d) }
    }
    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    private func sleep(_ d: Duration) async {
        if d == .milliseconds(300), holdDelay {
            await withCheckedContinuation { delayWaiters.append($0) }
        } else if d == .milliseconds(300) {
            for _ in 0..<20 { await Task.yield() } // 生产里这 300ms 让旧进程的退出回调先跑完：这里用让出主线程模拟
        } else if d == .milliseconds(200) || d == .milliseconds(100) {
            if holdStopPoll { await withCheckedContinuation { pollWaiters.append($0) } }
        } else {
            try? await Task.sleep(for: .seconds(3600)) // 防抖 / 限频的等待定时器：测试里不会自己到点（由用例直接再调 evaluateListen）
        }
    }
    func releaseDelay() { holdDelay = false; delayWaiters.forEach { $0.resume() }; delayWaiters = [] }
    func releaseStopPoll() { holdStopPoll = false; pollWaiters.forEach { $0.resume() }; pollWaiters = [] }

    /// 让主线程上已排队的 Task 都跑完（子进程回调、重启任务）。
    func settle() async { for _ in 0..<40 { await Task.yield() } }

    /// 起一个“运行中”的 Bridge：启动并让它写出 bridge_started。
    func boot() async {
        engine.start()
        await settle()
        children[0].say("{\"msg\":\"bridge_started\"}")
        await settle()
    }

    /// 让地址变化走完防抖与限频，触发网络自动重启（LAN 地址 → 10.9.9.9）。
    func triggerNetworkRestart() async {
        decideNetworkRestart()
        await settle()
    }

    /// 同上但不 settle：重启任务只是排了队、还没跑到第一行（H2-R 的窗口）。
    func decideNetworkRestart() {
        nics = [NetInterface(name: "en0", ip: "10.9.9.9")]
        clock = clock.addingTimeInterval(31) // 过了启动后的 30 秒限频窗口
        engine.evaluateListen() // 记下“变化”，等防抖
        clock = clock.addingTimeInterval(4) // 过了 3 秒防抖
        engine.evaluateListen() // 决策 .restart → 排入重启任务
    }
}

@MainActor
final class EngineWiringTests: XCTestCase {
    func testFakeLauncherReceivesTheMacParentPID() async {
        let rig = Rig(lan: false)
        await rig.boot()
        XCTAssertEqual(rig.children.count, 1)
        XCTAssertEqual(rig.children[0].launch.environment["BRIDGE_PARENT_PID"], String(ProcessInfo.processInfo.processIdentifier))
    }

    // MARK: H1 — 只改监听开关也必须出现「需重启」

    func testTogglingLanOrTailscaleMakesRestartPending() async {
        let rig = Rig(lan: true, tailscale: false)
        await rig.boot()
        XCTAssertEqual(rig.engine.status, .running)
        XCTAssertFalse(rig.engine.pendingRestart, "刚启动：没有未生效的更改")
        rig.settings.listenLan = false // 关掉局域网
        XCTAssertTrue(rig.engine.pendingRestart, "关 LAN：进程仍按旧意图监听，必须提示需要重启")
        rig.settings.listenLan = true
        XCTAssertFalse(rig.engine.pendingRestart, "改回去：不再需要重启")
        rig.settings.listenTailscale = true // 开 Tailscale：本机此刻没有 100.x 地址，解析出来的 bind 不变，环境变量不变
        XCTAssertTrue(rig.engine.pendingRestart, "开 TS：即使解析到的监听地址没变，意图变了也要提示")
        rig.settings.listenTailscale = false
        XCTAssertFalse(rig.engine.pendingRestart)
    }

    func testStartedWithTailscaleIntentThenTurnedOffIsPending() async {
        // 起时勾了 Tailscale 但没有 100.x 地址（解析不到、bind 里没有它）：关掉它，意图变了就要提示
        let rig = Rig(lan: false, tailscale: true)
        await rig.boot()
        XCTAssertFalse(rig.engine.pendingRestart)
        XCTAssertTrue(rig.engine.activeListen?.tailscaleUnavailable == true)
        rig.settings.listenTailscale = false
        XCTAssertTrue(rig.engine.pendingRestart)
    }

    // D6：价格自动检查开关只经 pendingRestart 提示（不接网络重启状态机）；改回原值即不再待重启
    func testTogglingPricingAutoUpdateMakesRestartPendingWithoutTouchingNetworkRestart() async {
        let rig = Rig()
        await rig.boot()
        XCTAssertFalse(rig.engine.pendingRestart)
        rig.settings.pricingAutoUpdate = false
        XCTAssertTrue(rig.engine.pendingRestart)
        XCTAssertFalse(rig.engine.networkRestarting)
        XCTAssertEqual(rig.children.count, 1, "不会自己重启")
        rig.settings.pricingAutoUpdate = true
        XCTAssertFalse(rig.engine.pendingRestart)
    }

    func testIpChangeAloneIsNotPendingAndOtherSettingsStillAre() async {
        let rig = Rig(lan: true)
        await rig.boot()
        rig.nics = [NetInterface(name: "en0", ip: "10.9.9.9")] // 只是换了 IP（网络变化由监测自动处理）
        XCTAssertFalse(rig.engine.pendingRestart, "网络变化本身不算「设置有更改」，也不能自己和自己比出差异")
        let originalPort = rig.settings.port
        rig.settings.port = 50000 // 对照：其余环境变量仍按冻结地址比较
        XCTAssertTrue(rig.engine.pendingRestart)
        rig.settings.port = originalPort
        XCTAssertFalse(rig.engine.pendingRestart)
    }

    // MARK: H2 — 网络自动重启可被用户停止取消

    func testNetworkRestartProceedsWhenNobodyIntervenes() async {
        let rig = Rig()
        await rig.boot()
        await rig.triggerNetworkRestart()
        XCTAssertEqual(rig.children[0].terminateCount, 1, "重启内部的 stop 没有取消重启自己")
        XCTAssertEqual(rig.children.count, 2, "对照：没人干预 → 停完旧进程后启动了新进程")
        XCTAssertEqual(rig.engine.activeListen?.lan, "10.9.9.9", "新进程按新地址冻结")
    }

    func testUserStopDuringTheDelayPreventsTheAutoStart() async {
        let rig = Rig()
        await rig.boot()
        rig.holdDelay = true // 停在 stop 之后的 300ms 等待里
        await rig.triggerNetworkRestart()
        XCTAssertEqual(rig.children.count, 1, "还没启动新进程")
        XCTAssertTrue(rig.engine.networkRestarting, "旧进程是为重启而退出：状态区保持“正在重新监听…”")
        await rig.engine.stop() // 用户停止
        rig.releaseDelay()
        await rig.settle()
        XCTAssertEqual(rig.children.count, 1, "用户停止之后，到点的自动重启不得再 start")
        XCTAssertNotEqual(rig.engine.status, .starting)
        XCTAssertNotEqual(rig.engine.status, .running)
        XCTAssertFalse(rig.engine.networkRestarting)
        XCTAssertFalse(rig.engine.childRunning)
    }

    func testUserStopWhileStillStoppingTheOldProcessPreventsTheAutoStart() async {
        let rig = Rig()
        await rig.boot()
        rig.children[0].ignoresTerm = true // 旧进程停得慢
        rig.holdStopPoll = true
        await rig.triggerNetworkRestart()
        XCTAssertEqual(rig.children[0].terminateCount, 1)
        XCTAssertEqual(rig.children.count, 1)
        rig.engine.requestStop() // 退出 / 菜单的停止：同样作废进行中的自动重启
        rig.children[0].exit(0)
        rig.releaseStopPoll()
        await rig.settle()
        rig.releaseDelay()
        await rig.settle()
        XCTAssertEqual(rig.children.count, 1, "停机阶段被用户停止：不再 start")
        XCTAssertFalse(rig.engine.networkRestarting)
    }

    // H2-R：自动重启已排队、Task 还没跑时用户停止 / 启动 / 手动重启，排队的那次不能再自增拿到新代次。
    func testStopRightAfterTheAutoRestartIsQueuedKeepsItFromRunning() async {
        let rig = Rig()
        await rig.boot()
        rig.decideNetworkRestart() // 同一 MainActor turn：决定重启……
        rig.engine.requestStop() // ……立刻被用户停止
        await rig.settle()
        XCTAssertEqual(rig.children.count, 1, "排队中的自动重启被作废：不新增 child")
        XCTAssertEqual(rig.children[0].terminateCount, 1, "只有用户那次停止发了 SIGTERM")
        XCTAssertFalse(rig.engine.networkRestarting)
        XCTAssertFalse(rig.engine.childRunning)
    }

    func testAsyncStopRightAfterTheAutoRestartIsQueuedKeepsItFromRunning() async {
        let rig = Rig()
        await rig.boot()
        rig.decideNetworkRestart()
        await rig.engine.stop()
        await rig.settle()
        XCTAssertEqual(rig.children.count, 1)
        XCTAssertFalse(rig.engine.childRunning)
    }

    func testStartRightAfterTheAutoRestartIsQueuedKeepsItFromRunning() async {
        let rig = Rig()
        await rig.boot()
        rig.decideNetworkRestart()
        rig.engine.start() // 用户明确要启动（已在运行：保持现状），同样接管意图
        await rig.settle()
        XCTAssertEqual(rig.children.count, 1, "排队中的自动重启被作废：不重启运行中的进程")
        XCTAssertEqual(rig.children[0].terminateCount, 0)
        XCTAssertTrue(rig.engine.childRunning)
    }

    func testQueuedAutoRestartStillRunsWhenNobodyIntervenesWithoutSettle() async {
        let rig = Rig()
        await rig.boot()
        rig.decideNetworkRestart()
        await rig.settle()
        XCTAssertEqual(rig.children.count, 2, "对照：没人干预时排队的重启照常执行")
        XCTAssertEqual(rig.children[0].terminateCount, 1)
    }

    func testNewerAutoDecisionSupersedesTheQueuedOne() async {
        let rig = Rig()
        await rig.boot()
        rig.decideNetworkRestart()
        Task { await rig.engine.restart() } // 意图更新：手动重启在排队的自动重启之后登记
        await rig.settle()
        XCTAssertEqual(rig.children.count, 2, "只起一个新进程")
    }

    // 旧 stop 的等待者只作用于它捕获的 child：旧进程已退出、用户又启动了新 child，释放旧 stop 不能杀新 child。
    func testStaleStopWaiterDoesNotKillANewerChild() async {
        let rig = Rig()
        await rig.boot()
        rig.children[0].ignoresTerm = true
        rig.holdStopPoll = true
        let stopping = Task { await rig.engine.stop() } // 旧 stop 挂起在轮询里
        await rig.settle()
        XCTAssertEqual(rig.children[0].terminateCount, 1)
        rig.children[0].exit(0) // 旧进程退出
        await rig.settle() // 退出回调落地
        rig.engine.start() // 用户启动新 child
        await rig.settle()
        XCTAssertEqual(rig.children.count, 2)
        rig.releaseStopPoll() // 释放旧 stop
        await stopping.value
        XCTAssertEqual(rig.children[1].killCount, 0, "新 child 不被旧 stop 杀掉")
        XCTAssertTrue(rig.children[1].isRunning)
        XCTAssertEqual(rig.children[0].killCount, 0)
    }

    func testUserStartDuringTheDelayWinsOverTheAutoStart() async {
        let rig = Rig()
        await rig.boot()
        rig.holdDelay = true
        await rig.triggerNetworkRestart()
        XCTAssertEqual(rig.children.count, 1)
        rig.engine.start() // 用户明确点了“启动”
        await rig.settle()
        XCTAssertEqual(rig.children.count, 2, "用户的启动生效")
        XCTAssertFalse(rig.engine.networkRestarting, "用户的启动接管：不再显示“正在重新监听…”")
        rig.releaseDelay()
        await rig.settle()
        XCTAssertEqual(rig.children.count, 2, "旧的自动重启到点后不再接管（不会再起第三个）")
    }

    func testAutoRestartDoesNotResurrectAfterUserStartedProcessCrashed() async {
        let rig = Rig()
        await rig.boot()
        rig.holdDelay = true
        await rig.triggerNetworkRestart() // 自动重启停在 300ms
        rig.engine.start() // 用户启动了新进程……
        await rig.settle()
        rig.children[1].exit(1) // ……它马上崩了（进程已空，没有 process == nil 的守卫可兜）
        await rig.settle()
        rig.releaseDelay()
        await rig.settle()
        XCTAssertEqual(rig.children.count, 2, "旧的自动重启已被用户的启动作废：不会在进程崩溃后再复活出第三个")
        XCTAssertEqual(rig.engine.status, .failed("退出码 1"))
    }

    func testNewerRestartSupersedesAnOlderOne() async {
        let rig = Rig()
        await rig.boot()
        rig.holdDelay = true
        await rig.triggerNetworkRestart() // 自动重启 A 停在 300ms
        Task { await rig.engine.restart() } // 用户手动重启 B 取代它
        await rig.settle()
        rig.releaseDelay()
        await rig.settle()
        XCTAssertLessThanOrEqual(rig.children.count, 2, "两次重启不会各起一个进程")
        XCTAssertEqual(rig.children.count, 2)
    }

    // MARK: H3 — 新进程直接退出时清掉「正在重新监听…」

    func testNewProcessExitingWithoutStructuredLogsClearsNetworkRestarting() async {
        let rig = Rig()
        await rig.boot()
        await rig.triggerNetworkRestart()
        XCTAssertEqual(rig.children.count, 2)
        XCTAssertTrue(rig.engine.networkRestarting, "新进程已启动但还没有任何启动结果：保持重启中")
        rig.children[1].exit(1) // 没写 bridge_started / bridge_start_failed 就退出
        await rig.settle()
        XCTAssertFalse(rig.engine.networkRestarting, "新进程自己失败退出：不能让“正在重新监听…”永久覆盖真实状态")
        XCTAssertEqual(rig.engine.status, .failed("退出码 1"))
        XCTAssertNil(rig.engine.activeListen)
        XCTAssertFalse(rig.engine.pendingRestart)
    }

    func testRestartMarkerSurvivesTheOldProcessExitButClearsOnStartedOrFailedLines() async {
        let rig = Rig()
        await rig.boot()
        rig.holdDelay = true
        await rig.triggerNetworkRestart()
        XCTAssertTrue(rig.engine.networkRestarting, "为重启而退出的旧进程不清标记")
        rig.releaseDelay()
        await rig.settle()
        XCTAssertEqual(rig.children.count, 2)
        XCTAssertTrue(rig.engine.networkRestarting)
        rig.children[1].say("{\"msg\":\"bridge_started\"}")
        await rig.settle()
        XCTAssertFalse(rig.engine.networkRestarting)
        XCTAssertEqual(rig.engine.status, .running)
    }

    func testNewProcessReportingStartFailureClearsTheMarker() async {
        let rig = Rig()
        await rig.boot()
        await rig.triggerNetworkRestart()
        rig.children[1].say("{\"msg\":\"bridge_start_failed\",\"reason\":\"config_invalid\"}")
        await rig.settle()
        XCTAssertFalse(rig.engine.networkRestarting)
        XCTAssertEqual(rig.engine.status, .failed("config_invalid"))
    }

    func testManualStartAfterAFailedNetworkRestartWorks() async {
        let rig = Rig()
        await rig.boot()
        await rig.triggerNetworkRestart()
        rig.children[1].exit(1)
        await rig.settle()
        rig.engine.start()
        await rig.settle()
        XCTAssertEqual(rig.children.count, 3)
        XCTAssertEqual(rig.engine.status, .starting)
        XCTAssertFalse(rig.engine.networkRestarting)
    }
}
