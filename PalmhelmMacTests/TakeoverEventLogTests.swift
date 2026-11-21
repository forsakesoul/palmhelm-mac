import Foundation
import XCTest
@testable import PalmhelmMac

// O1-128：接管事件写入 app-events.log 的固定阶段 takeover。只写阶段名、结果与相对启动的毫秒数；不写 pid、路径或数据目录。
@MainActor
final class TakeoverEventLogTests: XCTestCase {
    private func makeLogDir() throws -> String {
        let dir = NSTemporaryDirectory() + "palmhelm-takeover-events-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func takeoverLines(in dir: String) -> [String] {
        let text = (try? String(contentsOfFile: dir + "/app-events.log", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.contains("\"stage\":\"takeover\"") }
    }

    func testAdoptionWritesTakeoverOkWithoutPidOrPath() async throws {
        let rig = try TakeoverRig()
        let dir = try makeLogDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        rig.engine.appEvents = AppEventLog(directory: dir)
        try rig.seedRunningBridge()
        await rig.engine.takeOverRunningBridge()
        let lines = takeoverLines(in: dir)
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("\"result\":\"ok\""))
        XCTAssertFalse(line.contains("pid"), "不写 pid 字段")
        XCTAssertFalse(line.contains("/"), "不写路径")
        XCTAssertFalse(line.contains(rig.dataDir), "不写数据目录")
    }

    func testIdentityMismatchWritesTakeoverFailedAndNeverAdopts() async throws {
        let rig = try TakeoverRig()
        let dir = try makeLogDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        rig.engine.appEvents = AppEventLog(directory: dir)
        try rig.seedRunningBridge(pid: 4242, startMicros: 12_345)
        rig.probe.table[4242] = BridgeProcessSnapshot(pid: 4242, startMicros: 99_999, executable: canonicalPath(rig.binary))
        await rig.engine.takeOverRunningBridge()
        XCTAssertFalse(rig.engine.childRunning)
        let lines = takeoverLines(in: dir)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(try XCTUnwrap(lines.first).contains("\"result\":\"failed\""))
    }

    func testNoRecordWritesNoTakeoverLine() async throws {
        let rig = try TakeoverRig()
        let dir = try makeLogDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        rig.engine.appEvents = AppEventLog(directory: dir)
        await rig.engine.takeOverRunningBridge()
        XCTAssertTrue(takeoverLines(in: dir).isEmpty)
    }
}
