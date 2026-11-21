import XCTest
import PalmhelmKit
@testable import PalmhelmMac

@MainActor final class O310MacTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }
    private func session(caps: Bool, connected: Bool = true, paused: Bool = false, count: Counter) throws -> MacSession {
        XCTAssertTrue(RuntimeEnvironment.isTestHost, "no real preferences or Keychain")
        let s = MacSession()
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data("{\"id\":\"o310-native\",\"name\":\"test\",\"permission\":\"control\",\"paused\":\(paused)}".utf8))
        let c = caps ? #","capabilities":{"steer":true}"# : ""
        s.state = try JSONDecoder().decode(BridgeState.self, from: Data("{\"occupancy\":\"busy\",\"targets\":[{\"id\":\"t1\",\"projectName\":\"p\",\"agentName\":\"design\",\"status\":\"working\"\(c)}],\"history\":{\"highWater\":0,\"items\":[]}}".utf8))
        s.link = connected ? .connected : .offline("cached endpoint")
        s.sendOverride = { _, _ in count.bump(); return try JSONDecoder().decode(MessageReceipt.self, from: Data(#"{"received":true,"eventKey":"o310"}"#.utf8)) }
        var draft = MacSession.ComposerDraft(); draft.text = "use: supplement"
        s.setDraft(draft, for: "t1")
        return s
    }
    func testWorkingDirectOldBridgeSendsOrdinarilyOnCommandReturn() async throws {
        let count = Counter(); let s = try session(caps: false, count: count)
        let note = await s.commandReturn(threadId: "t1", agent: "design")
        print("O310_MAC_OLD_DIRECT",count.count,note ?? "nil")
        XCTAssertEqual(count.count,1); XCTAssertNil(note)
    }
    func testOfflineCommandReturnMustNotSend() async throws {
        let count = Counter(); let s = try session(caps: true, connected: false, count: count)
        _ = await s.commandReturn(threadId: "t1", agent: nil)
        print("O310_MAC_OFFLINE",count.count)
        XCTAssertEqual(count.count,0)
    }
    func testPausedCommandReturnMustNotSend() async throws {
        let count = Counter(); let s = try session(caps: true, paused: true, count: count)
        _ = await s.commandReturn(threadId: "t1", agent: nil)
        print("O310_MAC_PAUSED",count.count)
        XCTAssertEqual(count.count,0)
    }
    func testNewProtocolDirectWorkingSendsOrdinarilyOnCommandReturn() async throws {
        let count = Counter(); let s = try session(caps: true,count: count)
        let note = await s.commandReturn(threadId:"t1",agent:"design")
        XCTAssertEqual(count.count,1);XCTAssertNil(note)
    }
}
