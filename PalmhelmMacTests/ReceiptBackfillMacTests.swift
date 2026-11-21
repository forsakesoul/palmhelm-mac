import Foundation
import PalmhelmKit
import XCTest
@testable import PalmhelmMac

// 回执后补关联（真实 MacSession，与 iOS 的 ReceiptBackfillSessionTests 同一规则）：
// A 无 receipt + 本机原生回显 B → 首页读取携带声明，采纳 Bridge 同形补丁 → A 一条、B 消失；其它回显不吞；形状变化不复用 ETag。

private actor FakeBackfillMac: SearchTranscriptClient {
    struct Call: Equatable { var etag: String?; var receipt: TranscriptReceiptRequest? }
    private(set) var calls: [Call] = []
    var results: [Result<TranscriptFetch, Error>]
    var hookAt: Int?
    var hook: (@MainActor @Sendable () -> Void)?
    init(_ results: [Result<TranscriptFetch, Error>]) { self.results = results }
    func setHook(at index: Int, _ f: @escaping @MainActor @Sendable () -> Void) { hookAt = index; hook = f }
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage { throw URLError(.notConnectedToInternet) }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage { throw URLError(.notConnectedToInternet) }
    func transcriptConditional(targetId: String, before: String?, limit: Int, ifNoneMatch: String?, receipt: TranscriptReceiptRequest?) async throws -> TranscriptFetch {
        calls.append(Call(etag: ifNoneMatch, receipt: receipt))
        if calls.count - 1 == hookAt, let f = hook { hook = nil; await f() }
        return try results.removeFirst().get()
    }
}

@MainActor
final class ReceiptBackfillMacTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func sent(_ key: String?, epoch: String? = "e1") -> MacSession.Sent {
        var m = MacSession.Sent(id: UUID(), text: "插话", at: t0, afterSeq: 0, targetId: "t1", eventKey: key)
        m.mode = .steer; m.agent = "claude"; m.sessionEpoch = epoch
        return m
    }
    private func command(_ key: String) -> ApiCommand {
        var c = ApiCommand(key: key, inboxSeq: 1, text: "x", origin: "api", targetId: "t1", state: "finished", reason: nil, lane: "use")
        c.directAgent = "claude"
        return c
    }
    private func page(updates: [TranscriptReceiptUpdate]? = nil) -> TranscriptPage {
        TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1",
                       items: [TranscriptItem(id: "A", role: "user", text: "插话"), TranscriptItem(id: "B", role: "assistant", text: "答")],
                       nextBefore: nil, hasMore: true, partial: false, receiptUpdates: updates)
    }
    private let patch = TranscriptReceiptUpdate(itemId: "A", receipt: TranscriptReceipt(commandKey: "ck", origin: "api", receiptState: "sent", eventKey: "K"))
    private func session() -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.backfill.mac.tests")!
        return s
    }

    func testBackfillRemovesTheLocalEchoAndKeepsUnrelatedOnes() async {
        let s = session()
        let mine = sent("K"), otherKey = sent("K2"), noKey = sent(nil), otherEpoch = sent("K3", epoch: "e0")
        s.sent = [mine, otherKey, noKey, otherEpoch]
        for k in ["K", "K2", "K3"] { s.commands[k] = command(k) }
        let fake = FakeBackfillMac([.success(.page(page(), etag: "\"v1\"")), .success(.page(page(updates: [patch]), etag: "\"v2\"")), .success(.page(page(), etag: "\"v3\""))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")

        await s.activeTranscriptTick(token, now: t0)
        XCTAssertTrue(s.pendingEchoes(threadId: "t1").map(\.id).contains(mine.id), "补丁到来前 B 仍显示")
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(2))
        let t = s.transcripts["t1"]
        XCTAssertEqual(t?.items.map(\.id), ["A", "B"])
        XCTAssertEqual(t?.items[0].text, "插话", "正文不变")
        XCTAssertEqual(t?.items[0].receipt?.eventKey, "K")
        XCTAssertEqual(t?.linkedEventKeys, ["K"])
        let echoes = s.pendingEchoes(threadId: "t1").map(\.id)
        XCTAssertFalse(echoes.contains(mine.id), "B 消失")
        XCTAssertTrue(echoes.contains(otherKey.id) && echoes.contains(noKey.id), "其它 key / 无 key 的回显不吞")
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(4))
        let calls = await fake.calls
        XCTAssertNil(calls[0].receipt)
        XCTAssertEqual(calls[1].receipt, TranscriptReceiptRequest(sessionEpoch: "e1", eventKeys: ["K", "K2"]))
        XCTAssertEqual(calls[2].receipt, TranscriptReceiptRequest(sessionEpoch: "e1", eventKeys: ["K2"]))
        XCTAssertNil(calls[1].etag); XCTAssertNil(calls[2].etag, "声明形状变了，旧 ETag 不复用")
    }

    func testAPatchFromASupersededActivationIsNotAdopted() async {
        let s = session()
        s.sent = [sent("K")]; s.commands["K"] = command("K")
        let fake = FakeBackfillMac([.success(.page(page(), etag: "\"v1\"")), .success(.page(page(updates: [patch]), etag: "\"v2\""))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        await fake.setHook(at: 1) { s.transcriptActivation.deactivate(); _ = s.transcriptActivation.activate("t1") }
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(2))
        XCTAssertTrue(s.transcripts["t1"]?.linkedEventKeys.isEmpty == true)
    }

    // MARK: R2：1 个仍保留的原生回显 + 20 个已终态普通发送

    func testKeptNativeEchoIsDeclaredEvenAfterTwentyFinishedOrdinarySends() {
        let s = session()
        let native = sent("native-K")
        var all = [native]
        s.commands["native-K"] = command("native-K")
        for i in 0..<20 {
            var m = MacSession.Sent(id: UUID(), text: "普通 \(i)", at: t0, afterSeq: 0, targetId: "t1", eventKey: "ord-\(i)")
            m.sessionEpoch = "e1"; all.append(m)
            s.commands["ord-\(i)"] = ApiCommand(key: "ord-\(i)", inboxSeq: 1, text: "x", origin: "api", targetId: "t1", state: "finished", reason: nil, lane: nil)
        }
        s.sent = all
        var th = TranscriptThread(); th.applyLatest(page()); s.transcripts["t1"] = th
        XCTAssertEqual(s.pendingEchoes(threadId: "t1").map(\.id), [native.id], "只有原生回显仍显示，20 个终态普通发送已隐藏")
        let r = s.receiptRequest(for: "t1")
        XCTAssertEqual(r?.eventKeys.count, 20)
        XCTAssertTrue(r?.eventKeys.contains("native-K") == true)
    }

    // MARK: G1：W1 真实路由输出走 refreshLatest/settleLatest 闭环

    private func fixture(_ name: String) throws -> TranscriptPage {
        try JSONDecoder().decode(TranscriptPage.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ReceiptFixtures/fixture-\(name).json")))
    }

    func testRealBridgeFixtureClosesTheLoopThroughTheSession() async throws {
        let pending = try fixture("receipt-updates-pending"), complete = try fixture("receipt-updates-complete")
        var older = try fixture("older-page-with-receipt")
        let u = try XCTUnwrap(complete.receiptUpdates?.first), epoch = try XCTUnwrap(complete.sessionEpoch), key = try XCTUnwrap(u.receipt.eventKey)
        for i in older.items.indices { older.items[i].receipt = nil }
        var th = TranscriptThread(); th.applyLatest(pending); th.applyOlder(older, snapshot: th.snapshot)
        let before = try XCTUnwrap(th.items.first { $0.id == u.itemId })
        let s = session()
        let b = sent(key, epoch: epoch), otherKey = sent("other-key", epoch: epoch), noKey = sent(nil, epoch: epoch)
        s.sent = [b, otherKey, noKey]
        s.commands[key] = command(key); s.commands["other-key"] = command("other-key")
        s.transcripts["t1"] = th
        XCTAssertTrue(s.pendingEchoes(threadId: "t1").map(\.id).contains(b.id), "采纳前 B 存在")
        XCTAssertFalse(complete.items.contains { $0.id == u.itemId }, "A 不在 complete 首页里")
        let fake = FakeBackfillMac([.success(.page(complete, etag: "\"c1\"")), .success(.page(complete, etag: "\"c1\""))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        let t = try XCTUnwrap(s.transcripts["t1"])
        let a = try XCTUnwrap(t.items.first { $0.id == u.itemId })
        XCTAssertEqual(t.items.filter { $0.id == u.itemId }.count, 1)
        XCTAssertEqual(a.text, before.text); XCTAssertEqual(a.t, before.t)
        XCTAssertEqual(a.receipt, u.receipt); XCTAssertEqual(t.linkedEventKeys, [key])
        XCTAssertTrue(TranscriptCopy.sourceLine(a).contains("Palmhelm"))
        let echoes = s.pendingEchoes(threadId: "t1").map(\.id)
        XCTAssertFalse(echoes.contains(b.id), "B 消失")
        XCTAssertTrue(echoes.contains(otherKey.id) && echoes.contains(noKey.id), "其他 key / 无 key 不吞")
        let after = s.transcripts["t1"]
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(2))
        XCTAssertEqual(s.transcripts["t1"]?.items, after?.items, "同一响应再来一次：幂等")
        XCTAssertEqual(s.transcripts["t1"]?.linkedEventKeys, after?.linkedEventKeys)
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].receipt?.eventKeys.contains(key) == true, "声明来自该次 Ticket")
    }

    func testRealFixtureIsNotAdoptedWithoutTheLoadedItemOrWithAWrongEpochOrASupersededActivation() async throws {
        let pending = try fixture("receipt-updates-pending"), complete = try fixture("receipt-updates-complete")
        let epoch = try XCTUnwrap(complete.sessionEpoch), key = try XCTUnwrap(complete.receiptUpdates?.first?.receipt.eventKey)
        func run(_ prepare: (inout TranscriptThread) -> Void = { _ in }, response: TranscriptPage, hook: Bool = false) async -> (MacSession, MacSession.Sent) {
            let s = session(); let b = sent(key, epoch: epoch)
            s.sent = [b]; s.commands[key] = command(key)
            var th = TranscriptThread(); th.applyLatest(pending); prepare(&th); s.transcripts["t1"] = th
            let fake = FakeBackfillMac([.success(.page(response, etag: "\"x\""))])
            s.searchClientOverride = { fake }
            let token = s.transcriptActivation.activate("t1")
            if hook { await fake.setHook(at: 0) { s.transcriptActivation.deactivate(); _ = s.transcriptActivation.activate("t1") } }
            await s.activeTranscriptTick(token, now: t0)
            return (s, b)
        }
        let (unknown, b1) = await run(response: complete)
        XCTAssertTrue(unknown.transcripts["t1"]?.linkedEventKeys.isEmpty == true)
        XCTAssertTrue(unknown.pendingEchoes(threadId: "t1").map(\.id).contains(b1.id))
        var wrong = complete; wrong.sessionEpoch = "other-epoch"
        let (badEpoch, _) = await run(response: wrong)
        XCTAssertTrue(badEpoch.transcripts["t1"]?.linkedEventKeys.isEmpty == true)
        var older = try fixture("older-page-with-receipt"); for i in older.items.indices { older.items[i].receipt = nil }
        let (stale, b3) = await run({ th in th.applyOlder(older, snapshot: th.snapshot) }, response: complete, hook: true)
        XCTAssertTrue(stale.transcripts["t1"]?.linkedEventKeys.isEmpty == true)
        XCTAssertTrue(stale.pendingEchoes(threadId: "t1").map(\.id).contains(b3.id), "激活已变：迟到结果不消 B")
    }

    // MARK: G2：Observation 正负控

    private final class Counter: @unchecked Sendable { var n = 0 }
    private func observed(_ s: MacSession, _ body: () async -> Void) async -> Int {
        let c = Counter()
        withObservationTracking { _ = s.transcripts["t1"]?.items; _ = s.transcripts["t1"]?.linkedEventKeys; _ = s.transcripts["t1"] } onChange: { c.n += 1 }
        await body()
        return c.n
    }
    private func linkedSession(_ responses: [Result<TranscriptFetch, Error>], withReceipt: Bool) -> MacSession {
        let s = session()
        s.sent = [sent("K")]; s.commands["K"] = command("K")
        var th = TranscriptThread()
        let item = TranscriptItem(id: "A", role: "user", text: "插话", receipt: withReceipt ? patch.receipt : nil)
        th.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1", items: [item, TranscriptItem(id: "B", role: "assistant", text: "答")], nextBefore: nil, hasMore: true, partial: false), snapshot: th.snapshot, etag: "\"v\"")
        s.transcripts["t1"] = th
        s.searchClientOverride = { FakeBackfillMac(responses) }
        return s
    }

    func testSameValueEmptyAndNotModifiedReadsDoNotNotifyObservers() async {
        let same = TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1", items: [TranscriptItem(id: "A", role: "user", text: "插话", receipt: patch.receipt), TranscriptItem(id: "B", role: "assistant", text: "答")], nextBefore: nil, hasMore: true, partial: false, receiptUpdates: [patch])
        let empty = TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1", items: same.items, nextBefore: nil, hasMore: true, partial: false, receiptUpdates: [])
        for (name, response) in [("same-value patch", Result<TranscriptFetch, Error>.success(.page(same, etag: "\"v\""))), ("empty patch", .success(.page(empty, etag: "\"v\""))), ("304", .success(.notModified))] {
            let s = linkedSession([response], withReceipt: true)
            let token = s.transcriptActivation.activate("t1")
            let n = await observed(s) { await s.activeTranscriptTick(token, now: t0) }
            XCTAssertEqual(n, 0, name)
        }
    }

    func testALegitimatePatchNotifiesObserversOnce() async {
        let withPatch = TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r1", items: [TranscriptItem(id: "A", role: "user", text: "插话"), TranscriptItem(id: "B", role: "assistant", text: "答")], nextBefore: nil, hasMore: true, partial: false, receiptUpdates: [patch])
        let s = linkedSession([.success(.page(withPatch, etag: "\"v2\""))], withReceipt: false)
        let token = s.transcriptActivation.activate("t1")
        let n = await observed(s) { await s.activeTranscriptTick(token, now: t0) }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(s.transcripts["t1"]?.linkedEventKeys, ["K"])
        XCTAssertEqual(s.transcripts["t1"]?.items.first?.receipt, patch.receipt)
    }

    // MARK: #110 C：重启后没有本机 Sent，服务端 command 补行也进回执后补（与 iOS 同一规则）

    private func restartedSession() throws -> MacSession {
        let s = session()
        s.stopStream()
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"c110-mac","name":"mac","paused":false,"permission":"control"}"#.utf8))
        return s
    }
    private func inbound(_ s: MacSession, _ key: String, _ state: String = "unknown", seq: Int = 155, target: String = "t1", origin: String = "api") {
        let json = #"{"key":"\#(key)","inboxSeq":\#(seq),"text":"合成 \#(key)","truncated":false,"origin":"\#(origin)","state":"\#(state)","lane":"ordinary","targetId":"\#(target)"}"#
        var parser = SSEParser()
        s.applyStreamEventForTest(BridgeEventDecoder.decode(parser.feed(Data("event: inbound\ndata: \(json)\n\n".utf8))[0]))
    }
    private func loadLatest(_ s: MacSession, items: [TranscriptItem]? = nil, epoch: String = "e1") {
        var th = TranscriptThread()
        th.applyLatest(TranscriptPage(status: "ok", sessionEpoch: epoch, revision: "r1",
                                      items: items ?? [TranscriptItem(id: "A", role: "user", text: "插话"), TranscriptItem(id: "B", role: "assistant", text: "答")],
                                      nextBefore: nil, hasMore: true, partial: false))
        s.transcripts["t1"] = th
    }

    func testRestartedSupplementRowIsDeclaredAndTheReceiptReplacesIt() async throws {
        let s = try restartedSession()
        inbound(s, "K")
        loadLatest(s)
        XCTAssertTrue(s.sent.isEmpty)
        XCTAssertEqual(s.threadTail(threadId: "t1").supplement.map(\.key), ["K"], "补行 B 显示")
        XCTAssertEqual(s.receiptRequest(for: "t1"), TranscriptReceiptRequest(sessionEpoch: "e1", eventKeys: ["K"]))
        let fake = FakeBackfillMac([.success(.page(page(updates: [patch]), etag: "\"v2\""))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        let t = try XCTUnwrap(s.transcripts["t1"])
        XCTAssertEqual(t.items[0].receipt?.eventKey, "K")
        XCTAssertEqual(t.linkedEventKeys, ["K"])
        XCTAssertEqual(t.items.map(\.id), ["A", "B"])
        XCTAssertTrue(s.threadTail(threadId: "t1").commandRows.isEmpty, "补行 B 消失")
        XCTAssertEqual(s.commands["K"]?.state, "unknown", "命令状态不被追认")
        XCTAssertNil(s.receiptRequest(for: "t1"), "已关联不再声明")
    }

    func testOnlyActualUnlinkedApiRowsOfTheLatestWindowAreDeclared() throws {
        let s = try restartedSession()
        let linkedItem = TranscriptItem(id: "uL", role: "user", text: "合成 L", receipt: .init(commandKey: "L", origin: "api", receiptState: "sent", eventKey: "L"))
        loadLatest(s, items: [linkedItem, TranscriptItem(id: "B", role: "assistant", text: "答")])
        inbound(s, "L", seq: 1); inbound(s, "FEI", seq: 2, origin: "feishu"); inbound(s, "OTHER", seq: 3, target: "t2")
        inbound(s, "FIN", "finished", seq: 4); inbound(s, "OK", "started", seq: 5)
        s.sent = [sent("X", epoch: "e0")]; inbound(s, "X", seq: 6)
        XCTAssertEqual(s.receiptRequest(for: "t1")?.eventKeys, ["OK"], "linked / 非 API / 别的目标 / 终态 / 他代次回显都不选")
        var pinned = TranscriptThread(); pinned.applyLatest(page())
        _ = pinned.applyLocated(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: ["x1", "x2"].map { TranscriptItem(id: $0, role: "user", text: $0) }, nextBefore: "c", hasMore: true), itemId: "x1")
        s.transcripts["t1"] = pinned
        XCTAssertNil(s.receiptRequest(for: "t1"), "历史 / 定位窗不选补行")
    }

    func testAShapeFlipFromNoClaimToASupplementKeyIsReadOnTheNextTickAndNothingIsScheduledOtherwise() async throws {
        let s = try restartedSession()
        loadLatest(s)
        let fake = FakeBackfillMac([.success(.page(page(), etag: "\"v1\"")), .success(.page(page(updates: [patch]), etag: "\"v2\"")), .success(.page(page(), etag: "\"v3\""))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        inbound(s, "K")
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(0.2))
        let early = await fake.calls.count
        XCTAssertEqual(early, 1, "节拍未到：没有额外读取")
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(2))
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].receipt, TranscriptReceiptRequest(sessionEpoch: "e1", eventKeys: ["K"]))
        XCTAssertNil(calls[1].etag, "形状变了：不沿无声明的 ETag 沉睡")
        XCTAssertEqual(s.transcripts["t1"]?.linkedEventKeys, ["K"])
    }

    func testUnclaimedKeysUnknownItemsAndOldEpochsAreNotAdoptedForSupplementRows() async throws {
        let s = try restartedSession()
        inbound(s, "K"); loadLatest(s)
        let wrongKey = TranscriptReceiptUpdate(itemId: "A", receipt: TranscriptReceipt(commandKey: "ck", origin: "api", receiptState: "sent", eventKey: "K2"))
        let wrongItem = TranscriptReceiptUpdate(itemId: "ZZ", receipt: patch.receipt)
        var oldEpoch = page(updates: [patch]); oldEpoch.sessionEpoch = "e0"
        let fake = FakeBackfillMac([.success(.page(page(updates: [wrongKey, wrongItem]), etag: "\"a\"")), .success(.page(oldEpoch, etag: "\"b\""))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        XCTAssertTrue(s.transcripts["t1"]?.linkedEventKeys.isEmpty == true)
        XCTAssertNil(s.transcripts["t1"]?.items.first?.receipt)
        XCTAssertEqual(s.threadTail(threadId: "t1").supplement.map(\.key), ["K"], "未关联：补行不被吞")
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(2))
        XCTAssertTrue(s.transcripts["t1"]?.linkedEventKeys.isEmpty == true, "旧 epoch 的补丁不采纳")
    }

    func testANewEpochDropsTheOldLinkAndStillClaimsWithoutLeaking() async throws {
        let s = try restartedSession()
        inbound(s, "K"); loadLatest(s)
        let next = TranscriptPage(status: "ok", sessionEpoch: "e2", revision: "r2", items: [TranscriptItem(id: "N", role: "user", text: "新代"), TranscriptItem(id: "M", role: "assistant", text: "答")], nextBefore: nil, hasMore: true, partial: false)
        let fake = FakeBackfillMac([.success(.page(page(updates: [patch]), etag: "\"v2\"")), .success(.page(next, etag: "\"v3\""))])
        s.searchClientOverride = { fake }
        let token = s.transcriptActivation.activate("t1")
        await s.activeTranscriptTick(token, now: t0)
        XCTAssertEqual(s.transcripts["t1"]?.linkedEventKeys, ["K"])
        await s.activeTranscriptTick(token, now: t0.addingTimeInterval(2))
        XCTAssertTrue(s.transcripts["t1"]?.linkedEventKeys.isEmpty == true)
        XCTAssertEqual(s.transcripts["t1"]?.items.map(\.id), ["N", "M"], "切代清掉旧关联与旧项")
        XCTAssertEqual(s.receiptRequest(for: "t1")?.sessionEpoch, "e2", "声明只表达当前代次；是否属于该代由 Bridge 核验")
    }
}
