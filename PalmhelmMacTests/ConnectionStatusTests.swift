import XCTest
@testable import PalmhelmMac

/// 连接阶段投影与自动配对重试判定的纯逻辑测试。
@MainActor
final class ConnectionStatusTests: XCTestCase {
    private func phase(
        _ status: BridgeEngine.Status = .running,
        portFile: Bool = true,
        credentials: Bool = true,
        secrets: Bool = true,
        link: MacSession.Link = .notPaired
    ) -> ConnectionPhase {
        ConnectionPhase.from(engineStatus: status, portFileReady: portFile, credentialsLoaded: credentials, secretsLoaded: secrets, link: link)
    }

    func testCredentialsNotReadyWinsOverEngineAndLink() {
        // 凭据/钥匙串未读完优先：即使引擎运行且会话未配对，也只显示读取中
        XCTAssertEqual(phase(credentials: false), .readingCredentials)
        XCTAssertEqual(phase(secrets: false, link: .connected), .readingCredentials)
    }

    func testEngineStatesWithoutPortFile() {
        XCTAssertEqual(phase(.stopped, portFile: false), .engineOff)
        XCTAssertEqual(phase(.starting, portFile: false), .engineStarting)
        XCTAssertEqual(phase(.stopping, portFile: false), .engineStopping)
        XCTAssertEqual(phase(.running, portFile: false), .engineStarting, "运行中但端口文件未就绪仍视为启动中")
    }

    func testFailedEngineWinsOverLink() {
        let p = phase(.failed("退出码 1"), link: .connected)
        XCTAssertEqual(p, .engineFailed("退出码 1"))
        XCTAssertEqual(p.label, "Bridge 启动失败：退出码 1")
        XCTAssertFalse(p.isTransitional)
    }

    func testRunningLinkStates() {
        XCTAssertEqual(phase(link: .notPaired), .preparingPairing)
        XCTAssertEqual(phase(link: .notPaired).label, "准备自动配对…")
        XCTAssertEqual(phase(link: .connecting), .pairing)
        XCTAssertTrue(phase(link: .connecting).isTransitional)
        XCTAssertEqual(phase(link: .connected), .connected)
        XCTAssertEqual(phase(link: .connected).label, "在线")
        XCTAssertEqual(phase(link: .offline("超时")), .offline("超时"))
        XCTAssertEqual(phase(link: .offline("超时")).label, "离线：超时")
    }

    func testStoppedIsOffRegardlessOfLink() {
        // 已停止（含手动停止）不因会话残留的连接态显示为在线
        XCTAssertEqual(phase(.stopped, link: .connected), .engineOff)
    }

    private func endpoint(_ port: Int) -> BridgeEngine.PalmhelmEndpoint {
        BridgeEngine.PalmhelmEndpoint(host: "127.0.0.1", port: port, https: false, spki: nil)
    }
    private let now = Date(timeIntervalSince1970: 1_000)

    func testFirstAttemptAfterBackoffWhenRunning() {
        XCTAssertTrue(PairingRetry.shouldAttempt(isRunning: true, endpoint: endpoint(1), paired: nil, link: .notPaired, now: now, nextTry: .distantPast))
    }

    func testBackoffNotElapsedDoesNotRetry() {
        // 回归触发：退避未到时若放开重试，失败后每 2 秒重新签码
        XCTAssertFalse(PairingRetry.shouldAttempt(isRunning: true, endpoint: endpoint(1), paired: nil, link: .notPaired, now: now, nextTry: now.addingTimeInterval(5)))
    }

    func testNotRunningOrNoEndpointDoesNotRetry() {
        XCTAssertFalse(PairingRetry.shouldAttempt(isRunning: false, endpoint: endpoint(1), paired: nil, link: .notPaired, now: now, nextTry: .distantPast))
        XCTAssertFalse(PairingRetry.shouldAttempt(isRunning: true, endpoint: nil, paired: nil, link: .notPaired, now: now, nextTry: .distantPast))
    }

    func testSameEndpointNotPairedRetriesPairingGap() {
        // 重配缺口（R2'）：同一端点曾配对成功，会话变回未配对（如 forget）⇒ 必须重新配对
        XCTAssertTrue(PairingRetry.shouldAttempt(isRunning: true, endpoint: endpoint(1), paired: endpoint(1), link: .notPaired, now: now, nextTry: .distantPast))
    }

    func testConnectedSameEndpointDoesNotRetry() {
        // 回归触发：已连通时若重试，会在每轮循环触发一次重配
        XCTAssertFalse(PairingRetry.shouldAttempt(isRunning: true, endpoint: endpoint(1), paired: endpoint(1), link: .connected, now: now, nextTry: .distantPast))
    }

    func testOfflineSameEndpointLeavesRefreshToAppBoot() {
        // 离线由 AppBoot 的刷新分支负责，不走配对重试（避免与 refresh 重复）
        XCTAssertFalse(PairingRetry.shouldAttempt(isRunning: true, endpoint: endpoint(1), paired: endpoint(1), link: .offline("x"), now: now, nextTry: .distantPast))
    }

    func testNewEndpointRetriesEvenWhenConnected() {
        XCTAssertTrue(PairingRetry.shouldAttempt(isRunning: true, endpoint: endpoint(2), paired: endpoint(1), link: .connected, now: now, nextTry: .distantPast))
    }
}
