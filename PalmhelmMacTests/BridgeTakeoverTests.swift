import Darwin
import XCTest
@testable import PalmhelmMac

// issue #54：后台运行开关与接管。全部用假子进程、假进程表与临时数据目录；不启动真实 Bridge，不发真实信号。
// 包含 A1-208（O1-400 复审）的反例：每个反例都改成了「正确行为」的断言。

@MainActor
final class TakeoverFakeChild: EngineChild {
    let launch: EngineLaunch
    let pid: Int32?
    var isRunning = true
    var terminateCount = 0
    var killCount = 0
    init(_ l: EngineLaunch, pid: Int32) {
        launch = l
        self.pid = pid
    }
    func terminate() { terminateCount += 1 }
    func kill() { killCount += 1 }
}

/// 后台线程把读取结果交回测试用的小盒子。
final class ReadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var e: Error?
    func set(_ error: Error?) { lock.withLock { e = error } }
    var error: Error? { lock.withLock { e } }
}

/// 忽略 SIGTERM 的假子进程：terminate 不让它退出，只有 kill 才结束（A1 重放的场景）。
@MainActor
final class StubbornChild: EngineChild {
    let launch: EngineLaunch
    let pid: Int32?
    var isRunning = true
    var terminateCount = 0
    var killCount = 0
    init(_ l: EngineLaunch, pid: Int32) {
        launch = l
        self.pid = pid
    }
    func terminate() { terminateCount += 1 }
    func kill() {
        killCount += 1
        isRunning = false
        launch.onExit(9)
    }
}

/// 线程安全的网卡快照盒子：interfaceProvider 是 @Sendable，不能直接捕获主线程对象。
final class NicBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [NetInterface]
    init(_ v: [NetInterface]) { self.v = v }
    var value: [NetInterface] {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

/// 假进程表：pid → 此刻的进程信息；测试里 nil 表示进程已不存在。
final class FakeProcessProbe: BridgeProcessProbing, @unchecked Sendable {
    var table: [Int32: BridgeProcessSnapshot] = [:]
    func snapshot(pid: Int32) -> BridgeProcessSnapshot? { table[pid] }
}

/// 把「等待中的协程」交给测试控制（用于停在重启的 300ms 空窗里）。
final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    var isHeld: Bool { lock.withLock { cont != nil } }
    func hold() async {
        await withCheckedContinuation { c in lock.withLock { cont = c } }
    }
    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { cont = nil }; return cont }
        c?.resume()
    }
}

@MainActor
final class TakeoverRig {
    static let loopback = ListenBaseline(ListenResolution(lan: nil, tailscale: nil, intent: ListenIntent(lan: false, tailscale: false)))
    /// 旧进程启动时「想要」局域网、但当时没有 LAN 地址。
    static let lanWanted = ListenBaseline(ListenResolution(lan: nil, tailscale: nil, intent: ListenIntent(lan: true, tailscale: false)))

    let defaults: UserDefaults
    let settings: EngineSettings
    let engine: BridgeEngine
    let root: String
    let dataDir: String
    /// 假的内置 Bridge 文件（真实存在，BinaryDigest 才能取到摘要）。
    let binary: String
    let probe = FakeProcessProbe()
    let nicBox = NicBox([])
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var launched: [TakeoverFakeChild] = []
    var signals: [(pid: Int32, sig: Int32)] = []
    var nextPid: Int32 = 4242

    init(keepAfterQuit: Bool = false) throws {
        let suite = "palmhelm.o398.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        root = NSTemporaryDirectory() + "palmhelm-o398-\(UUID().uuidString)"
        dataDir = root + "/data"
        binary = root + "/palmhelm-bridge"
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary, contents: Data("v1".utf8))
        settings = EngineSettings(defaults: defaults, secretsReady: true)
        settings.binaryPath = binary
        settings.dataDir = dataDir
        settings.listenLan = false
        settings.listenTailscale = false
        settings.keepBridgeAfterQuit = keepAfterQuit
        let box = nicBox
        settings.interfaceProvider = { box.value }
        engine = BridgeEngine(settings: settings)
        wire(engine)
    }

    deinit {
        let r = root
        try? FileManager.default.removeItem(atPath: r)
    }

    /// 所有引擎共用的假接缝：不看真实网络、不启动真实进程、不读真实进程表、不发真实信号。
    func wire(_ e: BridgeEngine) {
        e.watchNetwork = false
        e.watchAdopted = false
        e.now = { [unowned self] in self.clock }
        e.processProbe = probe
        e.launcher = { [unowned self] l in
            let pid = self.nextPid
            self.nextPid += 1
            let child = TakeoverFakeChild(l, pid: pid)
            self.launched.append(child)
            self.probe.table[pid] = BridgeProcessSnapshot(pid: pid, startMicros: 1_000 + Int64(pid), executable: canonicalPath(self.binary))
            return child
        }
        e.sendSignal = { [unowned self] pid, sig in
            self.signals.append((pid, sig))
            self.probe.table[pid] = nil // 信号送达后进程消失
            return 0
        }
        // 长等待（防抖 / 限频，≥1 秒）挂起，由用例直接驱动 evaluateListen；短等待（重启的 200ms / 300ms）立即让出
        e.sleep = { d in
            if d >= .seconds(1) { try? await Task.sleep(for: .seconds(3600)) } else { await Task.yield() }
        }
    }

    /// 同一套假接缝的第二个引擎（模拟「关掉 App 再打开」）。
    func secondEngine() -> BridgeEngine {
        let e = BridgeEngine(settings: settings)
        wire(e)
        return e
    }

    /// 模拟一个上次退出时仍在运行的后台 Bridge：写入身份记录，并让假进程表里有它。
    func seedRunningBridge(
        pid: Int32 = 4242, startMicros: Int64? = nil, executable: String? = nil, digest: String? = nil,
        recordDataDir: String? = nil, listen: ListenBaseline = TakeoverRig.loopback, background: Bool = true,
        environment: [String: String]? = nil
    ) throws {
        let start = startMicros ?? (1_000 + Int64(pid))
        let exe = canonicalPath(executable ?? binary)
        let record = EngineChildRecord(
            background: background, pid: pid, startMicros: start, executable: exe,
            binaryDigest: digest ?? BinaryDigest.of(binary) ?? "",
            dataDir: canonicalPath(recordDataDir ?? dataDir),
            environment: environment ?? ["PATH": "/usr/bin", "BRIDGE_DATA_DIR": dataDir, "BRIDGE_LOCAL_API_BIND": "127.0.0.1"],
            listen: listen)
        try record.save(dataDir: dataDir)
        probe.table[pid] = BridgeProcessSnapshot(pid: pid, startMicros: start, executable: exe)
        let portFile = #"{"hookPort":1,"apiPort":47821,"bind":"127.0.0.1","transport":"http","version":"1.0.0"}"#
        try portFile.write(toFile: dataDir + "/local-api.json", atomically: true, encoding: .utf8)
    }
}

@MainActor
final class BridgeTakeoverPolicyTests: XCTestCase {
    private func record(digest: String = "d1", dataDir: String = "/d", exe: String = "/app/palmhelm-bridge", background: Bool = true) -> EngineChildRecord {
        EngineChildRecord(
            background: background, pid: 77, startMicros: 500, executable: canonicalPath(exe), binaryDigest: digest,
            dataDir: canonicalPath(dataDir), environment: [:], listen: TakeoverRig.loopback)
    }
    private func snap(start: Int64 = 500, exe: String = "/app/palmhelm-bridge", pid: Int32 = 77) -> BridgeProcessSnapshot {
        BridgeProcessSnapshot(pid: pid, startMicros: start, executable: exe)
    }
    private func decide(_ r: EngineChildRecord, _ s: BridgeProcessSnapshot?, dataDir: String = "/d", exe: String = "/app/palmhelm-bridge", digest: String? = "d1") -> TakeoverDecision {
        TakeoverPolicy.decide(record: r, snapshot: s, dataDir: dataDir, executable: exe, binaryDigest: digest)
    }

    func testSameDataDirAndContentAdopts() {
        XCTAssertEqual(decide(record(), snap()), .adopt)
    }

    func testDifferentContentDigestReplaces() {
        XCTAssertEqual(decide(record(), snap(), digest: "d2"), .replace)
    }

    func testReusedPidIsNotAdopted() {
        XCTAssertEqual(decide(record(), snap(start: 999)), .none)
    }

    func testProcessRunningOtherExecutableIsNotAdopted() {
        XCTAssertEqual(decide(record(), snap(exe: "/usr/local/bin/other")), .none)
    }

    func testBundledPathMismatchIsNotAdopted() {
        XCTAssertEqual(decide(record(), snap(), exe: "/elsewhere/palmhelm-bridge"), .none)
    }

    func testOtherDataDirIsNotAdopted() {
        XCTAssertEqual(decide(record(), snap(), dataDir: "/other"), .none)
    }

    func testMissingProcessIsNotAdopted() {
        XCTAssertEqual(decide(record(), nil), .none)
    }

    func testForegroundRecordIsNeverAdopted() {
        XCTAssertEqual(decide(record(background: false), snap()), .none, "前台进程（带父进程守护）不是可独立存活的后台进程")
    }

    func testUnreadableBinaryIsNotAdopted() {
        XCTAssertEqual(decide(record(), snap(), digest: nil), .none)
    }

    func testRedactionKeepsSecretOutOfRecordAndDropsParentPid() {
        let env = ["FEISHU_APP_SECRET": "super-secret-value", "BRIDGE_PARENT_PID": "123", "PATH": "/usr/bin"]
        let red = EngineChildRecord.redacted(env)
        XCTAssertNil(red["BRIDGE_PARENT_PID"])
        XCTAssertEqual(red["PATH"], "/usr/bin")
        XCTAssertFalse(red["FEISHU_APP_SECRET"]!.contains("super-secret-value"))
        XCTAssertTrue(red["FEISHU_APP_SECRET"]!.hasPrefix("sha256:"))
        XCTAssertEqual(red, EngineChildRecord.redacted(env), "同一机密指纹稳定，设置比较才不会误报")
    }
}

/// R1：共用的私有文件 seam（no-follow 读、fstat 校验、大小上限、0600 暂存 + 原子 rename）。
final class PrivateFileTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "palmhelm-o401-pf-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testWriteProducesPrivateFileAndLeavesNoStagingFile() throws {
        let path = dir + "/rec.json"
        try PrivateFile.writeAtomically(Data("hello".utf8), to: path)
        XCTAssertEqual(try PrivateFile.read(path), Data("hello".utf8))
        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["rec.json"], "暂存文件发布后不残留")
    }

    func testReadRefusesSymlinkRatherThanFollowingIt() throws {
        let target = dir + "/target.json"
        try PrivateFile.writeAtomically(Data("x".utf8), to: target)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.json", withDestinationPath: target)
        XCTAssertThrowsError(try PrivateFile.read(dir + "/link.json")) { error in
            XCTAssertEqual(error as? PrivateFile.Failure, .unsafe("symlink"))
        }
    }

    func testReadRefusesWidePermissions() throws {
        let path = dir + "/wide.json"
        try PrivateFile.writeAtomically(Data("x".utf8), to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        XCTAssertThrowsError(try PrivateFile.read(path)) { error in
            XCTAssertEqual(error as? PrivateFile.Failure, .unsafe("mode"))
        }
    }

    func testReadRefusesOversizedFile() throws {
        let path = dir + "/big.json"
        try PrivateFile.writeAtomically(Data(count: PrivateFile.defaultMaxBytes + 1), to: path)
        XCTAssertThrowsError(try PrivateFile.read(path)) { error in
            XCTAssertEqual(error as? PrivateFile.Failure, .unsafe("size"))
        }
    }

    func testWriteOverSymlinkReplacesTheLinkNotItsTarget() throws {
        let target = dir + "/target.json"
        try PrivateFile.writeAtomically(Data("keep".utf8), to: target)
        let link = dir + "/rec.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        try PrivateFile.writeAtomically(Data("new".utf8), to: link)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "keep", "目标文件不被改写")
        XCTAssertEqual(try PrivateFile.read(link), Data("new".utf8))
    }

    /// R1a：FIFO 没有写入方时不能卡住调用方；必须被拒绝，且有超时上限。
    func testFifoIsRejectedWithoutBlocking() throws {
        let path = dir + "/fifo"
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let box = ReadOutcome()
        let done = expectation(description: "read returns")
        DispatchQueue.global().async {
            do { _ = try PrivateFile.read(path); box.set(nil) } catch { box.set(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(box.error as? PrivateFile.Failure, .unsafe("not_regular"), "FIFO 被拒绝（若阻塞则在 5 秒超时处失败）")
    }

    /// R1b：暂存文件的权限由 fchmod 显式设为 0600 并核实。创建权限被 umask 削成 0400 时，发布的记录仍是 0600，且能被自己读回。
    /// 这里用 createMode 模拟 umask 0277 的结果（0600 & ~0277 = 0400），不修改进程全局 umask。
    func testStagedFileIsForcedPrivateWhenCreationModeIsRestricted() throws {
        let path = dir + "/restricted.json"
        try PrivateFile.writeAtomically(Data("x".utf8), to: path, createMode: 0o400)
        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "发布的记录是 0600")
        XCTAssertEqual(try PrivateFile.read(path), Data("x".utf8), "自己写的记录能被自己读回")
    }

    func testFailedPublishLeavesNoStagingFileAndThrows() throws {
        let path = dir + "/blocked"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        XCTAssertThrowsError(try PrivateFile.writeAtomically(Data("x".utf8), to: path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["blocked"], "发布失败时删除暂存文件")
    }
}

@MainActor
final class BridgeTakeoverEngineTests: XCTestCase {
    func testAdoptsRunningBridgeWithSameDataDirAndContent() async throws {
        let rig = try TakeoverRig()
        try rig.seedRunningBridge()
        await rig.engine.takeOverRunningBridge()
        XCTAssertEqual(rig.engine.status, .running)
        XCTAssertTrue(rig.engine.isBackground)
        XCTAssertTrue(rig.engine.childRunning)
        XCTAssertEqual(rig.engine.displayStatus, "后台运行中")
        XCTAssertEqual(rig.engine.portFile?.apiPort, 47821, "接管后读取上次的端口文件")
        XCTAssertTrue(rig.launched.isEmpty, "接管不会再启动一份")
        XCTAssertTrue(rig.signals.isEmpty, "接管不发任何信号")
        XCTAssertTrue(rig.engine.logs.contains { $0.contains("接管后台运行中的 Bridge（pid 4242）") })
    }

    /// R3：版本不同时整个替换（停旧、起新）完成，即使「随 App 启动」关闭；AppBoot 与这里走同一个入口 bootOnLaunch。
    func testReplacementCompletesEvenWhenAutoStartIsOff() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        rig.settings.autoStart = false
        try rig.seedRunningBridge(digest: "old-binary-digest")
        await rig.engine.bootOnLaunch()
        XCTAssertEqual(rig.signals.map(\.sig), [SIGTERM], "旧版本收到 SIGTERM")
        XCTAssertEqual(rig.launched.count, 1, "新版本已经启动，不依赖「随 App 启动」")
        XCTAssertEqual(rig.engine.status, .starting)
        XCTAssertTrue(rig.engine.childRunning)
        XCTAssertTrue(rig.engine.isBackground)
    }

    func testReplacementWithAutoStartOnAlsoRelaunchesOnce() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        try rig.seedRunningBridge(digest: "old-binary-digest")
        await rig.engine.bootOnLaunch()
        XCTAssertEqual(rig.signals.map(\.sig), [SIGTERM])
        XCTAssertEqual(rig.launched.count, 1, "自动启动不会再起第二份")
    }

    func testReplacedRecordIsRewrittenForTheNewProcess() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        try rig.seedRunningBridge(digest: "old-binary-digest")
        rig.nextPid = 5001
        await rig.engine.bootOnLaunch()
        let record = try XCTUnwrap(EngineChildRecord.load(dataDir: rig.dataDir))
        XCTAssertEqual(record.pid, 5001, "新进程的身份替换旧记录")
        XCTAssertEqual(record.binaryDigest, BinaryDigest.of(rig.binary))
    }

    func testIdentityMismatchNeverAdoptsOrKills() async throws {
        // pid 被复用：进程表里同一个 pid 的启动时间已经不同
        let reused = try TakeoverRig()
        try reused.seedRunningBridge(pid: 4242, startMicros: 12_345)
        reused.probe.table[4242] = BridgeProcessSnapshot(pid: 4242, startMicros: 99_999, executable: canonicalPath(reused.binary))
        await reused.engine.takeOverRunningBridge()
        XCTAssertFalse(reused.engine.childRunning)
        XCTAssertTrue(reused.signals.isEmpty, "身份不符：不杀")
        XCTAssertTrue(reused.launched.isEmpty)
        XCTAssertNotNil(EngineChildRecord.load(dataDir: reused.dataDir), "进程仍在：记录保留，不擅自删除")

        let other = try TakeoverRig()
        try other.seedRunningBridge(executable: "/usr/local/bin/other")
        await other.engine.takeOverRunningBridge()
        XCTAssertFalse(other.engine.childRunning)
        XCTAssertTrue(other.signals.isEmpty, "不是内置 Bridge：不杀")
        XCTAssertTrue(other.launched.isEmpty)
    }

    func testRecordedDataDirMismatchIsNotAdopted() async throws {
        let rig = try TakeoverRig()
        try rig.seedRunningBridge(recordDataDir: rig.root + "/another-data")
        await rig.engine.takeOverRunningBridge()
        XCTAssertFalse(rig.engine.childRunning)
        XCTAssertTrue(rig.signals.isEmpty)
    }

    func testStaleRecordIsRemovedWhenProcessGone() async throws {
        let rig = try TakeoverRig()
        try rig.seedRunningBridge()
        rig.probe.table[4242] = nil
        await rig.engine.takeOverRunningBridge()
        XCTAssertFalse(rig.engine.childRunning)
        XCTAssertNil(EngineChildRecord.load(dataDir: rig.dataDir))
    }

    func testStopOnAdoptedBridgeSendsTermAndClearsRecord() async throws {
        let rig = try TakeoverRig()
        try rig.seedRunningBridge()
        await rig.engine.takeOverRunningBridge()
        await rig.engine.stop()
        XCTAssertEqual(rig.signals.map(\.sig), [SIGTERM])
        XCTAssertEqual(rig.engine.status, .stopped)
        XCTAssertFalse(rig.engine.childRunning)
        XCTAssertNil(EngineChildRecord.load(dataDir: rig.dataDir))
    }

    func testAdoptedBridgeExitingOnItsOwnIsCleared() async throws {
        let rig = try TakeoverRig()
        rig.engine.watchAdopted = true
        rig.engine.sleep = { _ in try? await Task.sleep(for: .milliseconds(5)) }
        try rig.seedRunningBridge()
        await rig.engine.takeOverRunningBridge()
        XCTAssertEqual(rig.engine.status, .running)
        rig.probe.table[4242] = nil // 外部结束
        for _ in 0..<400 where rig.engine.status == .running { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(rig.engine.childRunning)
        XCTAssertEqual(rig.engine.status, .stopped)
        XCTAssertNil(EngineChildRecord.load(dataDir: rig.dataDir))
    }

    /// 真正存活的旧后台 Bridge（pid 与启动时间均相符）、但 App 当前二进制不同使接管被拒：一次失败的前台启动不能删掉它的记录。
    func testFailedForegroundStartKeepsLiveForeignRecord() async throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        try rig.seedRunningBridge(pid: 4242, executable: "/usr/local/bin/other-bridge")
        await rig.engine.takeOverRunningBridge()
        XCTAssertFalse(rig.engine.childRunning)
        rig.nextPid = 5001
        rig.engine.start()
        XCTAssertNotNil(rig.launched.last?.launch.environment["BRIDGE_PARENT_PID"], "前台启动")
        rig.launched.last?.isRunning = false
        rig.launched.last?.launch.onExit(1)
        for _ in 0..<200 where rig.engine.status == .starting { try await Task.sleep(for: .milliseconds(5)) } // 等退出回调处理完
        XCTAssertNotEqual(rig.engine.status, .starting)
        let record = try XCTUnwrap(EngineChildRecord.load(dataDir: rig.dataDir), "旧后台进程的记录必须保留")
        XCTAssertEqual(record.pid, 4242)
    }

    /// 另一个存活的后台 Bridge（未被接管）仍有记录：后台启动的新 child 必须被停掉，旧记录原样保留，旧进程不被触碰。
    func testBackgroundPublishDoesNotReplaceLiveForeignRecord() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        try rig.seedRunningBridge(pid: 4242, executable: "/usr/local/bin/other-bridge")
        let before = try Data(contentsOf: EngineChildRecord.url(dataDir: rig.dataDir))
        var child: StubbornChild?
        rig.engine.launcher = { [unowned rig] launch in
            let c = StubbornChild(launch, pid: 5001)
            child = c
            rig.probe.table[5001] = BridgeProcessSnapshot(pid: 5001, startMicros: 5001, executable: canonicalPath(rig.binary))
            return c
        }
        rig.engine.start()
        for _ in 0..<2000 {
            if case .failed = rig.engine.status { break }
            await Task.yield()
        }
        let c = try XCTUnwrap(child)
        XCTAssertEqual(c.terminateCount, 1, "新 child 先 SIGTERM")
        XCTAssertFalse(c.isRunning, "新 child 确认退出")
        XCTAssertFalse(rig.engine.childRunning)
        XCTAssertEqual(try Data(contentsOf: EngineChildRecord.url(dataDir: rig.dataDir)), before, "旧记录原样保留")
        XCTAssertEqual(EngineChildRecord.load(dataDir: rig.dataDir)?.pid, 4242)
        XCTAssertNotNil(rig.probe.table[4242], "旧进程仍在")
        XCTAssertTrue(rig.signals.allSatisfy { $0.pid != 4242 }, "不向旧进程发信号")
    }

    /// PID 被无关进程复用（进程仍在，但启动时间不同）：不是同一个进程，后台启动照常发布，不被误判为存活。
    func testBackgroundPublishIgnoresReusedPid() throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        try rig.seedRunningBridge(pid: 4242, startMicros: 12_345)
        rig.probe.table[4242] = BridgeProcessSnapshot(pid: 4242, startMicros: 99_999, executable: "/usr/bin/unrelated")
        rig.nextPid = 5001
        rig.engine.start()
        XCTAssertEqual(rig.engine.status, .starting, "不应因复用的 pid 被 abandon")
        XCTAssertEqual(EngineChildRecord.load(dataDir: rig.dataDir)?.pid, 5001)
    }

    /// PID 复用的陈旧记录：前台启动时清掉。
    func testForegroundStartClearsRecordWithReusedPid() throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        try rig.seedRunningBridge(pid: 4242, startMicros: 12_345)
        rig.probe.table[4242] = BridgeProcessSnapshot(pid: 4242, startMicros: 99_999, executable: "/usr/bin/unrelated")
        rig.nextPid = 5001
        rig.engine.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: EngineChildRecord.url(dataDir: rig.dataDir).path))
    }

    /// 记录所指进程已经不存在（陈旧）：后台启动照常发布新记录。
    func testBackgroundPublishReplacesStaleRecord() throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        try rig.seedRunningBridge(pid: 4242)
        rig.probe.table[4242] = nil
        rig.nextPid = 5001
        rig.engine.start()
        XCTAssertEqual(EngineChildRecord.load(dataDir: rig.dataDir)?.pid, 5001)
    }

    /// 后台 Bridge 自己退出时清掉自己的记录（只删 pid 相符的那份）。
    func testOwnBackgroundChildExitClearsItsRecord() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        rig.engine.start()
        XCTAssertNotNil(EngineChildRecord.load(dataDir: rig.dataDir))
        rig.launched[0].isRunning = false
        rig.launched[0].launch.onExit(0)
        for _ in 0..<200 where rig.engine.status == .starting { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotEqual(rig.engine.status, .starting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EngineChildRecord.url(dataDir: rig.dataDir).path))
    }

    /// 记录所指的进程已不存在：前台启动时清掉这份陈旧记录。
    func testForegroundStartClearsStaleRecordWhoseProcessIsGone() throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        try rig.seedRunningBridge(pid: 4242)
        rig.probe.table[4242] = nil
        rig.nextPid = 5001 // 新子进程用别的 pid，否则假进程表里 4242 又“活”了
        rig.engine.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: EngineChildRecord.url(dataDir: rig.dataDir).path))
    }

    func testFreshBackgroundLaunchOmitsParentPidAndRecordsIdentity() throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        rig.engine.start()
        XCTAssertEqual(rig.launched.count, 1)
        XCTAssertNil(rig.launched[0].launch.environment["BRIDGE_PARENT_PID"])
        XCTAssertTrue(rig.engine.isBackground)
        XCTAssertTrue(rig.engine.keepsAfterQuit)
        let record = try XCTUnwrap(EngineChildRecord.load(dataDir: rig.dataDir))
        XCTAssertEqual(record.pid, 4242)
        XCTAssertTrue(record.background)
        XCTAssertNil(record.environment["BRIDGE_PARENT_PID"])
    }

    /// R6：前台进程（带父进程号）一律不写记录，所以它不会被当作可接管的后台进程。
    func testForegroundLaunchKeepsParentPidWritesNoRecordAndIsNotBackground() throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        rig.engine.start()
        XCTAssertNotNil(rig.launched[0].launch.environment["BRIDGE_PARENT_PID"])
        XCTAssertFalse(rig.engine.isBackground)
        XCTAssertFalse(rig.engine.keepsAfterQuit)
        XCTAssertNil(EngineChildRecord.load(dataDir: rig.dataDir), "前台进程不写接管记录")
    }

    /// A1-208 R6 反例：App 崩溃后残留的前台进程，下一次打开不能被当成后台进程接管。
    func testForegroundCrashLeavesNothingToTakeOver() async throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        rig.engine.start()
        let next = rig.secondEngine()
        await next.takeOverRunningBridge()
        XCTAssertFalse(next.isBackground)
        XCTAssertFalse(next.childRunning)
        XCTAssertTrue(rig.signals.isEmpty, "不杀前台进程")
        XCTAssertEqual(QuitCoordinator(settings: rig.settings, engine: rig.engine, confirmer: AcceptQuit()).decide(event: nil), .stopBridgeThenQuit,
                       "前台模式的退出路径保持 0fda1b1：先停 Bridge")
    }

    func testChangingKeepSettingMarksRestartPendingUntilNextStart() throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        rig.engine.start()
        XCTAssertFalse(rig.engine.pendingRestart)
        rig.settings.keepBridgeAfterQuit = true
        XCTAssertTrue(rig.engine.pendingRestart, "开关切换后，当前子进程的模式不同：需要重启才生效")
        rig.settings.keepBridgeAfterQuit = false
        XCTAssertFalse(rig.engine.pendingRestart)
    }

    /// R7：飞书配置完整、设置不变：启动后与接管后都不应要求重启（指纹只转换一次）。
    func testFeishuConfiguredSettingsNeedNoRestartAfterTakeover() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        rig.settings.feishuEnabled = true
        rig.settings.feishuAppId = "cli_fixture"
        rig.settings.feishuOwnerOpenId = "ou_fixture"
        rig.settings.feishuChatId = "oc_fixture"
        rig.settings.feishuAppSecret = "fake-fixture-secret"
        rig.engine.start()
        XCTAssertFalse(rig.engine.pendingRestart)
        let next = rig.secondEngine()
        await next.takeOverRunningBridge()
        XCTAssertTrue(next.isBackground)
        XCTAssertFalse(next.pendingRestart, "设置未改变：接管后不应显示待生效")
    }

    func testBackgroundSettingRoundTripsAndDefaultsOff() {
        let suite = "palmhelm.o398.default.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = EngineSettings(defaults: d, secretsReady: true)
        XCTAssertFalse(s.keepBridgeAfterQuit)
        XCTAssertTrue(s.confirmQuit)
        s.keepBridgeAfterQuit = true
        XCTAssertTrue(EngineSettings(defaults: d, secretsReady: true).keepBridgeAfterQuit)
        XCTAssertNil(s.environment()["BRIDGE_PARENT_PID"], "后台：不交出父进程号")
        s.keepBridgeAfterQuit = false
        XCTAssertNotNil(s.environment()["BRIDGE_PARENT_PID"], "默认关：保持父进程守护")
    }

    /// R1：记录文件被替换成符号链接（指向一份合法记录）：拒绝，不接管、不杀。
    func testSymlinkedRecordIsRejected() async throws {
        let rig = try TakeoverRig()
        try rig.seedRunningBridge()
        let url = EngineChildRecord.url(dataDir: rig.dataDir)
        let outside = URL(fileURLWithPath: rig.root).appendingPathComponent("outside-record.json")
        try FileManager.default.moveItem(at: url, to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        XCTAssertNil(EngineChildRecord.load(dataDir: rig.dataDir))
        await rig.engine.takeOverRunningBridge()
        XCTAssertFalse(rig.engine.childRunning)
        XCTAssertTrue(rig.signals.isEmpty)
        XCTAssertTrue(rig.launched.isEmpty)
    }

    /// R1：记录权限放宽（0666）：拒绝。
    func testWidePermissionRecordIsRejected() async throws {
        let rig = try TakeoverRig()
        try rig.seedRunningBridge()
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: EngineChildRecord.url(dataDir: rig.dataDir).path)
        await rig.engine.takeOverRunningBridge()
        XCTAssertFalse(rig.engine.childRunning)
        XCTAssertTrue(rig.signals.isEmpty)
    }

    /// R2 反例：元数据（大小、修改时间、inode）全部保留、内容不同的版本，必须被当作不同版本替换。
    func testInPlaceUpdateWithPreservedMetadataIsReplaced() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        try rig.seedRunningBridge() // 记录的是 v1 的内容摘要
        var before = stat()
        XCTAssertEqual(stat(rig.binary, &before), 0)
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: rig.binary))
        try fh.write(contentsOf: Data("v2".utf8))
        try fh.close()
        let times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(rig.binary.withCString { path in times.withUnsafeBufferPointer { utimensat(AT_FDCWD, path, $0.baseAddress, 0) } }, 0)
        var after = stat()
        XCTAssertEqual(stat(rig.binary, &after), 0)
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec, "修改时间已恢复，元数据未变")
        await rig.engine.takeOverRunningBridge()
        XCTAssertEqual(rig.signals.map(\.sig), [SIGTERM], "内容不同：替换，而不是接管")
        XCTAssertEqual(rig.launched.count, 1, "替换完成：新版本已启动")
        XCTAssertTrue(rig.engine.childRunning)
    }
}

/// 接管来的 Bridge 接入网络地址监听：基线是旧进程实际冻结的监听（R4），地址变化 → 防抖 → 限频 → 停接管进程 → 按当前设置启动。
@MainActor
final class BridgeTakeoverNetworkTests: XCTestCase {
    private func lanRig(keepAfterQuit: Bool = false) throws -> TakeoverRig {
        let rig = try TakeoverRig(keepAfterQuit: keepAfterQuit)
        rig.settings.listenLan = true
        rig.settings.tls = true
        return rig
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// 让 ListenWatch 看到一次地址变化并走完防抖与限频，决策为重启。
    private func changeAddress(_ rig: TakeoverRig, to nics: [NetInterface]) {
        rig.nicBox.value = nics
        rig.clock = rig.clock.addingTimeInterval(31) // 过启动后的 30 秒限频窗口
        rig.engine.evaluateListen() // 记下变化，等防抖
        rig.clock = rig.clock.addingTimeInterval(4) // 过 3 秒防抖
        rig.engine.evaluateListen() // 决策 .restart
    }

    func testAdoptedBridgeRestartsWhenLanAddressAppears() async throws {
        let rig = try lanRig()
        try rig.seedRunningBridge(listen: TakeoverRig.lanWanted)
        await rig.engine.takeOverRunningBridge()
        XCTAssertEqual(rig.engine.status, .running)
        changeAddress(rig, to: [NetInterface(name: "en0", ip: "192.168.1.9")])
        try await waitUntil { !rig.launched.isEmpty }
        XCTAssertEqual(rig.signals.map(\.sig), [SIGTERM], "先 SIGTERM 停掉接管的进程，并等待其退出")
        XCTAssertEqual(rig.signals.first?.pid, 4242)
        XCTAssertEqual(rig.launched.count, 1, "然后按当前设置启动新进程")
        XCTAssertTrue(rig.launched[0].launch.environment["BRIDGE_LOCAL_API_BIND"]?.contains("192.168.1.9") ?? false, "新进程监听新地址")
        XCTAssertEqual(rig.engine.status, .starting)
        XCTAssertTrue(rig.engine.networkRestarting, "启动中：「网络变化，正在重新监听…」保持到 bridge_started")
        XCTAssertTrue(rig.engine.childRunning)
    }

    /// A1-208 R4 反例：旧 Bridge 只监听回环；App 关闭期间局域网出现；重新打开接管时必须发现这次变化并重启。
    func testNetworkChangedWhileAppWasAwayIsRestarted() async throws {
        let rig = try lanRig(keepAfterQuit: true)
        try rig.seedRunningBridge(listen: TakeoverRig.lanWanted) // 旧进程冻结的是「无局域网地址」
        rig.nicBox.value = [NetInterface(name: "en0", ip: "192.168.1.9")]
        await rig.engine.takeOverRunningBridge()
        XCTAssertTrue(rig.engine.pendingRestart, "接管后立即对照一次：与冻结的监听不同，待重启")
        rig.clock = rig.clock.addingTimeInterval(31)
        rig.engine.evaluateListen()
        rig.clock = rig.clock.addingTimeInterval(10)
        rig.engine.evaluateListen()
        try await waitUntil { !rig.launched.isEmpty }
        XCTAssertEqual(rig.signals.map(\.sig), [SIGTERM])
        XCTAssertEqual(rig.launched.count, 1)
        XCTAssertTrue(rig.launched[0].launch.environment["BRIDGE_LOCAL_API_BIND"]?.contains("192.168.1.9") ?? false)
    }

    func testUnchangedAddressDoesNotRestartAdoptedBridge() async throws {
        let rig = try lanRig()
        rig.nicBox.value = [NetInterface(name: "en0", ip: "192.168.1.9")]
        try rig.seedRunningBridge(listen: ListenBaseline(ListenResolution(lan: "192.168.1.9", tailscale: nil, intent: ListenIntent(lan: true, tailscale: false))))
        await rig.engine.takeOverRunningBridge()
        XCTAssertEqual(rig.engine.status, .running)
        rig.clock = rig.clock.addingTimeInterval(31)
        rig.engine.evaluateListen()
        rig.clock = rig.clock.addingTimeInterval(10)
        rig.engine.evaluateListen()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(rig.signals.isEmpty, "地址没变：不重启")
        XCTAssertTrue(rig.launched.isEmpty)
        XCTAssertEqual(rig.engine.status, .running)
    }

    func testRestartAfterAddressChangeUsesCurrentBackgroundSetting() async throws {
        let rig = try lanRig(keepAfterQuit: false)
        try rig.seedRunningBridge(listen: TakeoverRig.lanWanted)
        await rig.engine.takeOverRunningBridge()
        rig.settings.keepBridgeAfterQuit = true // 用户在接管期间打开了后台运行
        changeAddress(rig, to: [NetInterface(name: "en0", ip: "192.168.1.9")])
        try await waitUntil { !rig.launched.isEmpty }
        XCTAssertEqual(rig.launched.count, 1)
        XCTAssertNil(rig.launched[0].launch.environment["BRIDGE_PARENT_PID"], "重启按当前设置：后台运行，不交出父进程号")
        XCTAssertTrue(rig.engine.isBackground)
        XCTAssertFalse(rig.engine.pendingRestart, "重启后的进程已经是新设置，没有待生效的更改")
    }
}

/// R5：后台重启的空窗（旧的已停、新的还没起）里不能退出 App。
@MainActor
final class BackgroundRestartQuitTests: XCTestCase {
    func testQuitDuringBackgroundNetworkRestartWaitsForReplacement() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        rig.settings.listenLan = true
        rig.settings.tls = true
        try rig.seedRunningBridge(listen: TakeoverRig.lanWanted)
        await rig.engine.takeOverRunningBridge()
        let gate = SleepGate()
        rig.engine.sleep = { d in
            if d == .milliseconds(300) { await gate.hold() } else if d >= .seconds(1) { try? await Task.sleep(for: .seconds(3600)) } else { await Task.yield() }
        }
        rig.nicBox.value = [NetInterface(name: "en0", ip: "192.168.1.9")]
        rig.clock = rig.clock.addingTimeInterval(31); rig.engine.evaluateListen()
        rig.clock = rig.clock.addingTimeInterval(4); rig.engine.evaluateListen()
        for _ in 0..<400 where !gate.isHeld { await Task.yield() }
        XCTAssertTrue(gate.isHeld, "停在旧进程已停、新进程未起的空窗")
        XCTAssertFalse(rig.engine.childRunning)
        XCTAssertTrue(rig.launched.isEmpty)

        let quit = QuitCoordinator(settings: rig.settings, engine: rig.engine, confirmer: AcceptQuit()).decide(event: nil)
        XCTAssertEqual(quit, .deferUntilRestartDone, "空窗里不能直接退出：会留下零个 Bridge")

        gate.release()
        for _ in 0..<400 where rig.launched.isEmpty { await Task.yield() }
        XCTAssertEqual(rig.launched.count, 1, "替换完成")
        XCTAssertEqual(QuitCoordinator(settings: rig.settings, engine: rig.engine, confirmer: AcceptQuit()).afterConfirmation(), .quitNow,
                       "替换完成后：后台 Bridge 保留，直接退出")
        XCTAssertTrue(rig.engine.childRunning)
    }

    /// R5b：版本替换（接管分支的 replace）也是后台重启事务：替换过程中退出，要等新进程起来后才退出。
    func testQuitDuringBackgroundReplacementWaitsForNewProcess() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        try rig.seedRunningBridge(digest: "old-version")
        let gate = SleepGate()
        rig.engine.sleep = { d in
            if d == .milliseconds(300) { await gate.hold() } else if d >= .seconds(1) { try? await Task.sleep(for: .seconds(3600)) } else { await Task.yield() }
        }
        let boot = Task { @MainActor in await rig.engine.bootOnLaunch() }
        for _ in 0..<400 where !gate.isHeld { await Task.yield() }
        XCTAssertTrue(gate.isHeld, "停在旧版本已停、新版本未起的空窗")
        XCTAssertEqual(rig.signals.map(\.sig), [SIGTERM])
        XCTAssertFalse(rig.engine.childRunning)
        let confirmer = AcceptQuit()
        XCTAssertEqual(QuitCoordinator(settings: rig.settings, engine: rig.engine, confirmer: confirmer).decide(event: nil), .deferUntilRestartDone)
        gate.release()
        await boot.value
        XCTAssertEqual(rig.launched.count, 1, "新版本已经起来")
        XCTAssertEqual(QuitCoordinator(settings: rig.settings, engine: rig.engine, confirmer: confirmer).afterConfirmation(), .quitNow,
                       "新进程起来之后，退出时保留后台 Bridge")
    }

    /// R1c：发布失败后，忽略 TERM 的子进程必须经有界停机被 SIGKILL 并确认退出，之后才显示已停止。
    func testRecordPublicationFailureStopsStubbornChildWithBoundedKill() async throws {
        let rig = try TakeoverRig(keepAfterQuit: true)
        try FileManager.default.createDirectory(at: EngineChildRecord.url(dataDir: rig.dataDir), withIntermediateDirectories: true)
        var child: StubbornChild?
        rig.engine.launcher = { [unowned rig] launch in
            let c = StubbornChild(launch, pid: 4242)
            child = c
            rig.probe.table[4242] = BridgeProcessSnapshot(pid: 4242, startMicros: 5242, executable: canonicalPath(rig.binary))
            return c
        }
        rig.engine.start()
        for _ in 0..<2000 {
            if case .failed = rig.engine.status { break }
            await Task.yield()
        }
        let c = try XCTUnwrap(child)
        XCTAssertEqual(c.terminateCount, 1, "先发 SIGTERM")
        XCTAssertEqual(c.killCount, 1, "忽略 SIGTERM：超时后 SIGKILL")
        XCTAssertFalse(c.isRunning, "确认进程真正退出")
        XCTAssertFalse(rig.engine.childRunning)
        XCTAssertFalse(rig.engine.isBackground)
        guard case .failed(let reason) = rig.engine.status else { return XCTFail("应显示失败/已停止：\(rig.engine.status)") }
        XCTAssertTrue(reason.text.contains("已停止"))
        XCTAssertTrue(rig.engine.displayStatus.hasPrefix("启动失败"), "界面不能显示「后台运行中」")
    }

    func testForegroundRestartKeepsOriginalQuitPath() throws {
        let rig = try TakeoverRig(keepAfterQuit: false)
        rig.engine.start()
        XCTAssertEqual(QuitCoordinator(settings: rig.settings, engine: rig.engine, confirmer: AcceptQuit()).decide(event: nil), .stopBridgeThenQuit)
        XCTAssertFalse(rig.engine.backgroundRestartInFlight)
    }
}

/// 只允许接受、不写任何偏好的确认替身（A1-208 反例共用）。
@MainActor
struct AcceptQuit: QuitConfirming {
    func confirm(keepsAfterQuit: Bool) -> QuitAnswer { QuitAnswer(quit: true, suppress: false) }
}

/// 系统进程表的只读探测：只读取测试宿主自己和一个不存在的 pid，不启动、不发信号。
final class SystemProcessProbeTests: XCTestCase {
    private func realPathOf(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buf) != nil ? String(cString: buf) : path
    }

    func testReadsOwnProcessAndRejectsMissingPid() throws {
        let own = try XCTUnwrap(SystemProcessProbe().snapshot(pid: getpid()))
        XCTAssertEqual(own.pid, getpid())
        XCTAssertGreaterThan(own.startMicros, 0)
        // proc_pidpath 给出内核记录的真实路径（/private/tmp 下的 DerivedData 会是 /private/tmp/…）；两边都用 realpath 比较，不做字面比较。
        XCTAssertEqual(realPathOf(own.executable), realPathOf(try XCTUnwrap(Bundle.main.executablePath)))
        XCTAssertNil(SystemProcessProbe().snapshot(pid: 2_000_000_000))
        XCTAssertNil(SystemProcessProbe().snapshot(pid: 1), "launchd 等系统进程不作为接管对象")
    }
}

/// 内容摘要：只在启动与接管时计算；内容变化摘要变化，元数据保留也一样。
final class BinaryDigestTests: XCTestCase {
    func testDigestTracksContentNotMetadata() throws {
        let dir = NSTemporaryDirectory() + "palmhelm-o401-digest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/bin"
        FileManager.default.createFile(atPath: path, contents: Data("aaaa".utf8))
        let a = try XCTUnwrap(BinaryDigest.of(path))
        XCTAssertEqual(a, BinaryDigest.of(path), "同一内容摘要稳定")
        FileManager.default.createFile(atPath: path, contents: Data("bbbb".utf8))
        XCTAssertNotEqual(BinaryDigest.of(path), a)
        XCTAssertNil(BinaryDigest.of(dir + "/missing"))
    }
}
