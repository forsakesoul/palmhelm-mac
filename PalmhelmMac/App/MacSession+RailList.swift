import Foundation
import Observation
import PalmhelmKit

// 目标栏的展示投影（A1-010 §4.1，对应 iOS 的会话目录）：MacSession 拥有一份不可变快照（分组 + 按 ID 的行展示值 + 收件箱分区），
// 由同一次输入一次构建，只在展示值不等时发布。5 秒一次的 targets 帧只推进 observation.t 时输出相等、不发布；
// 行视图只消费自己那份值并按值复用，不再逐行重算待批 / 最近活动 / 归档判定。
// 快照只用于展示：钉住、归档、删除、审批、选择等动作仍走各自的权威入口，按提交那一刻的事实复核。

/// 已登记目标的一行展示值。副标题里随时间变化的工作时长只存开始时刻，由 30 秒叶子按 Date 格式化。
/// 不含整份 TargetSummary：徽章只取实际画出的文字与色源，能力提示等未展示的元数据变化不让行失效。
struct RailRow: Equatable, Identifiable {
    var id: String
    var title: String
    var badgeText: String
    var badgeRole: AgentRole?
    /// 没有角色时徽章色由项目名哈希决定。
    var badgeColorSource: String
    var identityLine: String
    var modelShort: String?
    var modelAccessibility: String?
    var place: String
    var branch: String?
    var selected: Bool
    var current: Bool
    var pending: Int
    var activity: ActivityKind
    var workingSince: Date?
    var pinned: Bool
    var canArchive: Bool
}

/// 已不在登记表中的历史目标：只能展示标题。
struct HistoricalRailRow: Equatable, Identifiable {
    var id: String
    var title: String
    var canArchive: Bool
}

struct RailSnapshot: Equatable {
    /// 构建时的归属范围（端点 + 连接代次）：换连接后旧输出不再被消费。
    var scope = ""
    var sections: [LensSection] = []
    var rows: [String: RailRow] = [:]
    var historical: [String: HistoricalRailRow] = [:]
    var inbox = InboxModel(requests: [], blockedWithoutCard: [], working: [])
    var archivedCount = 0
}

/// 测试钩子：不可观察，只计数，不参与任何失效。
@MainActor
final class RailProbe {
    static var rowBodies = 0
    static var bellBodies = 0
    static var alertsBodies = 0
    var builds = 0
    var publishes = 0
    /// pendingApprovals getter 被读取的次数：目录构建内不应随行数增长。
    var pendingReads = 0
    /// targetOnline（整表线性查找）被调用的次数：目录构建不应再逐行调用。
    var targetLookups = 0
}

extension MacSession {
    /// 归属范围：Bridge 身份 + 端点 + 连接代次（sessionGen）。换代或换 Bridge 后重建之前旧输出不被消费；重建按当前事实读取，断线时仍可显示陈旧快照。
    /// Bridge 身份取低频字段 railBridgeId（权威入口判变才写），不在这里读整个 state：state 每 5 秒更新，读它会把原始状态依赖接回消费者。
    var railScope: String { "\(railBridgeId)|\(endpoint.map { "\($0.host):\($0.port)" } ?? "")#\(connectionEpoch)" }

    /// 权威 state 写入口（applyStateSnapshot / forget）调用：Bridge 身份变化时才写，访问器随即拒绝旧快照。
    func noteBridgeIdentity() {
        let id = state?.bridge?.id ?? "local"
        if railBridgeId != id { railBridgeId = id }
    }

    /// 视图消费的目标栏。范围不符时返回空目录，而不是旧连接的行。
    var railSnapshot: RailSnapshot {
        let stored = railStore
        return stored.scope == railScope ? stored : RailSnapshot(scope: railScope)
    }

    /// 同一轮的事实索引：目标、每个目标的待答数、指令状态、未确认发送、最近回执序号。构建与观察整理共用，只读一次。
    struct RailFacts {
        var targets: [String: TargetSummary] = [:]
        var pendingCount: [String: Int] = [:]
        var commandStates: [String: [String]] = [:]
        var unconfirmed: [String: Int] = [:]
        var lastSeq: [String: Int] = [:]
    }

    func railFacts(pending: [ApprovalView]) -> RailFacts {
        var f = RailFacts()
        let list = state?.targets ?? []
        for t in list where f.targets[t.id] == nil { f.targets[t.id] = t }
        for a in pending { if let id = ApprovalText.target(of: a, in: list)?.id { f.pendingCount[id, default: 0] += 1 } }
        for c in commands.values { if let id = c.targetId { f.commandStates[id, default: []].append(c.state) } }
        for m in sent {
            guard let id = m.targetId else { continue }
            let hasCommand = m.eventKey.map { commands[$0] != nil } ?? false
            if ArchiveWorkFacts.localSendUnresolved(outgoingStatus(m).phase, hasCommand: hasCommand) { f.unconfirmed[id, default: 0] += 1 }
        }
        for item in history { if let id = item.target?.id { f.lastSeq[id] = item.seq } } // 与 lastActivity 同：按顺序最后一条
        return f
    }

    /// 与 archiveEvidence 同一口径，但复用同轮索引；最终仍调原 ArchiveRules。
    func archiveEvidence(_ id: String, facts f: RailFacts) -> ArchiveEvidence {
        let online: Bool? = {
            guard let s = state else { return nil }
            if let t = f.targets[id] { return t.online }
            return s.observation?.complete == true ? false : nil
        }()
        let work = ArchiveWorkFacts(
            commandStates: f.commandStates[id] ?? [],
            pendingApprovals: f.targets[id] == nil ? 0 : (f.pendingCount[id] ?? 0),
            unconfirmedSends: f.unconfirmed[id] ?? 0,
            pendingSync: 0,
            hasDraft: !draft(id).isEmpty)
        let protected = selectedTarget == id || selectedThread == id || state?.binding?.targetId == id
        return ArchiveEvidence(online: online, facts: work, protected: protected)
    }

    func canArchiveForDisplay(_ id: String, facts: RailFacts) -> Bool {
        archiveBridgeId != nil && ArchiveRules.archiveManually(ArchiveRecord(), archiveEvidence(id, facts: facts)) != nil
    }

    /// 目标栏输入：已登记目标（未归档/删除）+ 整理目录里已不在登记表的历史目标。
    func makeRailInputs(facts f: RailFacts) -> [LensInput] {
        let targets = state?.targets ?? []
        let listed = targets.filter { !isHiddenFromMain($0.id) }.map { t in
            let m = marks.marks(markKey(t.id)), last = f.lastSeq[t.id] ?? 0
            return LensInput(key: t.id, target: t, title: ThreadIdentity.title(t), lastActivity: last,
                             pendingApprovals: f.pendingCount[t.id] ?? 0, unread: m.isUnread(lastActivity: last), pinned: m.pinned)
        }
        return listed + historicalInputs(excluding: Set(targets.map(\.id)))
    }

    /// 一次构建：读到的所有可观察输入都由 trackRail 的 tracking 收集，不手抄签名。
    func buildRail() -> RailSnapshot {
        railProbe.builds += 1
        _ = marksVersion
        _ = archiveVersion
        let pending = pendingApprovals
        let facts = railFacts(pending: pending)
        let inputs = makeRailInputs(facts: facts)
        var snap = RailSnapshot(scope: railScope)
        snap.sections = lens == .spaces ? spaceSections(items: inputs) : LensGrouping.sections(lens, inputs, spaces: state?.spaces)
        snap.inbox = InboxModel.build(approvals: pending, targets: state?.targets ?? [], pinned: { [self] in marks.marks(markKey($0)).pinned }, lastActivity: { facts.lastSeq[$0] ?? 0 })
        let currentTarget = state?.binding?.targetId
        let routed = selectedRequest == nil
        for t in state?.targets ?? [] {
            let id = t.id
            let role = ThreadIdentity.role(t)
            let count = facts.pendingCount[id] ?? 0
            snap.rows[id] = RailRow(
                id: id, title: ThreadIdentity.title(t),
                badgeText: role?.label ?? MacSession.badgeInitials(t.projectName), badgeRole: role, badgeColorSource: role == nil ? t.projectName : "",
                identityLine: ThreadIdentity.line(t),
                modelShort: ModelText.short(t, offline: link != .connected),
                modelAccessibility: ModelText.accessibility(t, offline: link != .connected),
                place: [t.location?.workspace, t.location?.tab].compactMap { $0 }.joined(separator: " › "),
                branch: t.repo?.branch,
                selected: routed && selectedTarget == id, current: currentTarget == id, pending: count,
                activity: ThreadActivity.activity(online: link == .connected ? facts.targets[id]?.online : nil, status: ThreadIdentity.status(t), pending: count),
                workingSince: workingSince[id], pinned: marks.marks(markKey(id)).pinned,
                canArchive: canArchiveForDisplay(id, facts: facts))
        }
        for input in inputs where input.target == nil {
            snap.historical[input.key] = HistoricalRailRow(id: input.key, title: input.title, canArchive: canArchiveForDisplay(input.key, facts: facts))
        }
        snap.archivedCount = archivedThreads.count
        return snap
    }

    static func badgeInitials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { "-_ ".contains($0) })
        let s = parts.count >= 2 ? String(parts[0].prefix(1) + parts[1].prefix(1)) : String(name.prefix(2))
        return s.uppercased()
    }

    /// 观察构建本身读到的输入；任何变化后在主 Actor 上合并为一次重建并重新订阅。
    /// 构建结果与已发布值的比较发生在 tracking 之外：不观察自己的输出。
    func trackRail() {
        let next = withObservationTracking {
            buildRail()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackRail() }
        }
        publishRail(next)
    }

    /// 只有展示值不等才写可观察输出：无关的 observation.t 帧在这里被吸收。
    func publishRail(_ next: RailSnapshot) {
        guard next != railStore else { return }
        railProbe.publishes += 1
        railStore = next
    }
}
