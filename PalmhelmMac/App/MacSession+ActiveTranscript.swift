import Foundation
import PalmhelmKit

// #88 S4：Mac 接线：与 iOS 同一套准入与采纳规则（Kit 共用）。
// #88 S3/S4 修复：会话记录的全部读取（最新页、更早页、激活节拍、续读）共用的准入与采纳（规则在 Kit：
// TranscriptReadGate / TranscriptActivation / TranscriptReadCadence / TranscriptExpansion / TranscriptThread）。
// 后台、失焦或非当前线程只标记 dirty，前台再补拉一次；旧连接或旧激活的结果不写入当前状态。
/// 读取簿记（#102，与 iOS 同）：最新页在途标记与同设备同目标的请求计数。只存在 MacSession 的观察之外，写入不触发观察。
struct TranscriptRequestBook: Equatable {
    var latestInFlight = false
    var activeRequests = 0
}

extension MacSession {
    func requestBook(_ id: String) -> TranscriptRequestBook { transcriptRequestBook[id] ?? TranscriptRequestBook() }

    /// 簿记为默认值时删除条目，避免线程释放后残留。
    func withRequestBook(_ id: String, _ change: (inout TranscriptRequestBook) -> Void) {
        var b = requestBook(id)
        change(&b)
        transcriptRequestBook[id] = b == TranscriptRequestBook() ? nil : b
    }

    func canStartTranscriptRequest(_ id: String) -> Bool { requestBook(id).activeRequests < TranscriptThread.maxActiveRequests }

    /// 闸门判定用的线程副本：簿记并入临时副本，不写回 transcripts。
    func transcriptForGate(_ id: String) -> TranscriptThread? {
        guard var t = transcripts[id] else { return nil }
        let b = requestBook(id)
        t.latestInFlight = b.latestInFlight
        t.activeRequests = b.activeRequests
        return t
    }

    /// 只在线程真的变化时写回：内容未变的刷新不写 transcripts，也就不触发观察。
    func updateTranscript(_ id: String, _ change: (inout TranscriptThread) -> Void) {
        guard var t = transcripts[id] else { return }
        change(&t)
        if t != transcripts[id] { transcripts[id] = t }
    }
}

extension MacSession {
    /// 内存上限（主要状态）：已加载的条目与全部展开的正文合计。超出时先淘汰非激活线程，再淘汰最旧的展开。
    static let transcriptMemoryCap = 4 << 20

    // MARK: 激活

    /// 设置激活线程：视图前台可见时传入线程 ID；切走、后台、失焦或连接换代时传 nil（立即停止，之前的结果不再采纳）。
    func setTranscriptActive(_ id: String?) {
        if let id, id == activeTranscriptThread, activeTranscriptTask != nil { return } // 同一线程重复设置：不重启节拍
        activeTranscriptTask?.cancel()
        activeTranscriptTask = nil
        transcriptCadence.cancel()
        activeTranscriptThread = nil
        transcriptExpansions = [:] // 展开状态只在本次浏览内保留
        guard let id else {
            transcriptActivation.deactivate()
            return
        }
        let token = transcriptActivation.activate(id)
        activeTranscriptThread = id
        touchTranscript(id)
        enforceTranscriptMemoryCap()
        activeTranscriptTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.activeTranscriptTick(token)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// 一次检查：有待补拉（dirty）时立即补一次；否则节拍到了才读取最新页。只有仍是发起时的激活才采纳结果。
    /// 测试直接调用它，不依赖计时器。
    func activeTranscriptTick(_ token: TranscriptActivation.Token, now: Date = Date()) async {
        guard transcriptActivation.accepts(token) else { return }
        if transcripts[token.targetId]?.dirty == true {
            transcripts[token.targetId]?.dirty = false
            _ = await refreshLatest(token.targetId)
            return
        }
        guard transcriptCadence.begin(now: now) else { return }
        let outcome = await refreshLatest(token.targetId)
        transcriptCadence.finish(now: now, success: outcome != false)
    }

    /// 骨架门禁：只有当前激活已确认过（首个应答或错误已到达）时才显示内容；切换目标后先显示骨架（#88 S4 修复）。
    func transcriptSettled(_ id: String) -> Bool {
        guard let current = transcriptActivation.current, current.targetId == id else { return false }
        return transcriptConfirmedToken == current
    }

    /// 骨架是否盖住线程内容：最近一次确认的就是这个线程且已有内容时（失焦 / 非活跃 / 重新聚焦后新激活尚未确认），继续显示已有内容；
    /// 切到别的线程（A→B，或 A→B→A）仍按 #88 S4 先显示骨架直到首个应答。transcriptSettled 的语义不变（淡入、knownIds、打字显现仍用它）。
    /// transcriptConfirmedToken 只在确认时被替换、不随停用清空，所以它的 targetId 就是“最近一次确认的线程”。
    func transcriptShowsSkeleton(_ id: String) -> Bool {
        TranscriptPresentation.showsSkeleton(targetId: id, connected: link == .connected, current: transcriptActivation.current, confirmed: transcriptConfirmedToken, status: transcripts[id]?.status)
    }

    // MARK: 最新页与更早页

    /// 会话记录变化、连接就绪、打开线程时使用：准入后补拉一次最新页（不在前台可见时只标记 dirty）。
    func loadTranscriptLatest(_ id: String) async {
        _ = await refreshLatest(id)
        await transcriptRefillIfDirty(id)
        await continueInitialFill(id)
    }

    /// 首屏补齐（#111）：首页字节预算被大段工具输出占满时只回少量条目甚至空页；条目不足且还有更早历史时继续取下一页，
    /// 不等用户操作。是否继续、何时停（上限 4 页、游标不前进、窗口离开最新、快照作废）由 Kit 的 wantsInitialFill 决定；
    /// 这里只核对仍是当前激活线程，请求照走 loadTranscriptOlder（同一套准入、单飞与快照守卫）。失败不重试，交还给手动加载。
    func continueInitialFill(_ id: String) async {
        guard transcripts[id]?.wantsInitialFill == true, transcriptActivation.current?.targetId == id else { return }
        await loadTranscriptOlder(id)
    }

    /// 最新页的唯一入口（节拍与其它读取共用）：准入 → 请求（带线程持有的 ETag）→ 采纳。
    /// 返回 nil 表示没有发起（延后或无法发起），true / false 为本次结果。
    @discardableResult
    func refreshLatest(_ id: String) async -> Bool? {
        guard let client = searchClient() else { return nil }
        switch TranscriptReadGate.decide(targetId: id, connection: connectionEpoch, activation: transcriptActivation, thread: transcriptForGate(id), receipt: receiptRequest(for: id)) {
        case .deferred:
            markTranscriptDirty(id)
            return nil
        case .start(let ticket):
            if transcripts[id] == nil { transcripts[id] = TranscriptThread() }
            withRequestBook(id) { $0.latestInFlight = true; $0.activeRequests += 1 }
            let result: Result<TranscriptFetch, Error>
            do {
                result = .success(try await client.transcriptConditional(targetId: id, before: nil, limit: BridgeAPI.transcriptPageLimit, ifNoneMatch: ticket.etag, receipt: ticket.receipt))
            } catch {
                result = .failure(error)
            }
            return settleLatest(ticket, result)
        }
    }

    /// 首页读取携带的后补声明：本线程当前原生代次内、尚未关联、带 eventKey 的本机发送（规范化与上限在 Kit）。
    /// 仍保留显示的原生回显（现有 keepsNativeEcho 分类）优先占名额，普通发送补满，避免已终态的普通发送把它挤出声明。
    func receiptRequest(for id: String) -> TranscriptReceiptRequest? {
        let t = transcripts[id]
        let mine = sent.filter { $0.targetId == id && $0.ownerKind == nil && $0.error == nil }
        // 服务端补行（重启后没有本机 Sent 的 command）：只取当前最新窗实际显示的未关联行；Bridge 用 command 的原生身份核验是否属于本代（#110）。
        let linked = t?.linkedEventKeys ?? []
        let supplement = TranscriptReceiptRequest.supplementKeys(commandRows: threadTail(threadId: id).commandRows, targetId: id, linked: linked)
        return TranscriptReceiptRequest.select(epoch: t?.sessionEpoch, linked: linked, sent: mine.map { ($0.eventKey, $0.sessionEpoch) },
                                               preferred: Set(mine.filter { keepsNativeEcho($0) }.compactMap(\.eventKey)), supplementKeys: supplement)
    }

    /// 最新页的采纳：只写当前连接与当前激活的结果；写入线程的同时写入它的 ETag（只有被采纳的页才有）。
    private func settleLatest(_ ticket: TranscriptReadGate.Ticket, _ result: Result<TranscriptFetch, Error>) -> Bool {
        let id = ticket.targetId
        guard ticket.connection == connectionEpoch else { return true } // 旧连接：计数已由 abandon 归还，结果不写入
        withRequestBook(id) { $0.latestInFlight = false; $0.activeRequests -= 1 }
        guard TranscriptReadGate.accepts(ticket, connection: connectionEpoch, activation: transcriptActivation, snapshot: transcripts[id]?.snapshot) else {
            markTranscriptDirty(id) // 激活已变或快照失效：不采纳；前台可见时补拉
            return true
        }
        if transcriptConfirmedToken != ticket.activation { transcriptConfirmedToken = ticket.activation }
        switch result {
        case .success(.notModified):
            // 304 只对应当前已采纳的那一页：核验通过即确认已同步，清除陈旧标记（F4）；否则补拉
            if let tag = ticket.etag, transcripts[id]?.validator(for: ticket.receipt) == tag { updateTranscript(id) { $0.markFresh() } } else { markTranscriptDirty(id) }
        case .success(.page(let page, let etag)):
            // 后补关联与页正文由 Kit 一并采纳（见 applyLatest）；ETag 绑定发起时的声明形状。
            updateTranscript(id) { _ = $0.applyLatest(page, snapshot: ticket.snapshot, etag: etag, shape: ticket.receipt) }
            pruneExpansions(for: id)
            touchTranscript(id)
        case .failure(let error):
            // 已有内容时保留并标记陈旧（可重试）；没有内容时显示失败
            if transcripts[id]?.items.isEmpty ?? true { transcripts[id]?.status = .failed(error.localizedDescription) } else { transcripts[id]?.markStale() }
            return false
        }
        enforceTranscriptMemoryCap()
        return true
    }

    /// 更早页：只在当前激活线程、线程仍是发起时的快照、连接未换时采纳。
    func loadTranscriptOlder(_ id: String) async {
        if transcriptActivation.current?.targetId == id, transcripts[id]?.hasRowsAboveWindow == true { // 窗口之上已加载：本地展开，不发请求
            transcripts[id]?.showOlderRows()
            return
        }
        guard let client = searchClient(), let thread = transcripts[id], thread.status == .ok, thread.hasMore, !thread.loadingOlder,
              canStartTranscriptRequest(id), let before = thread.nextBefore, let current = transcriptActivation.current, current.targetId == id else { return }
        let gen = connectionEpoch
        let snap = thread.snapshot
        transcripts[id]?.loadingOlder = true
        withRequestBook(id) { $0.activeRequests += 1 }
        let result: Result<TranscriptPage, Error>
        do {
            result = .success(try await client.transcript(targetId: id, before: before, limit: BridgeAPI.transcriptPageLimit))
        } catch {
            result = .failure(error)
        }
        guard gen == connectionEpoch else { return }
        withRequestBook(id) { $0.activeRequests -= 1 }
        transcripts[id]?.loadingOlder = false // 同连接的请求归还：不论激活或快照是否仍有效（正文可能已被淘汰）
        guard transcriptActivation.accepts(current), transcripts[id]?.snapshot == snap else { return }
        touchTranscript(id)
        switch result {
        case .success(let page):
            transcripts[id]?.applyOlder(page, snapshot: snap, cursor: before)
        case .failure(let error):
            transcripts[id]?.olderFailed(snapshot: snap)
            // 游标失效：只有仍是发起时的快照才作废并重拉；旧快照的 410 只结束自己（A1-123 F2-R）
            if case BridgeError.http(let s) = error, s == 410 { invalidateTranscript(id); markTranscriptDirty(id) }
        }
        enforceTranscriptMemoryCap()
        await transcriptRefillIfDirty(id)
        if case .success = result { await continueInitialFill(id) }
    }

    /// 有待补拉时补拉一次最新页（只消费一次标记；仍不能读则重新标记）。
    func transcriptRefillIfDirty(_ id: String) async {
        guard transcripts[id]?.dirty == true else { return }
        transcripts[id]?.dirty = false
        _ = await refreshLatest(id)
    }

    private func markTranscriptDirty(_ id: String) {
        transcripts[id, default: TranscriptThread()].dirty = true
    }

    // MARK: 按条续读（长回复的展开）

    /// 「展开全文」：从首页截断的正文开始；去掉末尾的省略号，与服务端签发令牌时的前缀一致。
    func beginTranscriptExpansion(_ threadId: String, _ item: TranscriptItem) {
        let key = Self.expansionKey(threadId, item.id)
        guard transcriptExpansions[key] == nil else { return }
        transcriptExpansionSeq += 1
        let base = item.truncated && item.text.hasSuffix("…") ? String(item.text.dropLast()) : item.text
        transcriptExpansions[key] = TranscriptExpansion(itemId: item.id, sessionEpoch: transcripts[threadId]?.sessionEpoch ?? "",
                                                        text: base, continuation: item.truncated ? item.continuation : nil, seq: transcriptExpansionSeq, displaySpans: item.displaySpans)
    }

    /// 收起：删除该条目的展开实例（旧票据与迟到应答随之失效）；重新展开即新建实例（F3）。
    func collapseTranscriptText(_ threadId: String, _ itemId: String) {
        transcriptExpansions[Self.expansionKey(threadId, itemId)] = nil
    }

    /// 「继续加载后文」：与最新页、更早页共用准入（前台可见的当前线程、同设备同目标两槽）；不满足时既不建展开也不发请求（F2）。
    /// 单飞；应答必须自证身份；活动或连接变化后迟到的应答丢弃。
    func loadMoreTranscriptText(_ threadId: String, _ itemId: String) async {
        guard let client = searchClient(), let current = transcriptActivation.current, current.targetId == threadId,
              canStartTranscriptRequest(threadId) else { return }
        let key = Self.expansionKey(threadId, itemId)
        if transcriptExpansions[key] == nil {
            guard let item = transcripts[threadId]?.items.first(where: { $0.id == itemId }) else { return }
            beginTranscriptExpansion(threadId, item)
        }
        guard let ticket = transcriptExpansions[key]?.beginLoad() else { return }
        let gen = connectionEpoch
        withRequestBook(threadId) { $0.activeRequests += 1 }
        let result: Result<TranscriptItemSegment, Error>
        do {
            result = .success(try await client.transcriptItem(targetId: threadId, itemId: itemId, continuation: ticket.continuation))
        } catch {
            result = .failure(error)
        }
        guard gen == connectionEpoch else { return } // 旧连接：计数已由 abandon 归还
        withRequestBook(threadId) { $0.activeRequests -= 1 }
        // 请求期间激活已变：展开实例已随之清空（迟到应答无处可落），这里不再写入
        guard transcriptActivation.accepts(current), transcriptExpansions[key] != nil else { return }
        // 会话已换（sessionEpoch 变化）：这个展开属于旧会话，整条丢弃
        guard transcripts[threadId]?.sessionEpoch == transcriptExpansions[key]?.sessionEpoch else { transcriptExpansions[key] = nil; return }
        switch result {
        case .success(let segment):
            _ = transcriptExpansions[key]?.complete(ticket, with: segment)
        case .failure(let error):
            var reset = false
            if case BridgeError.http(let status) = error, status == 410 { reset = true }
            transcriptExpansions[key]?.fail(ticket, reset: reset)
        }
        enforceTranscriptMemoryCap()
    }

    /// 「回到最新」：裁剪过较新内容则整体恢复为最新页；否则只把渲染窗口移回最新处。
    func jumpToLatestTranscript(_ id: String) async {
        guard transcripts[id]?.hasNewer == true else {
            transcripts[id]?.showLatestRows()
            return
        }
        transcripts[id]?.resumeFromLatest()
        await loadTranscriptLatest(id)
    }

    func touchTranscript(_ id: String) {
        transcriptClock += 1
        transcriptLastUsed[id] = transcriptClock
    }

    /// 最新页采纳后：展开若已不属于当前版本的条目（令牌变化、条目消失），整条丢弃。
    func pruneExpansions(for threadId: String) {
        let items = transcripts[threadId]?.items ?? []
        for (key, exp) in transcriptExpansions where key.hasPrefix(threadId + "|") {
            if let item = items.first(where: { $0.id == exp.itemId }), exp.belongs(to: item) { continue }
            transcriptExpansions[key] = nil
        }
    }

    /// 全局硬上限（4 MiB，覆盖所有线程的已加载条目与全部展开）。淘汰顺序（F1）：
    /// 1 非当前线程整线程按 LRU 丢弃（跳过在途）；2 当前线程最旧的、窗口之外的段（保留游标以便重取）；
    /// 3 窗口之外的展开；4 窗口之后的较新内容（裁掉，用户「回到最新」时按最新页恢复）；5 窗口内的展开。
    /// 可见行（渲染窗口）本身不被淘汰。
    func enforceTranscriptMemoryCap() {
        func total() -> Int {
            transcripts.values.reduce(0) { $0 + $1.footprintBytes } + transcriptExpansions.values.reduce(0) { $0 + $1.bytes }
        }
        let active = transcriptActivation.current?.targetId
        while total() > Self.transcriptMemoryCap {
            // 非当前线程（含在途）：按 LRU 释放正文。在途的只作废票据与正文，请求计数由票据归还时扣减（R1）。
            let inactive = transcripts.filter { $0.key != active && $0.value.footprintBytes > 0 }
            if let victim = inactive.min(by: { (transcriptLastUsed[$0.key] ?? 0) < (transcriptLastUsed[$1.key] ?? 0) }) {
                let id = victim.key
                if requestBook(id).latestInFlight || victim.value.loadingOlder || requestBook(id).activeRequests > 0 {
                    transcripts[id]?.evictBody()
                } else {
                    dropTranscript(id)
                }
                for key in transcriptExpansions.keys where key.hasPrefix(id + "|") { transcriptExpansions[key] = nil }
                continue
            }
            if let cur = active, (transcripts[cur]?.evictOldestChunk() ?? 0) > 0 { continue }
            let visible = Set(transcripts[active ?? ""]?.visibleItems.map(\.id) ?? [])
            if let cur = active,
               let e = transcriptExpansions.filter({ $0.key.hasPrefix(cur + "|") && !visible.contains($0.value.itemId) }).min(by: { $0.value.seq < $1.value.seq }) {
                transcriptExpansions[e.key] = nil
                continue
            }
            if let cur = active, (transcripts[cur]?.trimNewest() ?? 0) > 0 { continue }
            if let e = transcriptExpansions.min(by: { $0.value.seq < $1.value.seq }) {
                transcriptExpansions[e.key] = nil
                continue
            }
            break // 只剩当前线程渲染窗口内的行（行数固定，与展开无关）
        }
    }

    /// 整线程丢弃（仅非当前、且没有在途请求的线程）：其展开一并移除；再次打开时从最新页重来。
    private func dropTranscript(_ id: String) {
        transcripts[id] = nil
        transcriptLastUsed[id] = nil
        for key in transcriptExpansions.keys where key.hasPrefix(id + "|") { transcriptExpansions[key] = nil }
    }

    static func expansionKey(_ threadId: String, _ itemId: String) -> String { threadId + "|" + itemId }
}
