import XCTest
@testable import PalmhelmMac

final class FakeVault: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private(set) var reads: [String] = []
    var denyReads: Set<String> = [] // "service|account"
    var failWrites = false
    func put(_ service: String, _ account: String, _ v: String) { lock.withLock { items["\(service)|\(account)"] = v } }
    func get(_ service: String, _ account: String) -> String? { lock.withLock { items["\(service)|\(account)"] } }
    var vault: LegacyImport.Vault {
        .init(
            read: { [self] s, a in
                lock.withLock {
                    reads.append("\(s)|\(a)")
                    if denyReads.contains("\(s)|\(a)") { return .failed(-128) }
                    return items["\(s)|\(a)"].map { .found($0) } ?? .notFound
                }
            },
            write: { [self] v, s, a in
                lock.withLock {
                    if failWrites { return false }
                    items["\(s)|\(a)"] = v
                    return true
                }
            })
    }
}

final class LegacyImportTests: XCTestCase {
    private let oldSvc = LegacyImport.legacyKeychainService
    private let newSvc = KeychainStore.formalBundleID
    private func suite() -> UserDefaults {
        let name = "palmhelm.test.legacy-import.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return d
    }

    // MARK: 偏好

    func testKeyMappingWhitelistsAndRenamesOnlyTheOldPrefix() {
        XCTAssertEqual(LegacyImport.mappedKey("reins.lens"), "palmhelm.lens")
        XCTAssertEqual(LegacyImport.mappedKey("reins.mac.selfDeviceId"), "palmhelm.mac.selfDeviceId")
        XCTAssertEqual(LegacyImport.mappedKey("engine.port"), "engine.port")
        XCTAssertEqual(LegacyImport.mappedKey("feishu.appId"), "feishu.appId")
        XCTAssertEqual(LegacyImport.mappedKey("bridge.spki"), "bridge.spki")
        XCTAssertNil(LegacyImport.mappedKey("engine.dataDir"), "路径类偏好不导入")
        XCTAssertNil(LegacyImport.mappedKey("engine.binaryPath"), "路径类偏好不导入")
        XCTAssertNil(LegacyImport.mappedKey("NSWindow Frame main"))
        XCTAssertNil(LegacyImport.mappedKey("AppleLanguages"))
        XCTAssertNil(LegacyImport.mappedKey("palmhelm.lens"), "新前缀不是旧域的键")
    }

    func testExtraEnvDropsOnlyDataDirAndHookRuntimeLines() {
        let text = "# 注释保留\nBRIDGE_ROUTING=1\nBRIDGE_DATA_DIR=/old/dir\n  export BRIDGE_HOOK_RUNTIME = /old/bin\nFEISHU_GROUP_PANEL_ROOT=/work/panel\nBRIDGE_DATA_DIR_EXTRA=keep\nnot an assignment"
        XCTAssertEqual(LegacyImport.sanitizedExtraEnv(text), "# 注释保留\nBRIDGE_ROUTING=1\nFEISHU_GROUP_PANEL_ROOT=/work/panel\nBRIDGE_DATA_DIR_EXTRA=keep\nnot an assignment")
    }

    func testDefaultsImportCopiesAllowedKeysAndNeverOverwritesNewValues() {
        let d = suite()
        d.set(51000, forKey: "engine.port") // 新域已有：保留
        let old: [String: Any] = [
            "engine.dataDir": "/opt/example/.remote-herdr-bridge", "engine.binaryPath": "/opt/example/libexec/b",
            "engine.port": 47821, "engine.tls": true, "engine.keepAfterQuit": true,
            "engine.extraEnv": "BRIDGE_ROUTING=1\nBRIDGE_HOOK_RUNTIME=/old\n",
            "feishu.enabled": true, "feishu.appId": "cli_x", "bridge.host": "127.0.0.1", "bridge.spki": "abc",
            "reins.lens": "spaces", "reins.mac.selfDeviceId": "dev1", "reins.threadMarks.v1": Data([1, 2]),
            "NSWindow Frame main": "1 2 3 4",
        ]
        let r = LegacyImport.importDefaults(from: old, into: d)
        XCTAssertEqual(r, .init(imported: 10, skippedExisting: 1, skippedNotAllowed: 3))
        XCTAssertEqual(d.integer(forKey: "engine.port"), 51000)
        XCTAssertNil(d.object(forKey: "engine.dataDir"))
        XCTAssertNil(d.object(forKey: "engine.binaryPath"))
        XCTAssertNil(d.object(forKey: "NSWindow Frame main"))
        XCTAssertEqual(d.string(forKey: "engine.extraEnv"), "BRIDGE_ROUTING=1\n")
        XCTAssertEqual(d.string(forKey: "palmhelm.lens"), "spaces")
        XCTAssertEqual(d.string(forKey: "palmhelm.mac.selfDeviceId"), "dev1")
        XCTAssertEqual(d.data(forKey: "palmhelm.threadMarks.v1"), Data([1, 2]))
        XCTAssertNil(d.object(forKey: "reins.lens"), "旧键名不写进新域")
        XCTAssertEqual(d.bool(forKey: "engine.keepAfterQuit"), true)
        XCTAssertEqual(d.string(forKey: "bridge.spki"), "abc")
    }

    func testDefaultsImportRunsOnce() {
        let d = suite()
        XCTAssertNotNil(LegacyImport.importDefaults(from: ["engine.tls": true], into: d))
        d.removeObject(forKey: "engine.tls")
        XCTAssertNil(LegacyImport.importDefaults(from: ["engine.tls": true], into: d), "完成标志已写：不再导入")
        XCTAssertNil(d.object(forKey: "engine.tls"))
    }

    func testEmptyOrMissingOldDomainStillCompletes() {
        let d = suite()
        XCTAssertEqual(LegacyImport.importDefaults(from: nil, into: d), .init(imported: 0, skippedExisting: 0, skippedNotAllowed: 0))
        XCTAssertTrue(d.bool(forKey: LegacyImport.defaultsDoneKey))
    }

    // MARK: 钥匙串

    func testSecretsAreCopiedToTheNewServiceAndTheOldItemsStay() {
        let f = FakeVault()
        f.put(oldSvc, "feishu-app-secret", "S1")
        f.put(oldSvc, "device-token", "T1")
        let flags = suite()
        let r = LegacyImport.importSecrets(vault: f.vault, newService: newSvc, flags: flags)
        XCTAssertEqual(r?.completed, true)
        XCTAssertEqual(r?.outcomes, ["feishu-app-secret": .imported, "device-token": .imported])
        XCTAssertEqual(f.get(newSvc, "feishu-app-secret"), "S1")
        XCTAssertEqual(f.get(newSvc, "device-token"), "T1")
        XCTAssertEqual(f.get(oldSvc, "feishu-app-secret"), "S1", "旧条目不删")
        XCTAssertEqual(f.get(oldSvc, "device-token"), "T1", "旧条目不删")
        XCTAssertTrue(flags.bool(forKey: LegacyImport.secretsDoneKey))
        XCTAssertNil(LegacyImport.importSecrets(vault: f.vault, newService: newSvc, flags: flags), "完成后不再读钥匙串")
    }

    func testOnlyTheTwoKnownAccountsAreRead() {
        let f = FakeVault()
        f.put(oldSvc, "something-else", "X")
        _ = LegacyImport.importSecrets(vault: f.vault, newService: newSvc, flags: suite())
        XCTAssertFalse(f.reads.contains { $0.hasSuffix("|something-else") })
        XCTAssertNil(f.get(newSvc, "something-else"))
    }

    func testMissingOldItemsCountAsHandled() {
        let f = FakeVault()
        let flags = suite()
        let r = LegacyImport.importSecrets(vault: f.vault, newService: newSvc, flags: flags)
        XCTAssertEqual(r?.outcomes, ["feishu-app-secret": .nothingToImport, "device-token": .nothingToImport])
        XCTAssertEqual(r?.completed, true)
        XCTAssertTrue(flags.bool(forKey: LegacyImport.secretsDoneKey))
    }

    func testDeniedReadDoesNotSetTheFlagAndRetryOnlyTouchesWhatIsMissing() {
        let f = FakeVault()
        f.put(oldSvc, "feishu-app-secret", "S1")
        f.put(oldSvc, "device-token", "T1")
        f.denyReads = ["\(oldSvc)|device-token"]
        let flags = suite()
        let first = LegacyImport.importSecrets(vault: f.vault, newService: newSvc, flags: flags)
        XCTAssertEqual(first?.completed, false)
        XCTAssertEqual(first?.outcomes["feishu-app-secret"], .imported)
        XCTAssertEqual(first?.outcomes["device-token"], .failed(-128))
        XCTAssertFalse(flags.bool(forKey: LegacyImport.secretsDoneKey))
        XCTAssertNil(f.get(newSvc, "device-token"))
        // 用户之后授权：重试只补缺的一项，已导入的不再读旧条目
        f.denyReads = []
        let before = f.reads.filter { $0 == "\(oldSvc)|feishu-app-secret" }.count
        let second = LegacyImport.importSecrets(vault: f.vault, newService: newSvc, flags: flags)
        XCTAssertEqual(second?.completed, true)
        XCTAssertEqual(second?.outcomes, ["feishu-app-secret": .alreadyPresent, "device-token": .imported])
        XCTAssertEqual(f.reads.filter { $0 == "\(oldSvc)|feishu-app-secret" }.count, before, "已导入账户不再读旧条目")
        XCTAssertEqual(f.get(newSvc, "device-token"), "T1")
        XCTAssertTrue(flags.bool(forKey: LegacyImport.secretsDoneKey))
    }

    func testFailedWriteLeavesTheFlagUnset() {
        let f = FakeVault()
        f.put(oldSvc, "feishu-app-secret", "S1")
        f.failWrites = true
        let flags = suite()
        let r = LegacyImport.importSecrets(vault: f.vault, newService: newSvc, flags: flags)
        XCTAssertEqual(r?.completed, false)
        XCTAssertFalse(flags.bool(forKey: LegacyImport.secretsDoneKey))
        XCTAssertEqual(f.get(oldSvc, "feishu-app-secret"), "S1")
    }

    func testNewServiceValueWinsAndTheOldItemIsNotRead() {
        let f = FakeVault()
        f.put(newSvc, "feishu-app-secret", "NEW")
        f.put(oldSvc, "feishu-app-secret", "OLD")
        let r = LegacyImport.importSecrets(vault: f.vault, newService: newSvc, flags: suite())
        XCTAssertEqual(r?.outcomes["feishu-app-secret"], .alreadyPresent)
        XCTAssertEqual(f.get(newSvc, "feishu-app-secret"), "NEW")
        XCTAssertFalse(f.reads.contains("\(oldSvc)|feishu-app-secret"))
    }

    // MARK: 测试宿主屏蔽

    // 门禁的反例：注入一个空的目标域。门禁在时导入不写任何东西；门禁被去掉时完成标志会落进这个域，测试失败。
    // 真实域不作断言的依据：真实域里可能已有上一次正式启动写入的完成标志，断言“没有标志”会因此失败（#92）。
    func testLaunchEntryPointsAreInertInTheTestHost() async {
        XCTAssertTrue(RuntimeEnvironment.isTestHost)
        let suite = "PalmhelmMacTests.legacy-import-gate"
        let target = UserDefaults(suiteName: suite)!
        target.removePersistentDomain(forName: suite)
        LegacyImport.importDefaultsOnLaunch(into: target)
        XCTAssertFalse(target.bool(forKey: LegacyImport.defaultsDoneKey), "测试宿主不导入偏好")
        target.removePersistentDomain(forName: suite)
        // 真实域：只比较内容是否变化（不读取或打印具体值）。
        let before = NSDictionary(dictionary: UserDefaults.standard.dictionaryRepresentation())
        let line = await LegacyImport.importSecretsOnLaunch()
        let after = NSDictionary(dictionary: UserDefaults.standard.dictionaryRepresentation())
        XCTAssertTrue(before.isEqual(after), "测试宿主不改动真实偏好")
        XCTAssertNil(line, "测试宿主不触碰真实钥匙串")
    }

    func testSecretAccountsMatchWhatTheAppActuallyStores() {
        XCTAssertEqual(LegacyImport.secretAccounts, ["feishu-app-secret", KeychainStore.tokenAccount])
    }
}
