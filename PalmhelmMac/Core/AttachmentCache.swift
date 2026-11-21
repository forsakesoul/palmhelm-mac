import AppKit

/// 附件来源（D5）：用户引用 = 拖入 / 粘贴的文件，按原路径引用，绝不清理；缓存位图 = 剪贴板里没有文件的位图，由本 App 转 PNG 写进自己的缓存目录。
/// 只有「缓存位图」才可能被清理。来源随发送快照与恢复一起保留；旧快照没有来源时按「用户引用」处理（宁可不清理）。
enum AttachmentSource: String, Equatable, Sendable { case userReference, cachedBitmap }

/// 本 App 自己的位图缓存：~/Library/Caches/Palmhelm/attachments（目录 0700、文件 0600）。不写 Bridge 数据目录，也不扫旧的 Bridge attachments 目录。
enum AttachmentCache {
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Palmhelm/attachments", isDirectory: true)
    }

    struct Failure: Error, Equatable { let message: LText }

    // MARK: 自有登记（F1）
    // 清理只删「本 App 自己 store 写入」的文件：缓存目录里一个只记文件名与 inode 的登记清单（.owned.json，0600，不是 <UUID>.png 所以清理遍历不会碰它）。
    // 用户自己放进缓存目录、名为 UUID.png 的老文件不在清单里，一律不删；清单是链接 / 非普通文件 / 解析失败 / inode 对不上都按「没有登记」处理，宁可不删。
    static let manifestName = ".owned.json"
    struct Owned: Codable, Equatable { var name: String; var ino: UInt64 }

    private static func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
    }

    static func readManifest(in dir: URL) -> [Owned]? {
        let url = dir.appendingPathComponent(manifestName)
        guard lstatType(url) == .typeRegular, let data = try? Data(contentsOf: url), data.count < 1_000_000 else { return nil }
        return try? JSONDecoder().decode([Owned].self, from: data)
    }

    private static func writeManifest(_ list: [Owned], in dir: URL) throws {
        let url = dir.appendingPathComponent(manifestName)
        if lstatType(url) != nil, lstatType(url) != .typeRegular { throw Failure(message: LText(String(localized: "图片缓存登记文件被替换成了链接，已拒绝使用"))) }
        try JSONEncoder().encode(list).write(to: url, options: .atomic)
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch { throw Failure(message: LText(String(localized: "图片缓存登记文件权限设置失败"))) }
    }

    /// 登记一个刚写入的缓存文件（store 内部用；测试也用它造「本 App 写入」的老文件）。
    static func register(_ url: URL, in dir: URL) throws {
        guard let ino = inode(url) else { throw Failure(message: LText(String(localized: "图片缓存文件状态读取失败"))) }
        var list = readManifest(in: dir) ?? []
        list.removeAll { $0.name == url.lastPathComponent }
        list.append(Owned(name: url.lastPathComponent, ino: ino))
        try writeManifest(list, in: dir)
    }

    private static func lstatType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType // attributesOfItem 不跟随符号链接
    }

    /// 确认缓存目录是真实目录（不是符号链接 / 文件）；不存在则以 0700 创建，已存在的权限不对就收紧，收紧失败要报错（不静默）。
    static func prepare(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if lstatType(dir) == nil {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { throw Failure(message: LText(String(localized: "图片缓存目录创建失败"))) }
        }
        guard lstatType(dir) == .typeDirectory else { throw Failure(message: LText(String(localized: "图片缓存目录被替换成了链接或文件，已拒绝使用"))) }
        let perm = ((try? fm.attributesOfItem(atPath: dir.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if perm & 0o777 != 0o700 {
            do { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) } catch { throw Failure(message: LText(String(localized: "图片缓存目录权限设置失败"))) }
        }
    }

    /// 位图转 PNG 写入缓存：文件名新 UUID，权限 0600；失败（含权限设置失败）抛出，调用方显示。
    static func store(_ image: NSImage, in dir: URL = defaultDirectory) throws -> String {
        try prepare(dir)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure(message: LText(String(localized: "图片没能转成 PNG")))
        }
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        do { try png.write(to: url, options: .atomic) } catch { throw Failure(message: LText(String(localized: "图片没能保存，请再试一次"))) }
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } catch {
            try? FileManager.default.removeItem(at: url)
            throw Failure(message: LText(String(localized: "图片缓存文件权限设置失败，已丢弃")))
        }
        do { try register(url, in: dir) } catch {
            try? FileManager.default.removeItem(at: url) // 没登记上就不留：留下的文件以后谁也不会清理
            throw (error as? Failure) ?? Failure(message: LText(String(localized: "图片缓存登记失败，已丢弃")))
        }
        return url.path
    }

    /// 清理：只处理登记清单里的文件（F1）；且仍要满足：缓存目录的直接子级、普通文件（lstat，不跟随符号链接）、文件名是 <UUID>.png、inode 与登记一致、修改时间早于 maxAge。
    /// 目录本身是符号链接 / 不是目录、清单不可信，都整个拒绝；不递归，不碰别的目录（包括旧 Bridge 的 attachments）。返回删掉的文件数。清单随之去掉已删除 / 已不存在的项。
    @discardableResult
    static func cleanup(in dir: URL = defaultDirectory, now: Date = Date(), maxAge: TimeInterval = AttachmentCache.maxAge) -> Int {
        let fm = FileManager.default
        guard lstatType(dir) == .typeDirectory, let owned = readManifest(in: dir) else { return 0 }
        var removed = 0
        var keep: [Owned] = []
        for o in owned {
            let url = dir.appendingPathComponent(o.name)
            guard url.deletingLastPathComponent().path == dir.path, o.name == url.lastPathComponent, url.pathExtension == "png", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue } // 不合规的登记项直接丢弃
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue } // 文件已不存在：去掉登记
            guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.systemFileNumber] as? UInt64) == o.ino else { continue } // 被换过 / 不是普通文件：不删，登记也作废
            guard let mtime = attrs[.modificationDate] as? Date, now.timeIntervalSince(mtime) > maxAge else { keep.append(o); continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 } else { keep.append(o) }
        }
        if keep != owned { try? writeManifest(keep, in: dir) }
        return removed
    }
}
