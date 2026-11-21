import XCTest
import PalmhelmKit
@testable import PalmhelmMac

/// App 内语言切换（Mac 侧）：垫片取选定语言的 lproj、缓存文案按当前语言重算、显示日期用选定语言。
/// DisplayLanguage 是进程级，XCTest 串行跑；每个用例结束都回到“跟随系统”。
@MainActor
final class LanguageSwitchMacTests: XCTestCase {
    override func setUp() async throws {
        DisplayLanguage.shared.attach(defaults: AppDefaults.standard)
        DisplayLanguage.shared.select(.system)
    }
    override func tearDown() async throws { DisplayLanguage.shared.select(.system) }

    /// 与 A2 的 Foundation 探针同一结论：locale 参数不能替代 bundle，必须按选定语言取对 lproj。
    func testShimUsesSelectedLprojNotLocaleParameter() {
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(String(localized: "在线", locale: Locale(identifier: "zh-Hans")), "Online", "选 English：传 zh-Hans locale 也不改资源语言")
        DisplayLanguage.shared.select(.zhHans)
        XCTAssertEqual(String(localized: "在线", locale: Locale(identifier: "en")), "在线", "选简体中文：传 en locale 也不改资源语言")
    }

    func testCachedTextFollowsLanguageWithoutRebuilding() {
        let note = LText(String(localized: "在线"))
        let link = MacSession.Link.offline(LText(String(localized: "在线")))
        DisplayLanguage.shared.select(.zhHans)
        XCTAssertEqual(note.text, "在线")
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(note.text, "Online", "同一个缓存值，切语言后显示新语言")
        XCTAssertEqual(ConnectionPhase.offline("x").label, "Offline: x")
        XCTAssertEqual(ConnectionPhase.from(engineStatus: .running, portFileReady: true, credentialsLoaded: true, secretsLoaded: true, link: link).label, "Offline: Online")
    }

    func testStringLiteralLTextIsShownAsIs() {
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(LText(String(localized: "在线")).text, "Online", "String(localized:) 构造的走 Catalog")
        let literal: LText = "在线"
        XCTAssertEqual(literal.text, "在线", "字面量 LText 原样显示（测试/最终文本）")
    }

    func testSettingsLabelsUseSelfNamesAndTranslatedFollowSystem() {
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(LanguageSection.label(.system), "Follow system")
        XCTAssertEqual(LanguageSection.label(.zhHans), "简体中文")
        XCTAssertEqual(LanguageSection.label(.en), "English")
        DisplayLanguage.shared.select(.zhHans)
        XCTAssertEqual(LanguageSection.label(.system), "跟随系统")
    }

    func testDisplayDateUsesSelectedLanguageButKeepsInstant() {
        let d = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14/15，随时区
        DisplayLanguage.shared.select(.en)
        XCTAssertTrue(d.shown(date: .abbreviated).contains("Nov"))
        DisplayLanguage.shared.select(.zhHans)
        XCTAssertTrue(d.shown(date: .abbreviated).contains("11月"))
        XCTAssertEqual(d.timeIntervalSince1970, 1_700_000_000, "只改显示，不改时刻")
    }

    func testSwitchingLanguageDoesNotTouchSessionState() {
        let s = MacSession()
        s.link = .offline("x")
        s.commandNotes["k"] = LText(String(localized: "在线"))
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(s.link, .offline("x"))
        XCTAssertEqual(s.commandNotes["k"]?.text, "Online")
        XCTAssertEqual(s.commandNotes.count, 1, "不清字典、不伪造新错误来刷语言")
    }

    /// A1-000 M-F3：菜单栏计数行整句走 Catalog（拼接中文 String 会让 Text 按 verbatim 显示）。
    func testMenuBarCountLineIsLocalizedAsAWhole() {
        DisplayLanguage.shared.select(.zhHans)
        XCTAssertEqual(MenuBarCountLine.text(pending: 2, running: 1, unresolved: 3, pendingSync: true), "待答 2 · 在途 1 · 结果未知 3 · 状态待同步")
        XCTAssertEqual(MenuBarCountLine.text(pending: 0, running: 0, unresolved: 0, pendingSync: false), "待答 0 · 在途 0")
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(MenuBarCountLine.text(pending: 2, running: 1, unresolved: 3, pendingSync: true), "Needs you 2 · In flight 1 · result unknown 3 · status pending sync")
        XCTAssertEqual(MenuBarCountLine.text(pending: 0, running: 0, unresolved: 0, pendingSync: false), "Needs you 0 · In flight 0")
    }

    /// A1-000 M-F1：Session/视图缓存的提示是延迟文案，同一个值切语言后显示新语言；不改业务状态。
    func testReturnedAndStoredNotesRetranslateOnSwitch() async throws {
        let s = MacSession()
        DisplayLanguage.shared.select(.zhHans)
        let restore = try XCTUnwrap(s.restoreUnattributed(UUID()))
        let renameOpt = await s.renameThisDevice("")
        let rename = try XCTUnwrap(renameOpt)
        let blockedOpt = await s.commandReturn(threadId: "t1", agent: nil)
        let blocked = try XCTUnwrap(blockedOpt)
        let missing = URL(fileURLWithPath: "/nonexistent/palmhelm-lang-test.png")
        var list: [ComposerAttachment] = []
        let attach = try XCTUnwrap(ComposerAttachments.add([.file(missing)], to: &list, editable: true))
        let submit = MacSession.RequestSubmit.kept(LText(String(localized: "没能重新取到问题，草稿已保留，请稍后重试")))
        XCTAssertEqual(restore.text, "这条发送已经恢复过，或没有可恢复的内容")
        XCTAssertEqual(blocked.text, "还没有配对")
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(restore.text, "This send was already restored, or there's nothing to restore")
        XCTAssertEqual(rename.text, "The name needs 1 to 32 characters on one line")
        XCTAssertEqual(blocked.text, "Not paired yet")
        XCTAssertEqual(attach.text, "File doesn't exist or can't be read: palmhelm-lang-test.png")
        guard case .kept(let why) = submit else { return XCTFail() }
        XCTAssertEqual(why.text, "Couldn't reload the questions. The draft is kept. Try again later.")
        XCTAssertTrue(list.isEmpty, "只改显示，不动草稿/附件列表")
        XCTAssertEqual(s.commands.count, 0)
    }

    /// A1-000 M-F2（Mac 自建显示 style）：系统非公历 + 24 小时制在真实输出里保留；统计按显式时区，不因显示语言/日历改变时刻。
    func testMacDisplayStylesKeepSystemCalendarAndHourCycle() {
        let utc = TimeZone(identifier: "UTC")!
        let epoch = 1_700_000_000_000 // 2023-11-14 22:13:20 UTC
        let buddhist = Locale(identifier: "en_US@calendar=buddhist;hours=h23")
        let line = KitL10n.$locale.withValue(buddhist) { UsageModel.timesLine(generatedT: epoch, asOfT: epoch, tz: utc) }
        XCTAssertTrue(line.contains("2566"), "价格日期用系统佛历：\(line)")
        XCTAssertTrue(line.contains("22:13"), "24 小时制保留，时刻不变：\(line)")
        XCTAssertFalse(line.contains("PM"), line)
        let gregorian = KitL10n.$locale.withValue(Locale(identifier: "en_US")) { UsageModel.timesLine(generatedT: epoch, asOfT: epoch, tz: utc) }
        XCTAssertTrue(gregorian.contains("2023") && gregorian.contains("10:13"), "公历 + 12 小时制对照：\(gregorian)")
    }

    // MARK: A2-002 R2/R3 的 Mac 同构

    private func bindingSession(binding: String = "A") -> MacSession {
        let s = MacSession()
        s.state = try! JSONDecoder().decode(BridgeState.self, from: Data("{\"occupancy\":\"free\",\"binding\":{\"targetId\":\"\(binding)\",\"projectName\":\"P\",\"agentName\":\"claude\"},\"targets\":[{\"id\":\"A\",\"projectName\":\"A\",\"online\":true},{\"id\":\"B\",\"projectName\":\"B\",\"online\":true}],\"history\":{\"highWater\":0,\"items\":[]}}".utf8))
        s.link = .connected
        return s
    }

    /// R2：真实发送失败后，同一条 Sent 的 error 在切语言后按当前语言解释（存事实，不存译文；describe 是纯函数）。
    func testSentErrorIsExplainedAtDisplayTime() async throws {
        let s = bindingSession(binding: "A")
        s.device = try? JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d","name":"mac","paused":false}"#.utf8))
        s.sendOverride = { _, _ in throw URLError(.timedOut) }
        s.stateOverride = { [unowned s] in await MainActor.run { s.state ?? BridgeState.empty } }
        s.selectTarget("A")
        DisplayLanguage.shared.select(.zhHans)
        var d = MacSession.ComposerDraft(); d.text = "你好"
        s.setDraft(d, for: "A")
        let ok = await s.submitComposer(threadId: "A", agent: nil)
        XCTAssertFalse(ok)
        let err = try XCTUnwrap(s.sent.first?.error)
        XCTAssertEqual(err.text, "无法连接")
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(err.text, "Can't connect", "同一条失败记录，切 English 即变英文")
        XCTAssertEqual(s.sent.count, 1)
        XCTAssertEqual(s.sent.first?.draft, "你好", "只改显示，不动失败记录与草稿")
    }

    /// R3：Mac 自产标签原先是固定中文（不进 Catalog），英文界面半英半中。
    func testOwnLabelsFollowSelectedLanguage() {
        DisplayLanguage.shared.select(.zhHans)
        XCTAssertEqual(UsageModel.freshnessText("stale"), "价格表较旧")
        XCTAssertEqual(StatuslineSourceCommand.message(for: "usage"), "命令参数不对")
        XCTAssertEqual(MacSession.hookNote(HookInstallResult(ok: false, error: "settings_locked"), install: true), "配置正在被修改，请稍后重试")
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(UsageModel.freshnessText("stale"), "Price table is older")
        XCTAssertEqual(StatuslineSourceCommand.message(for: "usage"), "Invalid command arguments")
        XCTAssertEqual(MacSession.hookNote(HookInstallResult(ok: false, error: "settings_locked"), install: true), "The config is being modified. Try again shortly.")
    }

    /// R3 附带的功能缺陷：数据状态事实用“比较译文”去重“扫描有缺口”，英文下比不上、同一句出现两次。
    func testDataStatusFactsDoNotDuplicateScanGapInEnglish() throws {
        let json = #"{"window":"24h","timeZone":"Asia/Shanghai","generatedT":1,"partial":true,"reasons":[],"quality":{},"bucketMs":3600000,"buckets":[],"recent":{"today":{"from":"a","to":"a","byModel":{}},"d7":{"from":"a","to":"a","byModel":{}},"d30":{"from":"a","to":"a","byModel":{}}},"heatmap":{"days":[],"activity":[]},"prices":{},"agents":{"claude":{"candidates":0,"parsed":0,"complete":0},"codex":{"candidates":0,"parsed":0,"complete":0}}}"#
        let u = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        let t = try JSONDecoder().decode(UsageEstimateTotals.self, from: Data(#"{"tokens":{"input":1,"output":0,"cacheRead":0,"cacheWrite":0},"costUsd":null,"hasUnpriced":false,"partial":true,"priceStale":false}"#.utf8))
        for lang in [AppLanguageChoice.zhHans, .en] {
            DisplayLanguage.shared.select(lang)
            let facts = UsageModel.dataStatusFacts(u, totals: t, offline: nil, failure: nil)
            let gap = lang == .en ? "Scan has gaps" : "扫描有缺口"
            XCTAssertFalse(facts.contains(gap), "\(lang)：缺口由标题表达，事实列表里不重复：\(facts)")
        }
    }

    /// A2-003 R2-a 的 Mac 同构：成功提示（lastDecisionNote）在真实提交流程里发出后，切语言即按新语言显示；服务器 hint 原文不翻译。
    func testSuccessNoteFollowsLanguageAfterItWasPosted() async throws {
        let s = MacSession()
        s.link = .connected
        s.device = try JSONDecoder().decode(DeviceInfo.self, from: Data(#"{"id":"d","name":"mac","paused":false,"permission":"control"}"#.utf8))
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let a = ApprovalView(id: "r1", status: "pending", targetLabel: "P", attribution: "exact", toolName: "Bash", summary: "x", createdT: now, expiresT: now + 600_000)
        s.approvals["r1"] = a
        s.pendingCallOverride = { _ in try JSONDecoder().decode(DecisionResponse.self, from: Data(#"{"status":"decided"}"#.utf8)) }
        DisplayLanguage.shared.select(.zhHans)
        let ok = await s.release(a)
        XCTAssertTrue(ok)
        let note = try XCTUnwrap(s.lastDecisionNote)
        XCTAssertEqual(note.text, "已交回终端")
        DisplayLanguage.shared.select(.en)
        XCTAssertEqual(s.lastDecisionNote?.text, "Returned to terminal", "同一条已发出的成功提示，切 English 即变英文")
        XCTAssertEqual(s.approvals["r1"]?.status, "decided", "只改显示，不重做业务动作")
    }

    /// A1-001 M-F4：拼接不依赖 Catalog 首尾空白；英文实际输出两段都在、不黏连，也覆盖无价格日期分支与朗读分隔符。
    func testJoinedTextsDoNotDependOnCatalogEdgeWhitespace() {
        let utc = TimeZone(identifier: "UTC")!
        let epoch = 1_700_000_000_000
        DisplayLanguage.shared.select(.en)
        let en = UsageModel.timesLine(generatedT: epoch, asOfT: epoch, tz: utc)
        XCTAssertTrue(en.hasPrefix("Response generated "), en)
        XCTAssertTrue(en.contains(" · Price "), "两段之间有空格，不黏连：\(en)")
        XCTAssertFalse(en.contains("· Price") && !en.contains(" · Price"), en)
        let enOnly = UsageModel.timesLine(generatedT: epoch, asOfT: nil, tz: utc)
        XCTAssertTrue(enOnly.hasPrefix("Response generated ") && !enOnly.contains("Price"), enOnly)
        XCTAssertEqual(DisplayList.join(["A", "B", "C"]), "A, B, C")
        XCTAssertEqual(UsageModel.legacyCost((usd: 1, hasUnpriced: true)), "≈$1.00 · includes unpriced usage")
        DisplayLanguage.shared.select(.zhHans)
        let zh = UsageModel.timesLine(generatedT: epoch, asOfT: epoch, tz: utc)
        XCTAssertTrue(zh.hasPrefix("响应生成 ") && zh.contains(" · 价格 "), zh)
        XCTAssertEqual(DisplayList.join(["甲", "乙"]), "甲，乙")
        XCTAssertEqual(UsageModel.legacyCost((usd: 1, hasUnpriced: true)), "≈$1.00 · 含未报价部分")
    }
}
