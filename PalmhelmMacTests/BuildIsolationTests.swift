import XCTest
@testable import PalmhelmMac

/// #100：钥匙串服务名按构建隔离；旧版导入只在正式 bundle id 下运行。全部用注入的替身，绝不读写真实钥匙串。
final class BuildIsolationTests: XCTestCase {
    private let demoBundleID = "com.forsakesoul.palmhelm.mac.demo"

    private func suite() -> UserDefaults {
        let name = "palmhelm.test.build-isolation.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return d
    }

    func testFormalBundleKeepsTheOriginalServiceName() {
        XCTAssertEqual(KeychainStore.serviceName(bundleID: KeychainStore.formalBundleID), "com.forsakesoul.palmhelm.mac")
    }

    func testOtherBundleIDsUseTheirOwnServiceName() {
        XCTAssertEqual(KeychainStore.serviceName(bundleID: demoBundleID), demoBundleID)
        XCTAssertNotEqual(KeychainStore.serviceName(bundleID: demoBundleID), KeychainStore.formalBundleID)
    }

    func testMissingBundleIDFailsClosedInsteadOfFallingBackToTheFormalName() {
        XCTAssertNil(KeychainStore.serviceName(bundleID: nil))
        XCTAssertNil(KeychainStore.serviceName(bundleID: ""))
    }

    func testOnlyTheFormalBundleIDRunsTheLegacyImport() {
        XCTAssertTrue(LegacyImport.isFormal(bundleID: KeychainStore.formalBundleID))
        XCTAssertFalse(LegacyImport.isFormal(bundleID: demoBundleID))
        XCTAssertFalse(LegacyImport.isFormal(bundleID: nil))
    }

    func testNonFormalBuildMarksDefaultsAsNotNeededWithoutReadingTheLegacyDomain() {
        let d = suite()
        var readLegacy = false
        let r = LegacyImport.runDefaultsImport(bundleID: demoBundleID, into: d) {
            readLegacy = true
            return ["engine.tls": true]
        }
        XCTAssertNil(r)
        XCTAssertFalse(readLegacy, "非正式构建不读旧域")
        XCTAssertNil(d.object(forKey: "engine.tls"))
        XCTAssertTrue(d.bool(forKey: LegacyImport.defaultsDoneKey))
    }

    func testNonFormalBuildNeverReadsOrWritesTheKeychain() {
        let f = FakeVault()
        f.put(LegacyImport.legacyKeychainService, "device-token", "T")
        f.put(KeychainStore.formalBundleID, "device-token", "formal-token")
        let flags = suite()
        XCTAssertNil(LegacyImport.runSecretsImport(bundleID: demoBundleID, flags: flags, vault: f.vault))
        XCTAssertTrue(f.reads.isEmpty, "非正式构建不读钥匙串")
        XCTAssertEqual(f.get(KeychainStore.formalBundleID, "device-token"), "formal-token", "正式命名空间不被写入")
        XCTAssertTrue(flags.bool(forKey: LegacyImport.secretsDoneKey))
    }

    func testFormalBuildStillImportsIntoTheFormalName() {
        let f = FakeVault()
        f.put(LegacyImport.legacyKeychainService, "device-token", "T")
        let r = LegacyImport.runSecretsImport(bundleID: KeychainStore.formalBundleID, flags: suite(), vault: f.vault)
        XCTAssertEqual(r?.outcomes["device-token"], .imported)
        XCTAssertEqual(f.get(KeychainStore.formalBundleID, "device-token"), "T")
    }
}
