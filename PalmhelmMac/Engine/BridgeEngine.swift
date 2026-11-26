import Darwin
import Foundation
import Network
import Observation

// 托管内置 Bridge 子进程：启动/停止/重启、日志环形缓冲、从数据目录读 local-api.json 得到端口与证书指纹。
// 停机只发 SIGTERM（Bridge 自己有 10 秒绝对期限与清理），超时才 SIGKILL。
@MainActor
@Observable
final class BridgeEngine {
    enum Status: Equatable {
        case stopped, starting, running, stopping
        case failed(LText)
        var label: String {
            switch self {
            case .stopped: String(localized: "已停止")
            case .starting: String(localized: "启动中")
            case .running: String(localized: "运行中")
            case .stopping: String(localized: "停止中")
            case .failed(let r): String(localized: "启动失败 · \(r.text)")
            }
        }
    }

    struct PortFile: Decodable, Sendable {
        struct Tls: Decodable, Sendable { let spkiSha256: String }
        let hookPort: Int
        let apiPort: Int
        let bind: String
        let binds: [String]?
        let hostnames: [String]?
        let transport: String
        let version: String?
        let tls: Tls?
        var allBinds: [String] { binds ?? [bind] }
    }

    private(set) var status: Status = .stopped
    private(set) var logs: [String] = []
    private(set) var portFile: PortFile?
    private(set) var startedAt: Date?
    /// 启动时冻结的子进程环境与数据目录：设置页随时可改，但当前进程只认这一份（模式、Hook 目录都从这里读）。
    private(set) var activeEnv: [String: String] = [:]
    private(set) var activeDataDir: String = ""
    /// 启动时解析并传给 Bridge 的监听地址（冻结）：用于「设置有更改」判定与网络变化时的重启决策。
    private(set) var activeListen: ListenResolution?
    /// 网络变化触发的重启正在进行（状态区显示「网络变化，正在重新监听…」）。
    private(set) var networkRestarting = false
    /// 每次系统网络路径变化加一：设置页据此重新读取当前解析到的地址。
    private(set) var networkRevision = 0
    private var listenWatch: ListenWatch?
    private var watchTimer: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    let settings: EngineSettings
    private var process: (any EngineChild)?
    private var stdoutBuf = Data()
    private var stderrBuf = Data()
    /// 当前子进程是否与 App 解耦（启动时不带 BRIDGE_PARENT_PID，退出 App 时不停它）。接管来的进程恒为 true。
    private(set) var isBackground = false
    private var adoptedWatch: Task<Void, Never>?
    /// 当前这次停止是接管进程的网络重启（而非用户停止 / 退出）：停止完成时不清网络重启状态。
    private var adoptedRestartVictim = false
    /// 后台子进程的重启进行中（旧的已停、新的还没起）：此时不能退出 App，否则会没有任何 Bridge。
    private(set) var backgroundRestartInFlight = false
    /// 启动时环境的比较域（机密为指纹、不含 BRIDGE_PARENT_PID）：与当前设置的比较域各只转换一次。
    private var activeFingerprint: [String: String] = [:]

    // 测试接缝：默认就是生产行为（真实子进程、真实时钟、真实睡眠、监视系统网络路径、系统进程表、真实信号）。
    var launcher: (EngineLaunch) throws -> any EngineChild = { try ProcessChild.launch($0) }
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    var now: () -> Date = { Date() }
    var watchNetwork = true
    var processProbe: any BridgeProcessProbing = SystemProcessProbe()
    /// 启动阶段的固定记录（测试可注入临时目录）。只写阶段名、结果与相对启动的毫秒数。
    var appEvents: AppEventLog = .shared
    var sendSignal: ProcessSignal = systemSignal
    /// 接管后是否轮询它是否还活着（2 秒一次）；测试关闭，由测试直接驱动。
    var watchAdopted = true

    /// 重启代次（H2）：用户的停止 / 启动 / 重启、退出、新的重启都会让更早的（等待中或进行中的）重启作废；
    /// 重启内部的 stop 不会作废它自己。重启在每个等待点之后、真正 start 之前都要复核自己的代次。
    private var restartGen = 0
    /// 当前这次子进程启动的编号：退出回调带着编号回来，区分「为重启而退出的旧进程」与「新进程自己失败退出」（H3）。
    private var currentLaunch = 0
    private var restartVictimLaunch: Int?
    /// 模式切换期间置位（切换器负责置位与清除）：此时任何入口都不启动子进程。
    var startBlocked = false

    init(settings: EngineSettings) { self.settings = settings }

    var isRunning: Bool { status == .running }
    /// 运行中按实际传给子进程的环境判定；未运行按设置预判（缺项时 Bridge 会以独立模式起）。
    var mode: String { (process != nil ? activeEnv["FEISHU_APP_ID"] != nil : settings.feishuConfigured) ? String(localized: "飞书组合模式") : String(localized: "独立模式") }
    /// 设置是否有未生效的更改。两部分独立比较（H1）：
    /// ① 监听意图（局域网 / Tailscale 开关）与启动时冻结的意图不同——地址是按冻结解析生成的，只比环境变量看不出开关变化；
    /// ② 其余环境变量按启动时冻结的地址比较：网络变化本身（IP 变了）不算「设置有更改」，它由网络监测自动处理。
    /// ③ 后台运行开关与当前子进程的实际模式不同：要下次启动 Bridge 才生效。
    var pendingRestart: Bool {
        guard process != nil, let active = activeListen else { return false }
        return settings.intent != active.intent
            || activeFingerprint != EngineChildRecord.redacted(settings.fingerprintEnvironment(resolution: active))
            || isBackground != settings.keepBridgeAfterQuit
    }

    /// 菜单栏 / 设置里的状态文字：运行中且与 App 解耦时标为「后台运行中」。
    var displayStatus: String { status == .running && isBackground ? String(localized: "后台运行中") : status.label }
    /// 退出 App 后 Bridge 是否继续运行：有子进程时以它的实际模式为准（设置的切换要下次启动才生效），没有时按设置。
    var keepsAfterQuit: Bool { childRunning ? isBackground : settings.keepBridgeAfterQuit }

    /// 当前实际监听地址对手机的可达性（分类规则见 EngineSettings.reach）。
    var reach: EngineSettings.Reach? { portFile.map { EngineSettings.reach(of: $0.allBinds.joined(separator: ",")) } }

    /// 用户 / 自动启动入口：作废任何等待中或进行中的重启（用户明确要启动，不能再被旧的自动重启接管）。
    func start() {
        invalidateRestart()
        startProcess()
    }

    private func invalidateRestart() {
        restartGen += 1
        networkRestarting = false
        restartVictimLaunch = nil
        adoptedRestartVictim = false
        backgroundRestartInFlight = false // 被作废的重启不会再启动新进程，退出不再需要等它
    }

    /// 所有启动路径（start、重启、网络自动重启、接管替换）的共同入口：远程模式或切换期间一律不起进程，也不改状态。
    private func startProcess() {
        guard settings.connectionMode == .local, !startBlocked else { return }
        guard process == nil else { return }
        guard settings.secretsLoaded else { append("[palmhelm] 钥匙串尚未读完，先不启动"); return } // 否则飞书 Secret 为空会以独立模式冻结运行环境
        guard let bin = settings.resolvedBinary else {
            status = .failed(LText(String(localized: "未找到 Bridge 二进制（设置里指定路径）")))
            return
        }
        // 监听地址按意图从当前网卡解析（一次启动只解析一次，env 与后续重启决策用同一份）
        let listen = settings.resolvedListen()
        // 勾了 Tailscale 且取到了地址：启动前一律以 Tailscale 实际 MagicDNS 名为准，覆盖手填/过期的值（用户反馈：填错域名手机就连不上，且无从知道正确值）
        if listen.tailscale != nil,
           let n = EngineSettings.detectTailscaleDNSName(), n != settings.hostnames { settings.hostnames = n; append("[palmhelm] 已按 Tailscale 自动更正 MagicDNS 主机名") }
        if let code = settings.listenProblemCode(for: listen) { // 无效监听组合在共同启动入口拒绝（含自动启动），不把注定失败的配置交给 Bridge（A1-155 F3 建议）
            status = .failed(LText(String(localized: "监听配置无效：\(EngineSettings.listenProblemText(code))")))
            append("[palmhelm] 未启动：\(code)")
            return
        }
        if listen.lanUnavailable { append("[palmhelm] 局域网暂不可用（没有可用的局域网地址），只监听其余已勾选的地址") }
        if listen.tailscaleUnavailable { append("[palmhelm] Tailscale 暂不可用（没有 100.64/10 的隧道地址）") }
        let dir = settings.dataDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        activeEnv = settings.environment(resolution: listen)
        // 账户来源的指纹在启动时记入比较域（不进入子进程环境）：之后文件内容变化即「设置有更改」。
        activeFingerprint = EngineChildRecord.redacted(activeEnv.merging([EngineSettings.sourcesFingerprintKey: settings.sourcesFingerprint]) { _, new in new })
        activeListen = listen
        activeDataDir = dir
        stdoutBuf = Data(); stderrBuf = Data()
        currentLaunch += 1
        let id = currentLaunch
        let launch = EngineLaunch(
            executable: bin, environment: activeEnv, directory: dir,
            onStdout: { [weak self] d in Task { @MainActor in self?.consume(d, stderr: false) } },
            onStderr: { [weak self] d in Task { @MainActor in self?.consume(d, stderr: true) } },
            onExit: { [weak self] code in Task { @MainActor in self?.terminated(launch: id, code: code) } })
        do {
            let child = try launcher(launch)
            process = child
            isBackground = activeEnv["BRIDGE_PARENT_PID"] == nil
            if let problem = publishBackgroundRecord(child, bin: bin, dir: dir) {
                abandonUnrecordedBackground(child, problem)
                return
            }
            status = .starting
            startedAt = now()
            AppEventLog.shared.mark(.childLaunch)
            portFile = nil
            listenWatch = ListenWatch(started: listen, at: now())
            startPathMonitor()
            append("[palmhelm] 启动 \(bin)")
        } catch {
            status = .failed(LText(String(localized: "无法启动进程")))
            append("[palmhelm] 启动失败：\(error.localizedDescription)")
        }
    }

    /// 设置页/菜单的停止：SIGTERM 后最多等 12 秒，超时 SIGKILL，并等到进程确实消失。重复调用是幂等的（已在停止中只会继续等）。
    /// 用户的停止同时作废等待中或进行中的重启（H2）：停下就是停下，不会被稍后到点的自动重启再拉起来。
    func stop() async {
        invalidateRestart()
        await stopProcess()
    }

    /// 模式切换用的有界停机：作废排队与进行中的重启，SIGTERM → 最多 12 秒 → SIGKILL → 最多 5 秒。
    /// 返回进程是否确认退出；未确认时保留进程跟踪（之后的停止与退出照常处理），调用方据此保持 local。
    func stopForModeSwitch() async -> Bool {
        invalidateRestart()
        guard let p = process else { return true }
        terminateChild()
        for _ in 0..<60 where p.isRunning { await sleep(.milliseconds(200)) }
        if p.isRunning { kill(p) }
        for _ in 0..<50 where p.isRunning { await sleep(.milliseconds(100)) }
        guard !p.isRunning else { return false }
        if let adopted = p as? AdoptedChild {
            adoptedGone(adopted)
        } else if process === p {
            // 退出回调是异步回到主线程的：这里直接收束，并让迟到的回调因代次过期而被忽略。
            terminated(launch: currentLaunch, code: 0)
            currentLaunch += 1
        }
        return true
    }

    /// 重启内部用的停机：不作废重启代次（否则重启会取消自己）。
    private func stopProcess() async {
        guard let p = process else { return }
        terminateChild()
        await stopChild(p)
        // 接管的进程没有退出回调：确认它已消失后在这里清理（否则之后的启动会被当作「已在运行」）
        if let adopted = p as? AdoptedChild, process === p { adoptedGone(adopted) }
    }

    /// 有界停机（调用方已发出 SIGTERM）：最多等 12 秒，超时 SIGKILL，并等到进程确实消失。只作用于这次捕获的 child。
    private func stopChild(_ p: any EngineChild) async {
        for _ in 0..<60 where p.isRunning { await sleep(.milliseconds(200)) } // 最多 12 秒
        kill(p) // 只作用于这次捕获的 child：期间它退出、用户又启动了新 child 时，不能误杀新的
        while p.isRunning { await sleep(.milliseconds(100)) }
    }

    /// 发 SIGTERM，不等待；退出路径由 AppDelegate 用主运行循环定时器轮询 childRunning。同样作废进行中的重启。
    func requestStop() {
        invalidateRestart()
        terminateChild()
    }
    private func terminateChild() {
        guard let p = process, status != .stopping else { return }
        status = .stopping
        p.terminate()
    }
    var childRunning: Bool { process?.isRunning ?? false }
    func forceKill() { if let p = process { kill(p) } }
    private func kill(_ p: any EngineChild) {
        guard p.isRunning else { return }
        p.kill()
        switch p.lastKillOutcome {
        case .groupSignaled: append("[palmhelm] 停机超时，已向 Bridge 进程组发送强制结束信号（尚未确认全部退出）")
        case .rootSignaled: append("[palmhelm] 停机超时，已向 Bridge 根进程发送强制结束信号；无法确认进程组，子进程清理未确认")
        case .notRunning: append("[palmhelm] 停机超时，但 Bridge 进程已不存在或身份已变，未发送信号")
        case .failed(let code, _): append("[palmhelm] 停机超时，强制结束信号发送失败（errno \(code)）；进程可能仍在运行")
        case nil: append("[palmhelm] 停机超时，已强制结束")
        }
    }

    /// 手动重启（设置页 / 菜单）。
    func restart() async { await performRestart(auto: false, claimed: nil) }

    /// 重启：停 → 等 300ms → 启。每个等待点之后都复核代次：期间被用户停止 / 启动 / 被更新的重启取代，就不再继续。
    /// auto=true（网络地址变化触发）时标记旧进程是「为重启而退出」，状态区显示「网络变化，正在重新监听…」。
    /// claimed：自动重启在排队处同步登记的代次；Task 真正运行时若已被用户停止 / 启动 / 更新的重启作废，就不能再进来自增拿新代次。
    private func performRestart(auto: Bool, claimed: Int?) async {
        let gen: Int
        if let claimed {
            guard claimed == restartGen else { return }
            gen = claimed
        } else {
            restartGen += 1
            gen = restartGen
        }
        if auto {
            restartVictimLaunch = currentLaunch
            adoptedRestartVictim = process is AdoptedChild // 接管来的进程没有退出回调：由 adoptedGone 按这个标记保留网络重启状态
            networkRestarting = true
        } else {
            networkRestarting = false
            restartVictimLaunch = nil
            adoptedRestartVictim = false
        }
        // 后台子进程的重启：从停旧到起新是一个事务，期间 App 不能退出（否则没有任何 Bridge）
        backgroundRestartInFlight = isBackground
        defer { if gen == restartGen { backgroundRestartInFlight = false } }
        await stopProcess()
        guard gen == restartGen else { return }
        await sleep(.milliseconds(300))
        guard gen == restartGen else { return } // start 之前再复核：这次重启的意图仍然有效
        startProcess()
        if auto && status != .starting { networkRestarting = false } // 启动中：等 bridge_started / 失败 / 退出再清
    }

    // MARK: 网络变化（h8）

    /// 系统网络路径变化 → 重新评估。监视器本身常驻（只读系统路径，不联网）；没有运行中的 Bridge 时不做任何事。
    private func startPathMonitor() {
        guard watchNetwork, pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.networkChanged() } }
        m.start(queue: DispatchQueue(label: "palmhelm.network-path"))
        pathMonitor = m
    }

    private func networkChanged() {
        networkRevision += 1
        evaluateListen()
    }

    /// 决策交给纯函数 ListenWatch：变化 + 3 秒防抖 + 30 秒限频；暂空与未变不重启。需要等待时挂一个定时器到点再评估。
    func evaluateListen() {
        watchTimer?.cancel(); watchTimer = nil
        guard process != nil, status == .running || status == .starting, var watch = listenWatch else { return }
        let action = watch.observe(settings.resolvedListen(), now: now())
        listenWatch = watch
        switch action {
        case .none: break
        case .wait(let until):
            watchTimer = Task { [weak self] in
                guard let self else { return }
                await self.sleep(.seconds(max(0.05, until.timeIntervalSince(self.now()))))
                guard !Task.isCancelled else { return }
                self.evaluateListen()
            }
        case .restart:
            append("[palmhelm] 网络地址变化，重新监听")
            restartGen += 1
            let claimed = restartGen
            Task { [weak self] in await self?.performRestart(auto: true, claimed: claimed) }
        }
    }

    /// 子进程退出。launch 是这次启动的编号：只有「为网络重启而被我们停掉的那个旧进程」退出时才保留 networkRestarting 与冻结的监听；
    /// 其余退出（包括新进程起来后没写任何 bridge_started / bridge_start_failed 就直接退出）都清掉重启标记，状态行回到真实状态（H3）。
    private func terminated(launch: Int, code: Int32) {
        guard launch == currentLaunch else { return } // 更早一次启动的迟到回调：不再代表当前进程
        let wasRestartVictim = launch == restartVictimLaunch
        let exitedPid = process?.pid
        process = nil
        isBackground = false
        EngineChildRecord.remove(dataDir: activeDataDir, ownedBy: exitedPid, probe: processProbe)
        portFile = nil
        listenWatch = nil
        watchTimer?.cancel(); watchTimer = nil
        if wasRestartVictim {
            restartVictimLaunch = nil // 网络重启中保留上一份冻结值，直到新进程启动并重新冻结
        } else {
            networkRestarting = false
            activeListen = nil
        }
        if case .failed = status { return }
        status = code == 0 ? .stopped : .failed(LText(String(localized: "退出码 \(code)")))
        append("[palmhelm] Bridge 已退出（\(code)）")
    }

    private func consume(_ data: Data, stderr: Bool) {
        if stderr { stderrBuf.append(data) } else { stdoutBuf.append(data) }
        var buf = stderr ? stderrBuf : stdoutBuf
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
            buf.removeSubrange(buf.startIndex...nl)
            handle(line: line, stderr: stderr)
        }
        if stderr { stderrBuf = buf } else { stdoutBuf = buf }
    }

    private func handle(line: String, stderr: Bool) {
        append(line)
        if line.contains("\"msg\":\"bridge_started\"") {
            networkRestarting = false
            status = .running
            AppEventLog.shared.mark(.bridgeStarted)
            readPortFile()
        } else if line.contains("\"msg\":\"bridge_start_failed\"") {
            let reason = line.range(of: "\"reason\":\"").map { String(line[$0.upperBound...].prefix { $0 != "\"" }) } ?? "unknown"
            status = .failed(LText(reason)) // Bridge 原样的 reason 码，不翻译
            networkRestarting = false
            AppEventLog.shared.mark(.bridgeStarted, .failed)
        }
    }

    private func append(_ line: String) {
        logs.append(line)
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    /// 上一条诊断的阶段文本（不含时间）：只与上一条比较，相同阶段连续出现只记一条（长期离线重试不刷满日志缓冲）。
    private var lastDiagnosticStage: String?

    /// 配对阶段诊断：`[palmhelm] 时间 阶段`。调用方只传阶段与错误类别（不含令牌、配对码、secret、指纹原文）。
    func diagnose(_ stage: String) {
        guard stage != lastDiagnosticStage else { return }
        lastDiagnosticStage = stage
        append("[palmhelm] \(Date().formatted(date: .omitted, time: .standard)) \(stage)")
    }

    // MARK: 接管与后台运行

    /// 后台子进程写入身份记录（接管用）。前台子进程不写：它靠父进程守护退出，不能被当作可独立存活的进程接管（R6）。
    /// 返回 nil 表示成功或无需记录；返回原因表示后台记录没能保存，调用方必须停掉这个刚启动的进程（R1）。
    private func publishBackgroundRecord(_ child: any EngineChild, bin: String, dir: String) -> String? {
        guard isBackground else {
            EngineChildRecord.remove(dataDir: dir, ownedBy: nil, probe: processProbe) // 前台启动：只清陈旧记录，不删仍在运行的后台 Bridge 的记录
            return nil
        }
        guard let pid = child.pid else { return "pid_unreadable" }
        guard let snap = processProbe.snapshot(pid: pid) else { return "process_unreadable" }
        // 另一个仍存活的后台 Bridge 的记录不能被替换：否则它失去接管凭据，且无法再被找回。
        if let existing = EngineChildRecord.load(dataDir: dir), existing.pid != pid, existing.isSameLiveProcess(processProbe) {
            return "record_owned_by_live_bridge"
        }
        guard let digest = BinaryDigest.of(bin) else { return "binary_unreadable" }
        let record = EngineChildRecord(
            background: true, pid: pid, startMicros: snap.startMicros, executable: canonicalPath(snap.executable),
            binaryDigest: digest, dataDir: canonicalPath(dir), environment: activeFingerprint,
            listen: ListenBaseline(activeListen ?? settings.resolvedListen()))
        do {
            try record.save(dataDir: dir)
            return nil
        } catch {
            return "record_write_failed"
        }
    }
    /// 后台记录原因码的界面文案（日志只用原因码）。
    static func backgroundRecordProblemText(_ code: String) -> String {
        switch code {
        case "pid_unreadable": String(localized: "读不到进程号")
        case "process_unreadable": String(localized: "读不到进程信息")
        case "binary_unreadable": String(localized: "读不到 Bridge 可执行文件")
        case "record_write_failed": String(localized: "写入身份记录失败")
        case "record_owned_by_live_bridge": String(localized: "数据目录里另一个后台 Bridge 仍在运行，不能替换它的记录")
        default: code
        }
    }

    /// 后台记录没能保存：这个进程以后无法被接管，留着它会让用户以为它会一直运行。停掉它，并把原因显示出来。
    /// 收尾与现有的停机一致：SIGTERM → 有界等待 → SIGKILL → 确认真正退出后，才把状态显示为已停止。
    private func abandonUnrecordedBackground(_ child: any EngineChild, _ problem: String) {
        isBackground = false
        status = .stopping
        startedAt = nil
        append("[palmhelm] 后台运行记录未保存（\(problem)），正在停止刚启动的 Bridge")
        child.terminate()
        Task { [weak self] in await self?.finishAbandon(child, problem) }
    }

    private func finishAbandon(_ child: any EngineChild, _ problem: String) async {
        await stopChild(child)
        if process === child {
            process = nil
            portFile = nil
            listenWatch = nil
        }
        status = .failed(LText(String(localized: "后台运行记录未保存，已停止（\(Self.backgroundRecordProblemText(problem))）")))
        append("[palmhelm] 刚启动的 Bridge 已停止")
    }

    /// 启动序列（AppBoot 与测试共用同一个入口）：先接管或替换上次留下的后台 Bridge，再按「随 App 启动」设置自动启动。
    func bootOnLaunch() async {
        guard settings.connectionMode == .local else { return } // 远程模式：不接管、不启动本机 Bridge
        await takeOverRunningBridge()
        if settings.autoStart { start() }
    }

    /// 启动前接管：数据目录里有本 App 记录的 Bridge，且进程仍在、身份逐项相符（pid、启动时间、可执行路径、数据目录），就直接托管它。
    /// 可执行文件与当前 App 内置的不同（App 已更新）：先停掉它，之后由调用方按新版本启动。
    /// 身份不符（pid 被复用、路径不同等）一律不接管、不杀进程，交给现有的启动路径（端口/锁冲突时照常提示失败）。
    func takeOverRunningBridge() async {
        guard process == nil, let bin = settings.resolvedBinary else { return }
        let dir = settings.dataDir
        guard let record = EngineChildRecord.load(dataDir: dir) else { return }
        let snap = processProbe.snapshot(pid: record.pid)
        guard let snap else {
            EngineChildRecord.remove(dataDir: dir, ownedBy: nil, probe: processProbe) // 记录的进程已经不在：清掉陈旧记录
            return
        }
        let decision = TakeoverPolicy.decide(record: record, snapshot: snap, dataDir: dir, executable: bin, binaryDigest: BinaryDigest.of(bin))
        guard decision != .none else {
            appEvents.mark(.takeover, .failed) // 记录的进程仍在但身份不符：不接管、不杀
            return
        }
        let child = AdoptedChild(snapshot: snap, probe: processProbe, managedGroup: ManagedProcessGroup.flagged(record.environment), signal: sendSignal)
        process = child
        activeDataDir = dir
        isBackground = true
        status = .running
        if decision == .replace {
            // 旧版本：与重启共用同一个事务入口（停 → 等待 → 起新）：期间退出会等它完成（backgroundRestartInFlight）；不经过「随 App 启动」门禁
            append("[palmhelm] 后台运行的 Bridge 与当前 App 内置版本不同，先停止再按新版本启动")
            await restart()
            appEvents.mark(.takeover, .ok)
            return
        }
        activeEnv = record.environment
        activeFingerprint = record.environment // 已是比较域（机密为指纹），不再转换
        // 监听基线用旧进程实际冻结的地址与意图（而不是当前网络）：期间发生的网络变化由下面的对照与监听发现
        let baseline = record.listen.resolution
        activeListen = baseline
        listenWatch = ListenWatch(started: baseline, at: now())
        startPathMonitor()
        startedAt = Date(timeIntervalSince1970: TimeInterval(snap.startMicros) / 1_000_000)
        readPortFile()
        append("[palmhelm] 接管后台运行中的 Bridge（pid \(snap.pid)）")
        appEvents.mark(.takeover, .ok)
        if watchAdopted { watchAdoptedChild(child) }
        evaluateListen() // 接管完成后立即对照一次当前网络；有差异则按正常流程（防抖、限频）重启
    }

    /// 接管的进程没有退出回调，定时确认它还在；消失后清理运行态（与正常退出的收尾一致）。
    private func watchAdoptedChild(_ child: AdoptedChild) {
        adoptedWatch?.cancel()
        adoptedWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let engine = self else { return }
                await engine.sleep(.seconds(2))
                if Task.isCancelled { return }
                if !child.isRunning {
                    engine.adoptedGone(child)
                    return
                }
            }
        }
    }

    /// 接管的进程已经消失（停止完成，或被外部结束）：清掉运行态与身份记录。只处理仍是当前进程的那一次。
    private func adoptedGone(_ child: AdoptedChild) {
        guard (process as? AdoptedChild) === child else { return }
        adoptedWatch?.cancel()
        adoptedWatch = nil
        process = nil
        isBackground = false
        portFile = nil
        listenWatch = nil
        watchTimer?.cancel(); watchTimer = nil
        if adoptedRestartVictim {
            adoptedRestartVictim = false // 网络重启中：保留「正在重新监听」与冻结的监听，新进程启动后再清
        } else {
            networkRestarting = false
            activeListen = nil
        }
        EngineChildRecord.remove(dataDir: activeDataDir, ownedBy: child.snapshot.pid, probe: processProbe)
        if case .failed = status {} else { status = .stopped }
        append("[palmhelm] 后台运行的 Bridge 已退出")
    }

    func readPortFile() {
        let url = URL(fileURLWithPath: activeDataDir).appendingPathComponent("local-api.json")
        guard let data = try? Data(contentsOf: url), let pf = try? JSONDecoder().decode(PortFile.self, from: data) else { return }
        portFile = pf
    }

    /// 本机 Bridge 的设备口端点（内置 Bridge 的证书指纹来自本机数据目录文件，可信）。
    var selfEndpoint: PalmhelmEndpoint? {
        guard let pf = portFile else { return nil }
        return PalmhelmEndpoint(host: pf.bind == "0.0.0.0" ? "127.0.0.1" : pf.bind, port: pf.apiPort, https: pf.transport == "https", spki: pf.tls?.spkiSha256)
    }

    struct PalmhelmEndpoint: Equatable { let host: String; let port: Int; let https: Bool; let spki: String? }
}
