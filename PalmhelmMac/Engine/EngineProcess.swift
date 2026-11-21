import Foundation

// Bridge 子进程的抽象（测试接缝）：生产用 Foundation.Process（ProcessChild）；测试注入假子进程，不真启动 Bridge。
// 回调可能在任意线程调用，调用方自己切回主线程。

/// 一次启动的全部参数与回调。
struct EngineLaunch: Sendable {
    let executable: String
    let environment: [String: String]
    let directory: String
    let onStdout: @Sendable (Data) -> Void
    let onStderr: @Sendable (Data) -> Void
    let onExit: @Sendable (Int32) -> Void
}

@MainActor
protocol EngineChild: AnyObject {
    var isRunning: Bool { get }
    /// 进程号：用于记录身份（接管用）。拿不到时为 nil，此时不记录，也就不能被接管。
    var pid: Int32? { get }
    func terminate() // SIGTERM
    func kill() // SIGKILL（仅当仍在运行）；托管进程组时一次结束整个已确认的组（#107）
    /// 最近一次 kill 的结论；假子进程无此概念。
    var lastKillOutcome: ChildKillOutcome? { get }
}

extension EngineChild {
    var pid: Int32? { nil }
    var lastKillOutcome: ChildKillOutcome? { nil }
}

enum EngineProcessError: Error, Equatable {
    case testHostForbidden
}

@MainActor
final class ProcessChild: EngineChild {
    private let p: Process
    /// 启动时捕获的身份与本次是否声明了独立进程组；强杀时据此复核，pid 被复用或身份变化不发组信号。
    private let snapshot: BridgeProcessSnapshot?
    private let managedGroup: Bool
    private let probe: BridgeProcessProbing
    private(set) var lastKillOutcome: ChildKillOutcome?
    private init(_ p: Process, snapshot: BridgeProcessSnapshot?, managedGroup: Bool, probe: BridgeProcessProbing) {
        self.p = p; self.snapshot = snapshot; self.managedGroup = managedGroup; self.probe = probe
    }

    var isRunning: Bool { p.isRunning }
    var pid: Int32? { p.processIdentifier }
    func terminate() { p.terminate() }
    func kill() {
        guard p.isRunning else { return }
        guard let snapshot else { // 启动时读不到身份：不能组杀，只结束根进程
            let rc = systemSignal(p.processIdentifier, SIGKILL)
            lastKillOutcome = rc == 0 ? .rootSignaled("identity_unavailable") : (rc == ESRCH ? .notRunning : .failed(errno: rc, group: false))
            return
        }
        lastKillOutcome = ManagedProcessGroup.forceKill(snapshot: snapshot, flagged: managedGroup, probe: probe, signal: systemSignal)
    }

    static func launch(_ l: EngineLaunch, probe: BridgeProcessProbing = SystemProcessProbe(), makeProcess: () -> Process = { Process() }) throws -> any EngineChild {
        guard !RuntimeEnvironment.isTestHost else { throw EngineProcessError.testHostForbidden }
        let p = makeProcess()
        p.executableURL = URL(fileURLWithPath: l.executable)
        p.environment = l.environment
        p.currentDirectoryURL = URL(fileURLWithPath: l.directory) // 干净 cwd：编译产物会读取 cwd 的 .env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            l.onStdout(d)
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            l.onStderr(d)
        }
        p.terminationHandler = { proc in l.onExit(proc.terminationStatus) }
        try p.run()
        return ProcessChild(p, snapshot: probe.snapshot(pid: p.processIdentifier), managedGroup: ManagedProcessGroup.flagged(l.environment), probe: probe)
    }
}
