import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #138 切片 1 修复轮（h2）：远程模式核心逻辑。假子进程、假管理口、门控替身驱动真实的引擎、会话与切换器，
// 不起真实 Bridge、不碰真实钥匙串或偏好。

@MainActor
private final class RMChild: EngineChild {
    let launch: EngineLaunch
    var isRunning = true
    /// true：SIGTERM 与 SIGKILL 都不让它退出（模拟停机失败）。
    var stubborn = false
    init(_ l: EngineLaunch) { launch = l }
    var pid: Int32? { nil }
    var lastKillOutcome: ChildKillOutcome? { nil }
    func terminate() { if !stubborn { exitNow(0) } }
    func kill() { if !stubborn { exitNow(9) } }
    func exitNow(_ code: Int32) {
        isRunning = false
        launch.onExit(code)
    }
}

private final class RMBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

private actor RMGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// 假本机管理口：记录调用；gate 让 issuePairCode 挂起，devicesGate 让设备列表挂起。
private final class RMHook: HookAdmin, @unchecked Sendable {
    let gate: RMGate?
    let devicesGate: RMGate?
    let devicesList: [HookClient.Device]
    let entered = RMBox(0)
    let devicesEntered = RMBox(0)
    let permissionSets = RMBox(0)
    let removed = RMBox<[String]>([])
    init(gate: RMGate? = nil, devicesGate: RMGate? = nil, devices: [HookClient.Device] = []) {
        self.gate = gate
        self.devicesGate = devicesGate
        devicesList = devices
    }
    func issuePairCode() async throws -> HookClient.PairCode {
        entered.value += 1
        if let gate { await gate.wait() }
        return HookClient.PairCode(code: "123456", expiresT: 0)
    }
    func setPermission(deviceId: String, _ permission: DevicePermission) async throws { permissionSets.value += 1 }
    func devices(all: Bool) async throws -> [HookClient.Device] {
        devicesEntered.value += 1
        if let devicesGate { await devicesGate.wait() }
        return devicesList
    }
    func remove(deviceId: String) async throws { removed.value.append(deviceId) }
}

private func decodePair(_ json: String) -> PairResponse { try! JSONDecoder().decode(PairResponse.self, from: Data(json.utf8)) }
private func rmState() -> BridgeState {
    try! JSONDecoder().decode(BridgeState.self, from: Data(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#.utf8))
}
private func rmDevice(_ id: String, name: String) -> HookClient.Device {
    try! JSONDecoder().decode(HookClient.Device.self, from: Data(#"{"id":"\#(id)","name":"\#(name)","pairedT":1,"lastSeenT":null,"paused":false,"revoked":false}"#.utf8))
}
private func rmApproval(_ id: String) -> ApprovalView {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    return ApprovalView(id: id, status: "pending", targetLabel: "P", attribution: "exact", toolName: "Bash", summary: "ls", truncated: false, createdT: now - 1000, expiresT: now + 600_000)
}

private func isDone(_ o: ModeSwitchOutcome) -> Bool { if case .done = o { return true }; return false }
private func isNote(_ o: ModeSwitchOutcome) -> Bool { if case .doneWithNote = o { return true }; return false }
private func isFailed(_ o: ModeSwitchOutcome) -> Bool { if case .failed = o { return true }; return false }

private let spkiA = Data(repeating: 7, count: 32).base64EncodedString()
private let spkiB = Data(repeating: 9, count: 32).base64EncodedString()
private let remoteEndpoint = BridgeEndpoint(host: "mac.example.ts.net", port: 47821, transport: .https, spkiSha256: spkiA)

@MainActor
private struct Rig {
    let settings: EngineSettings
    let engine: BridgeEngine
    let session: MacSession
    let children: RMBox<[RMChild]>
    let stubbornNext: RMBox<Bool>
    let stateCalls = RMBox(0)

    init() {
        let suite = "palmhelm.test.remote.\(UUID().uuidString)"
        settings = EngineSettings(defaults: UserDefaults(suiteName: suite)!, secretsReady: true)
        settings.binaryPath = "/fake/palmhelm-bridge"
        settings.dataDir = NSTemporaryDirectory() + "palmhelm-remote-\(UUID().uuidString)"
        settings.listenLan = false
        settings.listenTailscale = false
        settings.interfaceProvider = { [] }
        engine = BridgeEngine(settings: settings)
        engine.watchNetwork = false
        engine.sleep = { _ in }
        children = RMBox([])
        stubbornNext = RMBox(false)
        let kids = children, next = stubbornNext
        engine.launcher = { l in
            let c = RMChild(l)
            c.stubborn = next.value
            kids.value.append(c)
            return c
        }
        session = MacSession()
        session.streamDisabled = true
        session.endpoint = nil
        session.connectionModeProvider = { [settings] in settings.connectionMode }
        let calls = stateCalls
        session.stateOverride = { () async throws -> BridgeState in calls.value += 1; return rmState() }
    }

    /// 载入凭据（测试宿主下是内存钥匙串）。
    func loadToken(_ token: String = "local-token") async {
        KeychainStore.save(token, account: KeychainStore.tokenAccount)
        await session.loadCredentials(mode: settings.connectionMode)
    }

    /// 切换器：默认已完成启动（bootReady），与生产 AppBoot 置位后的状态一致。
    func switcher(ready: Bool = true) -> ConnectionModeSwitcher {
        let sw = ConnectionModeSwitcher(settings: settings, engine: engine, session: session, notch: nil)
        sw.bootReady = ready
        return sw
    }
}

@MainActor
final class RemoteModeTests: XCTestCase {
    override func setUp() {
        KeychainStore.delete(account: KeychainStore.tokenAccount)
        KeychainStore.clearEndpoint()
    }
    override func tearDown() {
        KeychainStore.delete(account: KeychainStore.tokenAccount)
        KeychainStore.clearEndpoint()
    }

    // MARK: 1 引擎守卫（I1）

    func testLocalStartStillLaunchesTheBridge() {
        let r = Rig()
        r.engine.start()
        XCTAssertEqual(r.children.value.count, 1, "本机模式照常启动（对照用例）")
    }

    func testRemoteModeNeverStartsALocalBridgeOnAnyPath() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        r.engine.start()
        await r.engine.restart()
        await r.engine.bootOnLaunch()
        XCTAssertEqual(r.children.value.count, 0, "start / restart / 启动序列在远程模式下都不起进程")
        XCTAssertFalse(r.engine.childRunning)
    }

    func testStartBlockedFlagStopsEveryPathToo() {
        let r = Rig()
        r.engine.startBlocked = true
        r.engine.start()
        XCTAssertEqual(r.children.value.count, 0, "切换期间的 startBlocked 也拦截启动")
        r.engine.startBlocked = false
        r.engine.start()
        XCTAssertEqual(r.children.value.count, 1)
    }

    /// 远程模式下排队中的网络自动重启：旧进程被停掉后，startProcess 守卫不再拉起新进程。
    func testRemoteModeQueuedNetworkRestartStartsNothing() async throws {
        let rig = try TakeoverRig()
        rig.settings.listenLan = true
        rig.settings.tls = true
        rig.engine.start() // 本机进程先在运行（模式绕过切换器直接改成远程，模拟竞争窗口）
        XCTAssertEqual(rig.launched.count, 1)
        rig.settings.connectionMode = .remote
        rig.nicBox.value = [NetInterface(name: "en0", ip: "192.168.1.9")]
        rig.clock = rig.clock.addingTimeInterval(31)
        rig.engine.evaluateListen()
        rig.clock = rig.clock.addingTimeInterval(4)
        rig.engine.evaluateListen() // 决策 .restart：排队的自动重启
        XCTAssertTrue(rig.engine.logs.contains { $0.contains("网络地址变化") }, "前置：确实排队了自动重启 logs=\(rig.engine.logs.suffix(5))")
        // 假进程不会因 SIGTERM 自行退出：等重启发出 terminate，再模拟它退出
        for _ in 0..<400 where rig.launched[0].terminateCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(rig.launched[0].terminateCount, 1, "重启已停掉旧进程")
        rig.launched[0].isRunning = false
        rig.launched[0].launch.onExit(0)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(rig.engine.childRunning, "旧进程退出后，远程模式下不再拉起新进程")
        XCTAssertEqual(rig.launched.count, 1, "远程模式下排队的网络重启不拉起新进程")
    }

    /// 远程模式下的接管替换（decision == .replace）：停掉旧版本后不按新版本启动。
    func testRemoteModeTakeoverReplaceStartsNothing() async throws {
        let rig = try TakeoverRig()
        rig.settings.connectionMode = .remote
        try rig.seedRunningBridge(digest: "stale-digest")
        await rig.engine.takeOverRunningBridge()
        XCTAssertTrue(rig.launched.isEmpty, "替换路径的重启在远程模式下不起进程")
    }

    // MARK: 2 切换器（R5 / R6）

    func testLocalToRemoteStopsTheLocalBridgeThenForgetsAndPersistsRemote() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http)
        r.engine.start()
        let out = await r.switcher().switchTo(.remote)
        XCTAssertTrue(isDone(out))
        XCTAssertEqual(r.settings.connectionMode, .remote)
        XCTAssertFalse(r.engine.childRunning, "本机子进程已确认退出")
        XCTAssertFalse(r.session.isPaired, "旧连接的令牌与端点已清掉")
        XCTAssertFalse(r.engine.startBlocked)
    }

    func testStopFailureKeepsLocalModeAndCredentials() async {
        let r = Rig()
        await r.loadToken("keep-me")
        r.session.endpoint = BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http)
        r.stubbornNext.value = true
        r.engine.start()
        let out = await r.switcher().switchTo(.remote)
        XCTAssertTrue(isFailed(out), "停机未确认：失败")
        XCTAssertEqual(r.settings.connectionMode, .local, "模式不落盘")
        XCTAssertTrue(r.session.isPaired, "凭据与端点保持不动")
        XCTAssertTrue(r.engine.childRunning, "未确认退出的进程仍被跟踪")
        XCTAssertFalse(r.engine.startBlocked, "失败后解除启动拦截")
    }

    func testRemoteToLocalCallsDeleteSelfAndStartsLocalBridge() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        let deleted = RMBox(0)
        let sw = r.switcher()
        sw.deleteSelfOverride = { _ in deleted.value += 1 }
        let out = await sw.switchTo(.local)
        XCTAssertTrue(isDone(out))
        XCTAssertEqual(deleted.value, 1, "远程自撤被调用")
        XCTAssertEqual(r.settings.connectionMode, .local)
        XCTAssertFalse(r.session.isPaired, "远程令牌与端点已清掉")
        XCTAssertEqual(r.children.value.count, 1, "autoStart 且钥匙串就绪：启动本机 Bridge")
    }

    func testDeleteSelfFailureStillSwitchesAndReturnsNote() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        let sw = r.switcher()
        sw.deleteSelfOverride = { _ in throw URLError(.cannotConnectToHost) }
        let out = await sw.switchTo(.local)
        XCTAssertTrue(isNote(out), "自撤未确认：切换完成并附带提示")
        XCTAssertEqual(r.settings.connectionMode, .local)
    }

    /// 自撤超时由客户端 timeout 决定（Kit 的绝对期限）：超时抛出后按未确认处理，切换照常完成。
    func testDeleteSelfTimeoutCompletesTheSwitch() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        let sw = r.switcher()
        sw.deleteSelfOverride = { _ in throw URLError(.timedOut) }
        let out = await sw.switchTo(.local)
        XCTAssertTrue(isNote(out))
        XCTAssertEqual(r.settings.connectionMode, .local)
    }

    func testSwitchIsSingleFlight() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        let gate = RMGate()
        let sw = r.switcher()
        sw.deleteSelfOverride = { _ in await gate.wait() }
        let first = Task { @MainActor in await sw.switchTo(.local) }
        for _ in 0..<500 where !sw.switching { await Task.yield() }
        let second = await sw.switchTo(.remote)
        XCTAssertTrue(isFailed(second), "切换中再次切换被拒")
        await gate.release()
        let firstResult = await first.value
        XCTAssertTrue(isDone(firstResult))
        XCTAssertEqual(r.settings.connectionMode, .local)
    }

    func testSwitchRefusesBeforeCredentialsAreLoaded() async {
        let r = Rig()
        let out = await r.switcher().switchTo(.remote)
        XCTAssertTrue(isFailed(out), "凭据未装载：拒绝切换")
        XCTAssertEqual(r.settings.connectionMode, .local)
    }

    /// R5：接管窗口（AppBoot 尚未完成 bootOnLaunch）内拒绝切换，后台 Bridge 不会被遗留。
    func testSwitchRefusedBeforeBootReadyLeavesLocalRunning() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http)
        r.engine.start()
        let out = await r.switcher(ready: false).switchTo(.remote)
        XCTAssertTrue(isFailed(out))
        XCTAssertEqual(r.settings.connectionMode, .local, "模式不变")
        XCTAssertTrue(r.engine.childRunning, "未停止本机 Bridge")
        XCTAssertTrue(r.session.isPaired, "凭据不变")
    }

    /// R6：仅在远程模式下断开，模式保持远程，结果带自撤确认。
    func testDisconnectRemoteKeepsRemoteModeAndClearsSession() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        let calls = RMBox(0)
        let sw = r.switcher()
        sw.deleteSelfOverride = { _ in calls.value += 1 }
        let out = await sw.disconnectRemote()
        XCTAssertTrue(isDone(out))
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(r.settings.connectionMode, .remote, "模式保持远程")
        XCTAssertFalse(r.session.isPaired)
    }

    func testDisconnectRemoteRefusedInLocalMode() async {
        let r = Rig()
        let out = await r.switcher().disconnectRemote()
        XCTAssertTrue(isFailed(out))
    }

    // MARK: 3 代次：过期结果不写 Keychain / 端点 / 连接态（R2 / R3）

    func testDelayedHookIssueAfterForgetIsDiscarded() async {
        let r = Rig()
        let gate = RMGate()
        let hook = RMHook(gate: gate)
        r.session.hookFactory = { _, _ in hook }
        let pairCalls = RMBox(0)
        r.session.pairOverride = { _, _, _ in pairCalls.value += 1; return decodePair(#"{"deviceId":"x","token":"late","spkiSha256":"\#(spkiA)"}"#) }
        let ep = BridgeEndpoint(host: "192.168.1.9", port: 47821, transport: .https, spkiSha256: spkiA)
        let task = Task { @MainActor in await r.session.ensurePaired(want: ep, hookPort: 1, dataDir: "/tmp/palmhelm-remote-hook") }
        for _ in 0..<500 where hook.entered.value == 0 { await Task.yield() }
        r.session.forget()
        await gate.release()
        await task.value
        XCTAssertFalse(r.session.isPaired, "过期的发码结果不写令牌或端点")
        XCTAssertEqual(pairCalls.value, 0)
        XCTAssertEqual(hook.permissionSets.value, 0)
        XCTAssertEqual(r.session.link, .notPaired)
    }

    func testDelayedPairPostAfterForgetIsDiscarded() async {
        let r = Rig()
        let gate = RMGate()
        r.session.hookFactory = { _, _ in RMHook() }
        let entered = RMBox(0)
        r.session.pairOverride = { _, _, _ in
            entered.value += 1
            await gate.wait()
            return decodePair(#"{"deviceId":"x","token":"late","spkiSha256":"\#(spkiA)"}"#)
        }
        let ep = BridgeEndpoint(host: "192.168.1.9", port: 47821, transport: .https, spkiSha256: spkiA)
        let task = Task { @MainActor in await r.session.ensurePaired(want: ep, hookPort: 1, dataDir: "/tmp/palmhelm-remote-post") }
        for _ in 0..<500 where entered.value == 0 { await Task.yield() }
        r.session.forget()
        await gate.release()
        await task.value
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount), "过期的配对结果不写钥匙串")
        XCTAssertFalse(r.session.isPaired)
    }

    /// R8：本机自配对挂在 POST 上时经历 local→remote→local：放行后的过期结果不写钥匙串或端点。
    func testLocalSelfPairResultAcrossRemoteAndBackIsDiscarded() async {
        let r = Rig()
        await r.session.loadCredentials() // 无令牌：本机自配对的前提
        let gate = RMGate()
        let entered = RMBox(0)
        r.session.hookFactory = { _, _ in RMHook() }
        r.session.pairOverride = { _, _, _ in
            entered.value += 1
            await gate.wait()
            return decodePair(#"{"deviceId":"x","token":"late","spkiSha256":"\#(spkiA)"}"#)
        }
        let ep = BridgeEndpoint(host: "192.168.1.9", port: 47821, transport: .https, spkiSha256: spkiA)
        let task = Task { @MainActor in await r.session.ensurePaired(want: ep, hookPort: 1, dataDir: "/tmp/palmhelm-remote-roundtrip") }
        for _ in 0..<500 where entered.value == 0 { await Task.yield() }
        let sw = r.switcher()
        let toRemote = await sw.switchTo(.remote)
        let toLocal = await sw.switchTo(.local)
        XCTAssertTrue(isDone(toRemote))
        XCTAssertTrue(isDone(toLocal))
        await gate.release()
        await task.value
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount), "过期的本机配对结果不写钥匙串")
        XCTAssertFalse(r.session.isPaired)
        XCTAssertEqual(r.settings.connectionMode, .local)
    }

    /// R2：设备列表挂起期间换代：不撤销任何设备，也不用当前会话刷新。
    func testStalePruneAfterForgetRemovesNothingAndDoesNotRefresh() async {
        let r = Rig()
        r.session.preferences.set("old-device", forKey: MacSession.selfDeviceIdKey)
        let devGate = RMGate()
        let hook = RMHook(devicesGate: devGate, devices: [rmDevice("old-device", name: "Mac")])
        r.session.hookFactory = { _, _ in hook }
        r.session.pairOverride = { _, _, _ in decodePair(#"{"deviceId":"new-device","token":"new","spkiSha256":"\#(spkiA)"}"#) }
        let ep = BridgeEndpoint(host: "192.168.1.9", port: 47821, transport: .https, spkiSha256: spkiA)
        let task = Task { @MainActor in await r.session.ensurePaired(want: ep, hookPort: 1, dataDir: "/tmp/palmhelm-remote-prune") }
        for _ in 0..<500 where hook.devicesEntered.value == 0 { await Task.yield() }
        r.session.forget()
        await devGate.release()
        await task.value
        XCTAssertTrue(hook.removed.value.isEmpty, "过期的清理不撤销设备")
        XCTAssertEqual(r.stateCalls.value, 0, "过期的配对不用当前会话刷新")
        XCTAssertFalse(r.session.isPaired)
    }

    /// R3：探测挂起期间切换：放行后零配对请求，凭据、端点、连接态都不写。
    func testRemotePairSuspendedAcrossSwitchSendsNothing() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        let gate = RMGate()
        let sends = RMBox(0)
        r.session.pairProbe = { _ in await gate.wait(); return spkiA }
        r.session.pairSend = { _, _, _ in sends.value += 1; return decodePair(#"{"deviceId":"d1","token":"remote-token","spkiSha256":"\#(spkiA)"}"#) }
        let task = Task { @MainActor in await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA) }
        for _ in 0..<500 where r.session.link != .connecting { await Task.yield() }
        r.session.forget()
        await gate.release()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(sends.value, 0, "过期的配对码不发出")
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount))
        XCTAssertNil(r.session.endpoint)
        XCTAssertEqual(r.session.link, .notPaired, "过期结果不改连接态")
    }

    /// R3：人工确认期间模式被切回本机：确认返回后不发码。
    func testRemotePairConfirmSuspendedAcrossModeChangeSendsNothing() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        let gate = RMGate()
        let sends = RMBox(0)
        r.session.pairProbe = { _ in spkiA }
        r.session.pairSend = { _, _, _ in sends.value += 1; return decodePair(#"{"deviceId":"d1","token":"remote-token","spkiSha256":"\#(spkiA)"}"#) }
        let task = Task { @MainActor in
            await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: nil, confirm: { _ in await gate.wait(); return true })
        }
        for _ in 0..<500 where r.session.link != .connecting { await Task.yield() }
        r.settings.connectionMode = .local
        await gate.release()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(sends.value, 0)
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount))
    }

    // MARK: 4 远程配对

    private func remoteSession() async -> (Rig, RMBox<Int>, RMBox<Int>) {
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote) // 凭据就绪（无令牌）：远程配对的前置条件
        let probes = RMBox(0), sends = RMBox(0)
        r.session.pairProbe = { _ in probes.value += 1; return spkiA }
        r.session.pairSend = { _, _, _ in sends.value += 1; return decodePair(#"{"deviceId":"d1","token":"remote-token","spkiSha256":"\#(spkiA)"}"#) }
        return (r, probes, sends)
    }

    func testRemotePairSavesPinnedEndpointRefreshesAndConnects() async {
        let (r, _, sends) = await remoteSession()
        let ok = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA)
        XCTAssertTrue(ok)
        XCTAssertEqual(sends.value, 1)
        XCTAssertEqual(r.session.endpoint?.host, "mac.example.ts.net")
        XCTAssertEqual(r.session.endpoint?.spkiSha256, spkiA)
        XCTAssertTrue(r.session.isPaired)
        XCTAssertEqual(KeychainStore.load(account: KeychainStore.tokenAccount), "remote-token")
        XCTAssertGreaterThanOrEqual(r.stateCalls.value, 1, "配对成功后确实发出了 refresh")
        XCTAssertEqual(r.session.link, .connected)
    }

    func testRemotePairRejectsPlaintextAndInvalidInputsWithoutAnyRequest() async {
        let (r, probes, sends) = await remoteSession()
        let loopback = BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http)
        let plainLink = PairLink.parse(URL(string: "palmhelm://pair?host=mac.example.ts.net&port=47821&code=123456&tls=0")!)!
        let loopbackLink = PairLink.parse(URL(string: "palmhelm://pair?host=127.0.0.1&port=47821&code=123456&tls=0")!)!
        let fpEncoded = spkiA.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? spkiA
        let plainFpLink = PairLink.parse(URL(string: "palmhelm://pair?host=mac.example.ts.net&port=47821&code=123456&tls=0&fp=\(fpEncoded)")!)!
        XCTAssertFalse(plainLink.tls)
        XCTAssertNotNil(plainFpLink.fp, "带 fp 的 http 链接仍能解析，应由 tls=0 拒绝")
        XCTAssertFalse(plainFpLink.tls)
        let rejected: [() async -> Bool] = [
            { await r.session.pairRemote(link: plainLink) },
            { await r.session.pairRemote(link: plainFpLink) },
            { await r.session.pairRemote(link: loopbackLink) },
            { await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA, extra: [loopback]) },
            { await r.session.pairRemote(host: "", port: 47821, code: "123456", expectedSpki: spkiA) },
            { await r.session.pairRemote(host: "mac .example", port: 47821, code: "123456", expectedSpki: spkiA) },
            { await r.session.pairRemote(host: "mac.example.ts.net", port: 0, code: "123456", expectedSpki: spkiA) },
            { await r.session.pairRemote(host: "mac.example.ts.net", port: 70000, code: "123456", expectedSpki: spkiA) },
            { await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "12345", expectedSpki: spkiA) },
            { await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "12a456", expectedSpki: spkiA) },
            { await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: "not-a-pin") },
            { await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: nil, confirm: nil) },
        ]
        for attempt in rejected {
            let ok = await attempt()
            XCTAssertFalse(ok)
        }
        XCTAssertEqual(probes.value, 0, "校验失败零探测")
        XCTAssertEqual(sends.value, 0, "校验失败零配对请求")
        XCTAssertFalse(r.session.isPaired)
    }

    func testRemotePairRejectedInLocalModeWithoutTouchingState() async {
        let (r, probes, sends) = await remoteSession()
        r.settings.connectionMode = .local
        let ok = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA)
        XCTAssertFalse(ok)
        XCTAssertEqual(probes.value, 0)
        XCTAssertEqual(sends.value, 0)
        XCTAssertEqual(r.session.link, .notPaired, "本机模式下不改连接态")
    }

    func testRemotePairRejectedWhenAlreadyPaired() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        let probes = RMBox(0)
        r.session.pairProbe = { _ in probes.value += 1; return spkiA }
        KeychainStore.save("existing", account: KeychainStore.tokenAccount)
        await r.session.loadCredentials(mode: .remote)
        r.session.endpoint = remoteEndpoint
        XCTAssertTrue(r.session.isPaired)
        let ok = await r.session.pairRemote(host: "other.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiB)
        XCTAssertFalse(ok)
        XCTAssertEqual(probes.value, 0, "已配对时需先断开，不发码")
    }

    func testRemotePairFingerprintMismatchDoesNotSave() async {
        let (r, _, sends) = await remoteSession()
        r.session.pairProbe = { _ in spkiB } // 实际握手与链接里的 fp 不符
        let ok = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA)
        XCTAssertFalse(ok)
        XCTAssertEqual(sends.value, 0, "指纹不符：不发配对码")
        XCTAssertFalse(r.session.isPaired)
    }

    func testRemotePairReportedFingerprintMismatchDoesNotSave() async {
        let (r, _, _) = await remoteSession()
        r.session.pairSend = { _, _, _ in decodePair(#"{"deviceId":"d1","token":"remote-token","spkiSha256":"\#(spkiB)"}"#) }
        let ok = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA)
        XCTAssertFalse(ok)
        XCTAssertFalse(r.session.isPaired)
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount))
    }

    func testRemotePairMissingReportedFingerprintDoesNotSave() async {
        let (r, _, _) = await remoteSession()
        r.session.pairSend = { _, _, _ in decodePair(#"{"deviceId":"d1","token":"remote-token"}"#) }
        let ok = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA)
        XCTAssertFalse(ok)
        XCTAssertFalse(r.session.isPaired)
    }

    func testRemotePairWithoutFingerprintRequiresConfirmation() async {
        let (r, _, sends) = await remoteSession()
        let declined = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: nil, confirm: { _ in false })
        XCTAssertFalse(declined, "用户拒绝确认短指纹")
        XCTAssertEqual(sends.value, 0)
        let accepted = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: nil, confirm: { _ in true })
        XCTAssertTrue(accepted)
        XCTAssertTrue(r.session.isPaired)
    }

    func testRemotePairKeychainWriteFailureSavesNoEndpoint() async {
        let (r, _, _) = await remoteSession()
        r.session.tokenSaver = { _ in false }
        let ok = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA)
        XCTAssertFalse(ok)
        XCTAssertNil(r.session.endpoint, "令牌写入失败：端点不提交")
        XCTAssertFalse(r.session.isPaired)
    }

    func testRemotePairRefusedWhileModeSwitchRuns() async {
        let (r, probes, _) = await remoteSession()
        r.session.modeSwitchInProgress = true
        let ok = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA)
        XCTAssertFalse(ok)
        XCTAssertEqual(probes.value, 0)
    }

    // MARK: 5 远程端点的 pin 校验

    func testLoadEndpointRequirePinnedRejectsPlaintextAndBadPins() {
        KeychainStore.saveEndpoint(BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http))
        XCTAssertNotNil(KeychainStore.loadEndpoint(), "本机读取不变")
        XCTAssertNil(KeychainStore.loadEndpoint(requirePinned: true), "远程拒绝 http")

        KeychainStore.saveEndpoint(BridgeEndpoint(host: "mac.example.ts.net", port: 47821, transport: .https, spkiSha256: "short"))
        XCTAssertNil(KeychainStore.loadEndpoint(requirePinned: true), "远程拒绝非 32 字节 pin")

        KeychainStore.saveEndpoint(BridgeEndpoint(host: "mac.example.ts.net", port: 47821, transport: .https, spkiSha256: spkiA))
        XCTAssertEqual(KeychainStore.loadEndpoint(requirePinned: true)?.spkiSha256, spkiA)
    }

    func testRemoteCredentialLoadDropsUnpinnedEndpointButLocalKeepsIt() async {
        KeychainStore.saveEndpoint(BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http))
        KeychainStore.save("t", account: KeychainStore.tokenAccount)
        let remote = MacSession()
        remote.streamDisabled = true
        await remote.loadCredentials(mode: .remote)
        XCTAssertNil(remote.endpoint, "远程启动装载：未固定的端点视为未配对")
        XCTAssertFalse(remote.isPaired)

        let local = MacSession()
        local.streamDisabled = true
        await local.loadCredentials(mode: .local)
        XCTAssertNotNil(local.endpoint, "本机装载行为不变")
    }

    // MARK: 6 刘海：连接换代与票据（R4 / R8）

    /// 旧票据 + 连接换代 + 同 ID 的新卡：零决策；当前票据：一次决策。
    func testStaleTicketCannotDecideANewCardWithTheSameIdAfterReset() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let s = MacSession()
        s.streamDisabled = true
        s.link = .connected
        let calls = RMBox<[String]>([])
        s.decideOverride = { a, d in calls.value.append("\(a.id):\(d)") }
        s.approvals["A"] = rmApproval("A")
        let c = NotchController()
        c.attach(session: s)
        defer { c.detach() }
        c.debugSetExpanded(true)
        c.debugTick()
        XCTAssertEqual(c.pin.id, "A")
        XCTAssertNotNil(c.snapshot, "差分基线已建立")
        let staleTicket = c.pinEpochTicket

        s.forget() // 连接换代
        s.approvals["A"] = rmApproval("A") // 新连接恰好同 ID
        c.resetConnection()
        XCTAssertNil(c.pin.id, "固定卡已清")
        XCTAssertNil(c.pinnedApproval)
        XCTAssertNil(c.snapshot, "差分基线已清")
        c.debugTick()
        XCTAssertEqual(c.pin.id, "A")

        await c.decidePinned(.allowOnce, expectedId: "A", epoch: staleTicket)
        XCTAssertTrue(calls.value.isEmpty, "旧票据不接收新代次的同 ID 审批")
        await c.decidePinned(.allowOnce, expectedId: "A", epoch: c.pinEpochTicket)
        XCTAssertEqual(calls.value, ["A:allowOnce"], "当前票据可以决策")
    }

    // MARK: 7 AppBoot 远程分支决策与冷启动（R1 / R2）

    func testRemoteRefreshNeverRetriesAuthFailureAndHonorsBackoff() {
        let now = Date()
        func decide(_ link: MacSession.Link, paired: Bool = true, authFailed: Bool = false, switching: Bool = false, nextTry: Date? = nil) -> Bool {
            RemoteRefreshRetry.shouldRefresh(link: link, isPaired: paired, authFailed: authFailed, switching: switching, now: now, nextTry: nextTry ?? now)
        }
        XCTAssertTrue(decide(.offline(LText("x"))))
        XCTAssertTrue(decide(.notPaired), "冷启动已有凭据：notPaired 也要刷新")
        XCTAssertFalse(decide(.offline(LText("x")), authFailed: true), "鉴权失败不循环刷新")
        XCTAssertFalse(decide(.offline(LText("x")), nextTry: now.addingTimeInterval(10)), "退避未到")
        XCTAssertFalse(decide(.notPaired, paired: false), "未配对不刷新")
        XCTAssertFalse(decide(.connected), "在线不刷新")
        XCTAssertFalse(decide(.connecting), "正在连接不刷新")
        XCTAssertFalse(decide(.offline(LText("x")), switching: true), "切换中不刷新（R2）")
    }

    /// R1：冷启动已有有效远程凭据：link 为 notPaired，决策为刷新，刷新发出第一次 state 请求并连上。
    func testColdStartWithPersistedRemoteCredentialsRefreshesOnce() async {
        KeychainStore.saveEndpoint(remoteEndpoint)
        KeychainStore.save("remote-token", account: KeychainStore.tokenAccount)
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        XCTAssertTrue(r.session.isPaired)
        XCTAssertEqual(r.session.link, .notPaired)
        let decide = RemoteRefreshRetry.shouldRefresh(link: r.session.link, isPaired: r.session.isPaired, authFailed: r.session.refreshAuthFailed, switching: false, now: Date(), nextTry: .distantPast)
        XCTAssertTrue(decide, "冷启动即决策刷新")
        if decide { await r.session.refresh() }
        XCTAssertEqual(r.stateCalls.value, 1, "发出第一次 state 请求")
        XCTAssertEqual(r.session.link, .connected)
    }

    // MARK: 7 权限与撤销（R7）

    func testRemoteCanControlRequiresConnectedAndExplicitControl() {
        let r = Rig()
        r.settings.connectionMode = .remote
        r.session.link = .connected
        XCTAssertFalse(r.session.canControl, "未知设备：不可控")
        r.session.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d1","name":"mac","paused":false,"permission":"readonly"}"#.utf8))
        XCTAssertFalse(r.session.canControl, "只读：不可控")
        r.session.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d1","name":"mac","paused":false}"#.utf8))
        XCTAssertFalse(r.session.canControl, "缺字段：不可控")
        r.session.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d1","name":"mac","paused":false,"permission":"control"}"#.utf8))
        XCTAssertTrue(r.session.canControl, "明确 control 且在线：可控")
        r.session.link = .offline(LText("x"))
        XCTAssertFalse(r.session.canControl, "离线：不可控")
    }

    func testLocalCanControlDefaultUnchangedWhenDeviceUnknown() {
        let r = Rig()
        r.session.link = .connected
        XCTAssertTrue(r.session.canControl, "本机模式缺省仍为可控")
    }

    /// R7：GET state 返回 401：清空会话与令牌，链接显示需要重新配对。
    func testRemoteStateAuthLostClearsSessionAndShowsRepairReason() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        r.session.stateOverride = { () async throws -> BridgeState in throw BridgeError.http(status: 401) }
        await r.session.refresh()
        XCTAssertFalse(r.session.isPaired, "令牌与端点已清")
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount))
        guard case .offline = r.session.link else { return XCTFail("应为离线并说明原因") }
    }

    /// R7：SSE 握手返回 401：停流并清空会话，不按断线重试。
    func testRemoteStreamAuthLostStopsAndClearsSession() async throws {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        r.session.streamDisabled = false
        let eventCalls = RMBox(0), retrySleeps = RMBox(0)
        r.session.eventsOverride = { _ in
            eventCalls.value += 1
            throw BridgeError.http(status: 401)
        }
        r.session.streamRetrySleep = { _ in retrySleeps.value += 1 } // 记录重试等待：鉴权失效必须直接返回，不进入等待
        await r.session.refresh() // 成功拉到 state，随后启动事件流
        XCTAssertEqual(r.session.link, .connected)
        for _ in 0..<200 where r.session.isPaired { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(r.session.isPaired, "事件流鉴权失效后清空会话")
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(eventCalls.value, 1, "不再重连")
        XCTAssertEqual(retrySleeps.value, 0, "没有进入断线重试等待")
    }

    /// R7 / F1：SSE ready 后的 GET state 返回 403：凭据清空、停止读流，不被普通离线原因覆盖。
    func testRemoteSSEReadyThenStateForbiddenStopsStream() async throws {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        r.session.link = .offline(LText("网络断开")) // ready 只在离线态下补拉 state
        r.session.streamDisabled = false
        let eventCalls = RMBox(0)
        r.session.eventsOverride = { _ in
            eventCalls.value += 1
            return AsyncThrowingStream { continuation in
                continuation.yield(.ready(highWater: 0))
                continuation.finish()
            }
        }
        r.session.streamRetrySleep = { _ in }
        r.session.stateOverride = { () async throws -> BridgeState in throw BridgeError.http(status: 403) }
        r.session.startStream()
        for _ in 0..<200 where r.session.isPaired { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(r.session.isPaired, "ready 后的鉴权失效清空会话")
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount))
        guard case .offline = r.session.link else { return XCTFail("应为离线并说明原因") }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(eventCalls.value, 1, "事件流不再被重新打开")
    }

    /// R7 / F1：直接读取 state（pullState）返回 401：同一处理，会话清空。
    func testRemotePullStateUnauthorizedClearsSession() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        r.session.link = .connected
        r.session.stateOverride = { () async throws -> BridgeState in throw BridgeError.http(status: 401) }
        _ = try? await r.session.pullState()
        XCTAssertFalse(r.session.isPaired)
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount))
        guard case .offline = r.session.link else { return XCTFail("应为离线并说明原因") }
    }

    /// F2：自动撤销同时重置刘海：展开的旧审批卡与摘要都要消失。
    func testAuthLostResetsNotchPinAndSnapshot() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        r.session.link = .connected
        r.session.approvals["A"] = rmApproval("A")
        let c = NotchController()
        c.attach(session: r.session)
        defer { c.detach() }
        r.session.onConnectionForgotten = { c.resetConnection() } // 与 AppDelegate 的接线一致
        c.debugSetExpanded(true)
        c.debugTick()
        XCTAssertEqual(c.pin.id, "A")
        XCTAssertNotNil(c.pinnedApproval)
        r.session.stateOverride = { () async throws -> BridgeState in throw BridgeError.http(status: 401) }
        _ = try? await r.session.pullState()
        XCTAssertNil(c.pin.id, "固定卡已清")
        XCTAssertNil(c.pinnedApproval, "旧审批不再渲染")
        XCTAssertNil(c.snapshot, "差分基线已清")
    }

    /// F2 对照：普通断线（网络错误）不触发连接遗忘，固定卡保留。
    func testOrdinaryOfflineDoesNotForgetConnection() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        let forgotten = RMBox(0)
        r.session.onConnectionForgotten = { forgotten.value += 1 }
        r.session.stateOverride = { () async throws -> BridgeState in throw URLError(.notConnectedToInternet) }
        await r.session.refresh()
        XCTAssertTrue(r.session.isPaired, "普通断线保留令牌")
        XCTAssertEqual(forgotten.value, 0)
    }

    /// R7：写接口 403（权限不足）不是撤销，令牌保留；走真实发送路径。
    func testRemoteWriteForbiddenKeepsToken() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        r.session.link = .connected
        r.session.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d1","name":"mac","paused":false,"permission":"control"}"#.utf8))
        r.session.sendOverride = { _, _ in throw BridgeError.http(status: 403) }
        let sent = await r.session.send("你好")
        XCTAssertFalse(sent)
        XCTAssertTrue(r.session.isPaired, "写接口的 403 不清除令牌")
    }

    /// F3：凭据未装载时，断开与配对都拒绝，零请求，存储不变。
    func testDisconnectAndPairRefusedBeforeCredentialsLoad() async {
        KeychainStore.saveEndpoint(remoteEndpoint)
        KeychainStore.save("persisted-token", account: KeychainStore.tokenAccount)
        let r = Rig()
        r.settings.connectionMode = .remote
        r.session.endpoint = remoteEndpoint // 持久化的端点已在，令牌仍在读取中
        let probes = RMBox(0), deleted = RMBox(0)
        r.session.pairProbe = { _ in probes.value += 1; return spkiA }
        let sw = r.switcher()
        sw.deleteSelfOverride = { _ in deleted.value += 1 }
        let out = await sw.disconnectRemote()
        XCTAssertTrue(isFailed(out))
        let paired = await r.session.pairRemote(host: "other.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiB)
        XCTAssertFalse(paired)
        XCTAssertEqual(deleted.value, 0)
        XCTAssertEqual(probes.value, 0)
        XCTAssertEqual(KeychainStore.load(account: KeychainStore.tokenAccount), "persisted-token", "存储不变")
        XCTAssertEqual(KeychainStore.loadEndpoint(requirePinned: true)?.host, "mac.example.ts.net")
    }

    /// F4：断开时自撤超时：切换结果为 doneWithNote，模式保持远程，文案为共用提示。
    func testDisconnectTimeoutReturnsSharedNoteAndStaysRemote() async {
        let r = Rig()
        await r.loadToken()
        r.session.endpoint = remoteEndpoint
        r.settings.connectionMode = .remote
        let sw = r.switcher()
        sw.deleteSelfOverride = { _ in throw URLError(.timedOut) }
        let out = await sw.disconnectRemote()
        guard case .doneWithNote(let note) = out else { return XCTFail("应为带提示的完成") }
        XCTAssertEqual(note.text, String(localized: "未能确认已从远程 Mac 移除本机，请在那台 Mac 的设备列表核对"))
        XCTAssertEqual(r.settings.connectionMode, .remote)
    }

    /// R8：resetConnection 清空非空的提示（toast）。收起时新来的待答产生提示，重置后为空。
    func testResetConnectionClearsANonEmptyToast() throws {
        guard NSScreen.main != nil else { throw XCTSkip("没有屏幕") }
        let s = MacSession()
        s.streamDisabled = true
        s.link = .connected
        s.approvals["A"] = rmApproval("A")
        let c = NotchController()
        c.attach(session: s)
        defer { c.detach() }
        c.debugTick() // 建立差分基线（含 A）
        c.debugSetExpanded(false)
        s.approvals["B"] = rmApproval("B")
        c.debugTick()
        XCTAssertNotNil(c.toast.current, "前置：收起时新待答产生提示")
        c.resetConnection()
        XCTAssertNil(c.toast.current, "重置后提示为空")
    }

    // MARK: 连接投影（h3 §1）

    /// 远程模式只看凭据与连接态：不看本机 Bridge 进程，也不要求 secretsLoaded。
    func testRemoteConnectionPhaseIgnoresEngineAndSecrets() {
        func phase(_ link: MacSession.Link, credentials: Bool = true, secrets: Bool = false, engine: BridgeEngine.Status = .failed(LText("x"))) -> ConnectionPhase {
            ConnectionPhase.from(mode: .remote, engineStatus: engine, portFileReady: false, credentialsLoaded: credentials, secretsLoaded: secrets, link: link)
        }
        XCTAssertEqual(phase(.notPaired), .remoteNotPaired)
        XCTAssertEqual(phase(.connecting), .remoteConnecting)
        XCTAssertEqual(phase(.connected), .connected)
        XCTAssertEqual(phase(.offline(LText("断开"))), .offline(LText("断开")))
        XCTAssertEqual(phase(.connected, credentials: false), .readingCredentials, "凭据未装载：仍在读取")
        XCTAssertEqual(phase(.connected, secrets: false), .connected, "远程不要求 secretsLoaded")
        XCTAssertEqual(phase(.notPaired).label, "未连接远程 Mac")
        XCTAssertEqual(phase(.connecting).label, "正在连接远程 Mac…")
        XCTAssertTrue(phase(.connecting).isTransitional)
        XCTAssertFalse(phase(.notPaired).isTransitional)
    }

    // MARK: 界面纯函数（h3 §2–§4）

    func testSettingsPanesFollowTheConnectionMode() {
        XCTAssertEqual(SettingsView.Pane.visible(for: .local), SettingsView.Pane.allCases, "本机模式显示全部")
        XCTAssertEqual(SettingsView.Pane.visible(for: .remote), [.appearance, .connection, .usagePrivacy, .about], "远程隐藏引擎、飞书、日志")
    }

    func testRemoteMenuFirstLineShowsTheRemoteMac() {
        XCTAssertEqual(MenuBarRemoteLine.text(host: "mac.example.ts.net", phase: "在线"), "远程 Mac · mac.example.ts.net · 在线")
        XCTAssertEqual(MenuBarRemoteLine.text(host: nil, phase: "未连接远程 Mac"), "远程 Mac · 未配对 · 未连接远程 Mac")
    }

    func testRemoteLinePresentationNamesTheRemoteMacAndPhase() {
        XCTAssertEqual(RemoteLinePresentation.line(endpoint: remoteEndpoint, phase: "在线"), "远程 Mac mac.example.ts.net · 在线")
        XCTAssertEqual(RemoteLinePresentation.help(endpoint: remoteEndpoint, phase: "在线"), "远程 Mac mac.example.ts.net:47821 · 在线。点击打开设置")
        XCTAssertEqual(RemoteLinePresentation.line(endpoint: nil, phase: "x"), "远程 Mac 未配对")
    }

    func testConnectionModeCopyStatesTheSideEffect() {
        XCTAssertEqual(ConnectionModeCopy.confirmMessage(target: .remote), "会停止本机 Bridge。")
        XCTAssertEqual(ConnectionModeCopy.confirmMessage(target: .local), "会断开远程 Mac 并清空本机上的会话视图。")
    }

    func testRemoteQuitTextDiffersFromLocal() {
        XCTAssertEqual(QuitPolicy.alertText(keepsAfterQuit: false, mode: .remote).text, "退出后刘海与提醒将停止，远程 Mac 上的会话不受影响。")
        XCTAssertTrue(QuitPolicy.alertText(keepsAfterQuit: true).text.contains("后台运行"), "本机文案不变")
    }

    /// 服务边界：远程模式下带图片的发送零请求、草稿与附件保留；纯文本照常发送。
    func testRemoteSubmitWithAttachmentSendsNothingAndKeepsDraft() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        let sent = RMBox(0)
        r.session.sendOverride = { _, _ in sent.value += 1; throw URLError(.timedOut) }
        var withImage = MacSession.ComposerDraft()
        withImage.text = "看图"
        withImage.attachments = [ComposerAttachment(path: "/tmp/palmhelm-remote.png", thumbnail: NSImage(size: NSSize(width: 1, height: 1)), source: .userReference)]
        r.session.setDraft(withImage, for: "A")
        let ok = await r.session.submitComposer(threadId: "A", agent: nil)
        XCTAssertFalse(ok)
        XCTAssertEqual(sent.value, 0, "图片不转发：零请求")
        XCTAssertEqual(r.session.draft("A").text, "看图", "草稿保留")
        XCTAssertEqual(r.session.draft("A").attachments.count, 1, "附件保留")

        r.session.link = .connected
        r.session.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d1","name":"mac","paused":false,"permission":"control"}"#.utf8))
        var textOnly = MacSession.ComposerDraft()
        textOnly.text = "只有文字"
        r.session.setDraft(textOnly, for: "B")
        _ = await r.session.submitComposer(threadId: "B", agent: nil)
        XCTAssertEqual(sent.value, 1, "普通文本照常发送")
    }

    /// 入口拒绝：远程模式下粘贴 / 拖入的图片不落盘、不改列表，并给出说明。
    func testRemoteComposerRefusesImageItemsAtTheEntry() {
        var list: [ComposerAttachment] = []
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let refusal = ComposerAttachments.add([.bitmap(image)], to: &list, editable: true, remote: true)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(list.isEmpty, "列表不变")
    }

    /// 本机模式的映射保持不变（对照）。
    func testLocalConnectionPhaseUnchangedByTheModeParameter() {
        let local = ConnectionPhase.from(mode: .local, engineStatus: .stopped, portFileReady: false, credentialsLoaded: true, secretsLoaded: true, link: .notPaired)
        XCTAssertEqual(local, .engineOff)
    }
}

// MARK: - h5：确认生命周期、复制准入、权限文案、断开提示（纯函数与一次性确认器）

@MainActor
final class RemoteModeReviewTests: XCTestCase {
    // 内存钥匙串在用例之间共享：上一个用例配对成功留下的令牌会让下一个用例的 isPaired 为真，入口拒绝后断言变成空过
    override func setUp() { KeychainStore.clearEndpoint() } // clearEndpoint 同时删除令牌
    override func tearDown() { KeychainStore.clearEndpoint() }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// 一次性确认器：只消费一次；确认绑定尝试标识，宿主离开后旧尝试不再展示，只有之后新开的尝试才展示。
    func testConfirmerAnswersOnceAndDisposeRefuses() async {
        let c = FingerprintConfirmer()
        let attempt = c.openAttempt()
        let first = Task { @MainActor in await c.ask(short: "ABCD-EFGH", attempt: attempt) }
        await waitUntil { c.pendingShort != nil }
        XCTAssertEqual(c.pendingShort, "ABCD-EFGH")
        c.answer(true)
        c.answer(false) // 重复回答无效
        let accepted = await first.value
        XCTAssertTrue(accepted)
        XCTAssertNil(c.pendingShort)

        let pending = Task { @MainActor in await c.ask(short: "KLMN-5678", attempt: attempt) }
        await waitUntil { c.pendingShort != nil }
        c.dispose()
        let disposedWhilePending = await pending.value
        XCTAssertFalse(disposedWhilePending, "待答时宿主离开：以拒绝收束")
        XCTAssertNil(c.pendingShort)

        let refused = await c.ask(short: "WXYZ-1234", attempt: attempt)
        XCTAssertFalse(refused, "宿主已离开：旧尝试不展示")
        XCTAssertNil(c.pendingShort)

        let next = c.openAttempt()
        let again = Task { @MainActor in await c.ask(short: "NEW-0001", attempt: next) }
        await waitUntil { c.pendingShort != nil }
        c.answer(true)
        let nextAccepted = await again.value
        XCTAssertTrue(nextAccepted, "之后新开的尝试可以展示并回答")
        let oldAgain = await c.ask(short: "OLD-9999", attempt: attempt)
        XCTAssertFalse(oldAgain, "旧标识不会因重新出现而复活")
        XCTAssertNil(c.pendingShort)
    }

    /// 回归（A1-004 #1）：延迟 probe → 宿主离开（作废尝试并取消）→ 宿主重新出现 → probe 放行：
    /// 旧确认不弹出，零 POST，pairing 复位，link 不再 connecting；随后可立即发起新配对且成功。
    func testManualPairingLeftAndReopenedWhileProbeHangsShowsNoOldPromptAndUnblocks() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        let gate = RMGate()
        let entered = RMBox(0), sends = RMBox(0)
        r.session.pairProbe = { _ in entered.value += 1; await gate.wait(); return spkiA }
        r.session.pairSend = { _, _, _ in sends.value += 1; return decodePair(#"{"deviceId":"d1","token":"remote-token","spkiSha256":"\#(spkiA)"}"#) }
        let confirmer = FingerprintConfirmer()
        let attempt = confirmer.openAttempt()
        let task = Task { @MainActor in
            await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: nil, confirm: { short in await confirmer.ask(short: short, attempt: attempt) })
        }
        await waitUntil { entered.value > 0 }
        r.session.cancelRemotePairing()
        confirmer.dispose() // 宿主离开
        // 宿主重新出现：视图不开启新尝试，也不复活旧尝试
        await gate.release()
        let abandoned = await task.value
        XCTAssertFalse(abandoned)
        XCTAssertNil(confirmer.pendingShort, "旧确认不弹出")
        XCTAssertEqual(sends.value, 0, "零 POST")
        XCTAssertFalse(r.session.pairing, "pairing 复位")
        XCTAssertEqual(r.session.link, .notPaired, "取消未提交：不再 connecting")

        r.session.pairProbe = { _ in spkiA }
        let again = await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA)
        XCTAssertTrue(again, "立即可发起新配对")
        XCTAssertEqual(sends.value, 1)
    }

    /// 回归（A1-004 #1）：已取消但尚未进入的带 fp 请求：零 probe、零 POST，连接态不变。
    func testCancelledBeforeEntryLinkPairingSendsNothingAndKeepsLink() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        let probes = RMBox(0), sends = RMBox(0)
        r.session.pairProbe = { _ in probes.value += 1; return spkiA }
        r.session.pairSend = { _, _, _ in sends.value += 1; return decodePair(#"{"deviceId":"d1","token":"t","spkiSha256":"\#(spkiA)"}"#) }
        r.session.link = .notPaired
        let task = Task { @MainActor in await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA) }
        task.cancel() // 在进入 pairRemote 之前取消
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(probes.value, 0, "零 probe")
        XCTAssertEqual(sends.value, 0, "零 POST")
        XCTAssertEqual(r.session.link, .notPaired, "连接态不变")
    }

    /// 收束不覆盖他处写入的状态：取消后若连接态已被别处改写，未提交的尝试不再覆盖它。
    func testAbandonedAttemptDoesNotOverwriteLaterState() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        let gate = RMGate()
        let entered = RMBox(0)
        r.session.pairProbe = { _ in entered.value += 1; await gate.wait(); return spkiA }
        let task = Task { @MainActor in await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA) }
        await waitUntil { entered.value > 0 }
        r.session.cancelRemotePairing()
        r.session.link = .connected // 别处写入的状态
        await gate.release()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(r.session.link, .connected, "不覆盖他处写入的状态")
    }

    /// 链接配对（带 fp，无人工确认）同样受取消代次约束：探测挂起时取消，零 POST。
    func testLinkPairingCancelledWhileProbeHangsSendsNothing() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        let gate = RMGate()
        let entered = RMBox(0), sends = RMBox(0)
        r.session.pairProbe = { _ in entered.value += 1; await gate.wait(); return spkiA }
        r.session.pairSend = { _, _, _ in sends.value += 1; return decodePair(#"{"deviceId":"d1","token":"t","spkiSha256":"\#(spkiA)"}"#) }
        let task = Task { @MainActor in await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA) }
        await waitUntil { entered.value > 0 }
        r.session.cancelRemotePairing()
        await gate.release()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(sends.value, 0)
        XCTAssertFalse(r.session.isPaired)
    }

    /// 回归（A1-005 #1）：已进入并挂在 probe 时只取消发起任务（不调 cancelRemotePairing）：
    /// probe 跑在 Kit 的独立 Task 里读不到父任务取消，资格仍须失效——手动与带 fp 两条路径都零 POST、不存凭据。
    func testCancellingOnlyTheTaskWhileProbeHangsSendsNothing() async {
        for manual in [true, false] {
            KeychainStore.clearEndpoint() // 两条路径各自独立判读
            let r = Rig()
            r.settings.connectionMode = .remote
            await r.session.loadCredentials(mode: .remote)
            let gate = RMGate()
            let entered = RMBox(0), sends = RMBox(0), asked = RMBox(0)
            r.session.pairProbe = { _ in entered.value += 1; await gate.wait(); return spkiA }
            r.session.pairSend = { _, _, _ in sends.value += 1; return decodePair(#"{"deviceId":"d1","token":"t","spkiSha256":"\#(spkiA)"}"#) }
            let task = Task { @MainActor in
                await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: manual ? nil : spkiA,
                                           confirm: { _ in asked.value += 1; return true })
            }
            await waitUntil { entered.value > 0 }
            task.cancel()
            await gate.release()
            let ok = await task.value
            XCTAssertFalse(ok, "manual=\(manual)")
            XCTAssertEqual(entered.value, 1, "manual=\(manual)：确实进入了 probe（防止入口拒绝导致空过）")
            XCTAssertEqual(asked.value, 0, "manual=\(manual)：任务已取消，不展示确认")
            XCTAssertEqual(sends.value, 0, "manual=\(manual)：零 POST")
            XCTAssertFalse(r.session.isPaired, "manual=\(manual)：不存凭据")
            XCTAssertFalse(r.session.pairing, "manual=\(manual)")
            XCTAssertEqual(r.session.link, .notPaired, "manual=\(manual)：同一连接内收束为未配对")
        }
    }

    /// 回归（A1-006）：凭据已保存、首次 GET state 挂起时取消发起任务：不报成功，凭据保留，
    /// 首次同步不随发起任务取消而早退（否则 link 停在 connecting，AppBoot 不会接续）。
    func testCancellingDuringFirstSyncKeepsCredentialsAndCompletesTheSync() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        let gate = RMGate()
        let syncing = RMBox(0)
        r.session.pairProbe = { _ in spkiA }
        r.session.pairSend = { _, _, _ in decodePair(#"{"deviceId":"d1","token":"remote-token","spkiSha256":"\#(spkiA)"}"#) }
        // 与 Kit 的请求期限一样：所在任务被取消时以 CancellationError 结束
        r.session.stateOverride = { () async throws -> BridgeState in syncing.value += 1; await gate.wait(); try Task.checkCancellation(); return rmState() }
        let task = Task { @MainActor in await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA) }
        await waitUntil { syncing.value > 0 }
        task.cancel()
        await gate.release()
        let ok = await task.value
        XCTAssertEqual(syncing.value, 1, "确实进入了首次同步")
        XCTAssertFalse(ok, "发起任务已取消：不报告成功")
        XCTAssertTrue(r.session.isPaired, "已确认的凭据保留")
        XCTAssertEqual(r.session.link, .connected, "首次同步独立完成，不停在 connecting")
    }

    /// 回归（A1-007）：凭据提交后、首次同步任务入场前发生断开（stopStream 换代 + 切换中）：
    /// 旧尝试的同步不得以新代次发起 GET、重开事件流或改写连接态。
    func testQueuedFirstSyncDoesNotRunAfterDisconnect() async {
        KeychainStore.clearEndpoint()
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        r.session.pairProbe = { _ in spkiA }
        r.session.pairSend = { _, _, _ in decodePair(#"{"deviceId":"d1","token":"remote-token","spkiSha256":"\#(spkiA)"}"#) }
        let session = r.session
        // 写令牌时排入一个断开动作：它先于随后创建的首次同步任务在主线程执行
        session.tokenSaver = { _ in
            Task { @MainActor in session.stopStream(); session.modeSwitchInProgress = true }
            return true
        }
        let ok = await session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA)
        XCTAssertFalse(ok, "连接已不归属本次尝试：不报告成功")
        XCTAssertTrue(session.modeSwitchInProgress, "断开动作确实先执行")
        XCTAssertEqual(r.stateCalls.value, 0, "零 GET state")
        XCTAssertEqual(session.link, .connecting, "不改写连接态")
    }

    /// 回归（A1-005 #2）：旧远程尝试挂在 probe 时切回本机（连接换代）、本机自配对写入 connecting；
    /// 放行旧 probe 后，旧尝试的收束不得把本机的 connecting 改成 notPaired。
    func testStaleRemoteAttemptKeepsLocalConnectingAfterSwitch() async {
        let r = Rig()
        r.settings.connectionMode = .remote
        await r.session.loadCredentials(mode: .remote)
        let gate = RMGate()
        let entered = RMBox(0), sends = RMBox(0)
        r.session.pairProbe = { _ in entered.value += 1; await gate.wait(); return spkiA }
        r.session.pairSend = { _, _, _ in sends.value += 1; return decodePair(#"{"deviceId":"d1","token":"t","spkiSha256":"\#(spkiA)"}"#) }
        let task = Task { @MainActor in await r.session.pairRemote(host: "mac.example.ts.net", port: 47821, code: "123456", expectedSpki: spkiA) }
        await waitUntil { entered.value > 0 }
        r.session.stopStream() // 切换器的连接换代
        r.settings.connectionMode = .local
        r.session.link = .connecting // 本机自配对写入的状态
        await gate.release()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(sends.value, 0)
        XCTAssertEqual(entered.value, 1, "确实进入了 probe（防止入口拒绝导致空过）")
        XCTAssertEqual(r.session.link, .connecting, "不覆盖切换后本机写入的 connecting")
    }

    /// 复制准入（纯函数）：过期、明文、回环、远程模式一律不复制；未过期 https 与二维码 payload 一致。
    func testCopyOnlyUnexpiredHTTPSLocalAndMatchesTheQRPayload() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = HookClient.PairCode(code: "123456", expiresT: Int((now.timeIntervalSince1970 + 600) * 1000))
        let expired = HookClient.PairCode(code: "123456", expiresT: Int((now.timeIntervalSince1970 - 1) * 1000))
        func portFile(_ transport: String) throws -> BridgeEngine.PortFile {
            try JSONDecoder().decode(BridgeEngine.PortFile.self, from: Data(#"{"hookPort":1,"apiPort":47821,"bind":"192.168.1.9","binds":["192.168.1.9"],"hostnames":[],"transport":"\#(transport)","tls":{"spkiSha256":"\#(spkiA)"}}"#.utf8))
        }
        let https = try portFile("https")
        let http = try portFile("http")

        let copied = PairingQR.copyText(mode: .local, code: fresh, at: now, portFile: https, reach: .lan)
        let qr = PairingQR.payload(code: fresh, at: now, portFile: https, reach: .lan)
        XCTAssertNotNil(copied)
        XCTAssertEqual(copied, qr, "未过期 https 的复制内容与二维码 payload 一致")
        XCTAssertTrue(copied?.contains("tls=1") ?? false)

        XCTAssertNil(PairingQR.copyText(mode: .local, code: expired, at: now, portFile: https, reach: .lan), "已过期不复制")
        XCTAssertNil(PairingQR.copyText(mode: .local, code: fresh, at: now.addingTimeInterval(601), portFile: https, reach: .lan), "点击时已过期（按点击时刻核对）")
        XCTAssertNil(PairingQR.copyText(mode: .local, code: fresh, at: now, portFile: http, reach: .lan), "明文不复制")
        XCTAssertNil(PairingQR.copyText(mode: .local, code: fresh, at: now, portFile: https, reach: .loopback), "回环不复制")
        XCTAssertNil(PairingQR.copyText(mode: .remote, code: fresh, at: now, portFile: https, reach: .lan), "远程模式不复制本机链接")
        XCTAssertNil(PairingQR.copyText(mode: .local, code: nil, at: now, portFile: https, reach: .lan), "没有码不复制")
    }

    /// 权限文案（纯函数）：可控 / 只读 / 未知；只有在线且已知只读才给指引。
    func testPermissionCopyGuidesOnlyForOnlineKnownReadonly() {
        XCTAssertEqual(RemotePermissionCopy.level(permission: "control"), .control)
        XCTAssertEqual(RemotePermissionCopy.level(permission: "readonly"), .readonly)
        XCTAssertEqual(RemotePermissionCopy.level(permission: nil), .unknown)
        XCTAssertEqual(RemotePermissionCopy.label(.control), "可控")
        XCTAssertEqual(RemotePermissionCopy.label(.readonly), "只读")
        XCTAssertEqual(RemotePermissionCopy.label(.unknown), "未知")
        XCTAssertNil(RemotePermissionCopy.guide(level: .control, link: .offline(LText("x"))), "控制 + 离线：无指引")
        XCTAssertNil(RemotePermissionCopy.guide(level: .control, link: .connected), "控制：无指引")
        XCTAssertNotNil(RemotePermissionCopy.guide(level: .readonly, link: .connected), "已知只读 + 在线：给指引")
        XCTAssertNil(RemotePermissionCopy.guide(level: .readonly, link: .offline(LText("x"))), "只读 + 离线：不给升权指引")
        XCTAssertNil(RemotePermissionCopy.guide(level: .unknown, link: .connected), "未知：不给升权指引")
    }

    /// 断开结果的提示映射（纯函数）：成功不提示；未确认自撤为警示；失败为错误。跨视图可见由视图层的公共状态承载。
    func testDisconnectOutcomeMapsToVisibleNotice() {
        XCTAssertNil(RemoteNotice.message(for: .done))
        XCTAssertEqual(RemoteNotice.message(for: .doneWithNote(LText("未确认"))), RemoteNotice.Message(text: "未确认", isWarning: true))
        XCTAssertEqual(RemoteNotice.message(for: .failed(LText("失败"))), RemoteNotice.Message(text: "失败", isWarning: false))
    }
}
