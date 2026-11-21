import PalmhelmKit
import XCTest
@testable import PalmhelmMac

// #49（A1-249 R2/R4 反例纳入）：编辑代次门禁与 Claude 根的唯一标签映射。纯类型，不起 SwiftUI。
@MainActor
final class AccountSourcesStateTests: XCTestCase {
    private func gen(_ dir: String, port: Int = 47821, started: TimeInterval? = 100, connection: String = "local") -> SourcesGeneration {
        SourcesGeneration(dataDir: dir, port: port, engineStartedAt: started, connection: connection)
    }

    private func claudeAccount(label: String?, status: String, errorCode: String? = nil) -> AccountSnapshot {
        AccountSnapshot(provider: "claude", accountId: "acct_src_x", source: "claude_statusline", status: status, errorCode: errorCode,
                        sources: label.map { [AccountSourceSummary(sourceId: "claude:x", label: $0, status: status)] })
    }

    // MARK: 标签映射（R2）

    func testMatchesByLabelNotPosition() {
        let entries = [
            AccountSourceEntry(provider: .codex, path: "/synthetic/codex", label: ""),
            AccountSourceEntry(provider: .claude, path: "/synthetic/claude-a", label: "工作"),
            AccountSourceEntry(provider: .claude, path: "/synthetic/claude-b", label: "个人"),
        ]
        let accounts = [
            AccountSnapshot(provider: "codex", accountId: "acct_1", source: "codex_app_server", status: "ok"),
            claudeAccount(label: "个人", status: "awaiting_refresh"),
            claudeAccount(label: "工作", status: "error", errorCode: "statusline_not_installed"),
        ]
        let states = ClaudeRootStatus.states(entries: entries, accounts: accounts)
        XCTAssertEqual(states[1], .notInstalled)
        XCTAssertEqual(states[2], .installed)
        XCTAssertNil(states[0])
    }

    // A1 反例：新 Claude 根不得被默认 Claude 账户（无 sources）认领。
    func testDefaultClaudeMustNotClaimConfiguredRoot() {
        let a = AccountSnapshot(provider: "claude", accountId: "default", source: "claude_statusline", status: "ok")
        XCTAssertEqual(ClaudeRootStatus.states(entries: [AccountSourceEntry(provider: .claude, path: "/new-root", label: "")], accounts: [a])[0], .unknown)
        XCTAssertEqual(ClaudeRootStatus.states(entries: [AccountSourceEntry(provider: .claude, path: "/new-root", label: "新")], accounts: [a])[0], .unknown)
    }

    func testDuplicateOrMissingLabelIsUnknown() {
        let dup = [
            AccountSourceEntry(provider: .claude, path: "/synthetic/a", label: "同名"),
            AccountSourceEntry(provider: .claude, path: "/synthetic/b", label: "同名"),
        ]
        let states = ClaudeRootStatus.states(entries: dup, accounts: [claudeAccount(label: "同名", status: "ok")])
        XCTAssertEqual(states[0], .unknown)
        XCTAssertEqual(states[1], .unknown)
        XCTAssertEqual(ClaudeRootStatus.states(entries: [AccountSourceEntry(provider: .claude, path: "/x", label: "")], accounts: [claudeAccount(label: "", status: "ok")])[0], .unknown)
    }

    func testTwoAccountsWithSameLabelAreAmbiguous() {
        let entries = [AccountSourceEntry(provider: .claude, path: "/synthetic/a", label: "工作")]
        let accounts = [claudeAccount(label: "工作", status: "ok"), claudeAccount(label: "工作", status: "ok")]
        XCTAssertEqual(ClaudeRootStatus.states(entries: entries, accounts: accounts)[0], .unknown)
    }

    func testFixedErrorCodesOnlyAndUnknownTextHasNoRawEcho() {
        XCTAssertEqual(ClaudeRootStatus.state(of: claudeAccount(label: "x", status: "error", errorCode: "source_changed")), .failed("source_changed"))
        XCTAssertEqual(ClaudeRootStatus.state(of: claudeAccount(label: "x", status: "error")), .failed("failed"))
        XCTAssertEqual(ClaudeRootStatus.state(of: claudeAccount(label: "x", status: "stale")), .installed)
        XCTAssertEqual(ClaudeRootStatus.state(of: claudeAccount(label: "x", status: "weird")), .unknown)
        XCTAssertFalse(ClaudeRootStatus.text(.failed("/secret/raw")).contains("/secret"))
    }

    // MARK: 代次门禁（R2/R4，A→B 未重载、旧异步结果、旧连接同标签）

    // A→B 切换但尚未重载：保存与操作都拒绝；在 B 上重载后正常。
    func testSaveAndActRefusedAfterDataDirChangeUntilReload() {
        var session = AccountSourcesSession()
        let a = gen("/synthetic/A")
        let b = gen("/synthetic/B")
        session.reload(at: a, entries: [AccountSourceEntry(provider: .codex, path: "/synthetic/a", label: "")], error: nil)
        XCTAssertTrue(session.canSave(current: a))
        XCTAssertFalse(session.canSave(current: b), "数据目录已变但列表仍属于 A：拒绝保存")
        XCTAssertFalse(session.canAct(current: b), "拒绝操作")
        session.reload(at: b, entries: [], error: nil)
        XCTAssertTrue(session.canSave(current: b))
    }

    // 旧的异步操作在切换到 B 后完成：不得改写 B 的消息，也不得使 B 的状态可见。
    func testStaleActionResultDoesNotTouchNewGeneration() {
        var session = AccountSourcesSession()
        let a = gen("/synthetic/A")
        let b = gen("/synthetic/B")
        session.reload(at: a, entries: [], error: nil)
        session.reload(at: b, entries: [], error: nil)
        XCTAssertFalse(session.deliverMessage("状态行已安装到 A 的目录", from: a, current: b))
        XCTAssertNil(session.message)
    }

    // 旧连接（同标签）的账户刷新不能给当前本机 engine 采用为 installed。
    func testOldConnectionSameLabelIsNotAdopted() {
        var session = AccountSourcesSession()
        let local = gen("/synthetic/A", connection: "local")
        let other = gen("/synthetic/A", connection: "remote-bridge")
        let entries = [AccountSourceEntry(provider: .claude, path: "/synthetic/root", label: "工作")]
        session.reload(at: local, entries: entries, error: nil)
        XCTAssertFalse(session.acceptAccounts([claudeAccount(label: "工作", status: "ok")], from: other, current: local), "来源代次不是当前代次")
        XCTAssertEqual(session.claudeStates(current: local, running: true, pendingRestart: false)[0], .unknown)
        XCTAssertTrue(session.acceptAccounts([claudeAccount(label: "工作", status: "ok")], from: local, current: local))
        XCTAssertEqual(session.claudeStates(current: local, running: true, pendingRestart: false)[0], .installed)
    }

    // Bridge 重启（startedAt 变化）：之前的刷新结果不再有效；待重启或未运行时一律未知。
    func testRestartAndPendingRestartInvalidateStates() {
        var session = AccountSourcesSession()
        let before = gen("/synthetic/A", started: 100)
        let after = gen("/synthetic/A", started: 200)
        let entries = [AccountSourceEntry(provider: .claude, path: "/synthetic/root", label: "工作")]
        session.reload(at: before, entries: entries, error: nil)
        XCTAssertTrue(session.acceptAccounts([claudeAccount(label: "工作", status: "ok")], from: before, current: before))
        XCTAssertEqual(session.claudeStates(current: after, running: true, pendingRestart: false)[0], .unknown)
        XCTAssertEqual(session.claudeStates(current: before, running: true, pendingRestart: true)[0], .unknown, "有待重启的更改：响应反映旧列表")
        XCTAssertEqual(session.claudeStates(current: before, running: false, pendingRestart: false)[0], .unknown, "Bridge 未运行")
    }

    // 加载失败：禁止保存与操作（不当作空列表覆盖）。
    func testLoadErrorBlocksSave() {
        var session = AccountSourcesSession()
        let a = gen("/synthetic/A")
        session.reload(at: a, entries: [], error: "无法读取")
        XCTAssertFalse(session.canSave(current: a))
        XCTAssertFalse(session.canAct(current: a))
    }

    // 保存成功后在新内容上重载：草稿与已保存一致。
    func testCommittedSaveResetsDraftAndVerification() {
        var session = AccountSourcesSession()
        let a = gen("/synthetic/A")
        session.reload(at: a, entries: [], error: nil)
        session.draft = [AccountSourceEntry(provider: .codex, path: "/synthetic/c", label: "")]
        XCTAssertTrue(session.dirty)
        session.committed(at: a, entries: session.draft, message: "已保存")
        XCTAssertFalse(session.dirty)
        XCTAssertEqual(session.message, "已保存")
    }

    // R2：A 的文件损坏、已切到 B 但尚未重载：删除被拒绝，B 的有效文件保留；在 B 加载失败后的明确删除才允许。
    func testDeleteBrokenRefusedAfterDataDirSwitchKeepsOtherRootFile() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("acct-del-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let dirA = base.appendingPathComponent("A").path
        let dirB = base.appendingPathComponent("B").path
        _ = try AccountSourcesStore.save([AccountSourceEntry(provider: .codex, path: "/synthetic/b", label: "")], dataDir: dirB)
        let fileB = dirB + "/" + AccountSourcesStore.fileName
        let a = gen(dirA)
        let b = gen(dirB)
        var session = AccountSourcesSession()
        session.reload(at: a, entries: [], error: "损坏")
        XCTAssertTrue(session.canDeleteBroken(current: a))
        var invoked = false
        XCTAssertFalse(session.deleteBroken(at: b) { invoked = true; try AccountSourcesStore.clear(dataDir: dirB) }, "数据目录已切到 B 但未重载：拒绝")
        XCTAssertFalse(invoked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB), "B 的有效文件保留")
        XCTAssertFalse(session.canDeleteBroken(current: b))

        session.reload(at: b, entries: [], error: "损坏")
        XCTAssertTrue(session.canDeleteBroken(current: b), "B 重载后加载失败才允许删除")
        XCTAssertTrue(session.deleteBroken(at: b) { try AccountSourcesStore.clear(dataDir: dirB) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileB))
    }

    func testDeleteRefusedWhenLoadSucceeded() {
        var session = AccountSourcesSession()
        let a = gen("/synthetic/A")
        session.reload(at: a, entries: [], error: nil)
        XCTAssertFalse(session.canDeleteBroken(current: a), "没有加载错误时不提供删除损坏文件")
    }
}
