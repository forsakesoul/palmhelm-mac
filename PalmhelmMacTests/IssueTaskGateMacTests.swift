import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #21 S2（Mac，A1-190 / O1-189）：派发门禁在会话层生效；被拦下时零请求；确认前复核的变化也拒。
// Mac 没有「勿扰」状态（普通发送也没有），因此这里覆盖暂停、断线与只读。
@MainActor
final class IssueTaskGateMacTests: XCTestCase {
    final class CountingTransport: IssueTaskTransport, @unchecked Sendable {
        var previews = 0
        var creates = 0
        func issueTaskOptions() async throws -> IssueTaskOptions { throw IssueTaskBlocked(reason: "unused") }
        func issueTaskList(sourceId: String, page: Int) async throws -> IssueTaskListPage { throw IssueTaskBlocked(reason: "unused") }
        func issueTaskDetail(sourceId: String, number: Int) async throws -> IssueTaskDetail { throw IssueTaskBlocked(reason: "unused") }
        func issueTaskPreview(_ request: IssueTaskRequest) async throws -> IssueTaskPreview {
            previews += 1
            return try JSONDecoder().decode(IssueTaskPreview.self, from: Data(#"{"text":"[任务] x","textDigest":"d","destinationVersion":"dv","sourceVersion":null}"#.utf8))
        }
        func issueTaskCreate(_ request: IssueTaskRequest) async throws -> IssueTaskCreated {
            creates += 1
            return try JSONDecoder().decode(IssueTaskCreated.self, from: Data(#"{"accepted":true,"eventKey":"api:d:u"}"#.utf8))
        }
    }

    private func device(permission: String = "control", paused: Bool = false) throws -> DeviceInfo {
        try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-gate","name":"Mac","paused":\#(paused),"permission":"\#(permission)"}"#.utf8))
    }

    private func request() -> IssueTaskRequest {
        IssueTaskRequest(targetId: "t1", destinationVersion: "dv", source: .manual(title: "x", description: "y", referenceUrl: nil), instructions: "", ackClosed: false,
                         clientMsgId: "00000000-0000-4000-8000-00000000000a", textDigest: "d")
    }

    private func session(_ transport: CountingTransport) throws -> MacSession {
        let s = MacSession()
        s.issueTaskTransportOverride = { transport }
        // sendBlocker 的配对判定：以发送替身视为已配对（不会真的发送）。
        s.sendOverride = { _, _ in throw URLError(.cancelled) }
        s.link = .connected
        s.device = try device()
        return s
    }

    private func assertBlocked(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected the gate to refuse", file: file, line: line)
        } catch let e as IssueTaskBlocked {
            XCTAssertFalse(e.reason.isEmpty, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testPausedDeviceBlocksPreviewAndConfirmWithoutRequests() async throws {
        let t = CountingTransport()
        let s = try session(t)
        s.device = try device(paused: true)
        XCTAssertEqual(s.issueTaskBlocker(), "这台设备已暂停接收任务，发送会被拒绝")
        await assertBlocked { _ = try await s.issueTaskPreviewChecked(request()) }
        await assertBlocked { _ = try await s.issueTaskCreateChecked(request()) }
        XCTAssertEqual(t.previews, 0)
        XCTAssertEqual(t.creates, 0)
    }

    func testDisconnectedBlocksPreviewAndConfirmWithoutRequests() async throws {
        let t = CountingTransport()
        let s = try session(t)
        s.link = .offline("断线")
        XCTAssertEqual(s.issueTaskBlocker(), "未连接 Bridge，暂时不能发送")
        await assertBlocked { _ = try await s.issueTaskPreviewChecked(request()) }
        await assertBlocked { _ = try await s.issueTaskCreateChecked(request()) }
        XCTAssertEqual(t.previews, 0)
        XCTAssertEqual(t.creates, 0)
    }

    func testReadOnlyDeviceBlocksPreviewAndConfirmWithoutRequests() async throws {
        let t = CountingTransport()
        let s = try session(t)
        s.device = try device(permission: "readonly")
        XCTAssertEqual(s.issueTaskBlocker(), MacSession.readOnlyNote)
        await assertBlocked { _ = try await s.issueTaskPreviewChecked(request()) }
        await assertBlocked { _ = try await s.issueTaskCreateChecked(request()) }
        XCTAssertEqual(t.previews, 0)
        XCTAssertEqual(t.creates, 0)
    }

    func testGateChangedBetweenPreviewAndConfirmRefusesConfirm() async throws {
        let t = CountingTransport()
        let s = try session(t)
        _ = try await s.issueTaskPreviewChecked(request())
        XCTAssertEqual(t.previews, 1, "门禁通过时预览照常发出")
        s.device = try device(paused: true) // 确认前设备被暂停
        await assertBlocked { _ = try await s.issueTaskCreateChecked(request()) }
        XCTAssertEqual(t.creates, 0, "确认前复核拦下：零确认请求")
    }

    func testAllowedPathStillReachesTheTransport() async throws {
        let t = CountingTransport()
        let s = try session(t)
        _ = try await s.issueTaskCreateChecked(request())
        XCTAssertEqual(t.creates, 1)
    }
}
