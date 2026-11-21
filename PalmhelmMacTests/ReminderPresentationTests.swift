import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// t18 h3（A1-001 R1–R3）：提醒页计数与标读批次用最终呈现集；身份变化结束本次展示；豁免只给本次由未读变已读的条目。
@MainActor
final class ReminderPresentationTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    private func state(_ id: String = "b1", blocked: String? = nil) -> BridgeState {
        let b = blocked.map { #","currentBlocked":\#($0),"currentBlockedFresh":true"# } ?? ""
        return decode(#"{"bridge":{"id":"\#(id)"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}\#(b)}"#)
    }
    private func session() -> MacSession {
        let s = MacSession()
        s.streamDisabled = true
        s.applyStateSnapshot(state())
        s.link = .connected
        s.reminderLedger = ReminderLedger()
        return s
    }
    private var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }
    private func receipt(_ n: Int, key: String = "k1") -> HistoryItem {
        HistoryItem(seq: n, uuid: "rj-\(n)", text: "rejected:x", kind: "text", replyTo: key, t: nowMs)
    }
    private func failure() -> MacSession.Sent {
        MacSession.Sent(id: UUID(), text: "x", at: Date(), afterSeq: 0, targetId: nil, eventKey: "k1", error: "failed", draft: "draft", attachmentPaths: [])
    }

    /// R1：同一次失败发送 + 两条指向它的回执，只呈现一行；未读数与标读批次按这一行计，不按三个别名计。
    func testUnreadCountMatchesThePresentedRowNotTheRawAliases() {
        let s = session()
        s.sent = [failure()]
        s.history = [receipt(1), receipt(2)]
        XCTAssertEqual(s.inboxAlerts.count, 1)
        XCTAssertEqual(s.unreadReminderCount, 1, "badge counts the one visible unread row, not three aliases")
        s.openReminders()
        XCTAssertEqual(s.unreadReminderCount, 0)
        XCTAssertEqual(s.inboxAlerts.count, 1)
    }

    /// R2：身份变化在共同入口结束本次展示；视图仍开着时由 onChange 按新身份重开，旧身份的已读批次不会复活。
    func testIdentitySwitchEndsPresentationAndReturningDoesNotReviveReadBatch() {
        let s = session()
        s.history = [receipt(1)]
        s.openReminders()
        XCTAssertEqual(s.inboxAlerts.count, 1)
        s.applyStateSnapshot(state("b2"))
        XCTAssertNil(s.reminderPresentation, "presentation ends on identity change without another onAppear")
        s.applyStateSnapshot(state("b1"))
        XCTAssertTrue(s.inboxAlerts.isEmpty, "returning to b1 cannot revive its already-read batch")
    }

    /// R2：同一身份的重复打开不重建批次，页内后到的项仍是未读。
    func testRepeatedOpenKeepsBatchAndLateItemsStayUnread() {
        let s = session()
        s.history = [receipt(1)]
        s.openReminders()
        s.history.append(receipt(2, key: "k2"))
        s.openReminders()
        XCTAssertEqual(s.unreadReminderCount, 1)
    }

    /// R3：打开前已读、当前仍阻塞的条目不因本次打开获得豁免；变成非当前（离线、未核对）后按已读隐藏。
    func testAlreadyReadCurrentDoesNotGetANewExemptionByReopening() {
        let s = session()
        let id = "nblocked2:c1"
        let r = HistoryItem(seq: 1, uuid: id, text: "x", kind: "text", replyTo: "e", target: .init(id: "t1", projectName: "P"), t: nowMs)
        s.applyStateSnapshot(state(blocked: #"[{"targetId":"t1","eventKey":"e","blockedSince":\#(nowMs)}]"#))
        s.history = [r]
        s.reminderLedger.markSeen(bridgeId: "b1", ids: [id], retained: [id])
        XCTAssertEqual(s.reminderStatus(r), .current(eventKey: "e"))
        s.openReminders()
        s.link = .offline("x")
        XCTAssertEqual(s.reminderStatus(r), .unverified)
        XCTAssertTrue(s.blockedReminders.isEmpty, "already-read current was not turned unread→read by this opening")
    }

    /// R3：普通未读项本次打开后变已读，豁免本次展示；之后不再按同一批次复活。
    func testUnreadItemIsExemptOnlyForThisPresentation() {
        let s = session()
        s.history = [receipt(1)]
        s.openReminders()
        XCTAssertEqual(s.inboxAlerts.map(\.id), ["rj:rj-1"])
        s.closeReminders()
        s.openReminders()
        XCTAssertTrue(s.inboxAlerts.isEmpty)
    }

    /// R4（Session 层）：展示期间可见集变空，展示仍是打开的（宿主条件靠它保持）；关闭后展示被结束。
    func testPresentationStaysOpenWhenVisibleSetEmptiesAndCloseEndsIt() {
        let s = session()
        let f = failure()
        s.sent = [f]
        s.openReminders()
        XCTAssertEqual(s.inboxAlerts.count, 1)
        s.markRestored(f.id)
        XCTAssertTrue(s.inboxAlerts.isEmpty)
        XCTAssertNotNil(s.reminderPresentation, "the open presentation is not ended by an empty visible set")
        s.closeReminders()
        XCTAssertNil(s.reminderPresentation)
    }
}
