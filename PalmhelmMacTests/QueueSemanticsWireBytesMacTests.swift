import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #89 片 B 联验（producer→consumer 契约字节，非真实 HTTP / SSE 传输）：与 iOS QueueSemanticsWireBytesTests 同一组场景，经 MacSession 真实采纳入口。
private final class MacHistoryCalls: @unchecked Sendable { var n = 0 }
private struct MacBytesClient: SearchTranscriptClient {
    let calls: MacHistoryCalls
    func search(q: String, limit: Int) async throws -> SearchResponse { throw URLError(.notConnectedToInternet) }
    func transcript(targetId: String, before: String?, limit: Int) async throws -> TranscriptPage { throw URLError(.notConnectedToInternet) }
    func targetHistory(targetId: String, before: String?, limit: Int) async throws -> TargetHistoryPage {
        calls.n += 1
        return try JSONDecoder().decode(TargetHistoryPage.self, from: Data(QueueV2WireBytes.history.utf8))
    }
}

@MainActor final class QueueSemanticsWireBytesMacTests: XCTestCase {
    private func stateWithCommands(working: Bool = false) throws -> BridgeState {
        let inner = String(QueueV2WireBytes.commands.dropFirst().dropLast())
        let status = working ? #","status":"working""# : ""
        return try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","bridge":{"id":"B-e2e"},"targets":[{"id":"t-x","projectName":"p","agentName":"a"\#(status)}],"history":{"highWater":0,"items":[]},\#(inner)}"#.utf8))
    }
    private func session() throws -> MacSession {
        let s = MacSession()
        s.stopStream()
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"e2e-mac","name":"mac","paused":false,"permission":"control"}"#.utf8))
        return s
    }
    private func readable(linked: [String] = []) -> TranscriptThread {
        var t = TranscriptThread(); t.status = .ok; t.sessionEpoch = "e1"
        t.items = linked.map { TranscriptItem(id: "u\($0)", role: "user", text: "x", receipt: .init(commandKey: $0, origin: "api", receiptState: "accepted", eventKey: $0)) }
        return t
    }

    func testHttpSnapshotThenSseFramesProduceTheSameFinalStateAsTheLedger() async throws {
        let s = try session()
        s.transcripts["t-x"] = readable()
        let snap = try stateWithCommands()
        s.stateOverride = { @Sendable in snap }
        try await s.pullState()
        XCTAssertEqual(s.messageStatus(for: s.commands["e2e:np"]!).phase, .stopped)
        XCTAssertEqual(s.messageStatus(for: s.commands["e2e:unc"]!).phase, .stoppedUncertain)
        XCTAssertTrue(s.commands["e2e:dl"]?.stopDisposition == nil && s.commands["e2e:fin"]?.stopDisposition == nil)
        var tail = s.threadTail(threadId: "t-x")
        XCTAssertEqual(tail.deadline.map(\.key), ["e2e:dl"])
        XCTAssertEqual(tail.supplement.map(\.key), ["e2e:np", "e2e:unc"])
        XCTAssertNotNil(s.messageStatus(for: s.commands["e2e:dl"]!).card?.deadlineText)

        var parser = SSEParser()
        let events = parser.feed(Data(QueueV2WireBytes.progressSSE.utf8)).map { BridgeEventDecoder.decode($0) }
        let titles = ["正在发送", "已送达 · 等待回合开始", "已送达 · 回合进行中"]
        var seen = 0
        for e in events {
            s.applyStreamEventForTest(e)
            if case .progress(let p) = e, p.eventKey == "e2e:dl" {
                let ms = s.messageStatus(for: s.commands["e2e:dl"]!)
                XCTAssertEqual(ms.card?.title, titles[seen])
                XCTAssertNil(ms.card?.deadlineText)
                seen += 1
            }
        }
        XCTAssertEqual(seen, 3)
        XCTAssertEqual(s.messageStatus(for: s.commands["e2e:np"]!).phase, .stopped)
        XCTAssertEqual(s.messageStatus(for: s.commands["e2e:unc"]!).phase, .stoppedUncertain)

        s.transcripts["t-x"] = readable(linked: ["e2e:dl"])
        tail = s.threadTail(threadId: "t-x")
        XCTAssertFalse(tail.commandRows.map(\.key).contains("e2e:dl"))
        let receipt = TranscriptReceipt(commandKey: "x", origin: "api", receiptState: "sent", eventKey: "e2e:dl")
        let idle = s.recordStatus(receipt)?.phase
        s.state = try stateWithCommands(working: true)
        XCTAssertEqual(s.recordStatus(receipt)?.phase, idle)
        XCTAssertEqual(idle, .processing)

        let calls = MacHistoryCalls()
        s.archiveClientOverride = { MacBytesClient(calls: calls) }
        let scope = try XCTUnwrap(s.ledgerScope("t-x"))
        await s.loadArchivedHistory("t-x", older: false, scope: scope)
        let rows = Dictionary(uniqueKeysWithValues: s.archivedPage("t-x").items.compactMap { r in r.command.map { ($0.key, r) } })
        XCTAssertEqual(Set(rows.keys), ["e2e:np", "e2e:unc", "e2e:dl", "e2e:fin"])
        XCTAssertEqual(MessageStatusRules.standalone(rows["e2e:np"]!.command!).phase, .stopped)
        XCTAssertEqual(MessageStatusRules.standalone(rows["e2e:unc"]!.command!).phase, .stoppedUncertain)
        XCTAssertNotNil(MessageStatusRules.standalone(rows["e2e:dl"]!.command!).card?.deadlineText)
        XCTAssertEqual(calls.n, 1)
        XCTAssertTrue(s.sent.isEmpty, "只读：没有任何发送副作用")
        XCTAssertEqual(s.messageStatus(for: s.commands["e2e:dl"]!).card?.title, "已送达 · 回合进行中", "历史行不改变当前 scope 的结论")
    }

    func testAWindowThatNeverSawTheKeysStillFindsThemInTheLedger() async throws {
        let s2 = try session()
        s2.transcripts["t-x"] = readable()
        s2.state = try stateWithCommands()
        XCTAssertTrue(s2.commands.isEmpty && s2.threadTail(threadId: "t-x").commandRows.isEmpty)
        let calls = MacHistoryCalls()
        s2.archiveClientOverride = { MacBytesClient(calls: calls) }
        let scope = try XCTUnwrap(s2.ledgerScope("t-x"))
        await s2.loadArchivedHistory("t-x", older: false, scope: scope)
        XCTAssertEqual(s2.archivedPage("t-x").items.compactMap(\.command).map(\.key).sorted(), ["e2e:dl", "e2e:fin", "e2e:np", "e2e:unc"])
        XCTAssertTrue(s2.commands.isEmpty)
    }
}
