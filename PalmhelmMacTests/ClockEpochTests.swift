import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// 待答有效性按边界调度（取代 O1-337 的 5 秒检查 + 分钟广播）：到期在精确的 expiresT 当刻发布一次，
// 普通秒 / 分钟且集合不变时读取待答的消费者保持静默；到期只影响本地展示。
@MainActor
final class ClockEpochTests: XCTestCase {
    private func session(expiresInMs: Int) throws -> MacSession {
        let s = MacSession()
        s.streamDisabled = true
        s.preferences = UserDefaults(suiteName: "palmhelm.clock-epoch")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-clock","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let json = #"{"occupancy":"free","targets":[{"id":"t1","projectName":"p","agentName":"p","status":"idle"}],"history":{"highWater":0,"items":[]},"approvals":[{"id":"ap-1","status":"pending","targetLabel":"p","attribution":"exact","toolName":"Bash","summary":"ls","truncated":false,"createdT":\#(now - 1_000),"expiresT":\#(now + expiresInMs)}]}"#
        s.stateOverride = { try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8)) }
        return s
    }

    /// 精确边界：到期的定时器在 expiresT 当刻发布，不等 5 秒拍；依赖待答的读取者收到通知。
    func testApprovalExpiresAtTheExactBoundaryAndNotifiesObservers() async throws {
        let s = try session(expiresInMs: 1_000)
        await s.refresh()
        XCTAssertEqual(s.pendingApprovals.map(\.id), ["ap-1"], "未到期时在待答里")
        let fired = Flag()
        withObservationTracking({ _ = s.pendingApprovals }, onChange: { fired.set() })
        try await Task.sleep(for: .milliseconds(1_700)) // 远小于旧的 5 秒拍
        XCTAssertTrue(fired.value, "到期当刻通知依赖待答的读取者")
        XCTAssertTrue(s.pendingApprovals.isEmpty)
    }

    func testApprovalStaysPendingWhileNotExpired() async throws {
        let s = try session(expiresInMs: 600_000)
        await s.refresh()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(s.pendingApprovals.map(\.id), ["ap-1"], "未到期的待答保持有效")
    }

    /// 未到期且集合不变时保持静默：分钟边界也不广播。
    func testNoNotificationWhileNothingExpires() async throws {
        let s = try session(expiresInMs: 600_000)
        await s.refresh()
        for _ in 0..<8 { await Task.yield() }
        let fired = Flag()
        withObservationTracking({ _ = s.pendingApprovals }, onChange: { fired.set() })
        for sec in 1...5 { s.dateProvider = { Date().addingTimeInterval(Double(sec) * 61) }; s.reconcileTimeValidity(fromTime: true) } // 跨分钟
        XCTAssertFalse(fired.value, "未到期：普通秒 / 分钟都不通知")
    }

    /// 过期的普通审批不发请求，给固定提示（O1-341 R3）。
    func testExpiredApprovalIsNotSentAndSaysSo() async throws {
        let s = try session(expiresInMs: 300)
        await s.refresh()
        let a = try XCTUnwrap(s.pendingApprovals.first)
        try await Task.sleep(for: .milliseconds(500))
        let sent = Flag()
        s.decideOverride = { _, _ in sent.set() }
        await s.decide(a, .allowOnce)
        XCTAssertFalse(sent.value, "过期后不发请求")
        XCTAssertEqual(s.decideError[a.id]?.text, "这条审批已过期，不能再处理")
    }
}

final class Flag: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}
