import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #89 片 B 真实 HTTP / SSE 联验（B-G2，Mac）：与 iOS QueueSemanticsLoopbackTests 同一条旅程。本地隔离测试 Bridge（真实 HTTP 路由 / SSE 中枢 /
// progress 轮询 / 指令与历史投影，127.0.0.1，临时数据），MacSession 走正式 BridgeClient：refresh 的真实 GET /v1/state、SSE、账本的真实 GET history。
// 需要 TEST_RUNNER_PALMHELM_E2E_SERVER=<out 目录> 指向已启动的测试 Bridge；没设置则跳过。
private final class MacTitleLog: @unchecked Sendable {
    private var list: [String?] = []
    func add(_ t: String?) { if list.last != .some(t) { list.append(t) } }
    var all: [String?] { list }
}

@MainActor final class QueueSemanticsLoopbackMacTests: XCTestCase {
    private func waitFor(_ seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(40)) }
        return cond()
    }

    func testRealHttpAndSseCarryTheSameKeysToTheParentAndTheLedger() async throws {
        guard let path = ProcessInfo.processInfo.environment["PALMHELM_E2E_SERVER"] else { throw XCTSkip("未设置 TEST_RUNNER_PALMHELM_E2E_SERVER") }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let meta = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("server.json"))) as? [String: Any])
        let port = try XCTUnwrap(meta["port"] as? Int), token = try XCTUnwrap(meta["token"] as? String)

        let s = MacSession()
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"e2e-mac","name":"mac","paused":false,"permission":"view"}"#.utf8))
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: port), token: token)
        var t = TranscriptThread(); t.status = .ok; t.sessionEpoch = "e1"
        s.transcripts["t-x"] = t
        defer { s.stopStream() }
        await s.refresh()   // 生产同步：真实 GET /v1/state，并建立真实 SSE
        s.startStream()

        let gotCommands = await waitFor(30) { s.commands["e2e:np"] != nil && s.commands["e2e:dl"] != nil }
        XCTAssertTrue(gotCommands, "真实 GET /v1/state 到达同批 K")
        XCTAssertEqual(s.messageStatus(for: try XCTUnwrap(s.commands["e2e:np"])).phase, .stopped)
        XCTAssertEqual(s.messageStatus(for: try XCTUnwrap(s.commands["e2e:unc"])).phase, .stoppedUncertain)
        XCTAssertTrue(s.commands["e2e:dl"]?.stopDisposition == nil && s.commands["e2e:aw"]?.stopDisposition == nil, "非暂停态没有 stop 键")
        let titles = MacTitleLog()
        XCTAssertNotNil(s.messageStatus(for: try XCTUnwrap(s.commands["e2e:dl"])).card?.deadlineText, "queued 带真实期限")
        titles.add(s.messageStatus(for: s.commands["e2e:dl"]!).card?.title)

        let advanced = await waitFor(40) {
            if let c = s.commands["e2e:dl"] { titles.add(s.messageStatus(for: c).card?.title) }
            return s.commands["e2e:pp"]?.state == "paused" && s.commands["e2e:aw"]?.state == "paused" && s.commands["e2e:dl"]?.queue?.phase == "running"
        }
        XCTAssertTrue(advanced, "SSE 帧到达：\(s.commands["e2e:dl"]?.state ?? "-")/\(s.commands["e2e:dl"]?.queue?.phase ?? "-")")
        XCTAssertEqual(s.messageStatus(for: s.commands["e2e:dl"]!).card?.title, "已送达 · 回合进行中")
        XCTAssertNil(s.messageStatus(for: s.commands["e2e:dl"]!).card?.deadlineText, "dispatch 之后期限移除")
        XCTAssertTrue(titles.all.contains { $0 == "正在发送" } && titles.all.contains { $0 == "已送达 · 等待回合开始" }, "阶段依次出现：\(titles.all)")
        XCTAssertEqual(s.messageStatus(for: s.commands["e2e:aw"]!).phase, .stoppedUncertain, "见过 awaiting 后暂停：保守")
        XCTAssertEqual(s.messageStatus(for: s.commands["e2e:pp"]!).phase, .stopped, "全新无证据的暂停：未发出")

        var tail = s.threadTail(threadId: "t-x")
        XCTAssertEqual(Set(tail.commandRows.map(\.key)), ["e2e:np", "e2e:unc", "e2e:dl", "e2e:aw", "e2e:pp"])
        XCTAssertTrue(tail.deadline.isEmpty)
        var linked = TranscriptThread(); linked.status = .ok; linked.sessionEpoch = "e1"
        linked.items = [TranscriptItem(id: "u1", role: "user", text: "正文 e2e:dl", receipt: .init(commandKey: "x", origin: "api", receiptState: "sent", eventKey: "e2e:dl"))]
        s.transcripts["t-x"] = linked
        tail = s.threadTail(threadId: "t-x")
        XCTAssertFalse(tail.commandRows.map(\.key).contains("e2e:dl"))
        XCTAssertEqual(s.recordStatus(linked.items[0].receipt)?.phase, .processing)

        let scope = try XCTUnwrap(s.ledgerScope("t-x"))
        await s.loadArchivedHistory("t-x", older: false, scope: scope)
        let rows = Dictionary(uniqueKeysWithValues: s.archivedPage("t-x").items.compactMap { r in r.command.map { ($0.key, $0) } })
        XCTAssertEqual(Set(rows.keys), ["e2e:np", "e2e:unc", "e2e:dl", "e2e:aw", "e2e:pp"], "账本从真实 GET 读到同批 K")
        XCTAssertEqual(rows["e2e:np"].map(MessageStatusRules.standalone)?.phase, .stopped)
        XCTAssertEqual(rows["e2e:unc"].map(MessageStatusRules.standalone)?.phase, .stoppedUncertain)
        XCTAssertTrue(s.sent.isEmpty)

        FileManager.default.createFile(atPath: dir.appendingPathComponent("done").path, contents: Data())
        try await Task.sleep(for: .milliseconds(800))
        let log = try String(contentsOf: dir.appendingPathComponent("requests.log"), encoding: .utf8).split(separator: "\n").map(String.init)
        let http = log.filter { line in ["GET ", "POST ", "PUT ", "DELETE ", "PATCH "].contains { line.hasPrefix($0) } }
        XCTAssertTrue(http.allSatisfy { $0.hasPrefix("GET ") }, "只有 GET：\(http)")
        XCTAssertEqual(http.filter { $0 == "GET /v1/targets/t-x/history" }.count, 1, "账本一次 GET")
        XCTAssertTrue(http.contains("GET /v1/events") && http.contains("GET /v1/state"))
    }
}
