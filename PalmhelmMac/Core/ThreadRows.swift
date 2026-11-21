import Foundation
import PalmhelmKit

// 线程行：Bridge 回执、服务端受理的指令与本机发出的消息合并。与 iPhone 端同一算法。
enum ThreadRow: Identifiable, Equatable {
    case receipt(HistoryItem)
    case command(ApiCommand)
    case mine(MacSession.Sent)

    var id: String {
        switch self {
        case .receipt(let r): "r\(r.seq)"
        case .command(let c): "c\(c.key)"
        case .mine(let m): "m\(m.id.uuidString)"
        }
    }

    /// 直达被 Bridge 拒绝（回执 rejected:，replyTo 为该条的 eventKey）时把本机发送标为失败；每次按当前 history 求值，回执先到或 eventKey 后回填都成立。
    static func withRejections(_ sent: [MacSession.Sent], history: [HistoryItem]) -> [MacSession.Sent] {
        sent.map { m in
            guard m.error == nil, let k = m.eventKey, let r = ReceiptText.rejectionItem(replyTo: k, in: history) else { return m }
            var c = m
            c.error = LText(ReceiptText.summary(r))
            return c
        }
    }

    /// 最新阅读窗的补行（#89 片 A）：服务端指令里没有记录行、没有本机回显 / 期限行覆盖的 queued / started / unknown / 停止，按共享规则补成只读 command 行。
    /// 只在 transcript 可读、非定位页、窗口下方无行且无更新内容时补（历史 / 定位窗零强插）；已关联（含不在可见窗口）的 key 不补尾；
    /// 本机 Sent 带不同会话代次的 key 不冒称属于当前原生会话（ApiCommand 自身没有代次，不按日期 / 文字猜）。
    static func supplement(commands: [ApiCommand], window: CommandWindow, threadId: String, transcript: TranscriptThread?, sent: [MacSession.Sent], echoes: [MacSession.Sent]) -> [ApiCommand] {
        guard let t = transcript, t.status == .ok, t.pinnedHit == nil, !t.hasRowsBelowWindow, !t.hasNewer else { return [] }
        let mine = commands.filter { $0.targetId == threadId }
        let covered = Set(echoes.compactMap(\.eventKey)).union(SendTimingRules.deadlineRows(mine).map(\.key))
        return ThreadCommandSupplement.rows(commands: mine, window: window, threadId: threadId, linkedKeys: t.linkedEventKeys, coveredKeys: covered, foreignKeys: foreignKeys(sent: sent, transcript: t), latestWindow: true, latestUserT: ThreadTailRules.latestUserTime(t))
    }

    /// 本机 Sent 带明确不同会话代次的 key：不属于当前原生会话（无代次不猜）。
    static func foreignKeys(sent: [MacSession.Sent], transcript t: TranscriptThread) -> Set<String> {
        Set(sent.compactMap { m -> String? in
            guard let k = m.eventKey, let e = m.sessionEpoch, let cur = t.sessionEpoch, e != cur else { return nil }
            return k
        })
    }

    /// 回执兜底分支的输入（会话记录不可读）：额外 command 行只取当前窗口成员，已淘汰的停止行不从缓存复活（commands 缓存本身不清，精确关联仍靠字典）。
    /// 已出窗口命令对应的本机回显同样不借它复活；没有权威命令的发送 / 失败回显、真实历史与 owner 回执照常保留。
    static func fallback(history: [HistoryItem], commands: [ApiCommand], window: CommandWindow, sent: [MacSession.Sent]) -> [ThreadRow] {
        let hidden = Set(commands.filter { !window.contains($0.key) }.map(\.key))
        return merge(history: history, commands: commands.filter { window.contains($0.key) },
                     sent: sent.filter { $0.eventKey.map { !hidden.contains($0) } ?? true })
    }

    /// 线程排序（O1-364 ①）：回执按入队时间，指令按服务端受理时间，统一按时间排；同一毫秒内回执在指令之后、按 seq / inboxSeq 稳定。
    /// 撤回只改状态，不改受理时间，所以不会把指令挪到别处。本机回显按它发送时的最近回执定位，排在它之后。
    /// 只有当所有指令与回执都带时间时才用时间排序；旧 Bridge 没有这些字段，退回回执锚定排序。
    /// 会话记录已有回执（eventKey 相同）的本机发送不再单独显示（O1-365）：只留记录行。
    static func withoutRecorded(_ sent: [MacSession.Sent], recorded: Set<String>) -> [MacSession.Sent] {
        sent.filter { m in !(m.eventKey.map { recorded.contains($0) } ?? false) }
    }

    /// 每线程最多保留的未关联原生插话回显（最近的）；更早的按普通消息规则处理。
    static let maxUnlinkedNativeEchoes = 20

    /// 本机回显的显示判定（与 iPhone 端 ThreadRows 同一规则）。普通消息：命令到终态即隐藏。原生直达插话：会话记录里还没关联、且仍属于其绑定的原生会话代次时保留
    /// （插话的回执常晚于命令完成，过早隐藏会让刚插入的那句消失），每线程最多 20 条。已关联（linked）的一律隐藏；期限行由 deadline 区块显示，这里不重复。
    /// `keepsNative` 只放行可保留的原生插话（送达、待确认或被暂停未送达）；未绑定代次的、以及 rejected 等被拒绝的终态，按普通规则。
    static func pendingEchoes(_ sent: [MacSession.Sent], linked: Set<String>, epoch: String?, deadlineKeys: Set<String>,
                              keepsNative: (MacSession.Sent) -> Bool, isTerminal: (MacSession.Sent) -> Bool) -> [MacSession.Sent] {
        // 已绑定的代次与当前代次不同：会话已换，不属于当前线程。未绑定（无证据）不在这里判定。
        func leftSession(_ m: MacSession.Sent) -> Bool {
            guard let mine = m.sessionEpoch, let epoch else { return false }
            return mine != epoch
        }
        let unlinkedNative = sent.filter { keepsNative($0) && $0.sessionEpoch != nil && !leftSession($0) && !($0.eventKey.map(linked.contains) ?? false) }
        let kept = Set(unlinkedNative.suffix(maxUnlinkedNativeEchoes).map(\.id))
        return sent.filter { m in
            if let k = m.eventKey, linked.contains(k) || deadlineKeys.contains(k) { return false }
            if m.error != nil { return true }
            if keepsNative(m), leftSession(m) { return false }
            if kept.contains(m.id) { return true }
            guard m.eventKey != nil else { return true }
            return !isTerminal(m)
        }
    }

    static func merge(history: [HistoryItem], commands: [ApiCommand], sent: [MacSession.Sent]) -> [ThreadRow] {
        // 0 或缺失的时间都是未知：只要有一条未知，整段退回回执锚定排序（O1-364 R2）
        guard commands.allSatisfy({ ($0.createdT ?? 0) > 0 }), history.allSatisfy({ ($0.t ?? 0) > 0 }) else { return mergeAnchored(history: history, commands: commands, sent: sent) }
        struct Key: Comparable {
            let t: Int, kind: Int, n: Int, tie: Double
            static func < (a: Key, b: Key) -> Bool { (a.t, a.kind, a.n, a.tie) < (b.t, b.kind, b.n, b.tie) }
        }
        let known = Set(commands.map(\.key))
        let pending = withRejections(sent, history: history).filter { $0.eventKey.map { !known.contains($0) } ?? true }
        var keyed: [(Key, ThreadRow)] = []
        for h in history { keyed.append((Key(t: h.t ?? 0, kind: 1, n: h.seq, tie: 0), .receipt(h))) }
        for c in commands { keyed.append((Key(t: c.createdT ?? 0, kind: 0, n: c.inboxSeq, tie: 0), .command(c))) }
        for m in pending {
            // 本机回显用发送当时的稳定锚，不随之后的回执或线程过滤变化（O1-364 R3）
            keyed.append((Key(t: m.anchorT ?? Int(m.at.timeIntervalSince1970 * 1000), kind: 2, n: 0, tie: m.at.timeIntervalSince1970), .mine(m)))
        }
        return keyed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func mergeAnchored(history: [HistoryItem], commands: [ApiCommand], sent: [MacSession.Sent]) -> [ThreadRow] {
        var firstReceipt: [String: Int] = [:]
        for item in history { if let k = item.replyTo, firstReceipt[k] == nil { firstReceipt[k] = item.seq } }
        var placed: [Int: [ApiCommand]] = [:]
        var unplaced: [ApiCommand] = []
        for c in commands.sorted(by: { $0.inboxSeq < $1.inboxSeq }) {
            if let seq = firstReceipt[c.key] { placed[seq, default: []].append(c) } else { unplaced.append(c) }
        }
        let known = Set(commands.map(\.key))
        var pending = withRejections(sent, history: history).filter { $0.eventKey.map { !known.contains($0) } ?? true }
            .sorted { ($0.afterSeq, $0.at) < ($1.afterSeq, $1.at) }
        var out: [ThreadRow] = []
        for item in history {
            while let m = pending.first, m.afterSeq < item.seq {
                out.append(.mine(m))
                pending.removeFirst()
            }
            for c in placed[item.seq] ?? [] { out.append(.command(c)) }
            out.append(.receipt(item))
        }
        out.append(contentsOf: unplaced.map { .command($0) })
        out.append(contentsOf: pending.map { .mine($0) })
        return out
    }
}
