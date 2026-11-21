import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// O1-327（Mac）：撤回成功后的回填——空输入框直接回填（无署名前缀），有内容则只提示、由用户选择替换；附件缺失不替换；失败不回填。
@MainActor
final class WithdrawRestoreMacTests: XCTestCase {
    private func session(withdrawFails: Bool = false) -> MacSession {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.withdraw-restore")!
        s.device = try! JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-w","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.sendOverride = { _, _ in MessageReceipt.stub("k1") }
        s.commandOverride = { _, _ in if withdrawFails { throw MessageActionError.notWithdrawable(state: nil) } }
        return s
    }
    private func queuedCommand(text: String) throws -> ApiCommand {
        let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
        return try JSONDecoder().decode(ApiCommand.self, from: Data(#"{"key":"k1","inboxSeq":1,"text":"\#(escaped)","truncated":false,"origin":"api","state":"queued","lane":"ordinary","targetId":"t1"}"#.utf8))
    }

    func testEmptyDraftIsFilledWithOriginalTextWithoutAttribution() async throws {
        let s = session()
        _ = await s.send("原文一句", draft: "原文一句")
        XCTAssertEqual(s.draft("t1").text, "", "发送后输入框已清空")
        await s.withdrawQueued(try queuedCommand(text: "[来自 Palmhelm · 我的 iPhone]\n原文一句"))
        XCTAssertEqual(s.draft("t1").text, "原文一句", "空输入框直接回填原文，不带署名前缀")
        XCTAssertNil(s.withdrawnOffer("t1"))
    }

    func testNonEmptyDraftIsNotOverwrittenUntilUserReplaces() async throws {
        let s = session()
        _ = await s.send("原文二句", draft: "原文二句")
        var d = MacSession.ComposerDraft(); d.text = "新的草稿"; s.setDraft(d, for: "t1")
        await s.withdrawQueued(try queuedCommand(text: "[来自 Palmhelm · 设备]\n原文二句"))
        XCTAssertEqual(s.draft("t1").text, "新的草稿", "有内容时不覆盖")
        XCTAssertEqual(s.withdrawnOffer("t1")?.text, "原文二句", "提示保留，等待用户选择")
        XCTAssertTrue(s.replaceWithWithdrawnOffer("t1"))
        XCTAssertEqual(s.draft("t1").text, "原文二句", "用户选择替换后放回原文")
        XCTAssertNil(s.withdrawnOffer("t1"))
    }

    func testDismissKeepsDraftAndClearsOffer() async throws {
        let s = session()
        _ = await s.send("原文三句", draft: "原文三句")
        var d = MacSession.ComposerDraft(); d.text = "保留的草稿"; s.setDraft(d, for: "t1")
        await s.withdrawQueued(try queuedCommand(text: "原文三句"))
        s.dismissWithdrawnOffer("t1")
        XCTAssertEqual(s.draft("t1").text, "保留的草稿")
        XCTAssertNil(s.withdrawnOffer("t1"))
    }

    /// R1：没有本机记录时不回填、不剥离任何东西（用户自己写的同形首行不能被误删）。
    func testWithoutLocalRecordNothingIsOfferedOrStripped() async throws {
        let s = session() // 没有本机发送记录（例如重启过）
        await s.withdrawQueued(try queuedCommand(text: "[来自 Palmhelm · 我的 Mac]\n保留我"))
        XCTAssertEqual(s.draft("t1").text, "", "没有可信来源：不回填")
        XCTAssertNil(s.withdrawnOffer("t1"))
    }

    /// S1：没有传输（没有凭据或客户端）→ 请求没有发出，明确失败，不回填。
    func testWithoutTransportWithdrawFailsExplicitlyAndOffersNothing() async throws {
        let s = MacSession()
        s.preferences = UserDefaults(suiteName: "palmhelm.withdraw-restore")!
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"mac-w","name":"mac","paused":false,"permission":"control"}"#.utf8))
        s.link = .connected
        s.sendOverride = { _, _ in MessageReceipt.stub("k1") }
        _ = await s.send("原文五句", draft: "原文五句")
        await s.withdrawQueued(try queuedCommand(text: "原文五句"))
        XCTAssertNil(s.withdrawnOffer("t1"), "没有传输：不能当成撤回成功")
        XCTAssertEqual(s.draft("t1").text, "", "不回填")
        XCTAssertEqual(s.commandNotes["k1"]?.text, "未连接 Bridge，操作没有发出")
    }

    /// R3：撤回替身（commandOverride）已返回成功，但刷新（stateOverride）还没结束时换了连接 → 不回填（代次在最后一个 await 之后复核）。
    func testConnectionChangeDuringRefreshAfterWithdrawSuccessOffersNothing() async throws {
        let gate = Gate()
        let s = session()
        s.setCredentialsForTest(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t")
        s.stateOverride = { await gate.wait(); return try JSONDecoder().decode(BridgeState.self, from: Data(#"{"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#.utf8)) }
        _ = await s.send("原文六句", draft: "原文六句")
        let task = Task { await s.withdrawQueued(try! queuedCommand(text: "原文六句")) }
        await gate.awaitEntered() // 撤回已成功，刷新挂起
        s.stopStream()            // 换连接 / 停机：代次变化
        await gate.release()
        await task.value
        XCTAssertNil(s.withdrawnOffer("t1"), "刷新期间代次变化：不回填")
        XCTAssertEqual(s.draft("t1").text, "")
    }

    /// R2：停止流（换连接 / 忘记配对）清掉残留的撤回原文提示。
    func testStopStreamClearsWithdrawnOffers() async throws {
        let s = session()
        _ = await s.send("原文七句", draft: "原文七句")
        var d = MacSession.ComposerDraft(); d.text = "有内容"; s.setDraft(d, for: "t1")
        await s.withdrawQueued(try queuedCommand(text: "原文七句"))
        XCTAssertNotNil(s.withdrawnOffer("t1"))
        s.stopStream()
        XCTAssertNil(s.withdrawnOffer("t1"), "换连接后不复活旧提示")
    }

    func testFailedWithdrawLeavesDraftAlone() async throws {
        let s = session(withdrawFails: true)
        _ = await s.send("原文四句", draft: "原文四句")
        await s.withdrawQueued(try queuedCommand(text: "原文四句"))
        XCTAssertEqual(s.draft("t1").text, "", "服务端没确认撤回，不回填")
        XCTAssertNil(s.withdrawnOffer("t1"))
    }

    func testMissingAttachmentKeepsOfferAndDoesNotReplace() async throws {
        let s = session()
        // 真实附件：发送时带一张 PNG，撤回前删掉它（附件在撤回后已不可读）。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palmhelm-o327-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        _ = await s.send("带附件", draft: "带附件", attachmentPaths: [png.path], attachmentSources: [.userReference])
        try FileManager.default.removeItem(at: png)
        s.setDraft({ var d = MacSession.ComposerDraft(); d.text = "现有"; return d }(), for: "t1")
        await s.withdrawQueued(try queuedCommand(text: "带附件"))
        XCTAssertEqual(s.draft("t1").text, "现有", "附件缺失：不覆盖现有内容")
        XCTAssertNotNil(s.withdrawnOffer("t1"), "附件缺失：提示保留")
        XCTAssertFalse(s.replaceWithWithdrawnOffer("t1"))
        XCTAssertEqual(s.draft("t1").text, "现有")
    }

    actor Gate {
        private var entered = false
        private var open = false
        func wait() async { entered = true; while !open { try? await Task.sleep(for: .milliseconds(2)) } }
        func awaitEntered() async { while !entered { try? await Task.sleep(for: .milliseconds(2)) } }
        func release() { open = true }
    }
}
