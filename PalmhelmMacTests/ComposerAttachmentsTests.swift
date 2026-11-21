import AppKit
import PalmhelmKit
import XCTest
@testable import PalmhelmMac

final class ComposerAttachmentsTests: XCTestCase {
    private var root: URL!
    private var cache: URL { root.appendingPathComponent("Caches/Palmhelm/attachments") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeFile(_ url: URL, age: TimeInterval = 0) throws {
        try Data([1, 2, 3]).write(to: url)
        if age > 0 { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
    }
    private func attachment(_ path: String, _ source: AttachmentSource = .userReference) -> ComposerAttachment {
        ComposerAttachment(path: path, thumbnail: NSImage(size: NSSize(width: 1, height: 1)), source: source)
    }
    private func image() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.addRepresentation(rep)
        return img
    }
    private func pngFile(_ url: URL) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
    private func perm(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    private func uuidPNG(_ dir: URL) -> URL { dir.appendingPathComponent("\(UUID().uuidString).png") }

    // MARK: 缓存位图：位置、权限、来源

    func testBitmapGoesToCacheDirWithPermissionsAndCachedSource() throws {
        var list: [ComposerAttachment] = []
        XCTAssertNil(ComposerAttachments.add([.bitmap(image())], to: &list, editable: true, cacheDir: cache))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].source, .cachedBitmap)
        XCTAssertEqual(URL(fileURLWithPath: list[0].path).deletingLastPathComponent().path, cache.path)
        XCTAssertEqual(perm(cache), 0o700)
        XCTAssertEqual(perm(URL(fileURLWithPath: list[0].path)), 0o600)
        XCTAssertNotNil(UUID(uuidString: URL(fileURLWithPath: list[0].path).deletingPathExtension().lastPathComponent))
    }

    func testLooseExistingCacheDirIsTightenedTo0700() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try AttachmentCache.store(image(), in: cache)
        XCTAssertEqual(perm(cache), 0o700)
    }

    func testCacheDirReplacedBySymlinkIsRefusedForStoreAndCleanup() throws {
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let old = uuidPNG(real)
        try makeFile(old, age: 30 * 86400)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: real)
        XCTAssertThrowsError(try AttachmentCache.store(image(), in: cache))
        XCTAssertEqual(AttachmentCache.cleanup(in: cache), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "链接指向的目录不被清理")
    }

    // MARK: 清理规则

    func testCleanupDeletesOnlyOldRegularUUIDPNGDirectChildren() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let old = uuidPNG(cache), fresh = uuidPNG(cache), edge = uuidPNG(cache)
        try owned(old, age: 8 * 86400)
        try owned(fresh, age: 6 * 86400)
        try owned(edge, age: 7 * 86400 - 60) // 7 天边界内：不删
        // 以下即使被登记也不合规：非 UUID 名、非 png、嵌套子目录
        let notUUID = cache.appendingPathComponent("notes.png"); try owned(notUUID, age: 30 * 86400)
        let wrongExt = cache.appendingPathComponent("\(UUID().uuidString).jpg"); try owned(wrongExt, age: 30 * 86400)
        let sub = cache.appendingPathComponent("sub"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = uuidPNG(sub); try makeFile(nested, age: 30 * 86400)
        XCTAssertEqual(AttachmentCache.cleanup(in: cache), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for keep in [fresh, edge, notUUID, wrongExt, nested] { XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), keep.lastPathComponent) }
    }

    func testCleanupNeverFollowsOrDeletesSymlinkNamedAsUUID() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("secret.png"); try makeFile(target, age: 30 * 86400)
        let link = uuidPNG(cache)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // 链接本身也要是「老的」，否则只是因为太新而没被删，测不到“不跟随 / 不删链接”的守卫
        var old = [timeval(tv_sec: time(nil) - 30 * 86400, tv_usec: 0), timeval(tv_sec: time(nil) - 30 * 86400, tv_usec: 0)]
        XCTAssertEqual(lutimes(link.path, &old), 0)
        try AttachmentCache.register(link, in: cache) // 即使被登记，链接也不删
        XCTAssertEqual(AttachmentCache.cleanup(in: cache), 0)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testCleanupSkipsAnOldDirectoryNamedLikeAUUIDPNG() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let dir = uuidPNG(cache)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: dir.path)
        try AttachmentCache.register(dir, in: cache)
        XCTAssertEqual(AttachmentCache.cleanup(in: cache), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "不是普通文件：不删")
    }

    // MARK: F1 自有登记

    /// 造一个「本 App 写入」的缓存文件：真实写入后登记，再把修改时间改老。
    private func owned(_ url: URL, age: TimeInterval) throws {
        try makeFile(url, age: age)
        try AttachmentCache.register(url, in: cache)
    }

    func testForeignOldUUIDPNGIsKeptWhileAnOldStoredBitmapIsDeleted() throws {
        let storedPath = try AttachmentCache.store(image(), in: cache)
        let stored = URL(fileURLWithPath: storedPath)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: stored.path)
        let foreign = uuidPNG(cache); try makeFile(foreign, age: 30 * 86400) // 用户自己放进缓存目录、名为 UUID.png 的老文件
        XCTAssertEqual(AttachmentCache.cleanup(in: cache), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path), "本 App 写入且超过 7 天：删")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "未登记：一律不删")
        XCTAssertEqual(perm(cache.appendingPathComponent(AttachmentCache.manifestName)), 0o600)
        XCTAssertEqual(AttachmentCache.readManifest(in: cache), [], "删掉的项从登记里去掉")
    }

    func testManifestThatIsASymlinkOrGarbageDeletesNothing() throws {
        let f = uuidPNG(cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try owned(f, age: 30 * 86400)
        let manifest = cache.appendingPathComponent(AttachmentCache.manifestName)
        let real = root.appendingPathComponent("real-manifest.json")
        try FileManager.default.moveItem(at: manifest, to: real)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: real) // 清单被换成链接
        XCTAssertEqual(AttachmentCache.cleanup(in: cache), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        try FileManager.default.removeItem(at: manifest)
        try Data("not json".utf8).write(to: manifest) // 被篡改成垃圾
        XCTAssertEqual(AttachmentCache.cleanup(in: cache), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testManifestListingAForeignFileWithTheWrongInodeDoesNotDelete() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let foreign = uuidPNG(cache); try makeFile(foreign, age: 30 * 86400)
        let forged = [AttachmentCache.Owned(name: foreign.lastPathComponent, ino: 1)] // 篡改：把外来文件写进清单，inode 对不上
        try JSONEncoder().encode(forged).write(to: cache.appendingPathComponent(AttachmentCache.manifestName))
        XCTAssertEqual(AttachmentCache.cleanup(in: cache), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testStoreFailsAndLeavesNoFileWhenTheManifestIsALink() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent(AttachmentCache.manifestName), withDestinationURL: root.appendingPathComponent("elsewhere.json"))
        XCTAssertThrowsError(try AttachmentCache.store(image(), in: cache))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".png") }
        XCTAssertTrue(leftovers.isEmpty, "登记不上就不留文件")
    }

    func testCleanupDoesNotScanLegacyBridgeAttachmentsDir() throws {
        let legacy = root.appendingPathComponent("bridge/attachments")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let f = uuidPNG(legacy); try makeFile(f, age: 30 * 86400)
        XCTAssertEqual(AttachmentCache.cleanup(in: cache), 0) // 缓存目录不存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    // MARK: 用户引用：绝不删

    func testUserFileInCacheDirNamedUUIDPNGIsNeverDeletedByRemove() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let f = uuidPNG(cache); try makeFile(f)
        var list = [attachment(f.path, .userReference)] // 用户引用的文件恰好在缓存目录且名为 UUID.png
        XCTAssertTrue(ComposerAttachments.remove(list[0], from: &list, editable: true))
        XCTAssertTrue(list.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "移除只脱离草稿，不碰文件")
    }

    func testRemoveCachedBitmapOnlyDetachesFromDraft() throws {
        var list: [ComposerAttachment] = []
        ComposerAttachments.add([.bitmap(image())], to: &list, editable: true, cacheDir: cache)
        let path = list[0].path
        ComposerAttachments.remove(list[0], from: &list, editable: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "统一按 TTL 清理，不做引用计数，也不立即删")
    }

    func testFileURLIsReferencedInPlaceNotCopied() throws {
        let f = root.appendingPathComponent("shot.png"); try pngFile(f)
        var list: [ComposerAttachment] = []
        XCTAssertNil(ComposerAttachments.add([.file(f)], to: &list, editable: true, cacheDir: cache))
        XCTAssertEqual(list[0].path, f.path)
        XCTAssertEqual(list[0].source, .userReference)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "不复制进缓存")
    }

    func testMissingOrUnreadableFileGivesErrorAndKeepsList() throws {
        let existing = root.appendingPathComponent("a.png"); try pngFile(existing)
        var list: [ComposerAttachment] = []
        ComposerAttachments.add([.file(existing)], to: &list, editable: true, cacheDir: cache)
        let err = ComposerAttachments.add([.file(root.appendingPathComponent("gone.png"))], to: &list, editable: true, cacheDir: cache)
        XCTAssertNotNil(err)
        XCTAssertEqual(list.count, 1, "已有附件保留")
    }

    // MARK: 来源随发送快照与恢复保留

    func testRestorePreservesSourceAndLegacyMissingSourceIsUserReference() throws {
        let a = root.appendingPathComponent("a.png"); try pngFile(a)
        let b = root.appendingPathComponent("b.png"); try pngFile(b)
        var m = MacSession.Sent(id: UUID(), text: "x", at: Date(), afterSeq: 0, targetId: "t", draft: "d", attachmentPaths: [a.path, b.path])
        m.attachmentSources = [.cachedBitmap] // 只有第一项记了来源
        var draft = "", atts: [ComposerAttachment] = []
        XCTAssertTrue(ComposerRules.restore(m, canEdit: true, draft: &draft, attachments: &atts))
        XCTAssertEqual(atts.map(\.source), [.cachedBitmap, .userReference])
    }

    // MARK: 粘贴归属 / 文本不回归

    func testPasteDecisionTable() {
        XCTAssertEqual(ComposerAttachments.pasteDecision(hasFiles: true, hasBitmaps: true, hasString: true), .files, "Finder 复制文件同时带文件名字符串：按文件引用")
        XCTAssertEqual(ComposerAttachments.pasteDecision(hasFiles: false, hasBitmaps: true, hasString: false), .bitmaps)
        XCTAssertEqual(ComposerAttachments.pasteDecision(hasFiles: false, hasBitmaps: true, hasString: true), .text, "有文本时位图不抢")
        XCTAssertEqual(ComposerAttachments.pasteDecision(hasFiles: false, hasBitmaps: false, hasString: true), .text)
    }

    func testPasteboardFileURLWinsAndTypeRangeIsUnchanged() throws {
        let png = root.appendingPathComponent("a.png"); try pngFile(png)
        let pdf = root.appendingPathComponent("a.pdf"); try makeFile(pdf)
        let pb = NSPasteboard(name: NSPasteboard.Name("palmhelm.test.\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([png as NSURL, pdf as NSURL])
        pb.setString("a.png", forType: .string)
        XCTAssertEqual(ComposerAttachments.imageFiles(pb).map(\.lastPathComponent), ["a.png"], "类型范围不扩大：pdf 不算")
        XCTAssertEqual(ComposerAttachments.decision(for: pb), .files)
        let pb2 = NSPasteboard(name: NSPasteboard.Name("palmhelm.test.\(UUID().uuidString)"))
        pb2.clearContents(); pb2.setString("普通文本", forType: .string)
        XCTAssertEqual(ComposerAttachments.decision(for: pb2), .text)
        XCTAssertTrue(ComposerAttachments.items(from: pb2).isEmpty)
    }

    // R1：发送中恢复为 no-op 且不标记；发送收尾后同一候选仍可恢复；收尾不清掉之后恢复的内容
    @MainActor
    func testRestoreDuringBusyIsNoOpAndSettleDoesNotEraseLaterRestore() {
        let rejected = HistoryItem(seq: 5, uuid: "u5", text: "rejected:dispatch_disabled（派发未开启）", kind: "text", replyTo: "kA")
        let a = MacSession.Sent(id: UUID(), text: "A", at: Date(), afterSeq: 1, targetId: "t", eventKey: "kA", error: nil, draft: "A draft", attachmentPaths: [])
        var draft = "B draft"
        var atts: [ComposerAttachment] = []
        let snapDraft = draft, snapAtts = atts
        // B 发送中：恢复 A 被挡，草稿不变
        XCTAssertFalse(ComposerRules.restore(a, canEdit: ComposerRules.canEdit(canControl: true, busy: true), draft: &draft, attachments: &atts))
        XCTAssertEqual(draft, "B draft")
        // B 成功收尾：只清自己的草稿
        ComposerRules.settle(recorded: true, draftSnap: snapDraft, attachSnap: snapAtts, draft: &draft, attachments: &atts)
        XCTAssertEqual(draft, "")
        // 冻结结束后候选仍可恢复（未被标记）
        XCTAssertEqual(MacSession.restorableSend(in: [a], history: [rejected], threadId: "t")?.id, a.id)
        XCTAssertTrue(ComposerRules.restore(a, canEdit: ComposerRules.canEdit(canControl: true, busy: false), draft: &draft, attachments: &atts))
        XCTAssertEqual(draft, "A draft")
        // 之后再有一次以旧快照为准的收尾（草稿已不同于快照）不得清掉 A 的内容
        ComposerRules.settle(recorded: true, draftSnap: snapDraft, attachSnap: snapAtts, draft: &draft, attachments: &atts)
        XCTAssertEqual(draft, "A draft")
    }

    func testCanEditRequiresControlAndNotBusy() {
        XCTAssertTrue(ComposerRules.canEdit(canControl: true, busy: false))
        XCTAssertFalse(ComposerRules.canEdit(canControl: true, busy: true))
        XCTAssertFalse(ComposerRules.canEdit(canControl: false, busy: false))
    }

    func testNotEditableAddAndRemoveAreNoOps() throws {
        var list: [ComposerAttachment] = []
        XCTAssertNil(ComposerAttachments.add([.bitmap(image())], to: &list, editable: false, cacheDir: cache))
        XCTAssertTrue(list.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "不可编辑时不落盘")
        let f = root.appendingPathComponent("a.png"); try makeFile(f)
        list = [attachment(f.path)]
        XCTAssertFalse(ComposerAttachments.remove(list[0], from: &list, editable: false))
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }
}
