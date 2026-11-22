import Foundation
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// #96（Mac 镜像）：owner 指令（切换到等）的回显靠系统回执 ack:<eventKey> 收敛；普通排队消息的显示不变。
@MainActor
final class SwitchEchoMacTests: XCTestCase {
    private func echo(_ key: String, text: String = "切换到 p claude") -> MacSession.Sent {
        var m = MacSession.Sent(id: UUID(), text: text, at: Date(), afterSeq: 0, targetId: "t1")
        m.eventKey = key
        return m
    }

    private func ack(_ key: String, _ text: String) throws -> HistoryItem {
        try JSONDecoder().decode(HistoryItem.self, from: Data(#"{"seq":5,"uuid":"ack:\#(key)","text":"\#(text)","kind":"text","replyTo":"\#(key)"}"#.utf8))
    }

    func testSwitchEchoResolvesWhenTheSwitchReceiptArrives() throws {
        let s = MacSession()
        let m = echo("k1")
        s.sent = [m]
        XCTAssertNotEqual(s.outgoingStatus(m).phase, .done, "without the receipt the echo is unresolved")
        s.history = [try ack("k1", "switched:t1@3")]
        XCTAssertEqual(s.outgoingStatus(m).phase, .done)
        XCTAssertNotEqual(s.outgoingStatus(m).label, "排队中 · 本轮结束后发送")
    }

    func testRejectedSwitchShowsRejected() throws {
        let s = MacSession()
        let m = echo("k3")
        s.sent = [m]
        s.history = [try ack("k3", "rejected:no_match")]
        XCTAssertEqual(s.outgoingStatus(m).phase, .rejected)
    }

    func testQueuedMessageKeepsItsQueuedDisplay() throws {
        let s = MacSession()
        let m = echo("k2", text: "普通消息")
        s.sent = [m]
        s.history = [try ack("k2", "queued:task:abc")]
        XCTAssertEqual(s.outgoingStatus(m).phase, .queued)
        XCTAssertEqual(s.outgoingStatus(m).label, "排队中 · 本轮结束后发送")
    }

    func testReceiptForAnotherEchoDoesNotResolve() throws {
        let s = MacSession()
        let m = echo("k4")
        s.sent = [m]
        s.history = [try ack("other", "switched:t1@9")]
        XCTAssertNotEqual(s.outgoingStatus(m).phase, .done)
    }
}
