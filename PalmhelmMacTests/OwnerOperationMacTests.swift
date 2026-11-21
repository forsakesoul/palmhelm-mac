import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #89 联测缺陷 ②③（片 A，Mac Session，纯逻辑）：当前线程重置的目标固定为捕获的 scope；owner 操作终态保留在稳定位置，不再混进待发回显。
@MainActor
final class OwnerOperationMacTests: XCTestCase {
    final class Wires: @unchecked Sendable {
        private let lock = NSLock(); private var values: [String] = []
        func add(_ s: String) { lock.withLock { values.append(s) } }
        var all: [String] { lock.withLock { values } }
    }
    private func state(bridge: String = "B1") throws -> BridgeState {
        try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","bridge":{"id":"\#(bridge)"},"targets":[{"id":"t1","projectName":"p","agentName":"a","status":"idle"},{"id":"a b","projectName":"q","agentName":"a","status":"idle"}],"binding":{"targetId":"other","projectName":"feishu-bound","agentName":"x"},"history":{"highWater":0,"items":[]}}"#.utf8))
    }
    private func session(_ wires: Wires, permission: String = "control") throws -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.owner-op-mac")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"own-mac","name":"mac","paused":false,"permission":"\#(permission)"}"#.utf8))
        s.link = .connected
        s.state = try state()
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        s.sendOverride = { wire, _ in wires.add(wire); return MessageReceipt.stub("k\(wires.all.count)") }
        return s
    }
    private func readable(_ ids: [String], loading: Bool = false) -> TranscriptThread {
        var t = TranscriptThread(); t.status = loading ? .loading : .ok; t.sessionEpoch = "e1"
        t.items = ids.map { TranscriptItem(id: $0, role: "user", text: "x \($0)") }
        return t
    }

    func testResetTargetsTheCapturedThreadNotTheFeishuBinding() async throws {
        let wires = Wires()
        let s = try session(wires)
        let req = try XCTUnwrap(s.ownerResetRequest(threadId: "t1"))
        XCTAssertEqual(req.command, "重置占用 t1")
        let r = await s.confirmOwnerReset(req)
        guard case .sent = r else { return XCTFail("expected sent, got \(r)") }
        XCTAssertEqual(wires.all, ["重置占用 t1"], "wire 只指向本线程目标：不带飞书绑定名、不带“派给”、不带条件 key")
        XCTAssertEqual(s.sent.last?.ownerKind, .resetOccupancy)
    }

    func testAChangedScopeOrPermissionSendsNothing() async throws {
        let wires = Wires()
        let s = try session(wires)
        let req = try XCTUnwrap(s.ownerResetRequest(threadId: "t1"))
        s.state = try state(bridge: "B2")
        let changed = await s.confirmOwnerReset(req)
        XCTAssertEqual(changed, .refused(OwnerOperationCopy.scopeChanged), "Bridge 变化")
        s.state = try state()
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"own-mac","name":"mac","paused":false,"permission":"readonly"}"#.utf8))
        let ro = await s.confirmOwnerReset(req)
        if case .sent = ro { XCTFail("read-only device must not send") }
        XCTAssertTrue(wires.all.isEmpty, "全部零发送")
    }

    func testATargetIdTheServerCannotReadBackGetsNoEntry() throws {
        let s = try session(Wires())
        XCTAssertNil(s.ownerResetRequest(threadId: "a b"))
        XCTAssertNil(s.ownerResetRequest(threadId: "missing"))
        XCTAssertNotNil(s.ownerResetRequest(threadId: "t1"))
    }

    func testAnOwnerOperationKeepsItsPlaceAndItsResultAfterItCompletes() async throws {
        let wires = Wires()
        let s = try session(wires)
        s.transcripts["t1"] = readable(["i1", "i2"])
        let idr = await s.send("重置占用 t1", inThread: "t1")
        let id = try XCTUnwrap(idr)
        let op = try XCTUnwrap(s.sent.first { $0.id == id })
        let sentAt = op.at
        XCTAssertEqual(op.anchorItemId, "i2")
        XCTAssertTrue(s.pendingEchoes(threadId: "t1").isEmpty && s.threadTail(threadId: "t1").echoes.isEmpty, "owner 操作不是待发回显")
        XCTAssertEqual(s.outgoingStatus(op).phase, .ownerSubmitted, "无回执：已提交，不是排队")
        s.transcripts["t1"] = readable(["i1", "i2", "i3", "i4"])
        s.history = [HistoryItem(seq: 5, uuid: "ack:k1", text: "reset:0", kind: "text", replyTo: "k1")]
        let done = try XCTUnwrap(s.sent.first { $0.id == id })
        XCTAssertEqual(s.outgoingStatus(done).phase, .done)
        let reply = s.receipts(of: id, statusPhase: .done).joined(separator: "\n")
        XCTAssertTrue(ReceiptText.summary(reply).contains("没有需要停止跟踪"), "结果经既有 receipts 收集 + 共享 summary 可读化")
        XCTAssertEqual(done.at, sentAt, "发送时间不随回执变化")
        let p = s.ownerPlacement(threadId: "t1", visibleItemIds: ["i1", "i2", "i3", "i4"])
        XCTAssertEqual(p.after["i2"]?.map(\.id), [id], "终态仍在原位置，不后移到尾部")
        XCTAssertTrue(p.local.isEmpty)
    }

    func testAMultiPartPanelResultKeepsEveryPart() async throws {
        let s = try session(Wires())
        s.transcripts["t1"] = readable(["i1"])
        let idr = await s.send("面板", inThread: "t1")
        let id = try XCTUnwrap(idr)
        let op = try XCTUnwrap(s.sent.first { $0.id == id })
        s.history = [HistoryItem(seq: 7, uuid: "ack:k1:p2", text: "第二片", kind: "text", replyTo: "k1"),
                     HistoryItem(seq: 6, uuid: "ack:k1", text: "第一片", kind: "text", replyTo: "k1"),
                     HistoryItem(seq: 8, uuid: "ack:k1:p3", text: "不是本条", kind: "text", replyTo: "other")]
        XCTAssertEqual(s.outgoingStatus(op).phase, .done)
        XCTAssertEqual(s.receipts(of: id, statusPhase: .done), ["第一片", "第二片"])
        let s2 = try session(Wires())
        s2.transcripts["t1"] = readable(["i1"])
        let id2r = await s2.send("面板", inThread: "t1")
        let id2 = try XCTUnwrap(id2r)
        s2.history = [HistoryItem(seq: 6, uuid: "ack:k1", text: "第一片", kind: "text")]
        XCTAssertEqual(s2.outgoingStatus(try XCTUnwrap(s2.sent.first { $0.id == id2 })).phase, .ownerSubmitted, "缺 replyTo 不采纳")
    }

    func testAMalformedAckNeverSettlesAnOwnerOperation() async throws {
        let s = try session(Wires())
        s.transcripts["t1"] = readable(["i1"])
        let idr = await s.send("重置占用 t1", inThread: "t1")
        let id = try XCTUnwrap(idr)
        let op = try XCTUnwrap(s.sent.first { $0.id == id })
        for bad in ["reset:-1", "switched:", "queued:task:x", "garbage"] {
            s.history = [HistoryItem(seq: 5, uuid: "ack:k1", text: bad, kind: "text", replyTo: "k1")]
            XCTAssertEqual(s.outgoingStatus(op).phase, .ownerSubmitted, bad)
        }
    }

    func testAMissingAnchorDegradesToTheLocalGroupOnlyInTheLatestWindow() async throws {
        let wires = Wires()
        let s = try session(wires)
        s.transcripts["t1"] = readable(["i1"])
        let idr = await s.send("面板", inThread: "t1")
        let id = try XCTUnwrap(idr)
        var p = s.ownerPlacement(threadId: "t1", visibleItemIds: ["z9"])
        XCTAssertTrue(p.after.isEmpty)
        XCTAssertEqual(p.local.map(\.id), [id])
        s.transcripts["t1"] = readable(["i1"], loading: true)
        p = s.ownerPlacement(threadId: "t1", visibleItemIds: ["z9"])
        XCTAssertTrue(p.isEmpty, "非最新窗不追加本机操作记录组")
        let otherr = await s.send("普通消息", inThread: "t1")
        let other = try XCTUnwrap(otherr)
        XCTAssertNil(s.sent.first { $0.id == other }?.ownerKind)
    }
}
