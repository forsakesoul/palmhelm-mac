import XCTest
@testable import PalmhelmMac

// #49（A1-249 反例纳入）：账户来源固定文件的安全存储。只用临时目录，不碰真实数据目录、钥匙串或网络。
@MainActor
final class AccountSourcesTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("acct-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private let codex = AccountSourceEntry(provider: .codex, path: "/synthetic/c", label: "")

    // A1 反例 1：数据根是指向另一合成目录的链接，保存不得在外部写入。
    func testLinkedRootMustNotWrite() throws {
        let d = try tempDir()
        let outside = try tempDir()
        let link = d.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try AccountSourcesStore.save([codex], dataDir: link.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    // A1 反例 F1：链接后接 /. 不得绕过数据根的链接拒绝。
    func testDotMustNotBypassLinkedRoot() throws {
        let d = try tempDir()
        let target = try tempDir()
        let link = d.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AccountSourcesStore.save([codex], dataDir: link.path + "/."))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testNonCanonicalDataDirIsRefused() throws {
        let d = try tempDir()
        for bad in [d.path + "/", d.path + "//x", d.path + "/./x", d.path + "/../x"] {
            XCTAssertThrowsError(try AccountSourcesStore.resolveRoot(bad, create: true), bad)
        }
    }

    // 系统别名的正向用例：/var 与 /tmp 这类祖先别名照常解析（t.TempDir 位于 /var 下）。
    func testSystemAliasAncestorStillResolves() throws {
        let d = try tempDir()
        XCTAssertNoThrow(try AccountSourcesStore.resolveRoot(d.path, create: false))
        XCTAssertTrue(d.path.hasPrefix("/var/") || d.path.hasPrefix("/private/"), "测试前提：临时目录位于系统别名之下")
    }

    // A1 反例 F2：保存只原子替换固定文件；旧内容在提交前不丢，失败后仍可读。
    func testSaveReplacesFixedFileAtomicallyAndKeepsReadableState() throws {
        let dir = try tempDir().appendingPathComponent("data").path
        let a = [AccountSourceEntry(provider: .codex, path: "/synthetic/a", label: "")]
        let b = [AccountSourceEntry(provider: .codex, path: "/synthetic/b", label: "")]
        _ = try AccountSourcesStore.save(a, dataDir: dir)
        _ = try AccountSourcesStore.save(b, dataDir: dir)
        XCTAssertEqual(try AccountSourcesStore.load(dataDir: dir), b)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertEqual(entries, [AccountSourcesStore.fileName], "没有残留的临时或旧文件")
    }

    func testFixedFileIsOwnerOnlyAndEnvPathFollowsExistence() throws {
        let dir = try tempDir().appendingPathComponent("data").path
        XCTAssertNil(AccountSourcesStore.configuredPath(dataDir: dir), "没有文件即未配置")
        _ = try AccountSourcesStore.save([codex], dataDir: dir)
        let file = dir + "/account-sources.json"
        let attrs = try FileManager.default.attributesOfItem(atPath: file)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(AccountSourcesStore.configuredPath(dataDir: dir), file)
    }

    // 损坏的文件：读取抛错（不当成空列表），文件状态为 unreadable（待重启比较据此判断）。
    func testCorruptFileThrowsAndReportsUnreadable() throws {
        let dir = try tempDir().appendingPathComponent("data").path
        _ = try AccountSourcesStore.save([codex], dataDir: dir)
        let file = dir + "/account-sources.json"
        try Data("not json".utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        XCTAssertThrowsError(try AccountSourcesStore.load(dataDir: dir))
        XCTAssertEqual(AccountSourcesStore.fileState(dataDir: dir), .readable(digest: AccountSourcesStore.digest(of: Data("not json".utf8))), "内容可读但不是合法列表：摘要仍可算出")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        XCTAssertEqual(AccountSourcesStore.fileState(dataDir: dir), .unreadable, "权限不合格即不可读")
        XCTAssertNotNil(AccountSourcesStore.configuredPath(dataDir: dir), "损坏的文件仍输出路径，由 Bridge 拒绝启动")
    }

    func testClearDeletesOnlyTheFixedRegularFile() throws {
        let d = try tempDir()
        let dir = d.appendingPathComponent("data")
        _ = try AccountSourcesStore.save([codex], dataDir: dir.path)
        try Data("mine".utf8).write(to: dir.appendingPathComponent("user.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("account-sources.json.d"), withIntermediateDirectories: true)
        try AccountSourcesStore.clear(dataDir: dir.path)
        XCTAssertNil(AccountSourcesStore.configuredPath(dataDir: dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("user.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("account-sources.json.d").path))
    }

    func testClearRefusesWhenFixedNameIsASymlink() throws {
        let d = try tempDir()
        let dir = d.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = d.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("account-sources.json"), withDestinationURL: victim)
        XCTAssertThrowsError(try AccountSourcesStore.clear(dataDir: dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    // R3：路径原样保留（尾随空格是另一个真实目录）。
    func testValidationKeepsRawPathsAndRequiresUniqueClaudeLabels() {
        XCTAssertTrue(AccountSourcesFile.problems([], isDirectory: { _ in true }).isEmpty)
        XCTAssertFalse(AccountSourcesFile.problems([AccountSourceEntry(provider: .claude, path: "/synthetic/a", label: "")], isDirectory: { _ in true }).isEmpty)
        let a = AccountSourceEntry(provider: .claude, path: "/synthetic/a", label: "同名")
        let b = AccountSourceEntry(provider: .claude, path: "/synthetic/b", label: "同名 ")
        XCTAssertFalse(AccountSourcesFile.problems([a, b], isDirectory: { _ in true }).isEmpty)
        XCTAssertFalse(AccountSourcesFile.problems([AccountSourceEntry(provider: .codex, path: "/a/../b", label: "")], isDirectory: { _ in true }).isEmpty)
        XCTAssertFalse(AccountSourcesFile.problems([AccountSourceEntry(provider: .codex, path: "/a/", label: "")], isDirectory: { _ in true }).isEmpty)
        XCTAssertTrue(AccountSourcesFile.problems([AccountSourceEntry(provider: .codex, path: "/synthetic/root ", label: "")], isDirectory: { _ in true }).isEmpty)
    }

    // A1 反例 R5：未知错误码不回显原文。
    func testUnknownErrorMustNotEcho() {
        let o = StatuslineSourceCommand.parse(status: 1, stderr: Data(#"{"ok":false,"reason":"privatecredential"}"#.utf8))
        XCTAssertEqual(o.reason, "failed")
        XCTAssertFalse(StatuslineSourceCommand.message(for: o.reason).contains("privatecredential"))
        XCTAssertTrue(StatuslineSourceCommand.message(for: o.reason).contains("未知原因"))
        XCTAssertTrue(StatuslineSourceCommand.message(for: "privatecredential").contains("未知原因"), "直接传入未知码也不回显")
        XCTAssertFalse(StatuslineSourceCommand.message(for: "privatecredential").contains("privatecredential"))
    }

    func testKnownReasonIsKeptAndNonJSONIsNotEchoed() {
        XCTAssertEqual(StatuslineSourceCommand.parse(status: 1, stderr: Data(#"{"ok":false,"reason":"source_not_listed"}"#.utf8)).reason, "source_not_listed")
        XCTAssertEqual(StatuslineSourceCommand.parse(status: 1, stderr: Data("/secret/path leaked".utf8)).reason, "failed")
        XCTAssertEqual(StatuslineSourceCommand.parse(status: 0, stderr: Data()), .init(ok: true, reason: nil))
    }
}
