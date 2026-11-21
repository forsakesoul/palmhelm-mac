import Darwin
import Foundation

/// Bridge 持久日志的只读尾部（A1-081 片 2）：<数据目录>/logs/bridge.log。
/// 从已解析的数据目录根以目录句柄逐段相对打开（O_DIRECTORY|O_NOFOLLOW），任何一段是链接即拒绝；文件本身 O_NONBLOCK 打开后 fstat 核普通文件、属主与 0600。
/// 只读末尾有界字节，不整文件载入。读到的历史行只用于展示，不喂给 BridgeEngine 的状态判断。
enum BridgeLogFile {
    static let maxTailBytes = 256 * 1024
    static let maxLines = 500

    enum Result: Equatable {
        case lines([String])
        case absent
        case unsafe(String)
    }

    static func path(dataDir: String) -> String { dataDir + "/logs/bridge.log" }

    static func tail(dataDir: String) -> Result {
        // 数据目录本身可能经由系统别名（如 /tmp → /private/tmp）：先解析到真实路径，之后的每一段都不跟随链接。
        let resolved = URL(fileURLWithPath: dataDir).resolvingSymlinksInPath().path
        let root = Darwin.open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { return .unsafe("root") }
        defer { close(root) }
        guard isOwnedDirectory(root) else { return .unsafe("root_owner") }
        let logs = Darwin.openat(root, "logs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard logs >= 0 else { return errno == ENOENT ? .absent : .unsafe(errno == ELOOP ? "logs_symlink" : "logs") }
        defer { close(logs) }
        guard isOwnedDirectory(logs) else { return .unsafe("logs_owner") }
        let fd = Darwin.openat(logs, "bridge.log", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .absent : .unsafe(errno == ELOOP ? "symlink" : "open") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return .unsafe("not_regular") }
        guard st.st_uid == geteuid(), (st.st_mode & 0o777) == 0o600 else { return .unsafe("owner_or_mode") }
        let size = Int(st.st_size)
        let start = max(0, size - maxTailBytes)
        guard lseek(fd, off_t(start), SEEK_SET) == off_t(start) else { return .unsafe("seek") }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < size - start {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, size - start - data.count)) }
            if n < 0 { return .unsafe("read") }
            if n == 0 { break }
            data.append(chunk, count: n)
        }
        if start > 0, let nl = data.firstIndex(of: 0x0A) { data.removeSubrange(...nl) } // 截断点之前的半行丢弃
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        return .lines(lines)
    }

    /// 目录句柄是本人所有的目录（不看路径；路径已由调用方逐段相对打开）。
    static func isOwnedDirectory(_ fd: Int32) -> Bool {
        var st = stat()
        return fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == geteuid()
    }
}
