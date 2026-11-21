import AppKit
import SwiftUI
import XCTest
@testable import PalmhelmMac

// A1-000 R1/R2：组字的编辑对象隔离（换草稿不串）与发送准入（组字中只确认候选，不发送）。
@MainActor
final class ComposerIMEScopeTests: XCTestCase {
    private final class Box { var text: String; init(_ t: String = "") { text = t } }

    private func field(_ box: Box, scope: String, enabled: Bool = true, gate: ComposerCompositionGate? = nil,
                       onSubmit: @escaping () -> Void = {}, onSubmitCommand: (() -> Void)? = nil) -> ComposerTextField {
        ComposerTextField(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            height: .constant(24), enabled: enabled, scope: scope, gate: gate,
            onSubmit: onSubmit, onSubmitCommand: onSubmitCommand, onImages: { _ in })
    }

    private func makeTextView(_ coord: ComposerTextField.Coordinator) -> ComposerNSTextView {
        let tv = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        tv.isRichText = false
        tv.delegate = coord
        return tv
    }

    private func compose(_ tv: NSTextView, _ s: String) {
        tv.setMarkedText(s, selectedRange: NSRange(location: s.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func key(_ code: UInt16, shift: Bool = false, command: Bool = false) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if command { flags.insert(.command) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
    }

    /// 在 scope A 里组字，再把控件重绑到 B（A→B）：返回 (B 的 box, 视图)。
    private func rebind(aText: String, composing: String, bText: String, bScope: String = "B", bEnabled: Bool = true) -> (a: Box, b: Box, tv: ComposerNSTextView) {
        let a = Box(aText), b = Box(bText)
        let coord = ComposerTextField.Coordinator(field(a, scope: "A"))
        let tv = makeTextView(coord)
        coord.sync(field(a, scope: "A"), to: tv)
        tv.setSelectedRange(NSRange(location: (aText as NSString).length, length: 0))
        compose(tv, composing)
        XCTAssertTrue(tv.hasMarkedText())
        coord.sync(field(b, scope: bScope, enabled: bEnabled), to: tv)
        return (a, b, tv)
    }

    // MARK: R1 编辑对象隔离

    /// 反例 1：A、B 的 binding 都是空，旧组字不能留给 B。
    func testRebindingBetweenTwoEmptyDraftsDiscardsTheOldComposition() {
        let r = rebind(aText: "", composing: "ni", bText: "")
        XCTAssertFalse(r.tv.hasMarkedText(), "旧组字作废")
        XCTAssertEqual(r.tv.string, "")
        XCTAssertEqual(r.b.text, "", "B 没有收到 A 的组字")
    }

    func testRebindingBetweenEqualNonEmptyDraftsDoesNotLeakTheComposition() {
        let r = rebind(aText: "hello", composing: "ni", bText: "hello")
        XCTAssertFalse(r.tv.hasMarkedText())
        XCTAssertEqual(r.tv.string, "hello")
        XCTAssertEqual(r.b.text, "hello")
    }

    func testRebindingToADifferentDraftShowsThatDraftOnly() {
        let r = rebind(aText: "hello", composing: "ni", bText: "world")
        XCTAssertEqual(r.tv.string, "world")
        XCTAssertEqual(r.b.text, "world", "B 的草稿原样")
        XCTAssertEqual(r.a.text, "hello", "A 的草稿也没被改写")
    }

    /// 反例 2：先换到 B 再禁用——禁用结束组字的回调不能把 A 的前缀与组字写进 B。
    func testRebindThenDisableKeepsTheOtherDraftIntact() {
        let r = rebind(aText: "A-prefix", composing: "ni", bText: "B-original", bEnabled: false)
        XCTAssertFalse(r.tv.hasMarkedText())
        XCTAssertEqual(r.tv.string, "B-original")
        XCTAssertEqual(r.b.text, "B-original")
    }

    /// 同一目标、不同连接身份（scope 不同）同样隔离。
    func testSameTargetOnAnotherConnectionIsADifferentScope() {
        let a = Box(), b = Box("saved")
        let coord = ComposerTextField.Coordinator(field(a, scope: "bridge1/t1"))
        let tv = makeTextView(coord)
        coord.sync(field(a, scope: "bridge1/t1"), to: tv)
        compose(tv, "ni")
        coord.sync(field(b, scope: "bridge2/t1"), to: tv)
        XCTAssertFalse(tv.hasMarkedText())
        XCTAssertEqual(b.text, "saved")
        XCTAssertEqual(tv.string, "saved")
    }

    /// 旧 scope 的待应用外部改写不会带到新 scope。
    func testPendingExternalFromTheOldScopeDoesNotSurvive() {
        let a = Box("hello"), b = Box("bb")
        let coord = ComposerTextField.Coordinator(field(a, scope: "A"))
        let tv = makeTextView(coord)
        coord.sync(field(a, scope: "A"), to: tv)
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        compose(tv, "ni")
        a.text = ""                                           // A 在组字中被外部清空 → pending
        coord.sync(field(a, scope: "A"), to: tv)
        XCTAssertNotNil(coord.pendingExternal)
        coord.sync(field(b, scope: "B"), to: tv)
        XCTAssertNil(coord.pendingExternal)
        XCTAssertEqual(tv.string, "bb")
    }

    /// 正控：同 scope 的 20 次普通重算保持组字；换 scope 之后新草稿里的新组字同样能保持。
    func testSameScopeUpdatesStillKeepTheCompositionAndANewScopeCanComposeAgain() {
        let a = Box()
        let coord = ComposerTextField.Coordinator(field(a, scope: "A"))
        let tv = makeTextView(coord)
        coord.sync(field(a, scope: "A"), to: tv)
        compose(tv, "ni")
        for _ in 0..<20 { coord.sync(field(a, scope: "A"), to: tv) }
        XCTAssertTrue(tv.hasMarkedText())
        XCTAssertEqual(tv.string, "ni")
        let b = Box("x")
        coord.sync(field(b, scope: "B"), to: tv)
        compose(tv, "zh")
        for _ in 0..<5 { coord.sync(field(b, scope: "B"), to: tv) }
        XCTAssertTrue(tv.hasMarkedText(), "新 scope 里重新开始的组字同样被保持")
    }

    /// 正控：同 scope、非组字时，外部清空（发送后）与外部替换（撤回恢复）仍然生效，停用/启用不丢内容。
    func testSameScopeExternalClearAndRestoreStillApply() {
        let a = Box("sent text")
        let coord = ComposerTextField.Coordinator(field(a, scope: "A"))
        let tv = makeTextView(coord)
        coord.sync(field(a, scope: "A"), to: tv)
        XCTAssertEqual(tv.string, "sent text")
        a.text = ""
        coord.sync(field(a, scope: "A", enabled: false), to: tv)          // 发送中：清空 + 冻结
        XCTAssertEqual(tv.string, "")
        a.text = "restored draft"
        coord.sync(field(a, scope: "A", enabled: true), to: tv)           // 撤回/失败后恢复
        XCTAssertEqual(tv.string, "restored draft")
    }

    // MARK: R2 发送准入（O1 裁决：组字中发送一律无操作，确认候选完全交给输入法）

    /// 组字中点发送（按钮/菜单共用 admitsSend）：每一次都是无操作——不放行、不结束组字、不改组字内容、不改草稿；
    /// 没有“下一次放行”标记。输入法自己确认候选（提交）之后，第一次操作才放行，草稿里是确认后的文字。
    func testSendDuringCompositionIsAlwaysANoOpUntilTheInputMethodConfirms() {
        let box = Box("hello ")
        let gate = ComposerCompositionGate()
        let coord = ComposerTextField.Coordinator(field(box, scope: "A", gate: gate))
        let tv = makeTextView(coord)
        gate.attach(tv)
        coord.sync(field(box, scope: "A", gate: gate), to: tv)
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        compose(tv, "ni")
        XCTAssertTrue(gate.isComposing)
        for attempt in 1...3 {
            XCTAssertFalse(gate.admitsSend(), "组字中第 \(attempt) 次：不发送")
            XCTAssertTrue(tv.hasMarkedText(), "组字没有被结束")
            XCTAssertEqual(tv.string, "hello ni", "组字内容没有被改动")
            XCTAssertEqual(box.text, "hello ", "草稿没有被改动（不会把拼音当成最终文字）")
        }
        tv.insertText("你", replacementRange: tv.markedRange())      // 输入法确认候选
        XCTAssertFalse(gate.isComposing)
        XCTAssertEqual(box.text, "hello 你", "草稿含输入法确认后的文字")
        XCTAssertTrue(gate.admitsSend(), "确认之后的第一次操作就放行（不需要多按一次）")
    }

    func testSendAdmissionPassesWhenNotComposing() {
        let box = Box("plain")
        let gate = ComposerCompositionGate()
        let coord = ComposerTextField.Coordinator(field(box, scope: "A", gate: gate))
        let tv = makeTextView(coord)
        gate.attach(tv)
        XCTAssertTrue(gate.admitsSend())
        XCTAssertEqual(box.text, "plain")
    }

    /// 发送入口的完整形态：组字中各入口零发送；确认后一次操作发送一次，内容是确认后的文字，之后清空照常。
    func testEverySendEntryIsSilentWhileComposingAndSendsOnceAfterConfirmation() {
        let box = Box("hello ")
        let gate = ComposerCompositionGate()
        var sent: [String] = []
        let coord = ComposerTextField.Coordinator(field(box, scope: "A", gate: gate))
        let tv = makeTextView(coord)
        gate.attach(tv)
        coord.sync(field(box, scope: "A", gate: gate), to: tv)
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        // 与 MainWindow.submit 相同的入口形态：先问 gate，放行才取草稿快照发送并清空。
        func entry() { guard gate.admitsSend() else { return }; sent.append(box.text); box.text = ""; coord.sync(field(box, scope: "A", gate: gate), to: tv) }
        compose(tv, "ni")
        entry(); entry(); entry()                                   // 按钮 / 时机菜单 / deadline 菜单
        XCTAssertEqual(sent, [], "组字中各入口零发送")
        XCTAssertEqual(tv.string, "hello ni")
        tv.insertText("你", replacementRange: tv.markedRange())
        entry()
        XCTAssertEqual(sent, ["hello 你"], "确认后一次操作发送一次，内容是确认后的文字")
        XCTAssertEqual(tv.string, "", "发送后清空照常")
    }

    /// Return / ⌘↩ 在组字中不触发发送（确认候选）；确认后 Return 发送一次，⌘↩ 走插话，Shift+Return 换行不发送。
    func testReturnKeysDoNotSubmitWhileComposingAndWorkAfterwards() {
        var submits = 0, commands = 0
        let box = Box()
        let coord = ComposerTextField.Coordinator(field(box, scope: "A", onSubmit: { submits += 1 }, onSubmitCommand: { commands += 1 }))
        let tv = makeTextView(coord)
        coord.sync(field(box, scope: "A", onSubmit: { submits += 1 }, onSubmitCommand: { commands += 1 }), to: tv)
        compose(tv, "ni")
        tv.keyDown(with: key(36))
        tv.keyDown(with: key(36, command: true))
        XCTAssertEqual(submits, 0, "组字中 Return 不发送")
        XCTAssertEqual(commands, 0, "组字中 ⌘↩ 不触发插话")
        tv.unmarkText()
        tv.keyDown(with: key(36, shift: true))
        XCTAssertEqual(submits, 0, "Shift+Return 换行不发送")
        tv.keyDown(with: key(36))
        XCTAssertEqual(submits, 1, "确认后 Return 发送一次")
        tv.keyDown(with: key(36, command: true))
        XCTAssertEqual(commands, 1)
    }
}
