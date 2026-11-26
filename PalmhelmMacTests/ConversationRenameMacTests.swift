import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #134 对话改名（Mac）：范围在打开时捕获，发请求前复核；只读不发请求；成功后名字经 pullState 的快照落地；
// 慢 GET 不回退期间更新的 targets；连接已切换则丢弃；herdr 非 synced 仍是成功并提示；错误码给固定文案。
private func renameSnapshot(customTitle: String?, bridge: String = "b1") throws -> BridgeState {
    let custom = customTitle.map { #","customTitle":"\#($0)""# } ?? ""
    return try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[{"projectName":"api","id":"t1"\#(custom)}],"history":{"highWater":0,"items":[]},"bridge":{"id":"\#(bridge)","name":"Mac","version":"1","endpoints":[]}}"#.utf8))
}

@MainActor
final class ConversationRenameMacTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        var n = 0
        var last: String??
    }

    private actor Gate {
        private var cont: CheckedContinuation<Void, Never>?
        private(set) var waiting = false
        func wait() async { waiting = true; await withCheckedContinuation { cont = $0 } }
        func open() { cont?.resume(); cont = nil }
        func untilWaiting() async { while !waiting { await Task.yield() } }
    }

    private func session(permission: String = "control", bridge: String = "b1") throws -> MacSession {
        let s = MacSession()
        s.streamDisabled = true
        s.applyStateSnapshot(try renameSnapshot(customTitle: nil, bridge: bridge))
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-d1","name":"Mac","paused":false,"permission":"\#(permission)"}"#.utf8))
        return s
    }

    func testReadOnlyDeviceSendsNothing() async throws {
        let s = try session(permission: "readonly")
        let calls = Counter()
        s.titleOverride = { _, _ in calls.n += 1; return .ok(customTitle: "x", herdr: "synced") }
        let r = await s.setTitle(s.titleScope("t1"), "新名字")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(calls.n, 0, "只读设备不发请求")
    }

    func testSuccessTakesTheNameFromThePullStateSnapshot() async throws {
        let s = try session()
        s.titleOverride = { _, _ in .ok(customTitle: "回包名", herdr: "synced") }
        s.stateOverride = { try renameSnapshot(customTitle: "快照名") }
        let r = await s.setTitle(s.titleScope("t1"), "回包名")
        XCTAssertTrue(r.ok)
        XCTAssertEqual(s.state?.targets.first?.customTitle, "快照名", "本地名字经 pullState 的快照落地，不直接取回包")
    }

    func testClearPassesNilThrough() async throws {
        let s = try session()
        let calls = Counter()
        s.titleOverride = { _, title in calls.last = .some(title); return .ok(customTitle: nil, herdr: "synced") }
        s.stateOverride = { try renameSnapshot(customTitle: nil) }
        let r = await s.setTitle(s.titleScope("t1"), nil)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(calls.last, .some(nil), "清除以 nil 发出")
        XCTAssertNil(s.state?.targets.first?.customTitle)
    }

    func testLateResultAfterConnectionChangeWritesNothing() async throws {
        let s = try session()
        let gate = Gate()
        let fetches = Counter()
        s.titleOverride = { _, _ in await gate.wait(); return .ok(customTitle: "迟到", herdr: "synced") }
        s.stateOverride = { fetches.n += 1; return try renameSnapshot(customTitle: "快照") }
        let scope = s.titleScope("t1")
        let pending = Task { await s.setTitle(scope, "迟到") }
        await gate.untilWaiting()
        s.stopStream() // 换了连接：会话代次推进
        await gate.open()
        let r = await pending.value
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message.text, MacSession.titleSavedOnOldConnection, "PUT 已成功后换连接：名字保存在原连接")
        XCTAssertEqual(fetches.n, 0, "过期结果不触发权威同步")
        XCTAssertNil(s.state?.targets.first?.customTitle, "过期结果不写任何本地状态")
    }

    func testHerdrNotSyncedIsStillSuccessWithANotice() async throws {
        let s = try session()
        s.titleOverride = { _, _ in .ok(customTitle: "名", herdr: "pane_gone") }
        s.stateOverride = { try renameSnapshot(customTitle: "名") }
        let r = await s.setTitle(s.titleScope("t1"), "名")
        XCTAssertTrue(r.ok, "名字已保存，成功态不变")
        XCTAssertEqual(r.message.text, "名字已保存；Herdr 窗口名未同步")
    }

    func testFailureCodesMapToFixedCopy() {
        XCTAssertEqual(MacSession.titleFailure(status: 400, code: "invalid_title"), "Bridge 不接受这个名字，请换一个")
        XCTAssertEqual(MacSession.titleFailure(status: 404, code: "target_not_found"), "这个对话已不在 Bridge 上")
        XCTAssertEqual(MacSession.titleFailure(status: 404, code: nil), "这台 Mac 上的 Bridge 版本过旧，不支持对话改名", "旧 Bridge 无接口")
        XCTAssertEqual(MacSession.titleFailure(status: 409, code: "read_only"), MacSession.readOnlyNote)
        XCTAssertEqual(MacSession.titleFailure(status: 503, code: "shutting_down"), "改名没有成功（shutting_down）")
    }

    /// 打开弹层后、提交前换了连接：范围已不同，零 PUT，给过期提示。
    func testScopeCapturedBeforeASwitchSendsNothing() async throws {
        let s = try session()
        let calls = Counter()
        s.titleOverride = { _, _ in calls.n += 1; return .ok(customTitle: "x", herdr: "synced") }
        let scope = s.titleScope("t1")
        s.stopStream()
        let r = await s.setTitle(scope, "旧草稿")
        XCTAssertEqual(calls.n, 0, "打开后已切换连接，不发请求")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message.text, MacSession.titleNotSaved)
    }

    /// A1 探针场景 1：PUT 成功 → GET 暂停 → SSE targets 帧写入更新的目标 → 放行带旧目标的 GET → 最终仍是更新的那份。
    func testNewerTargetsFrameSurvivesOlderPostPutGet() async throws {
        let older = try renameSnapshot(customTitle: "older")
        let newer = try renameSnapshot(customTitle: "newer")
        let s = try session()
        s.applyStateSnapshot(older)
        let gate = Gate()
        s.titleOverride = { _, _ in .ok(customTitle: "older", herdr: "synced") }
        s.stateOverride = { await gate.wait(); return older }
        let scope = s.titleScope("t1")
        let request = Task { await s.setTitle(scope, "older") }
        await gate.untilWaiting()
        s.applyTargetsFrame(newer.targets, spaces: nil)
        XCTAssertEqual(s.state?.targets.first?.customTitle, "newer")
        await gate.open()
        let result = await request.value
        XCTAssertTrue(result.ok)
        XCTAssertEqual(s.state?.targets.first?.customTitle, "newer", "旧 GET 覆盖了之后的 targets 帧")
    }

    /// A1 探针场景 2：PUT 成功 → GET 暂停 → 换连接 → 放行 GET → 成功结果不得出现在新连接里。
    func testConnectionChangeDuringPostPutGetDropsSuccessResult() async throws {
        let older = try renameSnapshot(customTitle: "older")
        let replacement = try renameSnapshot(customTitle: "current", bridge: "b2")
        let s = try session()
        s.applyStateSnapshot(older)
        let gate = Gate()
        s.titleOverride = { _, _ in .ok(customTitle: "older", herdr: "synced") }
        s.stateOverride = { await gate.wait(); return older }
        let scope = s.titleScope("t1")
        let request = Task { await s.setTitle(scope, "older") }
        await gate.untilWaiting()
        s.stopStream()
        s.applyStateSnapshot(replacement)
        await gate.open()
        let result = await request.value
        XCTAssertEqual(s.state?.targets.first?.customTitle, "current")
        XCTAssertFalse(result.ok, "旧连接的成功结果不得报告到新连接")
    }

    /// A1 探针场景 3：排队中的旧草稿在换连接后执行，不得发到新 Bridge。
    func testQueuedSaveFromPriorConnectionIsNotSentToReplacementTarget() async throws {
        let replacement = try renameSnapshot(customTitle: "current", bridge: "b2")
        let s = try session()
        let sends = Counter()
        s.titleOverride = { _, _ in sends.n += 1; return .ok(customTitle: "old draft", herdr: "synced") }
        s.stateOverride = { replacement }
        let scope = s.titleScope("t1")
        let request = Task { await s.setTitle(scope, "old draft") }
        s.stopStream()
        s.applyStateSnapshot(replacement)
        let result = await request.value
        XCTAssertEqual(sends.n, 0, "排队的旧草稿被发到了新 Bridge")
        XCTAssertFalse(result.ok)
    }

    /// 与改名无关的竞态：权威同步在途时来了 SSE targets 帧，GET 返回后不得回退。
    func testPullStateDoesNotRegressTargetsWrittenDuringItsRequest() async throws {
        let older = try renameSnapshot(customTitle: "older")
        let newer = try renameSnapshot(customTitle: "newer")
        let s = try session()
        s.applyStateSnapshot(older)
        let gate = Gate()
        s.stateOverride = { await gate.wait(); return older }
        let pull = Task { try await s.pullState() }
        await gate.untilWaiting()
        s.applyTargetsFrame(newer.targets, spaces: nil)
        await gate.open()
        try await pull.value
        XCTAssertEqual(s.state?.targets.first?.customTitle, "newer", "慢 GET 回退了期间更新的 targets")
    }

    /// h10：两个重叠的 GET（A 先发起、B 后发起）。A 先返回旧标题、B 后返回新标题 → 最终新标题。
    func testEarlierGetFinishingFirstDoesNotSuppressLaterGet() async throws {
        let old = try renameSnapshot(customTitle: "before")
        let new = try renameSnapshot(customTitle: "after")
        let s = try session()
        s.applyStateSnapshot(old)
        let gateA = Gate(), gateB = Gate()
        let calls = Counter()
        s.stateOverride = {
            calls.n += 1
            if calls.n == 1 { await gateA.wait(); return old }
            await gateB.wait(); return new
        }
        let pullA = Task { try await s.pullState() }
        await gateA.untilWaiting()
        let pullB = Task { try await s.pullState() }
        await gateB.untilWaiting()
        await gateA.open()
        try await pullA.value
        await gateB.open()
        try await pullB.value
        XCTAssertEqual(s.state?.targets.first?.customTitle, "after", "较早发起的 GET 先返回，不得挡住较晚发起的 GET")
    }

    /// h10：两个重叠的 GET，较晚发起的先返回新标题、较早发起的后返回旧标题 → 仍是新标题。
    func testLaterGetFinishingFirstIsNotRegressedByEarlierGet() async throws {
        let old = try renameSnapshot(customTitle: "before")
        let new = try renameSnapshot(customTitle: "after")
        let s = try session()
        s.applyStateSnapshot(old)
        let gateA = Gate(), gateB = Gate()
        let calls = Counter()
        s.stateOverride = {
            calls.n += 1
            if calls.n == 1 { await gateA.wait(); return old }
            await gateB.wait(); return new
        }
        let pullA = Task { try await s.pullState() }
        await gateA.untilWaiting()
        let pullB = Task { try await s.pullState() }
        await gateB.untilWaiting()
        await gateB.open()
        try await pullB.value
        await gateA.open()
        try await pullA.value
        XCTAssertEqual(s.state?.targets.first?.customTitle, "after", "较早发起的旧 GET 不得回退较晚的结果")
    }

    /// h10：PUT 传输错误晚到且范围已失效 → 结果未知，提示可能已保存。
    func testLateTransportErrorAfterSwitchReportsUnknownOutcome() async throws {
        let s = try session()
        let gate = Gate()
        s.titleOverride = { _, _ in await gate.wait(); throw URLError(.timedOut) }
        let scope = s.titleScope("t1")
        let pending = Task { await s.setTitle(scope, "迟到") }
        await gate.untilWaiting()
        s.stopStream()
        await gate.open()
        let r = await pending.value
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message.text, MacSession.titleUnknownOnOldConnection)
    }

    /// h10 R-b：自配对换了凭据后、拿到新 Bridge 的快照之前，旧范围与新开范围都不得发 PUT；拿到快照后新范围正常发出。
    func testCredentialSwapInvalidatesScopesUntilFreshSnapshot() async throws {
        let s = try session()
        let hook = QuietHook()
        s.hookFactory = { _, _ in hook }
        s.pairOverride = { ep, _, _ in
            try JSONDecoder().decode(PairResponse.self, from: Data(#"{"deviceId":"new","token":"new-token","spkiSha256":"SPKI-B"}"#.utf8))
        }
        let calls = Counter()
        s.titleOverride = { _, _ in calls.n += 1; return .ok(customTitle: "x", herdr: "synced") }
        KeychainStore.save("old-token", account: KeychainStore.tokenAccount)
        defer { KeychainStore.delete(account: KeychainStore.tokenAccount) }
        await s.loadCredentials()
        s.endpoint = BridgeEndpoint(host: "192.168.1.9", port: 47821, transport: .https, spkiSha256: "SPKI-A")
        let oldScope = s.titleScope("t1")
        s.stateOverride = { throw URLError(.cannotConnectToHost) }
        await s.ensurePaired(want: BridgeEndpoint(host: "192.168.1.9", port: 47821, transport: .https, spkiSha256: "SPKI-B"), hookPort: 1, dataDir: "/tmp/none")
        let newScope = s.titleScope("t1")
        let stale = await s.setTitle(oldScope, "旧草稿")
        let fresh = await s.setTitle(newScope, "新草稿")
        XCTAssertEqual(calls.n, 0, "换了凭据但未拿到新快照：不发 PUT")
        XCTAssertEqual(stale.message.text, MacSession.titleNotSaved)
        XCTAssertEqual(fresh.message.text, MacSession.titleNotSaved)
        let replacement = try renameSnapshot(customTitle: nil, bridge: "b2")
        s.stateOverride = { replacement }
        try await s.pullState()
        let after = await s.setTitle(s.titleScope("t1"), "新草稿")
        XCTAssertEqual(calls.n, 1, "拿到新 Bridge 的快照后，新范围正常发出")
        XCTAssertTrue(after.ok)
    }

    /// h12：GET 与 SSE 无共同版本；PUT 后的 GET 之后迟到的旧 SSE 帧可能短暂显示旧值，下一帧（内容不同）必须收敛到新值。
    func testOldSSEFrameAfterPostPutGetConvergesOnTheNextFrame() async throws {
        let before = try renameSnapshot(customTitle: "before")
        let after = try renameSnapshot(customTitle: "after")
        let s = try session()
        s.applyStateSnapshot(before)
        s.stateOverride = { after }
        s.titleOverride = { _, _ in .ok(customTitle: "after", herdr: "synced") }
        let result = await s.setTitle(s.titleScope("t1"), "after")
        XCTAssertTrue(result.ok)
        s.applyTargetsFrame(before.targets, spaces: nil) // 迟到的旧帧：短暂旧值允许
        s.applyTargetsFrame(after.targets, spaces: nil) // 下一次轮询推送的新内容
        XCTAssertEqual(s.state?.targets.first?.customTitle, "after", "不得永久停在旧值")
    }

    /// h12：PUT 后的 GET 进行中收到旧帧；下一帧（新内容）收敛到新值。
    func testDelayedPrePutFrameDuringPostPutGetConvergesOnTheNextFrame() async throws {
        let before = try renameSnapshot(customTitle: "before")
        let after = try renameSnapshot(customTitle: "after")
        let s = try session()
        s.applyStateSnapshot(before)
        let gate = Gate()
        s.stateOverride = { await gate.wait(); return after }
        s.titleOverride = { _, _ in .ok(customTitle: "after", herdr: "synced") }
        let scope = s.titleScope("t1")
        let rename = Task { await s.setTitle(scope, "after") }
        await gate.untilWaiting()
        s.applyTargetsFrame(before.targets, spaces: nil)
        await gate.open()
        _ = await rename.value
        s.applyTargetsFrame(after.targets, spaces: nil)
        XCTAssertEqual(s.state?.targets.first?.customTitle, "after", "下一帧收敛到权威值")
    }

    /// h12 P2：范围已过期后的 403（可能已在 Bridge 上生效）不能断言“未保存”。
    func testExpiredForbiddenFailureReportsUnknownOutcome() async throws {
        let s = try session()
        let gate = Gate()
        s.titleOverride = { _, _ in await gate.wait(); return .failed(status: 403, code: "read_only") }
        let scope = s.titleScope("t1")
        let pending = Task { await s.setTitle(scope, "x") }
        await gate.untilWaiting()
        s.stopStream()
        await gate.open()
        let r = await pending.value
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message.text, MacSession.titleUnknownOnOldConnection)
    }

    /// h12 P2：范围已过期后的 400（名字被拒，未保存）仍是“未保存”。
    func testExpiredInvalidTitleFailureReportsNotSaved() async throws {
        let s = try session()
        let gate = Gate()
        s.titleOverride = { _, _ in await gate.wait(); return .failed(status: 400, code: "invalid_title") }
        let scope = s.titleScope("t1")
        let pending = Task { await s.setTitle(scope, "x") }
        await gate.untilWaiting()
        s.stopStream()
        await gate.open()
        let r = await pending.value
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message.text, MacSession.titleNotSaved)
    }

    /// h14 P2：范围已过期后的 500（写入后的复核失败，标题可能已保存）不能断言“未保存”。
    func testExpiredServerFailureReportsUnknownOutcome() async throws {
        let s = try session()
        let gate = Gate()
        s.titleOverride = { _, _ in await gate.wait(); return .failed(status: 500, code: "internal") }
        let scope = s.titleScope("t1")
        let pending = Task { await s.setTitle(scope, "after") }
        await gate.untilWaiting()
        s.stopStream()
        await gate.open()
        let r = await pending.value
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.message.text, MacSession.titleUnknownOnOldConnection)
    }
}

/// 自配对测试用的最小本机管理口替身（SelfPairingTests 的替身为 private）。
private final class QuietHook: HookAdmin, @unchecked Sendable {
    func issuePairCode() async throws -> HookClient.PairCode { HookClient.PairCode(code: "123456", expiresT: 0) }
    func setPermission(deviceId: String, _ permission: DevicePermission) async throws {}
    func devices(all: Bool) async throws -> [HookClient.Device] { [] }
    func remove(deviceId: String) async throws {}
}
