import AppKit
import SwiftUI
import XCTest
@testable import PalmhelmMac

// 输入法组字（A2-000 / O1-002）：组字中的视图重算不得取消 marked text；外部改写在组字结束后应用；程序化写入不回写 binding。
@MainActor
final class ComposerIMETests: XCTestCase {
    private final class Box {
        var text = ""
    }

    private func makeField(_ box: Box) -> ComposerTextField {
        ComposerTextField(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            height: .constant(24),
            enabled: true,
            scope: "s",
            gate: nil,
            onSubmit: {},
            onSubmitCommand: nil,
            onImages: { _ in })
    }

    private func setup() -> (Box, ComposerTextField.Coordinator, ComposerNSTextView) {
        let box = Box()
        let coord = ComposerTextField.Coordinator(makeField(box))
        let tv = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        tv.isRichText = false
        tv.delegate = coord
        return (box, coord, tv)
    }

    private func compose(_ tv: NSTextView, _ s: String) {
        tv.setMarkedText(s, selectedRange: NSRange(location: s.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// 反馈序列：组字中，无关的视图更新（连续 20 次）不得取消组字，也不改变合成文本与选区。
    func testRepeatedUnrelatedUpdatesKeepTheComposition() {
        let (box, coord, tv) = setup()
        compose(tv, "ni")
        XCTAssertTrue(tv.hasMarkedText())
        for _ in 0..<20 { coord.applyExternal(box.text, to: tv) }
        XCTAssertTrue(tv.hasMarkedText(), "组字不得被视图更新取消")
        XCTAssertEqual(tv.string, "ni")
    }

    /// 组字在行中间：更新不得重置选区或把光标挪回末尾。
    func testMidLineCompositionKeepsItsPlaceAcrossUpdates() {
        let (box, coord, tv) = setup()
        coord.applyExternal("abcd", to: tv)
        box.text = "abcd"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<5 { coord.applyExternal(box.text, to: tv) }
        XCTAssertTrue(tv.hasMarkedText())
        XCTAssertEqual(tv.string, "abzhcd")
        XCTAssertEqual(tv.selectedRange().location, 4, "选区仍在组字末端")
    }

    /// 提交上屏：binding 得到最终文字。
    func testCommitUpdatesTheBinding() {
        let (box, coord, tv) = setup()
        compose(tv, "ni")
        for _ in 0..<3 { coord.applyExternal(box.text, to: tv) }
        tv.insertText("你", replacementRange: tv.markedRange())
        XCTAssertFalse(tv.hasMarkedText())
        XCTAssertEqual(tv.string, "你", "视图里的提交文字")
        XCTAssertEqual(box.text, "你")
    }

    /// 组字中的外部清空（如发送成功后清草稿）：等组字结束后应用，外部改写覆盖组字提交的文字。
    func testExternalClearDuringCompositionAppliesAfterCommit() {
        let (box, coord, tv) = setup()
        box.text = "hello"
        coord.applyExternal("hello", to: tv)
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        compose(tv, "ni")
        box.text = ""
        coord.applyExternal("", to: tv)
        XCTAssertTrue(tv.hasMarkedText(), "外部清空不得打断组字")
        tv.insertText("你", replacementRange: tv.markedRange())
        XCTAssertEqual(tv.string, "", "组字结束后外部清空生效")
        XCTAssertEqual(box.text, "")
    }

    /// 程序化写入不回写 binding（不形成 delegate 回写循环），且之后的普通输入正常同步。
    func testProgrammaticWriteDoesNotEchoAndTypingStillSyncs() {
        let (box, coord, tv) = setup()
        coord.applyExternal("draft", to: tv)
        XCTAssertEqual(tv.string, "draft")
        XCTAssertEqual(box.text, "", "程序化写入不回写 binding")
        tv.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(box.text, "draft!", "用户输入仍同步到 binding")
    }

    /// 清空成功后（非组字）：视图与 binding 一致为空。
    func testClearOutsideCompositionClearsTheView() {
        let (box, coord, tv) = setup()
        coord.applyExternal("sent", to: tv)
        box.text = ""
        coord.applyExternal("", to: tv)
        XCTAssertEqual(tv.string, "")
        XCTAssertFalse(tv.hasMarkedText())
    }
}
