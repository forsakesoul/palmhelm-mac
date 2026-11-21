import XCTest
import PalmhelmKit
@testable import PalmhelmMac

@MainActor
final class HookInstallationSessionTests: XCTestCase {
    private func session() -> MacSession { let s = MacSession(); s.link = .connected; s.isDistribution = true; return s }
    actor Gate {
        var entered = false
        var open = false
        func wait() async { entered = true; while !open { try? await Task.sleep(for: .milliseconds(2)) } }
        func awaitEntered() async { while !entered { try? await Task.sleep(for: .milliseconds(2)) } }
        func release() { open = true }
    }
    func testUnknownUnsupportedAndUnreadableAreNotOff() async {
        let s = session()
        XCTAssertEqual(s.hookSetting(.claude).state, .unknown)
        s.hookStatusOverride = { _ in throw BridgeError.http(status: 404) }
        await s.loadHookInstallation(.claude)
        XCTAssertEqual(s.hookSetting(.claude).state, .unsupported)
        s.hookStatusOverride = { _ in throw BridgeError.http(status: 503) }
        await s.loadHookInstallation(.claude)
        XCTAssertEqual(s.hookSetting(.claude).state, .unknown)
    }
    func testUnreadableStatusKeepsFailureWithoutBecomingOffOrSuccess() async {
        let s = session()
        s.hookStatusOverride = { _ in throw HookStatusUnreadable(lastFailure: HookLaunchFailure(reason: "config_symlink_unsafe", at: 1_792_399_000_000)) }
        await s.loadHookInstallation(.claude)
        let unreadable = s.hookSetting(.claude)
        XCTAssertEqual(unreadable.state, .unknown)
        XCTAssertNil(unreadable.installation)
        XCTAssertEqual(unreadable.unreadable?.reason, "config_symlink_unsafe")
        s.hookStatusOverride = { _ in HookInstallation(installed: false, trust: "not_required") }
        await s.loadHookInstallation(.claude)
        XCTAssertEqual(s.hookSetting(.claude).state, .off)
        XCTAssertNil(s.hookSetting(.claude).unreadable, "a readable configuration clears the unreadable failure")
    }
    func testUnknownAndReadOnlyDoNotMutate() async {
        let s = session()
        s.hookMutationOverride = { _, _, _ in XCTFail("must not mutate"); return HookInstallResult(ok: true) }
        await s.setHookInstallation(.codex, install: true)
        s.hookStatusOverride = { _ in HookInstallation(installed: false, trust: "unverifiable") }
        await s.loadHookInstallation(.codex)
        s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d","name":"m","paused":false,"permission":"readonly"}"#.utf8))
        await s.setHookInstallation(.codex, install: true)
        XCTAssertFalse(s.hookSetting(.codex).busy)
    }
    func testSuccessfulInstallAndRepairReadBackStatusAndClearFailure() async {
        let s = session()
        s.hookStatusOverride = { _ in HookInstallation(installed: true, trust: "unverifiable", lastFailure: HookLaunchFailure(reason: "launch_failed", at: 1792399000000)) }
        await s.loadHookInstallation(.codex)
        XCTAssertNotNil(s.hookSetting(.codex).installation?.lastFailure)
        s.hookMutationOverride = { provider, install, _ in
            XCTAssertEqual(provider, .codex); XCTAssertTrue(install)
            return HookInstallResult(ok: true)
        }
        s.hookStatusOverride = { _ in HookInstallation(installed: true, trust: "unverifiable") }
        await s.setHookInstallation(.codex, install: true)
        XCTAssertEqual(s.hookSetting(.codex).state, .on)
        XCTAssertNil(s.hookSetting(.codex).installation?.lastFailure)
    }
    func testLateReadAndMutationCannotCrossReconnectOfSameBridge() async {
        let s = session(), gate = Gate()
        s.hookStatusOverride = { _ in await gate.wait(); return HookInstallation(installed: true, trust: "not_required") }
        let task = Task { await s.loadHookInstallation(.claude) }
        await gate.awaitEntered()
        s.disconnect(reason: "test")
        s.link = .connected
        await gate.release(); await task.value
        XCTAssertEqual(s.hookSetting(.claude).state, .unknown)
        s.hookStatusOverride = { _ in HookInstallation(installed: false, trust: "not_required", managedLocation: "none") }
        await s.loadHookInstallation(.claude)
        let mutation = Gate()
        s.hookMutationOverride = { _, _, _ in await mutation.wait(); return HookInstallResult(ok: true) }
        let writing = Task { await s.setHookInstallation(.claude, install: true) }
        await mutation.awaitEntered()
        s.disconnect(reason: "test"); s.link = .connected
        await mutation.release(); await writing.value
        XCTAssertEqual(s.hookSetting(.claude).state, .unknown)
        XCTAssertFalse(s.hookSetting(.claude).busy)
        XCTAssertNil(s.hookSetting(.claude).note)
    }
    func testNewestReadWinsWithoutCrossingProviders() async {
        let s = session(), gate = Gate()
        s.hookStatusOverride = { _ in await gate.wait(); return HookInstallation(installed: true, trust: "not_required") }
        let old = Task { await s.loadHookInstallation(.claude) }
        await gate.awaitEntered()
        s.hookStatusOverride = { provider in HookInstallation(installed: provider == .codex, trust: "unverifiable") }
        await s.loadHookInstallation(.claude)
        await s.loadHookInstallation(.codex)
        await gate.release(); await old.value
        XCTAssertEqual(s.hookSetting(.claude).state, .off)
        XCTAssertEqual(s.hookSetting(.codex).state, .on)
    }
    func testStaleDefinitionCanRepairAndReadsBackCurrent() async {
        let s = session()
        s.hookStatusOverride = { _ in HookInstallation(installed: true, trust: "unverifiable", stale: true) }
        await s.loadHookInstallation(.codex)
        XCTAssertEqual(s.hookSetting(.codex).state, .stale)
        s.hookMutationOverride = { _, install, _ in
            XCTAssertTrue(install)
            return HookInstallResult(ok: true)
        }
        s.hookStatusOverride = { _ in HookInstallation(installed: true, trust: "unverifiable", stale: false) }
        await s.setHookInstallation(.codex, install: true)
        XCTAssertEqual(s.hookSetting(.codex).state, .on)
    }
    func testBadSuccessAndUnknownErrorAreNeverEchoed() {
        XCTAssertEqual(MacSession.hookNote(HookInstallResult(ok: false, error: "invalid_response"), install: true), "Bridge 的回复不认识，请升级后重试")
        XCTAssertFalse(MacSession.hookNote(HookInstallResult(ok: false, error: "/private/path"), install: false).contains("/private"))
    }
    func testFailureLineShowsFixedCopyAndTimeOnly() {
        let at = 1_792_399_000_000
        let permissions = HookInstallationRows.failureLine(HookLaunchFailure(reason: "config_permissions", at: at))
        XCTAssertTrue(permissions?.hasPrefix("Claude 配置文件的权限不安全（别人可写或不是你的文件）：") == true)
        XCTAssertTrue(permissions?.contains("修好配置") == true)
        XCTAssertTrue(HookInstallationRows.failureLine(HookLaunchFailure(reason: "runtime_publish_failed", at: at))?.hasPrefix("上次运行程序准备失败：") == true)
        XCTAssertTrue(HookInstallationRows.failureLine(HookLaunchFailure(reason: "update_failed", at: at))?.hasPrefix("启动时自动更新失败：") == true)
        XCTAssertNil(HookInstallationRows.failureLine(HookLaunchFailure(reason: "/opt/example/secret", at: at)))
        XCTAssertNil(HookInstallationRows.failureLine(HookLaunchFailure(reason: "config_unreadable", at: 0)))
    }

    // MARK: #108 非发行构建 / 归属 / 带版本确认修复

    private final class Calls: @unchecked Sendable { var n = 0; var versions: [String?] = []; var installs: [Bool] = [] }
    private let version = String(repeating: "ab", count: 32)
    private func ready(_ s: MacSession, location: String?, version v: String? = nil, installed: Bool = true) async {
        s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d","name":"m","paused":false,"permission":"control"}"#.utf8))
        s.hookStatusOverride = { _ in HookInstallation(installed: installed, trust: "not_required", managedLocation: location, configVersion: v) }
        await s.loadHookInstallation(.claude)
    }

    func testNonDistributionBuildsNeverWriteClaudeHooksButStillWriteCodexAndRead() async {
        let s = session(); s.isDistribution = false
        let calls = Calls()
        s.hookMutationOverride = { _, install, v in calls.n += 1; calls.installs.append(install); calls.versions.append(v); return HookInstallResult(ok: true) }
        await ready(s, location: "current")
        for install in [true, false] { await s.setHookInstallation(.claude, install: install) } // 安装 / 更新·修复 / 卸载
        XCTAssertEqual(calls.n, 0, "Claude 写在传输前拒绝")
        XCTAssertEqual(s.hookSetting(.claude).note?.text, MacSession.nonDistributionHookNote.text)
        XCTAssertNil(s.hookRepairCandidate(.claude), "非发行构建没有确认修复入口")
        await ready(s, location: "none", installed: false)
        await s.setHookInstallation(.claude, install: true)
        XCTAssertEqual(calls.n, 0, "原本未安装也不抢先写共享配置")
        XCTAssertEqual(s.hookSetting(.claude).state, .off, "只读状态仍可读取")
        s.hookStatusOverride = { _ in HookInstallation(installed: false, trust: "unverifiable") }
        await s.loadHookInstallation(.codex)
        await s.setHookInstallation(.codex, install: true)
        XCTAssertEqual(calls.n, 1, "Codex 路径不变")
    }

    // C-R1：旧 Bridge（无归属字段）/ 无状态不能放行 Claude 普通写；current / none 正控
    func testOldBridgeWithoutOwnershipFieldsNeverAllowsAPlainClaudeWrite() async {
        let calls = Calls()
        for (installed, stale) in [(true, false), (true, true), (false, false)] {
            let s = session()
            s.hookMutationOverride = { _, install, v in calls.n += 1; calls.installs.append(install); calls.versions.append(v); return HookInstallResult(ok: true) }
            s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d","name":"m","paused":false,"permission":"control"}"#.utf8))
            s.hookStatusOverride = { _ in HookInstallation(installed: installed, trust: "not_required", stale: stale) } // 缺 managedLocation / configVersion
            await s.loadHookInstallation(.claude)
            XCTAssertNotNil(MacSession.hookOwnershipRefusal(.claude, s.hookSetting(.claude).installation), "UI 同源：禁用并提示")
            await s.setHookInstallation(.claude, install: true)   // 安装 / 更新·修复
            await s.setHookInstallation(.claude, install: false)  // 卸载
            XCTAssertNil(s.hookRepairCandidate(.claude))
            XCTAssertEqual(s.hookSetting(.claude).note?.text, MacSession.hookOwnershipUnknownNote.text)
        }
        XCTAssertEqual(calls.n, 0, "旧 Bridge：正式版 install / update / uninstall 全部零 transport")
        for location in ["current", "none"] {
            let s = session()
            s.hookMutationOverride = { _, install, v in calls.n += 1; calls.installs.append(install); calls.versions.append(v); return HookInstallResult(ok: true) }
            await ready(s, location: location, installed: location == "current")
            await s.setHookInstallation(.claude, install: true)
            XCTAssertEqual(calls.versions.last ?? "x", nil, "\(location)：普通写放行且不带版本")
        }
        XCTAssertEqual(calls.n, 2)
        let unread = session(); unread.hookMutationOverride = { _, _, _ in calls.n += 1; return HookInstallResult(ok: true) }
        await unread.setHookInstallation(.claude, install: true) // 状态尚未读取
        XCTAssertEqual(calls.n, 2)
    }

    // C-R4：note 存生成方式，语言切换后同一个 note 显示新语言
    func testHookNotesFollowTheDisplayLanguageWithoutRebuilding() async {
        defer { DisplayLanguage.shared.select(.system) }
        DisplayLanguage.shared.attach(defaults: AppDefaults.standard)
        DisplayLanguage.shared.select(.zhHans)
        let s = session(); s.isDistribution = false
        await s.setHookInstallation(.claude, install: true)
        let note = try! XCTUnwrap(s.hookSetting(.claude).note)
        XCTAssertEqual(note.text, "开发或测试构建不修改共享 Claude 审批钩子。请在正式版 Palmhelm 中安装或修复。")
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(note.text, "Development and test builds do not change shared Claude approval hooks. Install or repair them in the distributed Palmhelm app.")
        XCTAssertEqual(MacSession.hookOwnershipOtherNote.text, "Claude approval hooks currently point to another data directory.", "设置页直接提示用同一生成 seam")
        XCTAssertEqual(MacSession.hookRepairChangedNote.text, "The hook configuration changed. Nothing was modified. Refresh and confirm again.")
    }

    func testRuntimeDistributionIsOffInTestsAndCannotBeEnabledByEnvironment() {
        XCTAssertFalse(RuntimeEnvironment.isDistribution)
        XCTAssertFalse(MacSession().isDistribution, "默认来自编译期身份：测试宿主 / 非正式打包为 false")
    }

    func testForeignOrUnverifiableOwnershipBlocksPlainWritesAndRepairNeedsTheCapturedVersion() async {
        for location in ["other", "unknown"] {
            let s = session(); let calls = Calls()
            s.hookMutationOverride = { _, install, v in calls.n += 1; calls.installs.append(install); calls.versions.append(v); return HookInstallResult(ok: true) }
            await ready(s, location: location, version: version)
            await s.setHookInstallation(.claude, install: true)
            await s.setHookInstallation(.claude, install: false)
            XCTAssertEqual(calls.n, 0, "\(location)：普通 install / uninstall 零写")
            let request = try! XCTUnwrap(s.hookRepairCandidate(.claude))
            XCTAssertEqual(request.version, version)
            s.hookStatusOverride = { _ in HookInstallation(installed: true, trust: "not_required", managedLocation: "current") }
            await s.loadHookInstallation(.claude)
            await s.confirmHookRepair(request) // 状态已重新读取成 current：旧确认失效
            XCTAssertEqual(calls.n, 0, "确认前配置版本 / 归属已变：零写")
        }
        let s = session(); let calls = Calls()
        s.hookMutationOverride = { _, install, v in calls.n += 1; calls.installs.append(install); calls.versions.append(v); return HookInstallResult(ok: true) }
        await ready(s, location: "other", version: version)
        let request = try! XCTUnwrap(s.hookRepairCandidate(.claude))
        s.hookStatusOverride = { _ in HookInstallation(installed: true, trust: "not_required", managedLocation: "current") }
        await s.loadHookInstallation(.claude)
        await s.confirmHookRepair(request)
        XCTAssertEqual(calls.n, 0)
        XCTAssertEqual(s.hookSetting(.claude).note?.text, MacSession.hookRepairChangedNote.text)
        await ready(s, location: "other", version: version)
        await s.confirmHookRepair(try! XCTUnwrap(s.hookRepairCandidate(.claude)))
        XCTAssertEqual(calls.n, 1)
        XCTAssertEqual(calls.versions, [version], "恰好传一次捕获的版本")
        XCTAssertEqual(calls.installs, [true], "修复是 install，没有卸载快捷动作")
    }

    func testRepairIsRefusedWithoutAVerifiableVersionAnOldBridgeOrAChangedScope() async {
        let calls = Calls()
        func fresh() -> MacSession {
            let s = session()
            s.hookMutationOverride = { _, _, v in calls.n += 1; calls.versions.append(v); return HookInstallResult(ok: true) }
            return s
        }
        var s = fresh(); await ready(s, location: "other", version: nil)
        XCTAssertNil(s.hookRepairCandidate(.claude), "缺版本：不提供修复")
        s = fresh(); await ready(s, location: "other", version: "NOT-HEX")
        XCTAssertNil(s.hookRepairCandidate(.claude), "版本畸形：不提供修复")
        s = fresh(); await ready(s, location: nil, version: nil)
        XCTAssertNil(s.hookRepairCandidate(.claude), "旧 Bridge（无归属字段）不提供确认修复，也不被当成 current 以外的特例")
        s = fresh(); await ready(s, location: "other", version: version)
        let request = try! XCTUnwrap(s.hookRepairCandidate(.claude))
        s.disconnect(reason: "test"); s.link = .connected
        await s.confirmHookRepair(request) // 重连：scope 变化
        s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d","name":"m","paused":false,"permission":"readonly"}"#.utf8))
        await s.confirmHookRepair(request) // 只读
        s.isDistribution = false
        await s.confirmHookRepair(request) // 非发行
        XCTAssertEqual(calls.n, 0)
    }

    func testConfirmedRepairServerRefusalsAreNotReportedAsSuccess() async {
        for code in ["hook_confirmation_required", "settings_changed"] {
            let s = session()
            s.hookMutationOverride = { _, _, _ in HookInstallResult(ok: false, error: code) }
            await ready(s, location: "other", version: version)
            await s.confirmHookRepair(try! XCTUnwrap(s.hookRepairCandidate(.claude)))
            XCTAssertEqual(s.hookSetting(.claude).note?.text, MacSession.hookRepairChangedNote.text, code)
        }
    }
}
