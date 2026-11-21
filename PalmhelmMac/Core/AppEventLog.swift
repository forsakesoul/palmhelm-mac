import Darwin
import Foundation

/// App 启动阶段的极小持久记录（A1-081 片 3 的取证）：~/Library/Logs/Palmhelm/app-events.log。
/// 只写固定阶段、固定结果与相对启动的单调毫秒数；不含路径、环境、钥匙串内容、令牌、配对码、正文或系统错误原文。
/// 两份轮转，每份 128 KiB。测试宿主里不写任何文件（directory 为 nil）。
final class AppEventLog: @unchecked Sendable {
    enum Stage: String {
        case launch, legacyImportDone, secretsLoaded, credentialsLoaded, keychainStalled, childLaunch, bridgeStarted, takeover
    }

    enum Result: String {
        case ok, stalled, cancelled, failed
    }

    static let shared = AppEventLog(directory: RuntimeEnvironment.isTestHost ? nil : defaultDirectory())

    private let directory: String?
    private let maxBytes: Int
    private let origin = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()

    init(directory: String?, maxBytes: Int = 128 * 1024) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    static func defaultDirectory() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Palmhelm")
    }

    func mark(_ stage: Stage, _ result: Result = .ok) {
        guard let directory else { return }
        let ms = (DispatchTime.now().uptimeNanoseconds - origin) / 1_000_000
        let line = "{\"ts\":\"\(Date().formatted(.iso8601))\",\"stage\":\"\(stage.rawValue)\",\"result\":\"\(result.rawValue)\",\"ms\":\(ms)}\n"
        lock.lock()
        defer { lock.unlock() }
        append(Data(line.utf8), directory: directory)
    }

    /// 目录与文件都经句柄相对打开；每一步检查结果，任一步失败放弃本次写入（不在未移开的旧文件上继续追加）。
    private func append(_ data: Data, directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 最后一段不跟随链接：目录被替换成链接时直接放弃，不写到链接指向的地方。
        let dir = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { return }
        defer { close(dir) }
        guard BridgeLogFile.isOwnedDirectory(dir) else { return }
        var fd = openAppend(dir, "app-events.log")
        guard fd >= 0 else { return }
        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); return }
        if Int(st.st_size) + data.count > maxBytes {
            close(fd)
            if unlinkat(dir, "app-events.log.1", 0) != 0, errno != ENOENT { return }
            guard renameat(dir, "app-events.log", dir, "app-events.log.1") == 0 else { return }
            fd = openAppend(dir, "app-events.log")
            guard fd >= 0 else { return }
        }
        defer { close(fd) }
        var written = 0
        let total = data.count
        data.withUnsafeBytes { raw in
            while written < total {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: written), total - written)
                if n <= 0 { return }
                written += n
            }
        }
    }

    /// O_NOFOLLOW 相对打开 + O_NONBLOCK（FIFO 没有读端时不阻塞）+ fstat 核普通文件、属主与 0600（权限失败即放弃）。
    private func openAppend(_ dir: Int32, _ name: String) -> Int32 {
        let fd = Darwin.openat(dir, name, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return -1 }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid() else {
            close(fd)
            return -1
        }
        if (st.st_mode & 0o777) != 0o600 {
            guard fchmod(fd, 0o600) == 0, fstat(fd, &st) == 0, (st.st_mode & 0o777) == 0o600 else {
                close(fd)
                return -1
            }
        }
        return fd
    }
}
