import XCTest
@testable import PalmhelmMac

// #49：引擎环境只输出固定文件的路径，且 extraEnv 不能覆盖它；待重启指纹随文件内容变化。
@MainActor
final class AccountSourcesEngineTests: XCTestCase {
    func testEnvironmentFollowsFixedFileAndFingerprintTracksContent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("acct-eng-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("data").path
        let suite = "palmhelm.acct.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = EngineSettings(defaults: d, secretsReady: true)
        s.dataDir = dir
        XCTAssertNil(s.environment()[AccountSourcesFile.envKey], "没有文件即未配置")
        let absent = s.sourcesFingerprint
        _ = try AccountSourcesStore.save([AccountSourceEntry(provider: .codex, path: "/synthetic/c", label: "")], dataDir: dir)
        XCTAssertEqual(s.environment()[AccountSourcesFile.envKey], dir + "/account-sources.json")
        let saved = s.sourcesFingerprint
        XCTAssertNotEqual(absent, saved, "内容变化即指纹变化（待重启判断）")
        XCTAssertNotNil(s.fingerprintEnvironment()[EngineSettings.sourcesFingerprintKey])
        XCTAssertNil(s.environment()[EngineSettings.sourcesFingerprintKey], "指纹只用于比较，不进入子进程环境")
        s.extraEnv = "BRIDGE_ACCOUNT_SOURCES_FILE=/etc/passwd"
        XCTAssertEqual(s.environment()[AccountSourcesFile.envKey], dir + "/account-sources.json", "其他变量不能覆盖")
    }

    // R1：只有确认不存在才省略；悬空链接、目录、权限不对的节点都照常输出固定路径（Bridge 会拒绝启动）。
    func testUnsafeConfiguredNodesStillReachBridgeAsFixedPath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("acct-node-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let dangling = base.appendingPathComponent("dangling")
        try fm.createDirectory(at: dangling, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dangling.appendingPathComponent(AccountSourcesStore.fileName).path, withDestinationPath: base.appendingPathComponent("missing-target").path)
        XCTAssertEqual(AccountSourcesStore.configuredPath(dataDir: dangling.path), dangling.path + "/" + AccountSourcesStore.fileName)
        let asDir = base.appendingPathComponent("asdir")
        try fm.createDirectory(at: asDir.appendingPathComponent(AccountSourcesStore.fileName, isDirectory: true), withIntermediateDirectories: true)
        XCTAssertNotNil(AccountSourcesStore.configuredPath(dataDir: asDir.path))
        let loose = base.appendingPathComponent("loose")
        try fm.createDirectory(at: loose, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: loose.appendingPathComponent(AccountSourcesStore.fileName))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: loose.appendingPathComponent(AccountSourcesStore.fileName).path)
        XCTAssertNotNil(AccountSourcesStore.configuredPath(dataDir: loose.path))
        XCTAssertNil(AccountSourcesStore.configuredPath(dataDir: base.appendingPathComponent("never-created").path), "只有 ENOENT 才是未配置")
    }
}
