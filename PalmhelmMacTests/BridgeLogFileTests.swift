import Darwin
import XCTest
@testable import PalmhelmMac

// A1-081 片 2：Bridge 持久日志的只读尾部（有界、不跟随链接、属主与权限校验）与 App 事件日志（固定字段、两份轮转）。
final class BridgeLogFileTests: XCTestCase {
    private func makeDataDir() throws -> String {
        let dir = NSTemporaryDirectory() + "bridgelog-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/logs", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    private func writeLog(_ dir: String, _ text: String, mode: mode_t = 0o600) throws {
        let path = BridgeLogFile.path(dataDir: dir)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, mode)
    }

    func testAbsentLogIsReportedAsAbsent() throws {
        let dir = try makeDataDir()
        XCTAssertEqual(BridgeLogFile.tail(dataDir: dir), .absent)
    }

    func testOnlyLastFiveHundredLinesAreReturned() throws {
        let dir = try makeDataDir()
        try writeLog(dir, (0..<600).map { "line-\($0)" }.joined(separator: "\n") + "\n")
        guard case .lines(let lines) = BridgeLogFile.tail(dataDir: dir) else { return XCTFail("expected lines") }
        XCTAssertEqual(lines.count, 500)
        XCTAssertEqual(lines.first, "line-100")
        XCTAssertEqual(lines.last, "line-599")
    }

    func testLargeFileIsReadFromTheTailAndDropsThePartialFirstLine() throws {
        let dir = try makeDataDir()
        let filler = String(repeating: "f", count: 200)
        let body = (0..<3000).map { "L\($0)-\(filler)" }.joined(separator: "\n") + "\n"
        try writeLog(dir, body)
        guard case .lines(let lines) = BridgeLogFile.tail(dataDir: dir) else { return XCTFail("expected lines") }
        XCTAssertLessThanOrEqual(lines.count, 500)
        XCTAssertEqual(lines.last, "L2999-\(filler)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("L0-") }, "bytes before the window must not be read")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("L") && $0.hasSuffix(filler) }, "no partial line from the cut point")
    }

    func testSymlinkedLogIsRefused() throws {
        let dir = try makeDataDir()
        let victim = NSTemporaryDirectory() + "victim-\(UUID().uuidString)"
        try Data("secret\n".utf8).write(to: URL(fileURLWithPath: victim))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: victim) }
        try FileManager.default.createSymbolicLink(atPath: BridgeLogFile.path(dataDir: dir), withDestinationPath: victim)
        XCTAssertEqual(BridgeLogFile.tail(dataDir: dir), .unsafe("symlink"))
    }

    /// 父目录 logs 是指向外部目录的链接：不返回外部内容（末端文件检查不足以覆盖这一点）。
    func testParentLogsSymlinkIsRefusedAndExternalContentNotShown() throws {
        let dir = try makeDataDir()
        let outside = NSTemporaryDirectory() + "outside-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(atPath: outside) }
        try Data("SYNTHETIC_PRIVATE_NOT_A_BRIDGE_LOG\n".utf8).write(to: URL(fileURLWithPath: outside + "/bridge.log"))
        chmod(outside + "/bridge.log", 0o600)
        try FileManager.default.removeItem(atPath: dir + "/logs")
        try FileManager.default.createSymbolicLink(atPath: dir + "/logs", withDestinationPath: outside)
        let result = BridgeLogFile.tail(dataDir: dir)
        XCTAssertNotEqual(result, .lines(["SYNTHETIC_PRIVATE_NOT_A_BRIDGE_LOG"]))
        guard case .unsafe = result else { return XCTFail("expected unsafe, got \(result)") }
    }

    /// FIFO 没有写端时打开不能阻塞（主线程上的读取不得卡住）。
    func testFIFOLogIsRefusedWithoutBlocking() throws {
        let dir = try makeDataDir()
        XCTAssertEqual(mkfifo(BridgeLogFile.path(dataDir: dir), 0o600), 0)
        let done = expectation(description: "tail returns")
        var result: BridgeLogFile.Result?
        DispatchQueue.global().async {
            result = BridgeLogFile.tail(dataDir: dir)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(result, .unsafe("not_regular"))
    }

    /// 轮转后按路径重新打开，读到的是新的当前文件（而不是旧的已移开的文件）。
    func testRotationReadsTheNewCurrentFile() throws {
        let dir = try makeDataDir()
        try writeLog(dir, "old-line\n")
        let path = BridgeLogFile.path(dataDir: dir)
        XCTAssertEqual(rename(path, path + ".1"), 0)
        try writeLog(dir, "new-line\n")
        XCTAssertEqual(BridgeLogFile.tail(dataDir: dir), .lines(["new-line"]))
    }

    func testWrongModeIsRefused() throws {
        let dir = try makeDataDir()
        try writeLog(dir, "x\n", mode: 0o644)
        XCTAssertEqual(BridgeLogFile.tail(dataDir: dir), .unsafe("owner_or_mode"))
    }
}

final class AppEventLogTests: XCTestCase {
    func testNilDirectoryWritesNothing() {
        let log = AppEventLog(directory: nil)
        log.mark(.launch) // 不应有任何文件副作用，也不应崩溃
    }

    func testRecordsAreFixedFieldsAndTwoFilesAreKept() throws {
        let dir = NSTemporaryDirectory() + "appevents-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let log = AppEventLog(directory: dir, maxBytes: 1000)
        for _ in 0..<60 { log.mark(.childLaunch) }
        log.mark(.keychainStalled, .stalled)
        let current = try String(contentsOfFile: dir + "/app-events.log", encoding: .utf8)
        let previous = try String(contentsOfFile: dir + "/app-events.log.1", encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/app-events.log.2"))
        XCTAssertLessThanOrEqual(current.utf8.count, 1000)
        XCTAssertLessThanOrEqual(previous.utf8.count, 1000)
        XCTAssertTrue(current.contains("\"stage\":\"keychainStalled\",\"result\":\"stalled\""))
        for line in (current + previous).split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("{\"ts\":\"") && line.contains("\"ms\":"), "unexpected line: \(line)")
            XCTAssertFalse(line.contains("/") || line.contains("token") || line.contains("secret"))
        }
    }
}

final class AppEventLogHardeningTests: XCTestCase {
    private func makeDir() -> String {
        let dir = NSTemporaryDirectory() + "appevents-h-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// 轮转失败（.1 是目录，无法移开）：放弃本次写入，当前文件不越过上限。
    func testFailedRotationDoesNotGrowPastTheCap() throws {
        let dir = makeDir()
        let log = AppEventLog(directory: dir, maxBytes: 600)
        log.mark(.launch)
        try FileManager.default.createDirectory(atPath: dir + "/app-events.log.1", withIntermediateDirectories: true)
        for _ in 0..<20 { log.mark(.childLaunch) }
        let size = (try FileManager.default.attributesOfItem(atPath: dir + "/app-events.log")[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(size, 600)
    }

    /// 最后一段是链接：不写到链接指向的外部目录。
    func testSymlinkedDirectoryIsNotFollowed() throws {
        let outside = NSTemporaryDirectory() + "appevents-out-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: outside) }
        let link = NSTemporaryDirectory() + "appevents-link-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: link) }
        AppEventLog(directory: link).mark(.launch)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside), [])
    }

    /// FIFO 占用了 app-events.log：mark 立即返回，不阻塞调用线程。
    func testFIFOEventLogDoesNotBlock() throws {
        let dir = makeDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(dir + "/app-events.log", 0o600), 0)
        let done = expectation(description: "mark returns")
        DispatchQueue.global().async {
            AppEventLog(directory: dir).mark(.launch)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}
