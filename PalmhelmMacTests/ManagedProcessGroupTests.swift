import Darwin
import Foundation
import XCTest
@testable import PalmhelmMac

// #107：Mac 对已确认托管的 Bridge 的强杀。真实进程只用本测试自己创建的 helper（/bin/sh + sleep），不碰正式 App / Bridge / 全机 sleep。

private final class GroupProbe: BridgeProcessProbing, @unchecked Sendable {
    var table: [Int32: BridgeProcessSnapshot] = [:]
    var groups: [Int32: Int32] = [:]
    func snapshot(pid: Int32) -> BridgeProcessSnapshot? { table[pid] }
    func processGroup(pid: Int32) -> Int32? { groups[pid] }
}

@MainActor final class ManagedProcessGroupTests: XCTestCase {
    private var spawned: [pid_t] = []
    private var groups: [pid_t] = []
    private var dir = ""

    override func setUp() {
        dir = NSTemporaryDirectory() + "mpg-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for g in groups { _ = Darwin.kill(-g, SIGKILL) }
        for p in spawned { _ = Darwin.kill(p, SIGKILL); var st: Int32 = 0; _ = waitpid(p, &st, WNOHANG) }
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: helper 进程

    private func spawn(_ path: String, _ args: [String], ownGroup: Bool) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if ownGroup {
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attr, 0)
        }
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, path, nil, &attr, argv, environ)
        XCTAssertEqual(rc, 0)
        spawned.append(pid)
        if ownGroup { groups.append(pid) }
        return pid
    }

    /// 假 Bridge 根（sh）+ 继承其进程组的 sleep 子进程；返回（根 pid，子 pid）。
    private func fakeBridge(ownGroup: Bool) throws -> (root: pid_t, child: pid_t) {
        let file = dir + "/child-\(UUID().uuidString)"
        let root = try spawn("/bin/sh", ["-c", "sleep 300 & echo $! > \(file); wait"], ownGroup: ownGroup)
        var child: pid_t = 0
        for _ in 0..<100 {
            if let s = try? String(contentsOfFile: file, encoding: .utf8), let n = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { child = n; break }
            usleep(30_000)
        }
        XCTAssertGreaterThan(child, 1, "helper 子进程没有起来")
        spawned.append(child)
        return (root, child)
    }

    private func alive(_ pid: pid_t) -> Bool { Darwin.kill(pid, 0) == 0 || errno != ESRCH }

    /// 等进程消失；根进程是本测试的子进程，先 waitpid 回收，不把僵尸当存活。
    private func gone(_ pid: pid_t, isOurChild: Bool) -> Bool {
        for _ in 0..<100 {
            if isOurChild { var st: Int32 = 0; _ = waitpid(pid, &st, WNOHANG) }
            if !alive(pid) { return true }
            usleep(30_000)
        }
        return false
    }

    private func identity(_ pid: pid_t) throws -> BridgeProcessSnapshot { try XCTUnwrap(SystemProcessProbe().snapshot(pid: pid)) }

    private func realSignal(_ pid: Int32, _ sig: Int32) -> Int32 { systemSignal(pid, sig) }

    // MARK: 真实进程

    func testSinglePidKillLeavesTheChildAliveButTheManagedGroupKillRemovesBoth() throws {
        let sentinel = try spawn("/bin/sleep", ["300"], ownGroup: true) // 无关的另一个进程组
        // 对照：旧行为（单 PID）→ 根没了，子进程存活
        let legacy = try fakeBridge(ownGroup: true)
        let legacySnap = try identity(legacy.root)
        let old = ManagedProcessGroup.forceKill(snapshot: legacySnap, flagged: false, probe: SystemProcessProbe(), signal: realSignal)
        XCTAssertEqual(old, .rootSignaled("unflagged"))
        XCTAssertTrue(gone(legacy.root, isOurChild: true))
        XCTAssertTrue(alive(legacy.child), "单 PID 强杀：继承组的子进程存活（#107 的缺陷）")
        _ = Darwin.kill(legacy.child, SIGKILL)

        // 新：托管组 → 一次 kill(-pid) 两者消失
        let b = try fakeBridge(ownGroup: true)
        let snap = try identity(b.root)
        XCTAssertEqual(SystemProcessProbe().processGroup(pid: b.root), b.root, "helper 是自己组的组长")
        let outcome = ManagedProcessGroup.forceKill(snapshot: snap, flagged: true, probe: SystemProcessProbe(), signal: realSignal)
        XCTAssertEqual(outcome, .groupSignaled)
        XCTAssertTrue(gone(b.root, isOurChild: true))
        XCTAssertTrue(gone(b.child, isOurChild: false), "同组子进程一并结束")
        XCTAssertTrue(alive(sentinel), "无关进程组不受影响")
    }

    func testAFlaggedProcessThatIsNotItsOwnGroupLeaderIsNeverGroupKilled() throws {
        let sentinel = try spawn("/bin/sleep", ["300"], ownGroup: true)
        let b = try fakeBridge(ownGroup: false) // 与测试进程同组：组不是 PID
        let snap = try identity(b.root)
        XCTAssertNotEqual(SystemProcessProbe().processGroup(pid: b.root), b.root)
        var sent: [(Int32, Int32)] = []
        let outcome = ManagedProcessGroup.forceKill(snapshot: snap, flagged: true, probe: SystemProcessProbe(), signal: { sent.append(($0, $1)); return self.realSignal($0, $1) })
        XCTAssertEqual(outcome, .rootSignaled("group_unconfirmed"), "不能确认组：只结束根进程并如实报告")
        XCTAssertTrue(sent.allSatisfy { $0.0 > 0 }, "绝不向负 PID（App / shell 组）发信号")
        XCTAssertTrue(gone(b.root, isOurChild: true))
        XCTAssertTrue(alive(sentinel))
        XCTAssertTrue(alive(getpid()), "测试进程自己的组没有被信号波及")
        _ = Darwin.kill(b.child, SIGKILL)
    }

    func testAChangedIdentityNeverSignalsAnything() throws {
        let b = try fakeBridge(ownGroup: true)
        var snap = try identity(b.root)
        snap = BridgeProcessSnapshot(pid: snap.pid, startMicros: snap.startMicros + 1, executable: snap.executable)
        var sent: [(Int32, Int32)] = []
        let outcome = ManagedProcessGroup.forceKill(snapshot: snap, flagged: true, probe: SystemProcessProbe(), signal: { sent.append(($0, $1)); return 0 })
        XCTAssertEqual(outcome, .notRunning)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(alive(b.root) && alive(b.child))
    }

    // MARK: 纯策略

    func testPolicyNegativeControlsWithAFakeProbe() {
        let snap = BridgeProcessSnapshot(pid: 500, startMicros: 7, executable: "/app/palmhelm-bridge")
        func run(_ s: BridgeProcessSnapshot, flagged: Bool, table: BridgeProcessSnapshot?, group: Int32?) -> (ChildKillOutcome, [(Int32, Int32)]) {
            let p = GroupProbe()
            if let table { p.table[table.pid] = table }
            if let group { p.groups[s.pid] = group }
            var sent: [(Int32, Int32)] = []
            let o = ManagedProcessGroup.forceKill(snapshot: s, flagged: flagged, probe: p, signal: { sent.append(($0, $1)); return 0 })
            return (o, sent)
        }
        var r = run(snap, flagged: true, table: snap, group: 500)
        XCTAssertEqual(r.0, .groupSignaled); XCTAssertEqual(r.1.map(\.0), [-500]); XCTAssertEqual(r.1.map(\.1), [SIGKILL])
        r = run(snap, flagged: false, table: snap, group: 500)
        XCTAssertEqual(r.0, .rootSignaled("unflagged")); XCTAssertEqual(r.1.map(\.0), [500], "旧无标志进程只走单 PID")
        r = run(snap, flagged: true, table: snap, group: 321)
        XCTAssertEqual(r.0, .rootSignaled("group_unconfirmed")); XCTAssertEqual(r.1.map(\.0), [500], "组是别人的（如 App 组）：不组杀")
        r = run(snap, flagged: true, table: snap, group: nil)
        XCTAssertEqual(r.0, .rootSignaled("group_unconfirmed"), "查询失败")
        r = run(snap, flagged: true, table: BridgeProcessSnapshot(pid: 500, startMicros: 8, executable: snap.executable), group: 500)
        XCTAssertEqual(r.0, .notRunning); XCTAssertTrue(r.1.isEmpty, "PID 被复用（启动时间变了）零信号")
        r = run(snap, flagged: true, table: BridgeProcessSnapshot(pid: 500, startMicros: 7, executable: "/bin/other"), group: 500)
        XCTAssertEqual(r.0, .notRunning); XCTAssertTrue(r.1.isEmpty, "路径变了零信号")
        r = run(snap, flagged: true, table: nil, group: 500)
        XCTAssertEqual(r.0, .notRunning); XCTAssertTrue(r.1.isEmpty, "进程已不在零信号")
        let one = BridgeProcessSnapshot(pid: 1, startMicros: 7, executable: "/sbin/launchd")
        r = run(one, flagged: true, table: one, group: 1)
        XCTAssertNotEqual(r.0, .groupSignaled); XCTAssertFalse(r.1.contains { $0.0 < 0 }, "pid 1 永不组杀")
    }

    // MARK: 信号结果如实（C-R2）：失败 / 零信号 / 身份变化都不是成功

    func testSignalFailuresAreReportedAndNeverRetriedOrRecordedAsSuccess() {
        let snap = BridgeProcessSnapshot(pid: 500, startMicros: 7, executable: "/app/palmhelm-bridge")
        func run(group: Int32?, rc: Int32) -> (ChildKillOutcome, [Int32]) {
            let p = GroupProbe(); p.table[500] = snap; if let group { p.groups[500] = group }
            var sent: [Int32] = []
            let o = ManagedProcessGroup.forceKill(snapshot: snap, flagged: true, probe: p, signal: { pid, _ in sent.append(pid); return rc })
            return (o, sent)
        }
        var r = run(group: 500, rc: EPERM)
        XCTAssertEqual(r.0, .failed(errno: EPERM, group: true)); XCTAssertEqual(r.1, [-500], "组信号失败：不转成成功，也不再对根 PID 重试")
        r = run(group: 321, rc: EPERM)
        XCTAssertEqual(r.0, .failed(errno: EPERM, group: false)); XCTAssertEqual(r.1, [500])
        r = run(group: 500, rc: ESRCH) // 信号后根进程仍在（probe 不变）
        XCTAssertEqual(r.0, .failed(errno: ESRCH, group: true), "ESRCH 但身份仍匹配：信号没送达，按失败报告，不记 notRunning")
        XCTAssertEqual(r.1, [-500], "不重试信号")
        // ESRCH 且复核时进程已不在 / 身份变了 → notRunning
        for after in [nil, BridgeProcessSnapshot(pid: 500, startMicros: 8, executable: snap.executable)] as [BridgeProcessSnapshot?] {
            let p = GroupProbe(); p.table[500] = snap; p.groups[500] = 500
            var calls = 0
            let o = ManagedProcessGroup.forceKill(snapshot: snap, flagged: true, probe: p, signal: { _, _ in calls += 1; p.table[500] = after; return ESRCH })
            XCTAssertEqual(o, .notRunning); XCTAssertEqual(calls, 1)
        }
        r = run(group: 500, rc: 0)
        XCTAssertEqual(r.0, .groupSignaled)
    }

    func testAdoptedChildExposesAFailedSignalAndIdentityChangeSendsNothing() async {
        let snap = BridgeProcessSnapshot(pid: 700, startMicros: 9, executable: "/app/palmhelm-bridge")
        let probe = GroupProbe(); probe.table[700] = snap; probe.groups[700] = 700
        let child = AdoptedChild(snapshot: snap, probe: probe, managedGroup: true, signal: { _, _ in EPERM })
        child.kill()
        XCTAssertEqual(child.lastKillOutcome, .failed(errno: EPERM, group: true))
        probe.table[700] = BridgeProcessSnapshot(pid: 700, startMicros: 10, executable: snap.executable) // PID 被复用
        let reused = AdoptedChild(snapshot: snap, probe: probe, managedGroup: true, signal: { _, _ in XCTFail("身份变化不得发信号"); return 0 })
        reused.kill()
        XCTAssertEqual(reused.lastKillOutcome, .notRunning)
    }

    // MARK: 接线

    func testAdoptedChildUsesTheFlagFromTheFrozenRecordEnvironment() {
        let snap = BridgeProcessSnapshot(pid: 700, startMicros: 9, executable: "/app/palmhelm-bridge")
        let probe = GroupProbe(); probe.table[700] = snap; probe.groups[700] = 700
        var sent: [(Int32, Int32)] = []
        let flagged = AdoptedChild(snapshot: snap, probe: probe, managedGroup: ManagedProcessGroup.flagged(["BRIDGE_MANAGED_PROCESS_GROUP": "1"]), signal: { sent.append(($0, $1)); return 0 })
        flagged.kill()
        XCTAssertEqual(sent.map(\.0), [-700]); XCTAssertEqual(flagged.lastKillOutcome, .groupSignaled)
        sent = []
        let legacy = AdoptedChild(snapshot: snap, probe: probe, managedGroup: ManagedProcessGroup.flagged([:]), signal: { sent.append(($0, $1)); return 0 })
        legacy.kill()
        XCTAssertEqual(sent.map(\.0), [700], "旧记录（无标志）：兼容原单 PID")
        let gone = AdoptedChild(snapshot: BridgeProcessSnapshot(pid: 701, startMicros: 1, executable: "/x"), probe: probe, managedGroup: true, signal: { sent.append(($0, $1)); return 0 })
        sent = []; gone.kill()
        XCTAssertTrue(sent.isEmpty)
    }

    func testTheEngineEnvironmentAlwaysCarriesTheFlagAndExtraEnvCannotOverrideIt() {
        let d = UserDefaults(suiteName: "palmhelm.mpg.tests")!
        d.removePersistentDomain(forName: "palmhelm.mpg.tests")
        let s = EngineSettings(defaults: d)
        s.extraEnv = "BRIDGE_MANAGED_PROCESS_GROUP=0"
        XCTAssertEqual(s.environment()["BRIDGE_MANAGED_PROCESS_GROUP"], "1")
        XCTAssertTrue(ManagedProcessGroup.flagged(s.environment()))
    }
}
