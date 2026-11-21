import Foundation
import XCTest
@testable import PalmhelmMac

// 子进程 PATH：系统目录在前，用户安装目录（含 ~/.homebrew/bin，gh 的常见位置）追加在后，不重复。
final class EngineSettingsChildPathTests: XCTestCase {
    func testUserInstallDirectoriesAreAppendedAfterSystemDirectories() {
        let home = NSHomeDirectory()
        let path = EngineSettings.childPath(base: "/usr/bin:/bin:/usr/sbin:/sbin")
        let parts = path.split(separator: ":").map(String.init)
        XCTAssertEqual(Array(parts.prefix(4)), ["/usr/bin", "/bin", "/usr/sbin", "/sbin"], "系统目录保持原有优先级")
        XCTAssertTrue(parts.contains("\(home)/.homebrew/bin"), "gh 常见的用户安装目录必须在子进程 PATH 中")
        XCTAssertTrue(parts.contains("\(home)/.local/bin"))
        XCTAssertLessThan(parts.firstIndex(of: "/usr/bin")!, parts.firstIndex(of: "\(home)/.homebrew/bin")!)
    }

    func testDirectoriesAlreadyPresentAreNotDuplicated() {
        let home = NSHomeDirectory()
        let base = "/usr/bin:\(home)/.homebrew/bin"
        let parts = EngineSettings.childPath(base: base).split(separator: ":").map(String.init)
        XCTAssertEqual(parts.filter { $0 == "\(home)/.homebrew/bin" }.count, 1)
    }
}
