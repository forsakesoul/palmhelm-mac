import Foundation
import PalmhelmKit

// 历史会话整理（#97）：Mac 侧只做接线——观察与判定、动作与历史分页都调用 Kit（ThreadArchiveStore / ArchiveRules / TargetHistoryPaging）。
// 整理记录只在本机；不在 Mac 复制任何规则。缺 Bridge ID 时不做任何持久整理。

/// 已归档的线程（离开目标栏后仍可在归档窗口找到）。
struct ArchivedThread: Identifiable, Equatable {
    let id: String // targetId
    let title: String
    let lastActivity: Int
    let reason: ArchiveReason
}

extension MacSession {
    var archiveBridgeId: String? { state?.bridge?.id }

    private var archivePrefix: String { "\(archiveBridgeId ?? "")|" }

    func archiveKey(_ targetId: String) -> String {
        ThreadArchiveStore.key(bridgeId: archiveBridgeId, targetId: targetId)
    }

    /// 三态在线（R4）：登记表中的明确值；完整观察中不在表里为明确离线；其余为未知。
    func archiveOnline(_ targetId: String) -> Bool? {
        guard let s = state else { return nil }
        if let t = s.targets.first(where: { $0.id == targetId }) { return t.online }
        return s.observation?.complete == true ? false : nil
    }

    /// 保护工作的事实（R3）：与 Kit 同一口径，草稿取自 Session 的 composerDrafts。
    func archiveFacts(_ targetId: String) -> ArchiveWorkFacts {
        let cmds = commands.values.filter { $0.targetId == targetId }
        let listed = state?.targets.first { $0.id == targetId }
        return ArchiveWorkFacts(
            commandStates: cmds.map(\.state),
            pendingApprovals: listed.map { approvals(for: $0).count } ?? 0,
            unconfirmedSends: localSendsUnresolved(targetId),
            pendingSync: 0,
            hasDraft: !draft(targetId).isEmpty)
    }

    /// 本机发出、结果未定且还没有指令的消息数（F1）：读取本机发送记录，与 Kit 的同一判定。
    func localSendsUnresolved(_ targetId: String) -> Int {
        sent.filter { m in
            guard m.targetId == targetId else { return false }
            let hasCommand = m.eventKey.map { commands[$0] != nil } ?? false
            return ArchiveWorkFacts.localSendUnresolved(outgoingStatus(m).phase, hasCommand: hasCommand)
        }.count
    }

    /// 本机的整理证据：当前选中或当前路由的目标受保护。
    func archiveEvidence(_ targetId: String) -> ArchiveEvidence {
        let protected = selectedTarget == targetId || selectedThread == targetId || state?.binding?.targetId == targetId
        return ArchiveEvidence(online: archiveOnline(targetId), facts: archiveFacts(targetId), protected: protected)
    }

    /// 界面据此决定是否显示归档/删除：与 Kit 的判定同一口径。
    func canArchiveOrDelete(_ targetId: String) -> Bool {
        archiveBridgeId != nil && ArchiveRules.archiveManually(ArchiveRecord(), archiveEvidence(targetId)) != nil
    }

    /// 目标栏是否隐藏该目标（归档或删除墓碑）。
    func isHiddenFromMain(_ targetId: String) -> Bool {
        _ = archiveVersion
        return ArchiveRules.isHiddenFromMain(archive.record(archiveKey(targetId)))
    }

    /// 整理目录里仍有效、但已不在登记表中的历史目标（R5 发现的旧目标也在此）：补进目标栏，只展示已投影的标题与最近活动。
    func historicalInputs(excluding known: Set<String>) -> [LensInput] {
        _ = archiveVersion
        guard archiveBridgeId != nil else { return [] }
        return archive.all.compactMap { key, rec -> LensInput? in
            guard key.hasPrefix(archivePrefix), !rec.deleted, rec.archived == nil else { return nil }
            let id = String(key.dropFirst(archivePrefix.count))
            guard !known.contains(id) else { return nil }
            return LensInput(key: id, target: nil, title: rec.title ?? id, lastActivity: rec.lastActivity ?? 0)
        }
    }

    /// 已归档的线程，按最近活动排序。
    var archivedThreads: [ArchivedThread] {
        _ = archiveVersion
        guard archiveBridgeId != nil else { return [] }
        return archive.all.compactMap { key, rec -> ArchivedThread? in
            guard key.hasPrefix(archivePrefix), let reason = rec.archived, !rec.deleted else { return nil }
            let id = String(key.dropFirst(archivePrefix.count))
            return ArchivedThread(id: id, title: rec.title ?? id, lastActivity: rec.lastActivity ?? 0, reason: reason)
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// 用一次观察推进整理记录。调用方只在最终合并之后调用（pullState 尾部、目标帧）。
    /// R5：除登记表外，还从已授权的历史投影（目标与标题）与指令投影（目标编号）发现旧目标；标题只取历史投影的 projectName。
    func observeArchive(_ observation: BridgeObservation?) {
        guard archiveBridgeId != nil else { return }
        let facts = railFacts(pending: pendingApprovals)
        var ids = Set((state?.targets ?? []).map(\.id))
        ids.formUnion(history.compactMap { $0.target?.id })
        ids.formUnion(commands.values.compactMap(\.targetId))
        for key in archive.all.keys where key.hasPrefix(archivePrefix) {
            ids.insert(String(key.dropFirst(archivePrefix.count)))
        }
        // 同一份事实一次交给存储：整轮最多保存一次。证据（lastObserved / absentSince）照常推进并保存；
        // archiveVersion 只在展示、可见性或目录信息变化时推进，证据时刻单独变化不让目标栏重算。
        // 顺序保持原来的结果：观察 → 登记目标标题 → 历史条目标题 → 只有指令投影的目标（F2，没有标题时用目标 ID）。
        var steps: [ThreadArchiveStore.Step] = ids.map { .observe(key: archiveKey($0), observation: observation, evidence: archiveEvidence($0, facts: facts)) }
        for t in state?.targets ?? [] {
            steps.append(.touch(key: archiveKey(t.id), title: ThreadIdentity.title(t), lastActivity: facts.lastSeq[t.id] ?? 0))
        }
        for item in history {
            guard let ref = item.target else { continue }
            steps.append(.touch(key: archiveKey(ref.id), title: ref.projectName ?? ref.id, lastActivity: facts.lastSeq[ref.id] ?? 0))
        }
        for id in Set(commands.values.compactMap(\.targetId)) {
            steps.append(.touch(key: archiveKey(id), title: id, lastActivity: facts.lastSeq[id] ?? 0, onlyIfUntitled: true))
        }
        if archive.apply(steps).displayChanged { archiveVersion += 1 }
    }

    /// 新的工作证据（单条指令或待答）立即恢复可见：只走正证据路径，观察为 nil 时不推进缺席计时。
    func restoreArchivedForWork(_ targetId: String?) {
        guard let targetId, archiveBridgeId != nil else { return }
        let ev = archiveEvidence(targetId)
        guard ev.pendingWork || ev.online == true else { return }
        archive.observe(archiveKey(targetId), nil, ev)
        archiveVersion += 1
    }

    /// 手动归档（只对明确离线、无待处理工作、未受保护的目标）。返回是否已保存。
    @discardableResult
    func archiveThread(_ targetId: String) -> Bool {
        guard archiveBridgeId != nil else { return false }
        let ev = archiveEvidence(targetId)
        let ok = archive.transform(archiveKey(targetId)) { ArchiveRules.archiveManually($0, ev) }
        archiveVersion += 1
        return ok
    }

    /// 恢复：取消归档，并从现在起重新计 7 天候选。
    @discardableResult
    func restoreThread(_ targetId: String) -> Bool {
        guard archiveBridgeId != nil else { return false }
        let ok = archive.transform(archiveKey(targetId)) { ArchiveRules.restore($0) }
        archiveVersion += 1
        return ok
    }

    /// 删除：只清本机展示与缓存（墓碑 + 内存中的该目标历史），不删 Bridge 账本。保存失败时不隐藏、返回 false。
    @discardableResult
    func deleteThread(_ targetId: String) -> Bool {
        guard archiveBridgeId != nil else { return false }
        let ev = archiveEvidence(targetId)
        let key = archiveKey(targetId)
        guard archive.transform(key, { ArchiveRules.delete($0, ev) }) else { return false }
        history.removeAll { $0.target?.id == targetId }
        archivedPaging[key] = nil
        archiveDeleteEpoch[key, default: 0] += 1
        archiveVersion += 1
        return true
    }

    /// 归档线程的历史分页（只读，R1/R2）：首载不带游标；续页只在首载完成且仍有更多时带不透明游标。
    /// 每次 await 后核对连接代次、Bridge 身份与删除版本，不符即丢弃。
    /// 消息账本页的 scope（只读读取活目标的历史）：没有 Bridge 身份时为 nil。Mac 没有账户切换，accountId 恒为 nil。
    func ledgerScope(_ targetId: String) -> LedgerScope? {
        archiveBridgeId.map { LedgerScope(targetId: targetId, epoch: connectionEpoch, bridgeId: $0, accountId: nil) }
    }

    /// 一次历史请求入队前冻结的归属：Bridge、连接代次、删除版本与请求槽身份。取得槽之后、发网之前必须仍然成立，
    /// 否则零请求零写入退出——不能在等待之后按“新的”代次与删除版本重新授权（否则删除期间排队的旧请求会复活已删缓存）。
    private struct HistoryClaim {
        let key: String
        let bridge: String
        let gen: Int
        let epoch: Int
        let slot: HistoryRequestSlot
    }

    /// 冻结归属并确保分页条目（及其请求槽）存在；没有 Bridge 身份返回 nil。
    private func claimHistory(_ targetId: String) -> HistoryClaim? {
        guard let bridge = archiveBridgeId else { return nil }
        let key = archiveKey(targetId)
        if archivedPaging[key] == nil { archivedPaging[key] = TargetHistoryPaging() }
        return HistoryClaim(key: key, bridge: bridge, gen: archiveSessionGen, epoch: archiveDeleteEpoch[key, default: 0], slot: archivedPaging[key]!.slot)
    }

    /// 冻结的归属是否仍然成立：同一连接代次、同一 Bridge、同一删除版本，且当前分页状态仍持有同一个请求槽（删除 / 断连后重建的新分页持有新槽）。
    private func historyClaimHolds(_ c: HistoryClaim) -> Bool {
        c.gen == archiveSessionGen && archiveBridgeId == c.bridge && archiveDeleteEpoch[c.key, default: 0] == c.epoch && archivedPaging[c.key]?.slot === c.slot
    }

    /// `scope` 非 nil（账本页）：请求发出前复核页面捕获的 scope，失效零请求；后面的迟到守卫沿原规则。
    /// 与刷新共用一个请求槽：旧调用退出之前本调用等待；等到之后先复核入队前冻结的归属、取消与范围，再读。
    func loadArchivedHistory(_ targetId: String, older: Bool = true, scope: LedgerScope? = nil) async {
        if let scope, scope != ledgerScope(targetId) { return }
        guard let claim = claimHistory(targetId) else { return }
        await claim.slot.acquire()
        defer { claim.slot.release() }
        guard historyClaimHolds(claim) else { return }
        await loadPagesLocked(targetId, claim: claim, older: older, scope: scope)
    }

    /// 已持有请求槽时的首载 / 续页（含空 partial 的自动继续）。每个 await 之后核对取消、冻结的归属（代次 / Bridge / 删除版本 / 槽身份）与页面 scope；
    /// 只释放本人的在途标志，失效 / 取消的返回零写、不继续续页。
    private func loadPagesLocked(_ targetId: String, claim: HistoryClaim, older: Bool, scope: LedgerScope?) async {
        var older = older
        let key = claim.key
        while true {
            guard !Task.isCancelled, historyClaimHolds(claim) else { return }
            if let scope, scope != ledgerScope(targetId) { return }
            var p = archivedPaging[key] ?? TargetHistoryPaging()
            let initial = p.canLoadInitial
            guard !p.loading, initial || (older && p.canLoadMore), let client = archiveClient() else { return }
            let before = initial ? nil : p.nextBefore
            p.beginLoad()
            archivedPaging[key] = p
            archiveVersion += 1
            func current() -> Bool { historyClaimHolds(claim) && !Task.isCancelled && (scope == nil || scope == ledgerScope(targetId)) }
            func abandon() {
                guard historyClaimHolds(claim), var q = archivedPaging[key] else { return }
                q.abandonLoad()
                archivedPaging[key] = q
                archiveVersion += 1
            }
            do {
                let page = try await client.targetHistory(targetId: targetId, before: before, limit: BridgeAPI.transcriptPageLimit)
                guard current() else { abandon(); return }
                var q = archivedPaging[key] ?? TargetHistoryPaging()
                q.apply(page, older: before != nil)
                archivedPaging[key] = q
                archiveVersion += 1
                guard q.shouldContinue else { return }
                older = true
            } catch {
                guard current() else { abandon(); return }
                var q = archivedPaging[key] ?? TargetHistoryPaging()
                q.failLoad()
                archivedPaging[key] = q
                archiveVersion += 1
                return
            }
        }
    }

    /// 账本刷新（#110 A）：把已加载范围里同 id 行的状态与指令更新到最新，并补上头部新增的行；离散触发（账本出现 / 回到前台），不轮询。
    /// 未首载沿首载路径（同一请求槽，不双发）。从最新页起按服务端 nextBefore 逐页向旧读到原最旧行所在页（页内为时间正序：保留锚及其后）或服务端耗尽；
    /// 失败、游标循环、空 partial 超限都保留已刷新内容与原游标并标记未完成。
    /// 物理串行：旧调用退出前等待；排队期间的多次激活至多一次尾随，被取消的排队者不运行、由后一个顶上（见 HistoryRequestSlot）。
    /// 入队前冻结归属：等待期间删除 / 断连 / 换 Bridge 的排队请求，醒来后零请求零写入退出。
    func refreshArchivedHistory(_ targetId: String, scope: LedgerScope? = nil) async {
        if let scope, scope != ledgerScope(targetId) { return }
        guard let claim = claimHistory(targetId) else { return }
        let key = claim.key, slot = claim.slot
        let seq = slot.registerRefresh()
        await slot.acquire()
        defer { slot.release() }
        guard !Task.isCancelled, historyClaimHolds(claim), !slot.refreshSatisfied(seq) else { return }
        if let scope, scope != ledgerScope(targetId) { return }
        guard var p = archivedPaging[key], p.loaded else {
            await loadPagesLocked(targetId, claim: claim, older: false, scope: scope) // 未首载：沿首载路径
            return
        }
        guard let client = archiveClient() else { return }
        let anchor = p.items.first?.id
        let startedAt = slot.refreshStarted()
        p.beginRefresh()
        archivedPaging[key] = p
        archiveVersion += 1
        func current() -> Bool { historyClaimHolds(claim) && !Task.isCancelled && (scope == nil || scope == ledgerScope(targetId)) }
        /// 只结束本人的刷新标志（断连 / 删除后分页已被清除或换槽则不碰）。
        func finish(complete: Bool, succeeded: Bool = false) {
            guard historyClaimHolds(claim), var q = archivedPaging[key] else { return }
            q.endRefresh(complete: complete)
            archivedPaging[key] = q
            archiveVersion += 1
            if succeeded { slot.refreshSucceeded(startedAt: startedAt) } // 只有成功读完才让排队的同类请求视为已满足
        }
        guard let anchor else {
            // 已加载但没有任何条目：重取首页一次，其后按既有 partial 继续规则。
            do {
                let page = try await client.targetHistory(targetId: targetId, before: nil, limit: BridgeAPI.transcriptPageLimit)
                guard current() else { finish(complete: Task.isCancelled); return }
                var q = archivedPaging[key] ?? TargetHistoryPaging()
                q.apply(page, older: false)
                q.endRefresh(complete: true)
                archivedPaging[key] = q
                archiveVersion += 1
                slot.refreshSucceeded(startedAt: startedAt)
                if q.shouldContinue { await loadPagesLocked(targetId, claim: claim, older: true, scope: scope) }
            } catch {
                finish(complete: Task.isCancelled)
            }
            return
        }
        var run = TargetHistoryRefresh(anchorID: anchor)
        var before: String? = nil
        while true {
            let page: TargetHistoryPage
            do { page = try await client.targetHistory(targetId: targetId, before: before, limit: BridgeAPI.transcriptPageLimit) } catch {
                finish(complete: Task.isCancelled) // 离页取消不算失败；网络错误保留失败标记，可再次激活重试
                return
            }
            guard current() else { finish(complete: true); return }
            var q = archivedPaging[key] ?? TargetHistoryPaging()
            let out = run.accept(page, requestedBefore: before, into: &q)
            archivedPaging[key] = q
            archiveVersion += 1
            if case .more(let next) = out { before = next; continue }
            finish(complete: out == .complete, succeeded: out == .complete)
            return
        }
    }

    /// 账本行的状态（#110 B）：scope 失效返回 nil；当前会话有同 key（且同目标）的指令时复用 `messageStatus(for:)`（同 inflight、同 tracker、同规则），
    /// 否则只对账本缓存的指令做独立求值。不把历史旧值写进 commands，也不借别条消息或全局 working 推断。
    func ledgerMessageStatus(_ item: TargetHistoryRow, scope: LedgerScope?) -> MessageStatus? {
        guard let scope, scope == ledgerScope(scope.targetId) else { return nil }
        return MessageStatusRules.ledger(row: item, scopeTarget: scope.targetId, current: item.command.flatMap { commands[$0.key] }, live: { messageStatus(for: $0) })
    }

    func archivedPage(_ targetId: String) -> TargetHistoryPaging {
        _ = archiveVersion
        return archivedPaging[archiveKey(targetId)] ?? TargetHistoryPaging()
    }
}
