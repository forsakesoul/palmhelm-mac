import CryptoKit
import Darwin
import Foundation

// 内置 Bridge 的进程身份（接管用）。Bridge 只写 local-api.json（端口、版本、指纹），不记录自己的 pid 或可执行文件，
// 所以由 App 在启动后台子进程时记下身份（pid、进程启动时间、可执行路径、二进制内容摘要、数据目录、冻结的监听地址），下次打开时逐项核对；任一项不符就不接管、不杀进程。
// 只有后台子进程（启动时没有 BRIDGE_PARENT_PID）才写记录：前台子进程靠父进程守护退出，不能被当作可独立存活的进程接管。

/// 某个 pid 此刻的进程信息（来自系统，不读取进程环境）。
struct BridgeProcessSnapshot: Equatable, Sendable {
    let pid: Int32
    /// p_starttime（秒 × 10⁶ + 微秒）：pid 被复用时必然不同。
    let startMicros: Int64
    /// proc_pidpath：进程实际执行的文件路径（已解析符号链接）。
    let executable: String
}

protocol BridgeProcessProbing: Sendable {
    /// nil：进程不存在、已是僵尸，或读不到信息。
    func snapshot(pid: Int32) -> BridgeProcessSnapshot?
    /// pid 此刻所在的进程组；查询失败为 nil。不参与身份相等判断（Bridge 早期建组不改变身份）。
    func processGroup(pid: Int32) -> Int32?
}

extension BridgeProcessProbing {
    func processGroup(pid: Int32) -> Int32? { nil }
}

struct SystemProcessProbe: BridgeProcessProbing {
    func processGroup(pid: Int32) -> Int32? {
        guard pid > 1 else { return nil }
        let g = getpgid(pid)
        return g > 0 ? g : nil
    }

    func snapshot(pid: Int32) -> BridgeProcessSnapshot? {
        guard pid > 1 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, info.kp_proc.p_pid == pid, info.kp_proc.p_stat != SZOMB else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let t = info.kp_proc.p_starttime
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return BridgeProcessSnapshot(pid: pid, startMicros: Int64(t.tv_sec) * 1_000_000 + Int64(t.tv_usec), executable: path)
    }
}

/// 规范化路径：解析符号链接与 ./..，用于比较数据目录与可执行文件。
func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

/// 私有文件的安全读写（App 内共用的 seam；身份记录等凭据类文件都走这里，不各自手写）。
/// 读：O_NOFOLLOW 打开（末端是符号链接即失败），fstat 校验普通文件、属主为本人、权限恰为 0600、大小不超过上限，之后才读内容。
/// 写：同目录创建 O_EXCL 且 0600 的暂存文件，写入并 fsync，再 rename 原子发布；任何一步失败都删除暂存文件并抛错。
enum PrivateFile {
    enum Failure: Error, Equatable {
        case unsafe(String)
        case io(String)
    }

    static let defaultMaxBytes = 64 * 1024

    static func read(_ path: String, maxBytes: Int = defaultMaxBytes) throws -> Data {
        // O_NONBLOCK：FIFO 等没有写入方的文件在 open 时不阻塞（否则会卡住主线程）；随后 fstat 拒绝非普通文件
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unsafe(errno == ELOOP ? "symlink" : "open") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure.io("fstat") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafe("not_regular") }
        guard st.st_uid == geteuid() else { throw Failure.unsafe("owner") }
        guard (st.st_mode & 0o777) == 0o600 else { throw Failure.unsafe("mode") }
        guard st.st_size >= 0, Int(st.st_size) <= maxBytes else { throw Failure.unsafe("size") }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { throw Failure.io("read") }
            if n == 0 { break }
            out.append(chunk, count: n)
            guard out.count <= maxBytes else { throw Failure.unsafe("size") }
        }
        return out
    }

    /// createMode：open 时的创建权限（生产恒为 0600；测试用它模拟 umask 削减后的结果，不改进程全局 umask）。
    static func writeAtomically(_ data: Data, to path: String, createMode: mode_t = 0o600) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let tmp = "\(dir)/.\(name).tmp-\(getpid())-\(UUID().uuidString)"
        let fd = Darwin.open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, createMode)
        guard fd >= 0 else { throw Failure.io("create") }
        do {
            defer { close(fd) }
            // umask 会把 open 的 0600 削减（如 0277 → 0400），这里在 fd 上显式设为 0600 并核实，不符就不发布
            guard fchmod(fd, 0o600) == 0 else { throw Failure.io("fchmod") }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & 0o777) == 0o600 else { throw Failure.unsafe("staged_mode") }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { throw Failure.io("write") }
                    offset += n
                }
            }
            guard fsync(fd) == 0 else { throw Failure.io("fsync") }
        } catch {
            unlink(tmp)
            throw error
        }
        guard rename(tmp, path) == 0 else {
            unlink(tmp)
            throw Failure.io("rename")
        }
    }

    static func remove(_ path: String) {
        unlink(path) // 删除的是链接本身，不跟随
    }
}

/// 可执行文件的内容摘要（SHA-256，分块读取）。只在启动与接管时各算一次；存活检查不重新计算。
enum BinaryDigest {
    static func of(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: canonicalPath(path)) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        do {
            while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 旧进程启动时实际冻结的监听：接管时以它为基线，而不是当前网络（否则期间的网络变化会被当作「已监听」而漏掉）。
struct ListenBaseline: Codable, Equatable {
    let lan: String?
    let tailscale: String?
    let intentLan: Bool
    let intentTailscale: Bool

    init(_ r: ListenResolution) {
        lan = r.lan
        tailscale = r.tailscale
        intentLan = r.intent.lan
        intentTailscale = r.intent.tailscale
    }

    var resolution: ListenResolution {
        ListenResolution(lan: lan, tailscale: tailscale, intent: ListenIntent(lan: intentLan, tailscale: intentTailscale))
    }
}

/// 后台子进程的身份记录（数据目录 engine-child.json，0600，经 PrivateFile 读写）。
/// environment 只保存「比较域」：机密已替换为指纹（redacted），比较时不再二次转换。
struct EngineChildRecord: Codable, Equatable {
    static let fileName = "engine-child.json"
    static let schema = 1

    let schemaVersion: Int
    /// 只有后台运行的子进程才会写入；读取时必须为 true，否则不接管。
    let background: Bool
    let pid: Int32
    let startMicros: Int64
    let executable: String
    let binaryDigest: String
    let dataDir: String
    let environment: [String: String]
    let listen: ListenBaseline

    init(background: Bool, pid: Int32, startMicros: Int64, executable: String, binaryDigest: String, dataDir: String, environment: [String: String], listen: ListenBaseline) {
        schemaVersion = Self.schema
        self.background = background
        self.pid = pid
        self.startMicros = startMicros
        self.executable = executable
        self.binaryDigest = binaryDigest
        self.dataDir = dataDir
        self.environment = environment
        self.listen = listen
    }

    static func url(dataDir: String) -> URL {
        URL(fileURLWithPath: canonicalPath(dataDir)).appendingPathComponent(fileName)
    }

    static func load(dataDir: String) -> EngineChildRecord? {
        guard let data = try? PrivateFile.read(url(dataDir: dataDir).path),
              let record = try? JSONDecoder().decode(EngineChildRecord.self, from: data),
              record.schemaVersion == schema, record.background else { return nil }
        return record
    }

    func save(dataDir: String) throws {
        try PrivateFile.writeAtomically(try JSONEncoder().encode(self), to: Self.url(dataDir: dataDir).path)
    }

    /// 记录所指的进程是否仍是同一个进程：pid 存活且启动时间相符。pid 被无关进程复用时启动时间不同，视为陈旧。
    /// 这是存活判定的唯一入口（清理与发布都用它），不比较 App 当前的可执行路径、数据目录或摘要。
    func isSameLiveProcess(_ probe: BridgeProcessProbing) -> Bool {
        guard let s = probe.snapshot(pid: pid) else { return false }
        return s.startMicros == startMicros
    }

    /// 只删本次要清理的进程自己的记录（记录 pid == ownedBy），或记录所指进程已不是同一个存活进程（陈旧）。
    /// 其余记录属于另一个仍在运行的后台 Bridge，必须保留：否则它再也无法被接管。ownedBy 为 nil 时只清陈旧记录。
    /// 无法解码的文件没有身份可判断，同样保留。
    static func remove(dataDir: String, ownedBy pid: Int32?, probe: BridgeProcessProbing) {
        let path = url(dataDir: dataDir).path
        guard let data = try? PrivateFile.read(path),
              let record = try? JSONDecoder().decode(EngineChildRecord.self, from: data) else { return }
        let owned = pid != nil && record.pid == pid
        guard owned || !record.isSameLiveProcess(probe) else { return }
        PrivateFile.remove(path)
    }

    /// 比较域：BRIDGE_PARENT_PID 是每次 App 启动都不同的运行期值，不参与「设置是否有更改」；FEISHU_APP_SECRET 只保留 SHA-256 指纹。
    /// 只在「当前设置」与「启动时环境」两侧各调用一次，结果直接比较，不做二次转换。
    static func redacted(_ env: [String: String]) -> [String: String] {
        var out = env
        out.removeValue(forKey: "BRIDGE_PARENT_PID")
        if let secret = out["FEISHU_APP_SECRET"] {
            out["FEISHU_APP_SECRET"] = "sha256:" + SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }
}

/// 接管决策（纯函数）。
enum TakeoverDecision: Equatable {
    /// 不接管：没有记录、记录不是后台进程、进程已不在、或身份不符（pid 被复用、不是本 App 内置的 palmhelm-bridge、数据目录不同）。
    case none
    /// 身份全部相符且与当前 App 内置版本的内容一致：直接托管。
    case adopt
    /// 身份相符但内容与当前 App 内置的不同（App 已更新）：先停掉，再按新版本启动。
    case replace
}

enum TakeoverPolicy {
    /// record：数据目录里的记录；snapshot：record.pid 此刻的进程（nil = 已不存在）；executable：当前 App 内置（或设置指定）的 Bridge 路径；
    /// binaryDigest：该文件此刻的内容摘要（nil = 读不到，无法判断版本，不接管）。
    static func decide(record: EngineChildRecord, snapshot: BridgeProcessSnapshot?, dataDir: String, executable: String, binaryDigest: String?) -> TakeoverDecision {
        guard record.background, record.dataDir == canonicalPath(dataDir) else { return .none }
        guard let s = snapshot, s.pid == record.pid, s.startMicros == record.startMicros, canonicalPath(s.executable) == record.executable else { return .none }
        guard record.executable == canonicalPath(executable), let digest = binaryDigest else { return .none }
        return record.binaryDigest == digest ? .adopt : .replace
    }
}

/// 信号发送：0 = 系统调用成功，其余为 errno。
typealias ProcessSignal = (Int32, Int32) -> Int32

/// 系统 kill 的结果（成功 0，否则 errno）。
func systemSignal(_ pid: Int32, _ sig: Int32) -> Int32 { Darwin.kill(pid, sig) == 0 ? 0 : errno }

/// 强杀的结论（日志与验收用）。只有 groupSignaled / rootSignaled 表示信号已成功发出，且都不等于“已确认消失”；
/// rootSignaled 只说明根进程的信号成功，子进程清理未确认。notRunning = 身份不符或进程已不在（零信号 / ESRCH），不是成功强杀。failed = 系统调用失败（如 EPERM），不重试、不换目标。
enum ChildKillOutcome: Equatable {
    case groupSignaled
    case rootSignaled(String)
    case notRunning
    case failed(errno: Int32, group: Bool)
}

/// #107：Mac 对其已确认托管的 Bridge 的强杀 seam（ProcessChild 与 AdoptedChild 共用）。
/// Bridge 在 BRIDGE_MANAGED_PROCESS_GROUP=1 时自建独立进程组（组长 = 自己），dns-sd 等子进程继承该组：
/// 只有此刻身份（pid + 启动时间 + 路径）仍是被托管的那个、且 getpgid(pid)==pid，才一次 kill(-pid, SIGKILL)；
/// 不向 App 组、未知 / 复用的 PID 或其它进程发信号。组不符 / 查询失败 / 旧的无标志进程：只对已确认的根进程发单 PID SIGKILL，并如实报告子进程未确认。
enum ManagedProcessGroup {
    static let envKey = "BRIDGE_MANAGED_PROCESS_GROUP"
    static func flagged(_ env: [String: String]) -> Bool { env[envKey] == "1" }

    static func forceKill(snapshot: BridgeProcessSnapshot, flagged: Bool, probe: BridgeProcessProbing, signal: ProcessSignal) -> ChildKillOutcome {
        guard probe.snapshot(pid: snapshot.pid) == snapshot else { return .notRunning }
        let group = flagged && snapshot.pid > 1 && probe.processGroup(pid: snapshot.pid) == snapshot.pid
        let rc = signal(group ? -snapshot.pid : snapshot.pid, SIGKILL)
        switch rc {
        case 0: return group ? .groupSignaled : .rootSignaled(flagged ? "group_unconfirmed" : "unflagged")
        case ESRCH:
            // ESRCH 后复核一次身份（不重试信号）：根进程仍在 = 信号没送达，按失败报告；已不在 / 身份变了才是 notRunning。
            return probe.snapshot(pid: snapshot.pid) == snapshot ? .failed(errno: ESRCH, group: group) : .notRunning
        default: return .failed(errno: rc, group: group)
        }
    }
}

/// 接管来的子进程：身份以 pid + 启动时间 + 可执行路径判定，pid 被复用后不再视为同一个进程。停止与强杀都直接作用于这个 pid。
/// 存活检查只读进程表，不重新计算二进制摘要。
@MainActor
final class AdoptedChild: EngineChild {
    let snapshot: BridgeProcessSnapshot
    private let probe: BridgeProcessProbing
    private let signal: ProcessSignal
    /// 记录里冻结的启动环境带 BRIDGE_MANAGED_PROCESS_GROUP=1：这个 Bridge 自建了独立进程组。
    private let managedGroup: Bool
    private(set) var lastKillOutcome: ChildKillOutcome?

    init(snapshot: BridgeProcessSnapshot, probe: BridgeProcessProbing, managedGroup: Bool = false, signal: @escaping ProcessSignal) {
        self.snapshot = snapshot
        self.probe = probe
        self.managedGroup = managedGroup
        self.signal = signal
    }

    var pid: Int32? { snapshot.pid }
    var isRunning: Bool { probe.snapshot(pid: snapshot.pid) == snapshot }
    func terminate() { if isRunning { _ = signal(snapshot.pid, SIGTERM) } }
    func kill() { lastKillOutcome = ManagedProcessGroup.forceKill(snapshot: snapshot, flagged: managedGroup, probe: probe, signal: signal) }
}
