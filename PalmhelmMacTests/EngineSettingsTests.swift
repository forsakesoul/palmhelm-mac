import XCTest
@testable import PalmhelmMac

@MainActor
final class EngineSettingsTests: XCTestCase {
    func testExperimentalClaudeQuotaDefaultsOffPersistsOnAndOwnsEnvironmentKey() throws {
        let suite = "palmhelm.o362.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: "engine.claudeQuotaEnabled") // 旧 SDK 开关不代表钥匙串访问授权
        let s = EngineSettings(defaults: d, secretsReady: true)
        XCTAssertFalse(s.claudeQuotaEnabled)
        XCTAssertEqual(s.environment()["BRIDGE_CLAUDE_QUOTA_ENABLED"], "0")
        s.claudeQuotaEnabled = true
        XCTAssertTrue(EngineSettings(defaults: d, secretsReady: true).claudeQuotaEnabled)
        XCTAssertEqual(s.environment()["BRIDGE_CLAUDE_QUOTA_ENABLED"], "1")
        s.extraEnv = "BRIDGE_CLAUDE_QUOTA_ENABLED=0"
        XCTAssertEqual(s.environment()["BRIDGE_CLAUDE_QUOTA_ENABLED"], "1", "其他变量不能覆盖独立开关")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try "BRIDGE_CLAUDE_QUOTA_ENABLED=1".write(to: path, atomically: true, encoding: .utf8)
        try s.importEnvFile(at: path.path)
        XCTAssertTrue(s.claudeQuotaEnabled)
        XCTAssertFalse(s.extraEnv.contains("BRIDGE_CLAUDE_QUOTA_ENABLED"))
    }
    func testChildPathAppendsUserInstallDirsOnce() {
        let home = NSHomeDirectory()
        let p = EngineSettings.childPath(base: "/usr/bin:/bin:/opt/homebrew/bin").split(separator: ":").map(String.init)
        XCTAssertEqual(p.prefix(3), ["/usr/bin", "/bin", "/opt/homebrew/bin"])
        XCTAssertEqual(p.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertTrue(p.contains("\(home)/.local/bin") && p.contains("/usr/local/bin"))
        XCTAssertTrue(EngineSettings.childPath(base: nil).hasPrefix("/usr/bin:/bin"))
    }

    func testCommentsAreRefreshedAndNormalizationIsIdempotent() {
        let text = "# 旧说明\n# 另一段旧说明\nBRIDGE_ROUTING=1\n\n# 过期说明\nFEISHU_GROUP_CHAT_IDS='oc_a,oc_b'"
        let normalized = EngineSettings.normalizeExtraEnv(text)
        XCTAssertEqual(normalized, EngineSettings.normalizeExtraEnv(normalized))
        XCTAssertEqual(normalized.split(separator: "\n").filter { $0.hasPrefix("# ") }.count, 2)
        XCTAssertFalse(normalized.contains("旧说明") || normalized.contains("过期说明"))
        XCTAssertTrue(normalized.contains("# \(EngineSettings.extraEnvComments["BRIDGE_ROUTING"]!)\nBRIDGE_ROUTING=1"))
        XCTAssertTrue(normalized.contains("独立模式下忽略"))
    }

    func testLegacyUnknownInternalAndOwnedKeysAreRemoved() {
        let removed = [
            "BRIDGE_REPO_DIR", "BRIDGE_HOST_PROJECT_NAME", "BRIDGE_HOST_PLUGIN_SOURCE_REF", "BRIDGE_HOST_CLIENT_SOURCE_REF",
            "BRIDGE_HOST_DAEMON_SOURCE_REF", "BRIDGE_HOST_APPROVAL_SOURCE_REF", "BRIDGE_EXECUTOR_SYSTEM_PATH", "BRIDGE_EXECUTOR_USER_PATH",
            "BRIDGE_UNKNOWN", "FEISHU_UNKNOWN", "BRIDGE_SPOOL_DIR", "BRIDGE_APPROVE_BUDGET_MS", "FOO",
        ] + Array(EngineSettings.ownKeys) + Array(EngineSettings.secretKeys)
        let text = removed.map { "\($0)=test-only" }.joined(separator: "\n") + "\nBRIDGE_ROUTING=1"
        let normalized = EngineSettings.normalizeExtraEnv(text)
        XCTAssertEqual(EngineSettings.parseEnvLines(normalized), ["BRIDGE_ROUTING": "1"])
        XCTAssertEqual(normalized.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init), ["BRIDGE_ROUTING=1"])
        XCTAssertEqual(EngineSettings.parseEnvLines(text), ["BRIDGE_ROUTING": "1"], "直接编辑也不能把未知、内部或机密键送给子进程")
    }

    func testAssignmentLinesAndParsedValuesArePreserved() {
        let lines = [
            #"  BRIDGE_TARGETS_ROOT = '/fixture/a b:/fixture/中文#tag'  "#,
            #"FEISHU_GROUP_TARGETS="a=b,$HOME,中文#tag""#,
            "BRIDGE_ROUTING=0",
            "BRIDGE_ROUTING=1",
            "BRIDGE_STEER_ENABLED=",
        ]
        let text = lines.joined(separator: "\n")
        let normalized = EngineSettings.normalizeExtraEnv(text)
        XCTAssertEqual(normalized.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init), lines)
        XCTAssertEqual(EngineSettings.parseEnvLines(normalized), [
            "BRIDGE_TARGETS_ROOT": "/fixture/a b:/fixture/中文#tag",
            "FEISHU_GROUP_TARGETS": "a=b,$HOME,中文#tag",
            "BRIDGE_ROUTING": "1",
            "BRIDGE_STEER_ENABLED": "",
        ])
    }

    /// 原生直达开关：白名单键经设置与解析保留，值原样进入 Bridge 环境；未知的同前缀键仍被丢弃。
    func testNativeSteerFlagIsWhitelistedAndItsValueReachesTheBridgeEnvironment() {
        let suite = "palmhelm.test.native-steer.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let text = "BRIDGE_NATIVE_STEER_ENABLED=1\nBRIDGE_NATIVE_STEER_UNKNOWN=1"
        let normalized = EngineSettings.normalizeExtraEnv(text)
        XCTAssertTrue(normalized.contains("# \(EngineSettings.extraEnvComments["BRIDGE_NATIVE_STEER_ENABLED"]!)\nBRIDGE_NATIVE_STEER_ENABLED=1"))
        XCTAssertFalse(normalized.contains("BRIDGE_NATIVE_STEER_UNKNOWN"), "未知键仍被丢弃")
        XCTAssertEqual(EngineSettings.parseEnvLines(normalized), ["BRIDGE_NATIVE_STEER_ENABLED": "1"])
        XCTAssertEqual(EngineSettings.parseEnvLines(text), ["BRIDGE_NATIVE_STEER_ENABLED": "1"], "直接编辑同样只认白名单")
        d.set(text, forKey: "engine.extraEnv")
        let s = EngineSettings(defaults: d, secretsReady: true)
        XCTAssertEqual(s.environment()["BRIDGE_NATIVE_STEER_ENABLED"], "1")
        XCTAssertNil(s.environment()["BRIDGE_NATIVE_STEER_UNKNOWN"])
    }

    func testStartupNormalizesAndPersistsWithoutLosingPricingMigration() {
        let suite = "palmhelm.test.extra-env.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("# 旧说明\nBRIDGE_REPO_DIR=/fixture/old\nBRIDGE_PRICING_AUTO_UPDATE=0\nBRIDGE_ROUTING='1'\nFEISHU_APP_SECRET=fixture-secret", forKey: "engine.extraEnv")
        let settings = EngineSettings(defaults: defaults, secretsReady: true)
        settings.interfaceProvider = { [] }
        XCTAssertFalse(settings.pricingAutoUpdate)
        XCTAssertEqual(settings.extraEnv, "# \(EngineSettings.extraEnvComments["BRIDGE_ROUTING"]!)\nBRIDGE_ROUTING='1'")
        XCTAssertEqual(defaults.string(forKey: "engine.extraEnv"), settings.extraEnv)
        XCTAssertEqual(settings.environment()["BRIDGE_ROUTING"], "1")
        XCTAssertNil(settings.environment()["FEISHU_APP_SECRET"])
        let restarted = EngineSettings(defaults: defaults, secretsReady: true)
        XCTAssertEqual(restarted.extraEnv, settings.extraEnv)
        XCTAssertFalse(restarted.pricingAutoUpdate, "旧 extraEnv 的 =0 必须跨重启保留在独立开关里")
    }

    func testImportNormalizesAndKeepsQuotedValuesAndSecretsInTheirOwnPlaces() throws {
        guard KeychainStore.usesMemoryBackend else { return XCTFail("导入测试只能使用内存钥匙串") }
        let suite = "palmhelm.test.extra-import.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); KeychainStore.delete(account: "feishu-app-secret") }
        let settings = EngineSettings(defaults: defaults, secretsReady: true)
        settings.interfaceProvider = { [] }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("extra-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let line = #"FEISHU_GROUP_TARGETS='  a=b,中文#tag  '"#
        try "# 旧说明\n\(line)\nBRIDGE_ROUTING=1\nBRIDGE_HOST_PLUGIN_SOURCE_REF=unused\nBRIDGE_SPOOL_DIR=/fixture/internal\nFEISHU_APP_SECRET=fixture-secret\nBRIDGE_LOCAL_API_PORT=47822\n".write(to: file, atomically: true, encoding: .utf8)
        try settings.importEnvFile(at: file.path)
        let first = settings.extraEnv
        XCTAssertTrue(first.contains(line), "导入保留原赋值行，不能先去引号再被第二次解析吞掉首尾空格")
        XCTAssertFalse(first.contains("FEISHU_APP_SECRET") || first.contains("unused") || first.contains("BRIDGE_SPOOL_DIR") || first.contains("BRIDGE_LOCAL_API_PORT"))
        XCTAssertEqual(settings.environment()["FEISHU_GROUP_TARGETS"], "  a=b,中文#tag  ")
        XCTAssertEqual(settings.feishuAppSecret, "fixture-secret")
        XCTAssertEqual(KeychainStore.load(account: "feishu-app-secret"), "fixture-secret")
        XCTAssertEqual(settings.port, 47822)
        try settings.importEnvFile(at: file.path)
        XCTAssertEqual(settings.extraEnv, first, "重复导入不叠加注释")
    }

    func testHookRuntimeOverrideIsWhitelistedAndReachesTheBridgeEnvironment() {
        let suite = "palmhelm.test.hook-runtime.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let text = "BRIDGE_HOOK_RUNTIME=/usr/local/bin/palmhelm-bridge\nBRIDGE_HOOK_RUNTIME_UNKNOWN=1"
        let normalized = EngineSettings.normalizeExtraEnv(text)
        XCTAssertTrue(normalized.contains("# \(EngineSettings.extraEnvComments["BRIDGE_HOOK_RUNTIME"]!)\nBRIDGE_HOOK_RUNTIME=/usr/local/bin/palmhelm-bridge"))
        XCTAssertFalse(normalized.contains("BRIDGE_HOOK_RUNTIME_UNKNOWN"), "未知键仍被丢弃")
        XCTAssertEqual(EngineSettings.parseEnvLines(normalized), ["BRIDGE_HOOK_RUNTIME": "/usr/local/bin/palmhelm-bridge"])
        d.set(text, forKey: "engine.extraEnv")
        let s = EngineSettings(defaults: d, secretsReady: true)
        XCTAssertEqual(s.environment()["BRIDGE_HOOK_RUNTIME"], "/usr/local/bin/palmhelm-bridge")
        XCTAssertNil(s.environment()["BRIDGE_HOOK_RUNTIME_UNKNOWN"])
    }

    func testCatalogContainsOnlyExtraKeysAndRetainsDocumentedCompatibilityOptions() {
        let keys = Set(EngineSettings.extraEnvComments.keys)
        XCTAssertTrue(keys.isDisjoint(with: EngineSettings.ownKeys))
        XCTAssertTrue(keys.isDisjoint(with: EngineSettings.secretKeys))
        for (key, comment) in EngineSettings.extraEnvComments {
            XCTAssertTrue(key.hasPrefix("BRIDGE_") || key.hasPrefix("FEISHU_"))
            XCTAssertFalse(comment.contains("\n"))
            XCTAssertTrue(comment.contains("默认"), "\(key) 说明默认行为")
        }
        for key in ["BRIDGE_TARGET_PROJECT_NAME", "BRIDGE_TARGET_CWD", "BRIDGE_TARGET_ORIGIN", "BRIDGE_TARGET_AGENT_NAME", "BRIDGE_TARGET_SPOOL_DIR", "BRIDGE_LOCK_PORT"] {
            XCTAssertTrue(keys.contains(key), "实际仍读取的兼容配置不能当成遗留键误删")
        }
        for key in keys.filter({ $0.hasPrefix("FEISHU_GROUP_") }) {
            XCTAssertTrue(EngineSettings.extraEnvComments[key]!.contains("独立模式下忽略"))
        }
    }
}
