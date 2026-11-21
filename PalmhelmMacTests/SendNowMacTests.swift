import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// 立即发送（mode=send_now）的 Mac 会话接线：直达且目标 nativeSendNow=true 才放行；绑定、能力缺失、目标或 agent 变化零请求；菜单与排队标题同源。
@MainActor
final class SendNowMacTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [QueuedAction] = []
        func record(_ kind: QueuedAction) { lock.withLock { list.append(kind) } }
        var value: [QueuedAction] { lock.withLock { list } }
    }

    private func session(capabilities: String, agent: String = "design", box: Box) throws -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.send-now.mac")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-send-now","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"busy","targets":[{"id":"t1","projectName":"p","agentName":"\#(agent)","status":"working","capabilities":\#(capabilities)}],"history":{"highWater":0,"items":[]}}"#.utf8))
        s.sendOverride = { _, _ in
            box.bump()
            return MessageReceipt.stub("send-now")
        }
        var d = MacSession.ComposerDraft()
        d.text = "立即的插话"
        s.setDraft(d, for: "t1")
        return s
    }

    private func command(_ key: String, direct: String? = "design", target: String = "t1") throws -> ApiCommand {
        let d = direct.map { #","directAgent":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"\#(key)","inboxSeq":1,"text":"补","truncated":false,"origin":"api","state":"queued","lane":"use","targetId":"\#(target)"\#(d)}"#.utf8))
    }

    func testDirectSendNowWithDeclaredCapabilitySendsSendNowMode() async throws {
        let box = Box()
        let s = try session(capabilities: #"{"steer":false,"nativeSendNow":true}"#, box: box)
        let ok = await s.submitComposer(threadId: "t1", agent: "design", mode: .sendNow)
        XCTAssertTrue(ok)
        XCTAssertEqual(box.value, 1)
        XCTAssertEqual(s.lastSendMode, .sendNow)
    }

    func testSendNowWithoutNativeSendNowIsZeroRequestAndKeepsTheDraft() async throws {
        // hook steer 与 nativeSteer 都不授权立即发送；false 灰显时也零请求
        for caps in [#"{"steer":true}"#, #"{"steer":true,"nativeSteer":true}"#, #"{"steer":false,"nativeSendNow":false}"#] {
            let box = Box()
            let s = try session(capabilities: caps, box: box)
            let ok = await s.submitComposer(threadId: "t1", agent: "design", mode: .sendNow)
            XCTAssertFalse(ok, caps)
            XCTAssertEqual(box.value, 0, caps)
        }
    }

    func testSendNowWhileBoundIsZeroRequestEvenWithCapability() async throws {
        let box = Box()
        let s = try session(capabilities: #"{"steer":false,"nativeSendNow":true}"#, box: box)
        let ok = await s.submitComposer(threadId: "t1", agent: nil, mode: .sendNow)
        XCTAssertFalse(ok)
        XCTAssertEqual(box.value, 0, "绑定目标永不发 send_now")
    }

    func testPromoteSendNowUsesItsKindAndOwnCapability() async throws {
        let box = Box()
        let s = try session(capabilities: #"{"steer":false,"nativeSendNow":true}"#, box: box)
        let calls = Calls()
        s.commandOverride = { kind, _ in calls.record(kind) }
        await s.promoteQueued(try command("api:d:30"), mode: .sendNow)
        XCTAssertEqual(calls.value, [.promoteSendNow])
        XCTAssertNil(s.commandNotes["api:d:30"])
    }

    func testPromoteSendNowWithoutCapabilityOrWithChangedAgentOrBoundIsZeroRequest() async throws {
        let calls = Calls()
        let noCap = try session(capabilities: #"{"steer":true,"nativeSteer":true}"#, box: Box())
        noCap.commandOverride = { kind, _ in calls.record(kind) }
        await noCap.promoteQueued(try command("api:d:31"), mode: .sendNow)
        XCTAssertEqual(noCap.commandNotes["api:d:31"]?.text, SendTimingCopy.directSendNowUnavailable)

        let renamed = try session(capabilities: #"{"steer":false,"nativeSendNow":true}"#, agent: "other", box: Box())
        renamed.commandOverride = { kind, _ in calls.record(kind) }
        await renamed.promoteQueued(try command("api:d:32"), mode: .sendNow)
        XCTAssertEqual(renamed.commandNotes["api:d:32"]?.text, SendTimingCopy.directTargetChanged)

        let bound = try session(capabilities: #"{"steer":false,"nativeSendNow":true}"#, box: Box())
        bound.commandOverride = { kind, _ in calls.record(kind) }
        await bound.promoteQueued(try command("api:d:33", direct: nil), mode: .sendNow)
        XCTAssertEqual(bound.commandNotes["api:d:33"]?.text, SendTimingCopy.sendNowNotDirect)
        XCTAssertEqual(calls.value, [], "三种情况都零请求")
    }

    /// 菜单、行内、对话框与 AX 标题同源：灰显项的标题带原因，且标题只来自 Kit 的 QueuedActionItem / SendMenuItem。
    func testSendNowTitlesAreOneSourceWithTheReasonWhenDisabled() {
        let disabled = QueuedActionItem(action: .promoteSendNow, enabled: false, disabledReason: SendTimingCopy.directNoSteer)
        XCTAssertEqual(disabled.title, "改为立即发送（可能另起一轮） — 直达暂不支持")
        let enabled = QueuedActionItem(action: .promoteSendNow, enabled: true, disabledReason: nil)
        XCTAssertEqual(enabled.title, "改为立即发送（可能另起一轮）")
        let menu = SendTimingRules.menu(steer: .unavailable, direct: true, nativeSteer: false, nativeSendNow: false).first { $0.choice == .sendNow }
        XCTAssertEqual(menu.map { SendControls.title($0, direct: true) }, "立即发送（可能另起一轮） — 直达暂不支持")
        let on = SendTimingRules.menu(steer: .unavailable, direct: true, nativeSteer: false, nativeSendNow: true).first { $0.choice == .sendNow }
        XCTAssertEqual(on.map { SendControls.title($0, direct: true) }, "立即发送（可能另起一轮）")
    }

    /// 旧 Bridge 绑定目标（快照无 capabilities）：显式 send_now 不被删成普通发送，零请求、保稿。
    func testOldBridgeBoundExplicitSendNowIsNotSilentlySent() async throws {
        let s = try plainSession(caps: nil, bound: true)
        let calls = Box()
        s.sendOverride = { _, _ in calls.bump(); return .stub("old") }
        let ok = await s.submitComposer(threadId: "t1", agent: nil, mode: .sendNow)
        XCTAssertFalse(ok, "explicit send_now must not be erased by old-Bridge fallback")
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(s.draft("t1").text, "立即的插话")
    }

    /// 本机 send_now 的回显：权威 command 未到、进度先到 finished 时仍是原生意图，不消失。
    func testSendNowEchoSurvivesProgressBeforeAuthoritativeCommand() throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSendNow":true}"#, box: Box())
        var t = TranscriptThread()
        t.applyLatest(TranscriptPage(status: "ok", sessionEpoch: "e1", revision: "r", items: []))
        s.transcripts["t1"] = t
        var m = MacSession.Sent(id: UUID(), text: "立即的插话", at: Date(), afterSeq: 0, targetId: "t1", eventKey: "k")
        m.agent = "design"; m.mode = .sendNow; m.sessionEpoch = "e1"
        s.sent = [m]
        s.inflight["k"] = "finished"
        XCTAssertTrue(s.isNativeInsert(m), "local send_now intent must be native before commands arrive")
        XCTAssertEqual(s.pendingEchoes(threadId: "t1").map(\.id), [m.id])
    }

    /// 无效回复的 send_now：中性「结果未知」，不写确定失败，也没有重试。
    func testInvalidResponseIsNeutralUnknownInTheBubble() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSendNow":true}"#, box: Box())
        s.sendOverride = { _, _ in throw MessageActionError.invalidResponse }
        _ = await s.submitComposer(threadId: "t1", agent: "design", mode: .sendNow)
        let m = try XCTUnwrap(s.sent.last)
        XCTAssertNil(m.error, "不写确定失败")
        XCTAssertEqual(s.outgoingStatus(m).phase, .unknown, "invalid response may follow a real terminal write")
        XCTAssertFalse(s.outgoingStatus(m).label.contains("重试"))
    }

    /// 连贯 HTTP：Session → 真实 BridgeClient → 线上 body（传输经 messageTransport 注入的 URLProtocol 桩）。
    func testSendNowComposerReachesTheWireThroughTheRealClient() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSendNow":true}"#, box: Box())
        s.sendOverride = nil
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "test-token")
        s.messageTransport = MacHTTPStub.session(sendReply: #"{"received":true,"eventKey":"api:d:60"}"#)
        let ok = await s.submitComposer(threadId: "t1", agent: "design", mode: .sendNow)
        XCTAssertTrue(ok)
        let send = try XCTUnwrap(MacHTTPStub.requests.first { !$0.path.hasSuffix("/promote") })
        XCTAssertTrue(send.body.contains(#""mode":"send_now""#), send.body)
    }

    /// 连贯 HTTP：排队的直达消息改为立即发送，线上为一次 promote，mode 严格为 send_now。
    func testPromoteSendNowReachesTheWireAsOneStrictModeRequest() async throws {
        let s = try session(capabilities: #"{"steer":false,"nativeSendNow":true}"#, box: Box())
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 9), token: "test-token")
        s.messageTransport = MacHTTPStub.session(promoteReply: #"{"eventKey":"api:d:61","mode":"send_now","state":"queued"}"#)
        await s.promoteQueued(try command("api:d:61"), mode: .sendNow)
        let promotes = MacHTTPStub.requests.filter { $0.path.hasSuffix("/promote") }
        XCTAssertEqual(promotes.count, 1)
        XCTAssertEqual(promotes.first?.body, #"{"mode":"send_now"}"#)
        XCTAssertNil(s.commandNotes["api:d:61"])
    }

    // 只有 mode 缺省（旧 Bridge 普通形状）保持不变：没有 send_now 字样。
    private func plainSession(caps: String?, bound: Bool) throws -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.send-now.mac.plain")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-plain","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        let target = caps.map { #"{"id":"t1","projectName":"p","agentName":"design","status":"idle","capabilities":\#($0)}"# } ?? #"{"id":"t1","projectName":"p","agentName":"design","status":"idle"}"#
        let binding = bound ? #","binding":{"targetId":"t1","projectName":"p","agentName":"design"}"# : ""
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[\#(target)]\#(binding),"history":{"highWater":0,"items":[]}}"#.utf8))
        var d = MacSession.ComposerDraft()
        d.text = "立即的插话"
        s.setDraft(d, for: "t1")
        return s
    }
}

/// 连贯 HTTP 用例的传输桩：每个用例一个只挂本桩的会话（经 messageTransport 注入）；记录请求并按路径回放；非发送/promote 路径返回 404。
private final class MacHTTPStub: URLProtocol, @unchecked Sendable {
    struct Request { let path: String; let body: String }
    nonisolated(unsafe) static var requests: [Request] = []
    nonisolated(unsafe) static var sendReply = Data()
    nonisolated(unsafe) static var promoteReply = Data()

    static func session(sendReply: String? = nil, promoteReply: String? = nil) -> URLSession {
        requests = []
        self.sendReply = Data((sendReply ?? "{}").utf8)
        self.promoteReply = Data((promoteReply ?? "{}").utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MacHTTPStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.requests.append(Request(path: path, body: Self.bodyText(request)))
        let isPromote = path.hasSuffix("/promote")
        let status = isPromote || path.hasSuffix("/v1/messages") ? 200 : 404
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isPromote ? Self.promoteReply : Self.sendReply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func bodyText(_ r: URLRequest) -> String {
        if let b = r.httpBody { return String(decoding: b, as: UTF8.self) }
        guard let s = r.httpBodyStream else { return "" }
        s.open(); defer { s.close() }
        var out = Data(); var buf = [UInt8](repeating: 0, count: 1024)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
        return String(decoding: out, as: UTF8.self)
    }
}
