import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// O1-364 ④（Mac）：这台 Mac 改名成功即时更新偏好与气泡头；失败或非法名字不改任何本地状态。
@MainActor
final class DeviceRenameMacTests: XCTestCase {
    private let suite = UserDefaults(suiteName: "palmhelm.device-rename.tests")!
    override func tearDown() {
        suite.removePersistentDomain(forName: "palmhelm.device-rename.tests")
        super.tearDown()
    }

    private func device(_ name: String) throws -> DeviceInfo {
        try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-d1","name":"\#(name)","paused":false,"permission":"control"}"#.utf8))
    }

    func testRenameUpdatesPreferenceDeviceAndBubbleHeader() async throws {
        let s = MacSession()
        s.preferences = suite
        s.device = try device("Mac")
        s.commands["k1"] = try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"k1","inboxSeq":1,"text":"x","truncated":false,"origin":"api","device":{"id":"mac-d1","name":"Mac"},"state":"queued"}"#.utf8))
        s.renameOverride = { name in try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-d1","name":"\#(name)","paused":false,"permission":"control"}"#.utf8)) }
        let message = await s.renameThisDevice("  书房 \n Mac  ")
        XCTAssertNil(message)
        XCTAssertEqual(s.deviceName, "书房 Mac")
        XCTAssertEqual(s.device?.name, "书房 Mac")
        XCTAssertEqual(s.commands["k1"]?.device?.name, "书房 Mac")
        XCTAssertEqual(suite.string(forKey: MacSession.deviceNameKey), "书房 Mac", "新名字跨启动保留")
    }

    func testInvalidOrFailedRenameChangesNothing() async throws {
        let s = MacSession()
        s.preferences = suite
        s.device = try device("Mac")
        final class Counter: @unchecked Sendable { var n = 0 }
        let calls = Counter()
        s.renameOverride = { _ in calls.n += 1; throw BridgeError.http(status: 400) }
        let tooLong = await s.renameThisDevice(String(repeating: "长", count: 33))
        XCTAssertNotNil(tooLong)
        XCTAssertEqual(calls.n, 0, "超长名字本地拒绝")
        let rejected = await s.renameThisDevice("好名字")
        XCTAssertEqual(rejected, "Bridge 不接受这个名字，请换一个")
        XCTAssertEqual(s.deviceName, "Mac")
        XCTAssertEqual(s.device?.name, "Mac")
    }

    /// O1-364 R4（Mac）：请求挂起期间换了连接（会话代次推进）→ 迟到结果不写任何本地状态。
    func testLateRenameAfterConnectionChangeWritesNothing() async throws {
        actor Gate {
            private var cont: CheckedContinuation<Void, Never>?
            private(set) var waiting = false
            func wait() async { waiting = true; await withCheckedContinuation { cont = $0 } }
            func open() { cont?.resume(); cont = nil }
        }
        let s = MacSession()
        s.preferences = suite
        s.device = try device("Mac")
        let gate = Gate()
        s.renameOverride = { name in
            await gate.wait()
            return try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-d1","name":"\#(name)","paused":false,"permission":"control"}"#.utf8))
        }
        let pending = Task { await s.renameThisDevice("迟到的名字") }
        while await !gate.waiting { await Task.yield() }
        s.stopStream() // 换了连接：会话代次推进
        await gate.open()
        let message = await pending.value
        XCTAssertNotNil(message)
        XCTAssertEqual(s.device?.name, "Mac")
        XCTAssertEqual(s.deviceName, "Mac")
    }
}
