import CryptoKit
import Darwin
import Foundation

// #49：账户来源文件的安全存储（Owner 裁决 O1-250）。固定文件 <数据目录>/account-sources.json，权限 0600。
// 写入 = 同目录 O_EXCL 临时文件 + fsync + renameat 原子替换（不需要清理旧文件）。
// 没有文件 = 没有配置；文件存在却无法读取 = 已配置但损坏：Bridge 启动时按 config_invalid 失败，Mac 端提示并禁止保存，不静默回退。
enum AccountSourcesStore {
    static let fileName = "account-sources.json"
    static let maxBytes = 64 * 1024

    enum StoreError: Error, Equatable {
        case untrustedRoot
        case missing
        case unsafeFile
        case tooLarge
        case decode
        case io
    }

    /// 文件状态：没有配置（缺失）、可读的当前内容（摘要）、或已配置但不可用（不可读 / 不合格）。
    enum FileState: Equatable {
        case absent
        case readable(digest: String)
        case unreadable
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 数据根（F1）

    /// 解析数据根的真实路径。入口只接受规范绝对路径：拒绝 . / .. / 空段（如 //）与末尾斜杠；
    /// 之后逐组件 lstat，中间组件的系统别名（如 /var → /private/var）按规则展开，末端组件不得是链接（数据根自身）。
    /// 每个真实目录须为 root 或本人所有、组与他人不可写；最终目录须为本人所有。create 时缺失的最终目录以 0700 创建。
    static func resolveRoot(_ path: String, create: Bool) throws -> String {
        guard path.hasPrefix("/"), path == "/" || !path.hasSuffix("/") else { throw StoreError.untrustedRoot }
        let names = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard !names.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw StoreError.untrustedRoot }
        var queue = names
        var current = "/"
        var hops = 0
        while !queue.isEmpty {
            let name = queue.removeFirst()
            try requireTrustedDirectory(current, requireUser: false)
            let next = current == "/" ? "/" + name : current + "/" + name
            var st = stat()
            if lstat(next, &st) != 0 {
                guard errno == ENOENT, create, queue.isEmpty else { throw StoreError.missing }
                guard mkdir(next, 0o700) == 0, lstat(next, &st) == 0 else { throw StoreError.io }
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                // 数据根自身不能是链接（末端组件）；只有中间组件的系统别名可以展开。
                guard !queue.isEmpty else { throw StoreError.untrustedRoot }
                hops += 1
                guard hops <= 40 else { throw StoreError.untrustedRoot }
                var buf = [CChar](repeating: 0, count: 4097)
                let n = readlink(next, &buf, 4096)
                guard n > 0 else { throw StoreError.untrustedRoot }
                let target = String(cString: buf)
                guard !target.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
                    throw StoreError.untrustedRoot
                }
                if target.hasPrefix("/") { current = "/" }
                queue = target.split(separator: "/").map(String.init) + queue
                continue
            }
            guard (st.st_mode & S_IFMT) == S_IFDIR else { throw StoreError.untrustedRoot }
            current = next
        }
        try requireTrustedDirectory(current, requireUser: true)
        return current
    }

    private static func requireTrustedDirectory(_ path: String, requireUser: Bool) throws {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw StoreError.untrustedRoot }
        let uid = geteuid()
        if requireUser {
            guard st.st_uid == uid else { throw StoreError.untrustedRoot }
        } else {
            guard st.st_uid == 0 || st.st_uid == uid else { throw StoreError.untrustedRoot }
        }
        guard st.st_mode & 0o022 == 0 else { throw StoreError.untrustedRoot }
    }

    /// 打开已核验的数据根为目录句柄（调用方关闭）。打开后 fstat 与 lstat 比对身份。
    static func openRoot(_ dataDir: String, create: Bool) throws -> Int32 {
        let real = try resolveRoot(dataDir, create: create)
        var before = stat()
        guard lstat(real, &before) == 0 else { throw StoreError.untrustedRoot }
        let fd = open(real, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.untrustedRoot }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino else {
            close(fd)
            throw StoreError.untrustedRoot
        }
        return fd
    }

    // MARK: 文件

    /// 读取固定文件：普通文件、本人所有、0600、大小有界；不跟随链接。
    static func readFile(root: Int32) throws -> Data {
        let fd = openat(root, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { throw StoreError.missing }
            throw StoreError.unsafeFile
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw StoreError.unsafeFile }
        guard st.st_uid == geteuid(), st.st_mode & 0o777 == 0o600 else { throw StoreError.unsafeFile }
        guard st.st_size <= off_t(maxBytes) else { throw StoreError.tooLarge }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxBytes {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw StoreError.io }
            if n == 0 { break }
            data.append(chunk, count: n)
        }
        guard data.count <= maxBytes else { throw StoreError.tooLarge }
        return data
    }

    /// 原子替换：同目录 O_EXCL 临时文件 0600 → 写入 → fsync → renameat → fsync 目录。失败时旧文件保持不变，临时文件被清理。
    static func writeFile(root: Int32, data: Data) throws {
        guard data.count <= maxBytes else { throw StoreError.tooLarge }
        let tmp = ".account-sources-tmp-" + UUID().uuidString
        let fd = openat(root, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io }
        var ok = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { ok = false; break }
                offset += n
            }
        }
        if ok, fsync(fd) != 0 { ok = false }
        close(fd)
        guard ok, renameat(root, tmp, root, fileName) == 0 else {
            unlinkat(root, tmp, 0)
            throw StoreError.io
        }
        _ = fsync(root)
    }

    // MARK: 高层操作

    /// 当前文件状态（用于「待重启」比较与读取前的判断）。不可读即 unreadable，不当作缺失。
    static func fileState(dataDir: String) -> FileState {
        let root: Int32
        do {
            root = try openRoot(dataDir, create: false)
        } catch StoreError.missing {
            return .absent
        } catch {
            return .unreadable
        }
        defer { close(root) }
        do {
            return .readable(digest: digest(of: try readFile(root: root)))
        } catch StoreError.missing {
            return .absent
        } catch {
            return .unreadable
        }
    }

    /// 读取列表：缺失返回 []（未配置）；存在但不合格或内容无法解码抛错（调用方不得当成空列表）。
    static func load(dataDir: String) throws -> [AccountSourceEntry] {
        let root: Int32
        do {
            root = try openRoot(dataDir, create: false)
        } catch StoreError.missing {
            return []
        }
        defer { close(root) }
        let data: Data
        do {
            data = try readFile(root: root)
        } catch StoreError.missing {
            return []
        }
        guard let entries = try? JSONDecoder().decode([AccountSourceEntry].self, from: data) else { throw StoreError.decode }
        return entries
    }

    /// 保存非空列表：原子替换固定文件，返回新摘要。
    static func save(_ entries: [AccountSourceEntry], dataDir: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entries)
        let root = try openRoot(dataDir, create: true)
        defer { close(root) }
        try writeFile(root: root, data: data)
        return digest(of: data)
    }

    /// 清空（取消配置）：先确认固定名字是本人的普通文件（不是链接、目录），再删除这一个文件；没有文件即已是清空状态。
    static func clear(dataDir: String) throws {
        let root: Int32
        do {
            root = try openRoot(dataDir, create: false)
        } catch StoreError.missing {
            return
        }
        defer { close(root) }
        var st = stat()
        guard fstatat(root, fileName, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw StoreError.unsafeFile
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid() else { throw StoreError.unsafeFile }
        guard unlinkat(root, fileName, 0) == 0 else { throw StoreError.io }
        _ = fsync(root)
    }

    /// 环境变量的路径。只有确认固定名字不存在（lstat ENOENT）才返回 nil（未配置，Bridge 行为与改动前相同）。
    /// 其它任何节点——普通文件、目录、悬空或任意链接、权限或属主不对、无法判断的错误——都照常返回固定路径：
    /// 交给 Bridge 按 config_invalid 拒绝启动，绝不把「坏配置」静默变成「未配置」。这里不打开、不跟随链接。
    static func configuredPath(dataDir: String) -> String? {
        guard !dataDir.isEmpty else { return nil }
        let candidate = dataDir + "/" + fileName
        var st = stat()
        if lstat(candidate, &st) != 0, errno == ENOENT { return nil }
        return candidate
    }
}
