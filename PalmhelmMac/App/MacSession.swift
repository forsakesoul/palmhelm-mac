import Foundation
import AppKit
import Observation
import os
import PalmhelmKit

// Mac 端会话：与内置 Bridge 自动配对（本机 Hook 密钥签码 → /pair），之后与 iPhone 端同一套状态/事件流/审批/发送逻辑。
@MainActor
@Observable
final class MacSession {
    enum Link: Equatable { case notPaired, connecting, connected, offline(LText) }

    var link: Link = .notPaired
    var endpoint: BridgeEndpoint? = KeychainStore.loadEndpoint()
    /// 这台 Mac 在 Bridge 上的设备名（O1-364 ④）：配对时上送，设置里可改；保存在偏好里，缺省 Mac。
    static let deviceNameKey = "palmhelm.mac.deviceName"
    var deviceName: String {
        get { preferences.string(forKey: Self.deviceNameKey) ?? "Mac" }
        set { preferences.set(newValue, forKey: Self.deviceNameKey) }
    }
    var state: BridgeState?
    /// 工作中目标的开始时刻（按目标 id）：只从本进程观测到 working 的那一刻起算，重启后从头计。
    var workingSince: [String: Date] = [:]
    var lastSync: Date?
    var history: [HistoryItem] = []
    var inflight: [String: String] = [:]
    var commands: [String: ApiCommand] = [:]
    var device: DeviceInfo?
    /// 排队消息的操作：固定提示（按 eventKey）、已改为立即插入的消息、单飞。
    var commandNotes: [String: LText] = [:]
    private var commandBusy: Set<String> = []
    /// 测试接缝：撤回 / 改为立即插入的传输（缺省走真实 BridgeClient）；只记录请求。
    var commandOverride: (@Sendable (QueuedAction, String) async throws -> Void)?
    private(set) var commandRequests: [QueuedAction] = []
    /// 署名偏好的存储（S3：默认 AppDefaults.standard，测试注入隔离 suite）。
    var preferences: UserDefaults = AppDefaults.standard
    var approvals: [String: ApprovalView] = [:]
    /// 当前时刻的唯一来源（测试可替换）。不可观察：普通的时间流逝不使任何投影失效；
    /// 待答 / 提醒的有效性只在边界时刻变化，由 timeValidityVersion 发布（见 MacSession+TimeValidity）。
    @ObservationIgnored var dateProvider: () -> Date = { Date() }
    var currentDate: Date { dateProvider() }
    /// 测试可注入固定时刻（提醒窗口的边界用例）。
    var now: Date {
        get { dateProvider() }
        set { let d = newValue; dateProvider = { d } }
    }
    var timeValidityVersion = 0
    @ObservationIgnored var validity = TimeValidityState()
    /// 提醒入口的摘要（可见提醒数 / 提醒回执数 / 未读数）：随有效性与数据变化判变后才写，入口小视图只读它，稳定帧静默。
    var reminderSummary = ReminderSummary()
    var streamState = String(localized: "未连接")
    /// 当前线程。唯一的变更入口（List 绑定、fixSelection、selectTarget 都经过它）：离开定位线程即退出定位，失效在途定位与 pin（R4）。
    var selectedThread: String? {
        didSet {
            // 旧版本的“系统线程”已撤掉：持久化或运行中遗留的旧编号回落到所选目标的第一条线程（没有就是空态），不留空白页
            if selectedThread == Self.legacySystemThread { selectedThread = threads(for: selectedTarget).first?.id }
            if selectedThread != oldValue, located?.threadId != selectedThread { leaveLocated() }
        }
    }
    /// 旧系统线程的编号：线程本身已不存在，这个常量只用来识别并回落遗留的选择。
    static let legacySystemThread = "__system__"
    /// 目标栏选中的目标（nil = 还没选）；选中后线程默认落到它的会话记录。
    var selectedTarget: String?
    /// 历史会话整理（#97）：每台 Mac 本地，不同步；规则与分页都在 Kit（见 MacSession+Archive.swift）。
    var archive = ThreadArchiveStore(defaults: AppDefaults.standard)
    var archiveVersion = 0
    /// 目标栏的展示投影（见 MacSession+RailList.swift）；视图经 railSnapshot 读取。
    var railStore = RailSnapshot()
    /// 目标栏快照的 Bridge 身份（低频）：只在权威入口判变才写。
    var railBridgeId = "local"
    @ObservationIgnored let railProbe = RailProbe()
    /// 空间分组排序的偏好（#98）：本机存储；目标栏可见状态与最近一次有效判定用于冻结与静默应用。
    var spaceStore = SpaceOrderStore(defaults: AppDefaults.standard)
    var spaceDocument: SpaceOrderDocument = SpaceOrderStore(defaults: AppDefaults.standard).load()
    var spaceListVisible = false
    var spaceLastEffective = false
    var spaceVersion = 0
    var archivedPaging: [String: TargetHistoryPaging] = [:]
    /// 每个归档键的删除版本：在途历史请求返回时比对，删除后不回填正文。
    var archiveDeleteEpoch: [String: Int] = [:]
    /// 当前连接代次（归档历史的在途请求返回时核对）。
    var archiveSessionGen: Int { sessionGen }
    /// 归档线程的历史客户端（与其它读取同一端点与令牌；无配对时为 nil）。
    /// 测试接缝：历史分页的传输（默认用已配对的 Bridge）。
    var archiveClientOverride: (() -> (any SearchTranscriptClient)?)?
    /// #21 派发任务的客户端（未配对即 nil）。权限由 Bridge 复核：只读设备的写请求得到固定 403。
    func issueTaskClient() -> BridgeClient? {
        guard let endpoint, let token else { return nil }
        return BridgeClient(endpoint: endpoint, token: token)
    }

    func archiveClient() -> (any SearchTranscriptClient)? {
        if let f = archiveClientOverride { return f() }
        guard let endpoint, let token else { return nil }
        return BridgeClient(endpoint: endpoint, token: token)
    }
    var selectedTargetSummary: TargetSummary? { state?.targets.first { $0.id == selectedTarget } }
    /// 本机发出消息的状态（O1-365）：与 iOS 同一 Kit 判定；只前进，不参与观察（视图读取时推进，结果幂等）。
    @ObservationIgnored var outgoingTracker = OutgoingStatusTracker()
    /// 自配对换了凭据后，尚未拿到新 Bridge 的快照：改名范围一律视为失效（C3）。
    @ObservationIgnored private var awaitingFreshState = false
    func targetWorking(_ targetId: String?) -> Bool {
        guard let id = targetId, let t = state?.targets.first(where: { $0.id == id }) else { return false }
        return ThreadIdentity.status(t) == .working
    }
    /// 原生直达插话（直达 + mode=steer，或已提升为立即插入的直达消息），且未撤回。撤回后不再按原生插话保留。
    func isNativeInsert(_ m: Sent) -> Bool {
        if let k = m.eventKey, let c = commands[k] {
            if c.reason == "withdrawn" { return false }
            if c.reason == "native_delivered" || (c.directAgent != nil && c.lane == "use") { return true }
        }
        return (m.mode == .steer || m.mode == .sendNow) && m.agent != nil
    }
    /// 原生插话的保留资格：是原生插话，且不是被拒绝的终态（rejected 按普通规则）。送达（native_delivered）、待确认（在途、finished）与被暂停未送达（paused，O1-068 保留为失败行）保留。
    func keepsNativeEcho(_ m: Sent) -> Bool { isNativeInsert(m) && !isNonDeliveredNative(m) }
    private func isNonDeliveredNative(_ m: Sent) -> Bool {
        guard let k = m.eventKey else { return false }
        if commands[k]?.reason == "native_delivered" { return false }
        let st = inflight[k] ?? commands[k]?.state
        return st == "rejected"
    }

    /// 命令已到终态（旧规则）：进度优先，其次权威指令；都没有时视为未终态。
    func echoTerminal(_ m: Sent) -> Bool {
        guard let k = m.eventKey else { return false }
        if let st = inflight[k] { return ProgressState(rawValue: st)?.isTerminal ?? false }
        if let c = commands[k] { return CommandState(rawValue: c.state)?.isTerminal ?? false }
        return false
    }

    /// 线程里要单独显示的本机回显（判定规则见 ThreadRow.pendingEchoes）。`deadlineKeys` 缺省取全部期限行；父级投影传入实际显示的期限键。
    func pendingEchoes(threadId: String, deadlineKeys: Set<String>? = nil) -> [Sent] {
        let threadCommands = commands.values.filter { $0.targetId == threadId }
        // owner 操作不是待发回显：它们及其结果经 ownerPlacement 保留在稳定位置。
        let mine = ThreadRow.withRejections(sent, history: history).filter { $0.targetId == threadId && $0.ownerKind == nil }
        let transcript = transcripts[threadId]
        return ThreadRow.pendingEchoes(mine, linked: transcript?.linkedEventKeys ?? [], epoch: transcript?.sessionEpoch,
                                       deadlineKeys: deadlineKeys ?? Set(SendTimingRules.deadlineRows(threadCommands).map(\.key)),
                                       keepsNative: { self.keepsNativeEcho($0) }, isTerminal: { self.echoTerminal($0) })
    }

    /// 最新阅读窗尾部（#89 片 B）：期限行、补行、本机回显一次得出，同一份实际行集合决定去重；历史 / 定位窗为空（数据保留）。父级 body 每次只取一次。
    func threadTail(threadId: String) -> ThreadTail<Sent> {
        guard let t = transcripts[threadId] else { return .empty }
        return ThreadTailRules.tail(commands: Array(commands.values), window: commandWindow, threadId: threadId, transcript: t,
                                    foreignKeys: ThreadRow.foreignKeys(sent: sent, transcript: t),
                                    echoes: { dl in
                                        // 已明确属于其他原生会话代次的普通回显同样不出现在当前尾部（失败行不是正文，保留）；数据仍在 sent。
                                        let foreign = ThreadRow.foreignKeys(sent: self.sent, transcript: t)
                                        return self.pendingEchoes(threadId: threadId, deadlineKeys: dl).filter { $0.error != nil || !($0.eventKey.map(foreign.contains) ?? false) }
                                    }, echoKey: \.eventKey)
    }

    /// 无本机 Sent 的指令行（他设备 / 飞书 / 重启后）的状态：事实经 Kit 同一入口，阶段经同一个 tracker（首次读取与反复读取一致，送达证据在采纳处已记录）。
    func messageStatus(for c: ApiCommand) -> MessageStatus {
        // 有权威指令时阶段只看指令事实；owner 指令的系统回执（ack）只在“没有指令记录”时才参与（OutgoingStatus.phase），这里不必按行扫描 history。
        let facts = MessageStatusRules.facts(for: c, inflight: inflight[c.key])
        let phase = outgoingTracker.advance(c.key, to: OutgoingStatus.phase(facts))
        return MessageStatusRules.status(for: c, phase: phase)
    }

    /// 会话记录里用户行的状态：只对能精确关联到权威指令（eventKey 相等）的回执给值；回执已给出的强结果不被 tracker 的旧终态压住。
    func recordStatus(_ r: TranscriptReceipt?) -> MessageStatus? {
        guard let r, let k = r.eventKey, let c = commands[k] else { return nil }
        let raw = OutgoingStatus.phase(.fromReceipt(r, command: c, inflight: inflight[k]))
        let tracked = outgoingTracker.advance(k, to: raw)
        return MessageStatusRules.status(for: c, phase: MessageStatusRules.isStrongReceiptResult(raw) ? raw : tracked)
    }

    /// 最新阅读窗里需要补行的服务端指令（他设备 / 飞书 / 重启后的 queued、started、unknown 与停止）。只在最新原生阅读窗补；规则见 ThreadRow.supplement。
    func supplementCommands(threadId: String) -> [ApiCommand] {
        ThreadRow.supplement(commands: Array(commands.values), window: commandWindow, threadId: threadId, transcript: transcripts[threadId],
                             sent: sent, echoes: pendingEchoes(threadId: threadId))
    }

    func outgoingStatus(_ m: Sent) -> (phase: OutgoingPhase, label: String) {
        var f = OutgoingFacts(hasEventKey: m.eventKey != nil, localError: m.error != nil && m.eventKey == nil, localUnknown: m.resultUnknown && m.eventKey == nil, agentWorking: targetWorking(m.targetId), nativeSteer: (m.mode == .steer || m.mode == .sendNow) && m.agent != nil, ownerKind: m.ownerKind)
        if let k = m.eventKey {
            if let c = commands[k] {
                // 事实经 Kit 同一入口填充（阶段 / 暂停分类 / 车道），两端与记录来源行共用。
                let cf = OutgoingFacts.fromCommand(c, inflight: inflight[k])
                f.commandState = cf.commandState; f.commandReason = cf.commandReason; f.steer = cf.steer; f.commandPhase = cf.commandPhase; f.stop = cf.stop
                // 普通直达排队后改为立即插入（promote）时本机记录仍是普通：以权威指令的直达 + use 车道为准。
                if c.directAgent != nil, c.lane == "use" { f.nativeSteer = true }
            }
            else if let st = inflight[k] { f.commandState = st }
        }
        // owner 指令（切换到等）的结果来自系统回执（ack:<eventKey>），与普通排队消息分开（#96）。
        if let k = m.eventKey { f.ackText = OutgoingFacts.ackText(eventKey: k, in: history) }
        let reject = m.eventKey != nil ? m.error : nil
        f.rejectText = reject?.text
        let phase = outgoingTracker.advance(m.eventKey ?? m.id.uuidString, to: OutgoingStatus.phase(f))
        if [.queued, .queuedSteer, .queuedNative].contains(phase), let key = m.eventKey, let c = commands[key] {
            return (phase, SendTimingCopy.commandStatus(state: "queued", reason: c.reason, lane: c.lane, direct: c.directAgent != nil, queueDeadlineT: c.queueDeadlineT))
        }
        return (phase, OutgoingStatus.label(phase, rejectText: reject?.text))
    }

    /// 用户 / 入口选中一个目标：这本身就是一次新的导航意图（旧的待消费 thread / card 作废），并离开请求详情。
    func selectTarget(_ id: String) {
        beginNavigation()
        selectedRequest = nil
        applySelection(id)
    }

    private func applySelection(_ id: String) {
        selectedTarget = id // 切换线程时的定位退出由 selectedThread 的 didSet 统一处理（A→B→A 不残留 pin）
        selectedThread = threads(for: id).first?.id
    }

    /// 某目标的待答：审批只带目标标签（候选时前缀“候选：”），按项目名匹配。未登记目标的审批只在铃铛里出现。
    // MARK: 身份与视角

    /// 已读 / 钉住：本机自己记，不跟随 Herdr 的 done 标记。
    let marks = ThreadMarkStore(defaults: AppDefaults.standard)
    private(set) var marksVersion = 0
    var lens: ThreadLens = ThreadLens(rawValue: AppDefaults.standard.string(forKey: "palmhelm.lens") ?? "") ?? .spaces {
        didSet { AppDefaults.standard.set(lens.rawValue, forKey: "palmhelm.lens"); lensPrefs.setLens(bridgeKey, lens); evaluateRecommendation() }
    }
    /// 视角偏好与推荐按机器存（1b）。
    let lensPrefs = LensPreferenceStore(defaults: AppDefaults.standard)
    private var bridgeKey: String { state?.bridge?.id ?? "local" }
    private(set) var lensPrefsVersion = 0
    /// 待呈现的推荐（视角 + 签名）。Mac 只在目标栏展开、横幅真正显示时才记录「已提示」（A1-134 F2），由视图调用 markRecommendationShown。
    private(set) var pendingRecommendation: (lens: ThreadLens, signature: String)?
    var lensRecommendation: ThreadLens? { _ = lensPrefsVersion; return pendingRecommendation?.lens }
    var lensRecommendationSignature: String? { _ = lensPrefsVersion; return pendingRecommendation?.signature }

    func evaluateRecommendation() {
        let inputs = railInputs
        guard !inputs.isEmpty else { pendingRecommendation = nil; return }
        let sig = LensGrouping.structureSignature(inputs, spaces: state?.spaces)
        if let p = pendingRecommendation { if p.signature == sig, p.lens != lens { return }; pendingRecommendation = nil }
        let rec = LensGrouping.recommend(inputs, spaces: state?.spaces)
        guard LensPreferenceStore.shouldRecommend(current: lens, recommended: rec, signature: sig, entry: lensPrefs.entry(bridgeKey)) else { return }
        pendingRecommendation = (rec, sig); lensPrefsVersion += 1
    }
    /// 横幅已经呈现：记录签名，同一签名之后不再提示；呈现中的横幅保留到切换/忽略/签名变化。
    func markRecommendationShown() { if let p = pendingRecommendation, lensPrefs.entry(bridgeKey).lastSignature != p.signature { lensPrefs.noteSignature(bridgeKey, p.signature) } }
    func acceptRecommendation() { if let p = pendingRecommendation { lens = p.lens }; pendingRecommendation = nil; lensPrefsVersion += 1 }
    func ignoreRecommendation() { if let p = pendingRecommendation { lensPrefs.ignore(bridgeKey, signature: p.signature) }; pendingRecommendation = nil; lensPrefsVersion += 1 }
    /// Mac 自己配对的设备迁移后为可控；旧 Bridge 没有权限字段时按可控。
    /// 本机模式沿用原缺省（缺字段视为可控）；远程模式只有明确为 control 且在线才可控，未知或缺字段一律不可控。
    var canControl: Bool {
        let d = device ?? state?.device
        guard connectionModeProvider() == .remote else { return d?.canControl ?? true }
        return link == .connected && d?.permission == DevicePermission.control.rawValue
    }

    func markKey(_ targetId: String) -> String { ThreadIdentity.key(bridgeId: state?.bridge?.id, targetId: targetId) }
    func lastActivity(_ targetId: String) -> Int { history.last { $0.target?.id == targetId }?.seq ?? 0 }
    func marks(for targetId: String) -> ThreadMarks { _ = marksVersion; return marks.marks(markKey(targetId)) }

    /// 目标栏按所选视角分组（Mac 的线程按目标组织，所以分组的单位是目标）。
    /// 已归档或删除（墓碑）的线程不进目标栏；整理目录里仍在、但已不在登记表中的历史目标补进来（无 target，只能展示标题）。
    var railInputs: [LensInput] {
        _ = marksVersion
        _ = archiveVersion
        return makeRailInputs(facts: railFacts(pending: pendingApprovals))
    }
    /// 侧栏收件箱：需要你处理（请求卡 + 无可靠卡的 blocked）→ 工作中。请求以 approvals 为权威。
    var inboxModel: InboxModel {
        _ = marksVersion
        return InboxModel.build(approvals: pendingApprovals, targets: state?.targets ?? [], pinned: { [self] in marks.marks(markKey($0)).pinned }, lastActivity: { [self] in lastActivity($0) })
    }
    var railSections: [LensSection] {
        if lens == .spaces { return spaceSections() }
        return LensGrouping.sections(lens, railInputs, spaces: state?.spaces)
    }

    func markSeen(_ targetId: String) { marks.markSeen(markKey(targetId), through: lastActivity(targetId)); marksVersion += 1 }
    func setPinned(_ targetId: String, _ pinned: Bool) { marks.setPinned(markKey(targetId), pinned); marksVersion += 1 }
    func markUnread(_ targetId: String) { marks.markUnread(markKey(targetId)); marksVersion += 1 }

    // MARK: 导航意图（D6）
    /// 入口（刘海 / 通知 / 搜索 / 收件箱卡）要去的地方。
    enum NavDestination: Equatable { case thread(String), request(String), inbox }
    /// 待主窗口消费的一次打开：窗口未出现 / 已关闭 / 冷启动时它一直留在 Session 里，窗口出现后消费；说明在 navNotice。
    struct NavRequest: Equatable { let serial: Int; let destination: NavDestination }
    /// 意图序号：每个新意图都 +1，同步清掉旧的待消费 thread / card 与说明；异步动作回来先核它，旧意图不再改导航。
    private(set) var navSerial = 0
    private(set) var pendingNav: NavRequest?
    /// 打不开时的说明（收件箱顶部显示，下一次导航 / 操作时清掉）。
    var navNotice: LText?
    /// 右侧工作区正在看的请求详情（提问 / 计划 / 长命令）；nil 是正常的线程工作区。
    var selectedRequest: String?
    /// 请求详情当前是否有效：卡已处理 / 过期 / 撤回就回到线程工作区，不停在旧卡上。
    var activeRequest: ApprovalView? {
        _ = timeValidityVersion
        guard let id = selectedRequest, let a = approvals[id], a.isPending(now: currentDate) else { return nil }
        return a
    }

    @discardableResult
    func beginNavigation() -> Int {
        navSerial += 1
        locateGen += 1 // 新的导航意图使在途的搜索定位失效（已落地的 pin / 回到最新规则不受影响：这里不清 located）
        pendingNav = nil
        navNotice = nil
        return navSerial
    }

    func consumeNav() -> NavRequest? {
        defer { pendingNav = nil }
        return pendingNav
    }

    private func finishNav(_ serial: Int, _ dest: NavDestination, notice: LText? = nil) {
        guard serial == navSerial else { return }
        navNotice = notice
        pendingNav = NavRequest(serial: serial, destination: dest)
    }

    /// 打开目标前的统一守卫（openThread / 搜索入口共用）：不在线不直接打开（避免停在可能陈旧的线程上），目标已不在列表也不打开；
    /// 两种情况都转收件箱并说明。返回 true = 可以打开。
    private func guardOpenTarget(_ targetId: String, serial my: Int) -> Bool {
        guard link == .connected else { selectedRequest = nil; lens = .inbox; finishNav(my, .inbox, notice: LText(String(localized: "未连接 Bridge，先不打开这个目标；连上后再试"))); return false }
        guard state?.targets.contains(where: { $0.id == targetId }) == true else { selectedRequest = nil; lens = .inbox; finishNav(my, .inbox, notice: LText(String(localized: "这个目标已不在 Herdr 的列表里"))); return false }
        return true
    }

    /// 打开某目标的线程。
    func openThread(_ targetId: String) {
        let my = beginNavigation()
        guard guardOpenTarget(targetId, serial: my) else { return }
        selectedRequest = nil
        applySelection(targetId)
        finishNav(my, .thread(targetId))
    }

    /// 打开一条待答：收件箱里定位到这张卡（短审批在卡上办，长内容在右侧详情）。冷启动 / 刚到的请求先补拉一次权威列表，回来再核意图与连接代次。
    func openRequest(_ requestId: String) async {
        let my = beginNavigation()
        let gen = sessionGen
        guard link == .connected else { selectedRequest = nil; lens = .inbox; finishNav(my, .inbox, notice: LText(String(localized: "未连接 Bridge，待答可能已变化；连上后再处理"))); return }
        if approvals[requestId]?.isPending(now: currentDate) != true { await reloadApprovals() }
        guard my == navSerial, gen == sessionGen else { return } // 期间有新意图 / 连接变了：旧意图作废
        lens = .inbox
        if let a = approvals[requestId], a.isPending(now: currentDate) {
            if let t = target(forApproval: a), approvalAttributionIsExact(a) { applySelection(t.id) }
            selectedRequest = requestId
            finishNav(my, .request(requestId))
        } else {
            selectedRequest = nil
            finishNav(my, .inbox, notice: LText(String(localized: "这条待答已处理、过期或撤回")))
        }
    }

    // MARK: 铃铛定位（B-01）
    enum InboxFocusTarget: Equatable { case request(String), top }
    /// 一次「请定位并高亮」的脉冲：serial 每次递增，所以侧栏已经展开、目标没变时再点铃铛也会产生一次可观察的定位 / 高亮（selectedRequest 不变化时 onChange 不会触发）。
    struct InboxFocus: Equatable { let target: InboxFocusTarget; let serial: Int; var at = Date() }
    private(set) var inboxFocus: InboxFocus?
    private var inboxFocusSerial = 0
    private var inboxFocusConsumed = 0
    func pulseInboxFocus(_ t: InboxFocusTarget) { inboxFocusSerial += 1; inboxFocus = InboxFocus(target: t, serial: inboxFocusSerial) }
    /// 侧栏消费脉冲：onChange 与 onAppear 共用。侧栏还没挂载（窄窗收起、在用量页）时脉冲先到，挂载时补消费；记住已消费的 serial 不重复，过了 5 秒的旧脉冲不再补播。
    static let focusFreshSeconds: TimeInterval = 5
    func takeInboxFocus(now: Date = Date()) -> InboxFocus? {
        guard let f = inboxFocus, f.serial > inboxFocusConsumed, now.timeIntervalSince(f.at) <= Self.focusFreshSeconds else { return nil }
        inboxFocusConsumed = f.serial
        return f
    }
    /// 没有待答时铃铛给的明确提示（侧栏顶部一行，约 2 秒后淡出；VoiceOver 播报同一句话）。
    static var noPendingText: String { String(localized: "没有需要你处理的请求") }
    static let flashSeconds: (top: Double, request: Double) = (2.0, 1.6)
    /// VoiceOver 播报（测试可替换）：缺省走 NSAccessibility 的 announcementRequested。
    var announcer: (String) -> Void = { text in
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// 工具栏铃铛：有待答 → 走现有的 openRequest 导航意图定位到第一条待处理卡并脉冲高亮；没有待答（或定位失败）→ 回收件箱顶部并脉冲高亮。
    /// 调用方先让侧栏展开（窄窗临时展开）；这里只管导航意图与定位脉冲。
    func bellTapped() async {
        if let first = inboxModel.requests.first {
            await openRequest(first.id)
            if selectedRequest == first.id { pulseInboxFocus(.request(first.id)); return }
        } else {
            openInbox()
        }
        pulseInboxFocus(.top)
        if inboxModel.requests.isEmpty { announcer(Self.noPendingText) } // 没有待答：明确告诉用户（视觉一行 + VoiceOver 同一句）
    }

    /// 回到收件箱（没有具体卡可定位）。
    func openInbox(notice: LText? = nil) {
        let my = beginNavigation()
        selectedRequest = nil
        lens = .inbox
        finishNav(my, .inbox, notice: notice)
    }

    private func approvalAttributionIsExact(_ a: ApprovalView) -> Bool { a.attribution == ApprovalAttribution.exact.rawValue }

    private func seedMarks() {
        marks.seedBaselineIfNeeded(bridge: state?.bridge?.id ?? "local", (state?.targets ?? []).map { (key: markKey($0.id), lastActivity: lastActivity($0.id)) }); marksVersion += 1
        if let l = lensPrefs.entry(bridgeKey).lens, l != lens { lens = l } // 这台机器上次选的视角
        evaluateRecommendation()
    }

    /// 「在 Herdr 中显示」：成功写切到了谁，失败写原因。
    func reveal(_ targetId: String) async -> (ok: Bool, message: LText) {
        guard let endpoint, let token else { return (false, LText(String(localized: "未配对"))) }
        guard canControl else { return (false, LText(Self.readOnlyNote)) }
        let who = state?.targets.first { $0.id == targetId }.map { t in [ThreadIdentity.role(t)?.label, ThreadIdentity.title(t)].compactMap { $0 }.joined(separator: " · ") } ?? targetId
        do {
            switch try await BridgeClient(endpoint: endpoint, token: token).reveal(targetId: targetId) {
            case .ok: return (true, LText(String(localized: "已在 Herdr 中切到 \(who)")))
            case .failed(_, let code): return (false, LText(RevealText.failure(code)))
            }
        } catch { return (false, LText(String(localized: "Bridge 未连接 · \(Self.describe(error))"))) }
    }

    func approvals(for t: TargetSummary) -> [ApprovalView] {
        pendingApprovals.filter { target(forApproval: $0)?.id == t.id }
    }
    func target(forApproval a: ApprovalView) -> TargetSummary? {
        ApprovalText.target(of: a, in: state?.targets ?? [])
    }
    static func projectName(ofApprovalLabel label: String) -> String { ApprovalText.projectName(ofLabel: label) }

    /// 某目标的线程：它自己的会话线程（没有回执时也给一条稳定的空线程）。全局的“系统线程”已撤掉：无目标的条目走收件箱（待答卡 / 提醒区）。
    func threads(for targetId: String?) -> [Thread] {
        guard let targetId else { return [] }
        let own = threads.first { $0.id == targetId } ?? Thread(id: targetId, title: state?.targets.first { $0.id == targetId }?.projectName ?? targetId, subtitle: nil, preview: String(localized: "还没有回执"), lastSeq: 0, count: 0)
        return [own]
    }
    var usage: UsageResponse?
    var usageError: LText?
    /// 用量页「账户额度」所选账户（provider|accountId；会话内保持，不写盘）。O1-368：不因数值变化或暂时失败抢回默认。
    var usageAccountKey: String?
    /// 正在提交决定的审批 id 与最近一次失败原因：主窗口卡片与刘海共用，避免两处连点同一项。
    var deciding: Set<String> = []
    var decideError: [String: LText] = [:]
    /// 切换目标：受理后要拉到权威 state 确认新绑定才算完成；确认失败/超时保持不可发送，直到下一次成功同步。
    enum SwitchState: Equatable { case idle, pending, failed(LText) }
    var switchState: SwitchState = .idle
    var switching: Bool { switchState == .pending }
    /// 事件流代次：stopStream/重连后，旧流的回调不能再改连接态。
    private var streamGen = 0
    /// 会话代次：stopStream/disconnect/forget 递增。所有异步同步（pullState/refresh）在 await 返回后、写状态前复核它，过期结果整体丢弃。
    private var sessionGen = 0
    /// 当前连接代次（空间排序的有效快照核对）。
    var spaceSessionGen: Int { sessionGen }
    /// 连接代次（只读）：换连接、换账号或停止时递增；派发 sheet 据此关闭（#21 S2）。
    var connectionEpoch: Int { sessionGen }
    /// 派发成功后要导航到的线程（列表据此定位）。
    var issueAcceptedTarget: String?
    /// 派发的传输替身（测试用）：设置后派发不触网。
    var issueTaskTransportOverride: (() -> IssueTaskTransport)?
    var usageLoading = false
    private var usageSeq = 0
    /// 目标在线快照只在会话连通时可信；断开后按未知展示。
    func targetOnline(_ id: String?) -> Bool? { railProbe.targetLookups += 1; return link == .connected ? state?.targets.first { $0.id == id }?.online : nil }
    private var token: String? // 由 loadCredentials() 在后台线程装入，不在主线程读钥匙串
    private(set) var credentialsLoaded = false

    /// 远程模式只接受带完整 SPKI 的 https 端点；本机模式保持原有读取。
    func loadCredentials(mode: ConnectionMode = .local) async {
        guard !credentialsLoaded else { return }
        token = await KeychainStore.loadAsync(account: KeychainStore.tokenAccount)
        if mode == .remote { endpoint = KeychainStore.loadEndpoint(requirePinned: true) }
        credentialsLoaded = true
    }

    /// 切换到本机前固定旧连接的客户端（远程自撤用）：之后 forget 清掉的是会话，这个快照仍指向旧 Mac。
    func currentClient(timeout: TimeInterval) -> BridgeClient? {
        guard let endpoint, let token else { return nil }
        return BridgeClient(endpoint: endpoint, token: token, timeout: timeout)
    }
    private var streamTask: Task<Void, Never>?

    var isPaired: Bool { token != nil && endpoint != nil }

    var pendingApprovals: [ApprovalView] {
        _ = timeValidityVersion // 有效集合变化（数据事件或到期边界）才发布
        railProbe.pendingReads += 1
        return approvals.values.filter { $0.isPending(now: currentDate) }.sorted { $0.createdT < $1.createdT }
    }

    /// 当前活动的证据：会话已连通，且目标取自最近一次成功同步的快照；离线 / 未同步时只能说「状态待同步」，不冒充当前。
    var activityLinked: Bool { link == .connected && state != nil }
    var knownTargetIds: Set<String>? { state.map { Set($0.targets.map(\.id)) } }
    /// 只含已知 queued / started 且目标仍在快照里的指令；结果未知 / 不识别 / 历史不计入（刘海、菜单、线程共用）。
    var runningCommands: [ApiCommand] {
        CurrentActivity.current(Array(commands.values), linked: activityLinked, targets: knownTargetIds)
    }
    /// 工作中的目标（刘海 / 菜单）：只在已连通且有快照时计；判定与线程列表、收件箱同一口径（ThreadIdentity.status == .working）。
    /// 包括 Herdr 里直接执行的任务，不要求经 Palmhelm 发出。
    var workingTargets: [TargetSummary] {
        guard activityLinked, let targets = state?.targets else { return [] }
        return targets.filter { ThreadIdentity.status($0) == .working }
    }
    /// 结果未知或不识别的未终结指令数（菜单单独说明）；离线时在途无法确认，另用 activityPendingSync。
    var unresolvedCommandCount: Int { CurrentActivity.unresolved(Array(commands.values), linked: activityLinked, targets: knownTargetIds) }
    var activityPendingSync: Bool {
        commands.values.contains { CurrentActivity.phase(of: $0, linked: activityLinked, targets: knownTargetIds) == .pendingSync }
    }
    func commandLabel(_ c: ApiCommand) -> String { CurrentActivity.displayLabel(of: c, linked: activityLinked, targets: knownTargetIds) }

    init() {
        trackRail()
        reconcileTimeValidity()
        trackTimeValidityInputs()
        observeClockEvents()
    }

    // ---- 与内置 Bridge 自动配对 ----
    /// 配对阶段诊断（由 AppBoot 注入引擎日志）：只记阶段与错误类别，不含令牌、配对码、secret、证书指纹。
    var diagnostics: ((String) -> Void)?
    private func diagnose(_ stage: String) { diagnostics?(stage) }

    /// 测试接缝：不起真实事件流（refresh 成功后默认会 startStream 连 Bridge）。
    var streamDisabled = false
    /// 测试接缝：自配对用到的本机管理口与 /pair 调用（缺省走真实 HookClient / BridgeClient）。
    var hookFactory: @Sendable (_ dataDir: String, _ hookPort: Int) -> any HookAdmin = { HookClient(dataDir: $0, hookPort: $1) }
    var pairOverride: (@Sendable (BridgeEndpoint, String, String) async throws -> PairResponse)?
    /// 远程配对的接缝（与 iPhone 端 AppSession 同名同签名）：默认走真实握手探测与配对请求。
    var pairProbe: (@Sendable (BridgeEndpoint) async throws -> String)?
    var pairSend: (@Sendable (BridgeEndpoint, String, String) async throws -> PairResponse)?
    /// 令牌写入钥匙串的接缝（测试可模拟写入失败）。
    var tokenSaver: @Sendable (String) -> Bool = { KeychainStore.save($0, account: KeychainStore.tokenAccount) }
    /// 远程配对单飞；模式切换进行中由切换器置位，配对一律拒绝。
    private(set) var pairing = false
    /// 远程配对的取消代次：配对发起后视图离开即递增，尚未发出的 POST 不再发出，晚到结果不写入。
    private var pairCancelEpoch = 0
    func cancelRemotePairing() { pairCancelEpoch += 1 }
    var modeSwitchInProgress = false
    /// 当前连接模式的只读来源（模式的唯一权威是 EngineSettings，由 AppDelegate 接入；会话不另存）。
    @ObservationIgnored var connectionModeProvider: () -> ConnectionMode = { .local }
    /// SSE 事件源的测试接缝（缺省走真实 BridgeClient.events）。
    @ObservationIgnored var eventsOverride: (@Sendable (Int?) async throws -> AsyncThrowingStream<BridgeEvent, Error>)?
    /// 最近一次 refresh 失败是不是鉴权失败（401 / 403：令牌无效或设备已被撤销）。只有它才需要重新自配对；网络 / 启动时序造成的离线不是。
    private(set) var refreshAuthFailed = false

    /// Bridge 启动后调用：已有令牌 → 先用它刷新（端点只是 host / 端口变化、传输与证书 spki 相同就更新端点后复用令牌）；
    /// 只有没有令牌、证书身份变了、或刷新被鉴权拒绝（401 / 403 / 设备已撤销）才用本机 Hook 密钥签码重新自配对。网络 / 时序离线不新签码，由调用方按退避重试 refresh。
    func ensurePaired(engine: BridgeEngine) async {
        guard engine.settings.connectionMode == .local else { return } // 远程模式不走自配对（I2）
        guard let pf = engine.portFile, let ep = engine.selfEndpoint else { return }
        let want = BridgeEndpoint(host: ep.host, port: ep.port, transport: ep.https ? .https : .http, spkiSha256: ep.spki)
        await ensurePaired(want: want, hookPort: pf.hookPort, dataDir: engine.activeDataDir)
    }

    func ensurePaired(want: BridgeEndpoint, hookPort: Int, dataDir: String) async {
        let sameEndpoint = endpoint == want
        diagnose("ensurePaired 开始（已有令牌：\(token != nil ? "是" : "否")，端点一致：\(sameEndpoint ? "是" : "否")）")
        guard token != nil else { await selfPair(dataDir: dataDir, hookPort: hookPort, endpoint: want); return }
        if !sameEndpoint {
            // host / 端口变了但传输与证书 spki 相同：还是同一个 Bridge，更新端点复用令牌（不重配、不多一个设备）
            guard let old = endpoint, old.transport == want.transport, old.spkiSha256 == want.spkiSha256 else {
                await selfPair(dataDir: dataDir, hookPort: hookPort, endpoint: want)
                return
            }
            KeychainStore.saveEndpoint(want)
            endpoint = want
            diagnose("ensurePaired 端点变化但证书相同，复用令牌")
        }
        let gen = sessionGen
        await refresh()
        guard gen == sessionGen else { return } // 刷新期间已切换 / 忘记配对：过期结果不再触发自配对
        if case .offline = link, refreshAuthFailed { await selfPair(dataDir: dataDir, hookPort: hookPort, endpoint: want) }
    }

    /// 自配对。开始时记下代次；每个等待点之后、任何写入（Keychain、端点、令牌、提权、清理设备）之前复核，
    /// 代次已变（忘记配对、切换模式）时成功与错误一律丢弃，不改连接态。
    private func selfPair(dataDir: String, hookPort: Int, endpoint ep: BridgeEndpoint) async {
        let gen = sessionGen
        link = .connecting
        diagnose("selfPair 开始")
        let hook = hookFactory(dataDir, hookPort)
        let pairCode: String
        do { pairCode = try await hook.issuePairCode().code } catch {
            guard gen == sessionGen else { return }
            diagnose("selfPair hook_issue_failed")
            link = .offline(LText(Self.describe(error)))
            return
        }
        guard gen == sessionGen else { return }
        do {
            let r: PairResponse
            if let f = pairOverride { r = try await f(ep, pairCode, deviceName) } else { r = try await BridgeClient(endpoint: ep, token: nil).pair(code: pairCode, deviceName: deviceName) }
            guard gen == sessionGen else { return }
            if ep.transport == .https, r.spkiSha256 != ep.spkiSha256 {
                diagnose("selfPair spki_mismatch")
                link = .offline(LText(String(localized: "指纹不一致")))
                return
            }
            KeychainStore.save(r.token, account: KeychainStore.tokenAccount)
            KeychainStore.saveEndpoint(ep)
            stopStream() // 换了凭据：旧范围立即失效；拿到新 Bridge 的快照之前，改名一律不发（R-b）
            awaitingFreshState = true
            token = r.token
            endpoint = ep
            diagnose("selfPair 成功")
            // 新配对的设备默认只读；这台 Mac 是 owner 本机，配对后用本机管理口把自己设为可控（失败时界面按只读提示）
            guard gen == sessionGen else { return }
            try? await hook.setPermission(deviceId: r.deviceId, .control)
            guard gen == sessionGen else { return }
            await pruneStaleSelfDevices(hook, keeping: r.deviceId, gen: gen)
            guard gen == sessionGen else { return } // 清理等待期间已切换：不再用当前会话刷新
            await refresh()
        } catch {
            guard gen == sessionGen else { return }
            diagnose("selfPair pair_failed")
            link = .offline(LText(Self.describe(error)))
        }
    }

    /// 这台 Mac 改名（O1-364 ④）：走 Bridge 自改名接口；成功后偏好、设备与本机气泡头即时更新，失败只返回提示。
    var renameOverride: (@Sendable (String) async throws -> DeviceInfo)?
    func renameThisDevice(_ raw: String) async -> LText? {
        guard let name = DeviceNameRules.clean(raw) else { return LText(String(localized: "名字需要 1 到 32 个字，且只能是一行")) }
        guard renameOverride != nil || (endpoint != nil && token != nil) else { return LText(String(localized: "未连接 Bridge，暂时不能改名")) }
        let gen = sessionGen, conn = connectionId, rev = deviceRevision // 请求开始时的会话 / 连接 / 设备版本（O1-364 R4）
        let d: DeviceInfo
        do {
            if let renameOverride { d = try await renameOverride(name) }
            else if let endpoint, let token { d = try await BridgeClient(endpoint: endpoint, token: token).renameSelf(name) }
            else { return LText(String(localized: "未连接 Bridge，暂时不能改名")) }
        } catch {
            if case BridgeError.http(status: 400) = error { return LText(String(localized: "Bridge 不接受这个名字，请换一个")) }
            return LText(String(localized: "改名没有成功：\(Self.describe(error))"))
        }
        // 提交前复核：连接或会话已变（换了 Bridge / 忘记配对）则不写任何本地状态
        guard gen == sessionGen, conn == connectionId else { return LText(String(localized: "改名结果已过期（已切换连接），未保存")) }
        if rev == deviceRevision { device = d; deviceRevision += 1 }
        else { device?.name = d.name; deviceRevision += 1 } // 期间有更新的权限 / 暂停（device 帧）：只采纳名字
        deviceName = d.name
        for (k, c) in commands where c.device?.id == d.id { commands[k]?.device?.name = d.name }
        return nil
    }

    /// 测试接缝：替换 Bridge 的改名请求（参数：线程 targetId、已裁剪的名字，nil 为清除）。
    var titleOverride: (@Sendable (String, String?) async throws -> TitleResult)?
    /// 改名范围：弹层打开时捕获（目标、连接代次、连接的 Bridge），提交前复核（C3）。
    func titleScope(_ targetId: String) -> LedgerScope {
        LedgerScope(targetId: targetId, epoch: sessionGen, bridgeId: connectionId, accountId: nil)
    }
    func titleScopeHeld(_ scope: LedgerScope) -> Bool { !awaitingFreshState && titleScope(scope.targetId) == scope }
    /// 过期提示按结果分三种（§3.3）：提交前失效 → 未保存；已成功后失效 → 已保存在原连接；结果未知 → 可能已保存。
    static var titleNotSaved: String { String(localized: "连接已切换，名字未保存") }
    static var titleSavedOnOldConnection: String { String(localized: "名字已保存在原连接，请切回查看") }
    static var titleUnknownOnOldConnection: String { String(localized: "名字可能已保存，请切回原连接确认") }
    /// 对话改名（#134）：名字的规范化与校验在 Bridge。PUT 前复核范围；成功后经 pullState 权威同步（不直接改本地 target），之后再复核。
    func setTitle(_ scope: LedgerScope, _ raw: String?) async -> (ok: Bool, message: LText) {
        guard titleOverride != nil || (endpoint != nil && token != nil) else { return (false, LText(String(localized: "未配对"))) }
        guard titleScopeHeld(scope) else { return (false, LText(Self.titleNotSaved)) }
        guard canControl else { return (false, LText(Self.readOnlyNote)) }
        let result: TitleResult
        do {
            if let titleOverride { result = try await titleOverride(scope.targetId, raw) }
            else if let endpoint, let token { result = try await BridgeClient(endpoint: endpoint, token: token).setTitle(targetId: scope.targetId, title: raw) }
            else { return (false, LText(String(localized: "未配对"))) }
        } catch {
            guard titleScopeHeld(scope) else { return (false, LText(Self.titleUnknownOnOldConnection)) }
            return (false, LText(String(localized: "改名没有成功：\(Self.describe(error))")))
        }
        switch result {
        case .failed(let status, let code):
            // 401/403 可能是撤销或降权发生在写入之后、回包之前：结果不确定，不能断言未保存。
            // 401/403/5xx 可能是写入之后的复核失败（如库错误）：标题可能已保存，不能断言未保存。
            guard titleScopeHeld(scope) else { return (false, LText((status == 401 || status == 403 || status >= 500) ? Self.titleUnknownOnOldConnection : Self.titleNotSaved)) }
            return (false, LText(Self.titleFailure(status: status, code: code)))
        case .ok(_, let herdr):
            guard titleScopeHeld(scope) else { return (false, LText(Self.titleSavedOnOldConnection)) }
            try? await pullState() // 名字已保存；同步失败不算改名失败，下一帧 targets 会带上
            guard titleScopeHeld(scope) else { return (false, LText(Self.titleSavedOnOldConnection)) }
            return herdr == "synced" ? (true, LText(String(localized: "已保存"))) : (true, LText(String(localized: "名字已保存；Herdr 窗口名未同步")))
        }
    }

    /// 改名失败的固定文案（按错误码；旧 Bridge 无该接口时 404 且无 target_not_found，提示版本过旧）。
    static func titleFailure(status: Int, code: String?) -> String {
        switch code {
        case "invalid_title", "bad_request": return String(localized: "Bridge 不接受这个名字，请换一个")
        case "read_only": return readOnlyNote
        case "target_not_found": return String(localized: "这个对话已不在 Bridge 上")
        default: break
        }
        switch status {
        case 400: return String(localized: "Bridge 不接受这个名字，请换一个")
        case 403, 409: return readOnlyNote
        case 404: return String(localized: "这台 Mac 上的 Bridge 版本过旧，不支持对话改名")
        default: return String(localized: "改名没有成功（\(code ?? "HTTP \(status)")）")
        }
    }

    /// 自配对成功后清掉旧的「这台 Mac」记录：仅按名称收窄——只撤销名称与本机 deviceName 完全相同、未撤销、且不是本次 deviceId 的设备（iPhone 等其他设备绝不碰）。
    /// 这不是按身份识别（Bridge 没有设备身份字段）：同名即视为旧的自配对记录，若用户改过 Mac 名称，旧名称的旧记录不会被清。
    /// 以前每次重配都会多留一条，已经堆起来的也会在下次自配对时被清掉。失败不影响本次配对。
    /// 本机上一次自配对得到的设备 id（偏好里保存）：只有它能证明是「这台 Mac 先前的记录」。显示名相同不是身份（O1-364 R6）。
    static let selfDeviceIdKey = "palmhelm.mac.selfDeviceId"
    /// 只撤销本机记录的上一台设备 id（且它仍有效）；没有记录或身份不明时一律保留，交给用户在设备表里管理。
    /// gen：调用方开始时的连接代次。列表返回后、删除前复核：过期的清理不再撤销任何设备。
    func pruneStaleSelfDevices(_ hook: any HookAdmin, keeping deviceId: String, gen: Int) async {
        let previous = preferences.string(forKey: Self.selfDeviceIdKey)
        preferences.set(deviceId, forKey: Self.selfDeviceIdKey)
        guard let previous, previous != deviceId else { return }
        guard let list = try? await hook.devices(all: false), gen == sessionGen else { return }
        guard list.contains(where: { $0.id == previous && !$0.revoked }) else { return }
        try? await hook.remove(deviceId: previous)
    }

    // ---- 远程配对（远程模式：配对到另一台 Mac）----

    /// 深链 / 二维码的配对链接。
    @discardableResult
    func pairRemote(link pl: PairLink, confirm: ((String) async -> Bool)? = nil) async -> Bool {
        await pairRemote(host: pl.host, port: pl.port, transport: pl.tls ? .https : .http, code: pl.code, expectedSpki: pl.fp, extra: pl.extra, confirm: confirm)
    }

    /// 手动输入的远程配对（只接受 https）。expectedSpki 为链接里的完整摘要；缺失时必须经 confirm 人工确认短指纹。
    @discardableResult
    func pairRemote(host: String, port: Int, code: String, expectedSpki: String? = nil, extra: [BridgeEndpoint] = [], confirm: ((String) async -> Bool)? = nil) async -> Bool {
        await pairRemote(host: host, port: port, transport: .https, code: code, expectedSpki: expectedSpki, extra: extra, confirm: confirm)
    }

    /// 一次配对尝试的资格：开始时捕获（连接代次、取消代次），之后所有关口都用 pairAttemptValid 核对同一份资格。
    private struct PairAttempt {
        let connection: Int
        let cancel: Int
        /// 发起任务被取消的标记：Kit 的 withDeadline 在独立 Task 里跑 probe / send，那里读不到父任务的 Task.isCancelled。
        let taskCancelled: OSAllocatedUnfairLock<Bool>
    }

    /// 尝试资格：同一连接、发起任务未取消、未被视图取消（离开 / 忘记）、未在切换、仍是远程模式。
    private func pairAttemptValid(_ attempt: PairAttempt) -> Bool {
        !attempt.taskCancelled.withLock { $0 } && attempt.cancel == pairCancelEpoch && pairConnectionOwned(attempt)
    }

    /// 连接仍归属本次尝试：同一连接代次、未在切换、仍为远程。切回本机后本机自配对写的 connecting 不属于本次尝试。
    private func pairConnectionOwned(_ attempt: PairAttempt) -> Bool {
        attempt.connection == connectionEpoch && !modeSwitchInProgress && connectionModeProvider() == .remote
    }

    /// 未提交地结束尝试：连接仍归属本次尝试且仍是 connecting 时收束为未配对（单飞保证这个 connecting 是本次写的）；不覆盖切换后或他处写入的状态。
    private func abandonPairAttempt(_ attempt: PairAttempt) {
        guard pairConnectionOwned(attempt), link == .connecting else { return }
        link = .notPaired
    }

    private func pairRemote(host: String, port: Int, transport: Transport, code: String, expectedSpki: String?, extra: [BridgeEndpoint], confirm: ((String) async -> Bool)?) async -> Bool {
        // 排队后、尚未进入时已被取消：零请求，不改连接态
        guard !Task.isCancelled else { return false }
        // 模式不对或已配对时直接拒绝，不改连接态（本机模式下不能把 link 写成远程的离线）
        // 凭据未装载时 isPaired 不可信（旧令牌可能还在读取中）：先不发任何请求
        guard !pairing, !modeSwitchInProgress, credentialsLoaded, connectionModeProvider() == .remote, !isPaired else { return false }
        guard !host.isEmpty, !host.contains(where: \.isWhitespace), (1...65535).contains(port) else {
            link = .offline(LText(String(localized: "地址或端口不正确，未发送配对码"))); return false
        }
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            link = .offline(LText(String(localized: "配对码需要 6 位数字"))); return false
        }
        // 远程只接受 https（包括回环与深链附带的所有候选）
        guard transport == .https, !extra.contains(where: { $0.transport != .https }) else {
            link = .offline(LText(String(localized: "远程 Mac 需开启 https，未发送配对码"))); return false
        }
        if let expectedSpki, !KeychainStore.isValidPin(expectedSpki) {
            link = .offline(LText(String(localized: "证书指纹格式不正确，未发送配对码"))); return false
        }
        if expectedSpki == nil, confirm == nil {
            link = .offline(LText(String(localized: "这台 Mac 没有提供证书指纹，无法确认身份，未发送配对码"))); return false
        }
        pairing = true; defer { pairing = false }
        let attempt = PairAttempt(connection: connectionEpoch, cancel: pairCancelEpoch, taskCancelled: OSAllocatedUnfairLock(initialState: false))
        let primary = BridgeEndpoint(host: host, port: port, transport: transport)
        link = .connecting
        let name = deviceName
        let outcome = await withTaskCancellationHandler { await PairRoute.pair(
            candidates: [primary] + extra, expectedSpki: expectedSpki,
            probeDeadline: BridgeAPI.Deadline.pairProbe, sendDeadline: BridgeAPI.Deadline.pairSend,
            probe: { [pairProbe] ep in
                // 资格失效即停：不再探测后面的地址
                guard self.pairAttemptValid(attempt) else { throw CancellationError() }
                if let pairProbe { return try await pairProbe(ep) }
                return try await BridgeClient.probe(host: ep.host, port: ep.port)
            },
            confirm: { spki in
                // 链接带完整摘要时，PairRoute 已在 confirm 之前按实际握手比对过，不需要人工确认
                if expectedSpki != nil { return self.pairAttemptValid(attempt) }
                // 展示确认之前核对资格：资格已失效（离开、取消、切换）时不展示
                guard self.pairAttemptValid(attempt), let short = SPKI.shortFingerprint(spkiSha256: spki), let confirm else { return false }
                let answer = await confirm(short)
                return answer && self.pairAttemptValid(attempt) // 确认返回后再核对
            },
            send: { [pairSend] ep in
                // 真正发 POST 之前复核：过期的配对码不能再消耗、不能在 Mac B 创建设备
                guard self.pairAttemptValid(attempt) else { throw CancellationError() }
                if let pairSend { return try await pairSend(ep, code, name) }
                return try await BridgeClient(endpoint: ep, token: nil).pair(code: code, deviceName: name)
            },
            reportedSpki: { $0.spkiSha256 })
        } onCancel: { [taskCancelled = attempt.taskCancelled] in taskCancelled.withLock { $0 = true } }
        guard pairAttemptValid(attempt) else { // 期间忘记配对 / 切换模式 / 视图离开 / 任务取消：过期结果一律不写
            abandonPairAttempt(attempt)
            return false
        }
        let success: PairRoute.Success<PairResponse>
        switch outcome {
        case .success(let s): success = s
        case .failure(.resultUnknown):
            link = .offline(LText(String(localized: "可能已配对但未收到结果：请在 Mac 设备列表核对，并重新生成配对码")))
            return false
        case .failure(.unreachable(let tried)):
            let where_ = tried.isEmpty ? "" : String(localized: "（试过：\(tried.joined(separator: "、"))）")
            link = .offline(LText(String(localized: "这台 Mac 的地址都连不上\(where_)。请确认两台 Mac 在同一网络，或都开着 Tailscale")))
            return false
        case .failure(.stopped(let error)):
            switch error as? PairRoute.PairRouteError {
            case .fingerprintMismatch?: link = .offline(LText(String(localized: "广播的证书指纹与实际连接不一致，已放弃")))
            case .notConfirmed?: link = .offline(LText(String(localized: "指纹未确认，未发送配对码")))
            case .reportedFingerprintMismatch?: link = .offline(LText(String(localized: "Bridge 回报的指纹与连接证书不一致，已放弃")))
            case .reportedFingerprintMissing?: link = .offline(LText(String(localized: "Bridge 没有回报证书指纹，无法核对，已放弃")))
            case nil: link = .offline(LText(Self.describe(error)))
            }
            return false
        }
        // 令牌先写入钥匙串，成功才提交端点与内存令牌：写失败时不留下指向未保存令牌的端点
        let ep = success.endpoint, r = success.response
        guard tokenSaver(r.token) else {
            link = .offline(LText(String(localized: "令牌无法写入钥匙串")))
            return false
        }
        KeychainStore.saveEndpoint(ep)
        token = r.token
        endpoint = ep
        diagnose("remotePair 成功")
        // 凭据已提交，首次同步属于连接本身：不随发起任务（设置页）取消。否则 GET state 以 CancellationError 早退，
        // link 停在 connecting，而 AppBoot 只重试 offline / notPaired。
        await withTaskCancellationHandler {
            await Task {
                // 排队期间可能已断开 / 切换：入场时连接不再归属本次尝试就不同步，避免以新代次重开旧连接的事件流
                guard self.pairConnectionOwned(attempt) else { return }
                await self.refresh()
            }.value
        } onCancel: { [taskCancelled = attempt.taskCancelled] in taskCancelled.withLock { $0 = true } }
        return pairAttemptValid(attempt) // 期间已取消或切换：结果已提交，但本次调用不再报告成功
    }

    // ---- 审批 ----
    private func mergeApproval(_ a: ApprovalView) {
        if let old = approvals[a.id], old.status != ApprovalStatus.pending.rawValue, a.status == ApprovalStatus.pending.rawValue { return }
        approvals[a.id] = a
        restoreArchivedForWork(target(forApproval: a)?.id) // 新待答立即恢复可见（只走正证据路径）
    }

    /// 最近一次决定的反馈（卡片提交后会消失，所以反馈独立于卡片；10 秒后自动清除）。
    var lastDecisionNote: LText?
    /// 这条反馈是不是警示（卡被别处处理 / 过期 / 撤回），界面据此换色，不显示成“成功”的绿色。
    var lastDecisionWarn = false
    private var noteClear: Task<Void, Never>?
    private func note(_ s: LText, warn: Bool = false) {
        lastDecisionNote = s
        lastDecisionWarn = warn
        noteClear?.cancel()
        noteClear = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { lastDecisionNote = nil } }
    }

    /// 测试接缝：截获决定（不走网络）。
    var decideOverride: (@Sendable (ApprovalView, ApprovalDecision) async -> Void)?
    func decide(_ a: ApprovalView, _ decision: ApprovalDecision, message: String? = nil) async {
        // 普通审批过期后不再发请求（O1-341 R3）：提交那一刻按当前时刻判断（生产里 currentDate 就是真实时钟，测试可注入）
        if let why = Self.submitBlock(a, current: approvals[a.id], now: currentDate) { decideError[a.id] = why; return }
        if let o = decideOverride { await o(a, decision); return }
        guard let endpoint, let token, !deciding.contains(a.id) else { return }
        guard canControl else { decideError[a.id] = LText(Self.readOnlyNote); return } // 只读本地先拦（Bridge 仍会 403）
        if let message, ApprovalMessage.isTooLong(message) { decideError[a.id] = LText(String(localized: "原因超过 \(ApprovalMessage.maxUTF16) 字，请缩短")); return }
        let gen = sessionGen
        deciding.insert(a.id); defer { if gen == sessionGen { deciding.remove(a.id) } }
        decideError[a.id] = nil
        do {
            let r = try await BridgeClient(endpoint: endpoint, token: token).decide(approvalId: a.id, decision: decision, message: message)
            guard gen == sessionGen else { return }
            var done = a; done.status = r.status; approvals[a.id] = done
            if decision == .deny {
                let gave = message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                note(LText(!gave ? String(localized: "已拒绝") : r.messageProjected == true ? String(localized: "已拒绝 · 原因未按原文提交，随决定提交的是「\(r.message ?? String(localized: "Palmhelm 拒绝"))」") : r.message == nil ? String(localized: "已拒绝 · 这个 Bridge 版本不转达原因") : String(localized: "已拒绝 · 原因已随决定提交（由钩子转达，不保证 agent 已读到）")))
            } else { note(LText(String(localized: "已允许一次"))) }
        } catch {
            await reloadApprovals()
            guard gen == sessionGen else { return }
            if approvals[a.id]?.isPending(now: currentDate) == true { decideError[a.id] = LText(String(localized: "提交失败 · \(Self.describe(error))")) }
            else { note(LText(String(localized: "这一条已在别处处理、过期或撤回")), warn: true) } // 卡已撤下：卡外说明（A1-107 F3）
        }
    }

    // MARK: 提问与计划（与审批同链路：只读本地先拦，失败以 Bridge 为准重拉）

    /// 终端镜像：只读拉取当前视口；失败返回 nil。
    func screen(_ threadId: String) async -> ScreenSnapshot? {
        guard let endpoint, let token else { return nil }
        return try? await BridgeClient(endpoint: endpoint, token: token).screen(targetId: threadId)
    }

    func approvalDetail(_ id: String) async -> ApprovalDetail? {
        guard let endpoint, let token else { return nil }
        return try? await BridgeClient(endpoint: endpoint, token: token).approvalDetail(id: id)
    }

    @discardableResult
    func answer(_ a: ApprovalView, _ answers: [QuestionAnswer]) async -> Bool {
        await submitPending(a, op: "answer", { try await $0.answer(approvalId: a.id, answers: answers) }) { _ in LText(String(localized: "答案已提交（由钩子转达给 agent）")) }
    }

    @discardableResult
    func revise(_ a: ApprovalView, message: String?) async -> Bool {
        if let message, ApprovalMessage.isTooLong(message) { decideError[a.id] = LText(String(localized: "理由超过 \(ApprovalMessage.maxUTF16) 字，请缩短")); return false }
        return await submitPending(a, op: "revise", { try await $0.revise(approvalId: a.id, message: message) }) { r in LText(ApprovalText.reviseHint(r.hint) ?? String(localized: "已打回，理由已随决定提交")) }
    }

    @discardableResult
    func release(_ a: ApprovalView) async -> Bool {
        await submitPending(a, op: "release", { try await $0.release(approvalId: a.id) }) { _ in LText(String(localized: "已交回终端")) }
    }

    /// 提交前的有效性：传入的请求与当前登记的同一条都必须存在且按此刻仍是待答；当前事实缺失（已移除）按不可提交，不当成有效。
    /// 返回 nil 表示可以提交，否则是给用户的固定说明：已按时刻过期用“已过期”，其余（已在别处处理、被撤回、已不在登记里）用统一说法。
    static func submitBlock(_ a: ApprovalView, current: ApprovalView?, now: Date) -> LText? {
        if !a.isPending(now: now) { return LText(String(localized: "这条审批已过期，不能再处理")) }
        guard let current, current.isPending(now: now) else { return LText(String(localized: "这一条已在别处处理、过期或撤回")) }
        return nil
    }

    // MARK: 请求草稿与提交前复核（D4）
    /// 连接身份（Bridge 编号）：请求草稿按「连接身份 + requestId」保存，换 Bridge 不会串。
    var connectionId: String { state?.bridge?.id ?? "local" }
    func requestKey(_ a: ApprovalView) -> String { "\(connectionId)~\(a.id)" }

    /// 提问草稿：Session 内存；切线程、进出请求详情、会话 / 用量、换主题都不丢。
    private(set) var questionDrafts: [String: QuestionDraft] = [:]
    func questionDraft(_ a: ApprovalView) -> QuestionDraft? { questionDrafts[requestKey(a)] }
    func setQuestionDraft(_ d: QuestionDraft?, for a: ApprovalView) {
        guard ownsRequest(a) else { return } // 请求已不在：迟到的加载不把草稿写回
        questionDrafts[requestKey(a)] = d
    }
    /// 计划打回理由 / 审批拒绝理由（输入中的文字）：同样按「连接身份 + requestId」。
    enum ReasonKind: String { case planRevise, approvalDeny }
    private(set) var requestReasons: [String: String] = [:]
    func reason(_ a: ApprovalView, _ kind: ReasonKind) -> String { requestReasons["\(requestKey(a))|\(kind.rawValue)"] ?? "" }
    func setReason(_ text: String, _ a: ApprovalView, _ kind: ReasonKind) {
        guard ownsRequest(a) else { return }
        requestReasons["\(requestKey(a))|\(kind.rawValue)"] = text.isEmpty ? nil : text
    }
    /// 请求还在列表里（含刚被决定、卡马上撤下的瞬间）才允许写草稿。
    private func ownsRequest(_ a: ApprovalView) -> Bool { approvals[a.id] != nil }

    /// 清掉已不存在的请求的草稿（处理 / 过期 / 撤回后）；卡没了就不再保留。
    func pruneRequestDrafts() {
        let live = Set(approvals.values.filter { $0.status == ApprovalStatus.pending.rawValue }.map { "\(connectionId)~\($0.id)" })
        questionDrafts = questionDrafts.filter { live.contains($0.key) }
        requestReasons = requestReasons.filter { live.contains(String($0.key.split(separator: "|", maxSplits: 1)[0])) }
    }

    enum RequestSubmit: Equatable, Error { case submitted, kept(LText), changed([ProjectedQuestion]), busy }
    private var submittingRequests: Set<String> = []

    /// 提交前复核（提问 / 计划共用的入口）：同一请求同时只跑一次（切视图重建卡片也不会重复提交）；连接在线、权限最新、
    /// 重新取请求确认仍 pending 且未过期；整个过程中连接代次与连接身份不变。失败一律保留草稿、不自动重放。返回新取到的详情。
    private func recheck(_ a: ApprovalView) async -> Result<ApprovalDetail, RequestSubmit> {
        let gen = sessionGen, conn = connectionId
        guard isPaired || sendOverride != nil else { return .failure(.kept(LText(String(localized: "还没有配对，草稿已保留")))) }
        guard link == .connected else { return .failure(.kept(LText(String(localized: "离线 · 草稿已保留，重连后再提交")))) }
        do { try await pullState() } catch { return .failure(.kept(LText(String(localized: "没能刷新连接状态，草稿已保留，请稍后重试")))) } // 刷新权限与列表：失败就停，不吞
        guard gen == sessionGen, conn == connectionId, link == .connected else { return .failure(.kept(LText(String(localized: "连接已变化，草稿已保留，请稍后重试")))) }
        guard canControl else { return .failure(.kept(LText(Self.readOnlyNote))) }
        guard let fresh = await approvalDetailForRecheck(a.id) else { return .failure(.kept(LText(String(localized: "没能重新取到内容，草稿已保留，请稍后重试")))) }
        // 最后一个 await 之后再核一次连接 / 权限 / 代次：取详情期间断线或被降为只读，不能凭先前的检查提交
        guard gen == sessionGen, conn == connectionId, link == .connected else { return .failure(.kept(LText(String(localized: "连接已变化，草稿已保留，请稍后重试")))) }
        guard canControl else { return .failure(.kept(LText(Self.readOnlyNote))) }
        let nowMs = Int(currentDate.timeIntervalSince1970 * 1000)
        guard fresh.view.status == ApprovalStatus.pending.rawValue, fresh.view.expiresT > nowMs else { return .failure(.kept(LText(String(localized: "这一条已处理、过期或撤回，没有提交")))) }
        return .success(fresh)
    }

    /// 测试接缝：重拉权威审批列表（缺省走真实 BridgeClient）。
    var approvalsListOverride: (@Sendable () async -> [ApprovalView]?)?
    /// 测试接缝：answer / revise / release 的传输（参数是操作名）。
    var pendingCallOverride: (@Sendable (String) async throws -> DecisionResponse)?
    /// 测试接缝：重新取请求详情（缺省走真实 BridgeClient）。
    var approvalDetailOverride: (@Sendable (String) async -> ApprovalDetail?)?
    private func approvalDetailForRecheck(_ id: String) async -> ApprovalDetail? {
        if let f = approvalDetailOverride { return await f(id) }
        return await approvalDetail(id)
    }

    /// 提交提问答案：先复核（含题目与草稿一致），再走 answer（沿用 submitPending 的单飞与 sessionGen）。
    func submitQuestion(_ a: ApprovalView, _ d: QuestionDraft) async -> RequestSubmit {
        guard d.answers != nil else { return .kept(LText(String(localized: "还有题没答完"))) }
        let key = requestKey(a)
        guard !submittingRequests.contains(key) else { return .busy }
        submittingRequests.insert(key); defer { submittingRequests.remove(key) }
        switch await recheck(a) {
        case .failure(let r): return r
        case .success(let fresh):
            guard let qs = fresh.body?.questions, !qs.isEmpty else { return .kept(LText(String(localized: "没能重新取到问题，草稿已保留，请稍后重试"))) }
            guard qs == d.questions else { return .changed(qs) }
            guard let answers = d.answers else { return .kept(LText(String(localized: "还有题没答完"))) }
            return await answer(a, answers) ? .submitted : .kept(decideError[a.id] ?? LText(String(localized: "提交失败，草稿已保留")))
        }
    }

    /// 提交计划打回：同样先复核，再走 revise。
    func submitRevise(_ a: ApprovalView, message: String?) async -> RequestSubmit {
        if let message, ApprovalMessage.isTooLong(message) { return .kept(LText(String(localized: "理由超过 \(ApprovalMessage.maxUTF16) 字，请缩短"))) }
        let key = requestKey(a)
        guard !submittingRequests.contains(key) else { return .busy }
        submittingRequests.insert(key); defer { submittingRequests.remove(key) }
        switch await recheck(a) {
        case .failure(let r): return r
        case .success: return await revise(a, message: message) ? .submitted : .kept(decideError[a.id] ?? LText(String(localized: "提交失败，理由已保留")))
        }
    }

    private func submitPending(_ a: ApprovalView, op: String, _ call: @Sendable (BridgeClient) async throws -> DecisionResponse, done: (DecisionResponse) -> LText) async -> Bool {
        guard (endpoint != nil && token != nil) || pendingCallOverride != nil, !deciding.contains(a.id) else { return false }
        guard canControl else { decideError[a.id] = LText(Self.readOnlyNote); return false }
        // 提交那一刻按当前时刻与当前请求事实复核：E 前取到的操作闭包在 E 后执行也不进任何传输（answer / revise / release 共用）。
        if let why = Self.submitBlock(a, current: approvals[a.id], now: currentDate) { decideError[a.id] = why; return false }
        let gen = sessionGen // 期间忘记配对 / 换了连接：旧结果一律不写（A1-099 F2）
        deciding.insert(a.id); defer { if gen == sessionGen { deciding.remove(a.id) } }
        decideError[a.id] = nil
        do {
            let r: DecisionResponse
            if let o = pendingCallOverride { r = try await o(op) } else if let endpoint, let token { r = try await call(BridgeClient(endpoint: endpoint, token: token)) } else { return false }
            guard gen == sessionGen else { return false }
            var x = a; x.status = r.status; approvals[a.id] = x
            note(done(r))
            return true
        } catch {
            guard gen == sessionGen else { return false }
            await reloadApprovals()
            guard gen == sessionGen else { return false }
            // 卡片已按 Bridge 状态撤下：说明放到卡外（主窗口与铃铛都显示），否则写进已不存在的卡里没人看得到（A1-107 F3）
            guard approvals[a.id]?.isPending(now: currentDate) == true else { note(LText(String(localized: "这一条已在别处处理、过期或撤回")), warn: true); return false }
            if case BridgeError.http(409) = error { decideError[a.id] = LText(String(localized: "已在别处处理、过期或撤回")) }
            else if case BridgeError.http(400) = error { decideError[a.id] = LText(String(localized: "答案不完整，或选项已不可用；草稿已保留")) }
            else { decideError[a.id] = LText(String(localized: "提交失败 · \(Self.describe(error))，草稿已保留")) }
            return false
        }
    }

    @discardableResult
    func reloadApprovals() async -> Bool {
        guard (endpoint != nil && token != nil) || approvalsListOverride != nil else { return false }
        let gen = sessionGen // 补拉期间忘记配对 / 换了连接：旧列表不写（A1-100 F1）
        let fetched: [ApprovalView]?
        if let f = approvalsListOverride { fetched = await f() } else if let endpoint, let token { fetched = try? await BridgeClient(endpoint: endpoint, token: token).approvals() } else { fetched = nil }
        guard let list = fetched, gen == sessionGen else { return false }
        let ids = Set(list.map(\.id))
        for (id, a) in approvals where a.status == ApprovalStatus.pending.rawValue && !ids.contains(id) { approvals[id] = nil }
        for a in list { mergeApproval(a) }
        pruneRequestDrafts()
        return true
    }

    // ---- 指令与进度 ----
    /// 命令尚未出现时到达的 progress 事实（O1-052 N1）：命令出现后经 Kit 物化；会话代次变化时清空。
    private var pendingProgress = PendingProgress()
    /// 会话内的 SSE 事实序号（每条 progress / inbound 帧递增）：快照请求发起时记下当时的值，之后只重放序号更大的帧（O1-054）。
    private var sseSeq = 0
    /// 每个 key 最近一次有效 SSE 事实的序号（#89）：快照读取期间出现序号更大的事实，快照合并不得把较新的本地状态拉回去。
    /// 未知 key 的 progress 在到达时即记录，不因之后的快照吸收或重放而丢失（O1-056）。
    private var lastFactSeq: [String: Int] = [:]
    /// 当前消息窗口（#89 片 A）：有界的“最新阅读窗可补行”指令集合。只在成员 / 暂停分类真实变化时写（值相同不发布）；
    /// commands 字典仍是精确关联缓存，不因窗口淘汰而清理。随 commands 一起在换连接 / 换账号时清空。
    private(set) var commandWindow = CommandWindow()
    private func admitToWindow(_ c: ApiCommand) {
        var w = commandWindow
        if w.admit(c) { commandWindow = w }
    }

    /// 记录 key 的最近事实序号；无命令的 key 超过 PendingProgress 容量时淘汰序号最小者（ponytail: 上限与待物化表相同，超限的旧快照才可能误清）。
    private func recordFact(_ key: String) {
        lastFactSeq[key] = sseSeq
        let unowned = lastFactSeq.filter { commands[$0.key] == nil }
        guard unowned.count > PendingProgress.capacity else { return }
        if let oldest = unowned.min(by: { $0.value < $1.value }) { lastFactSeq[oldest.key] = nil }
    }

    /// 增量（SSE inbound）：较新的非倒退事实；不带四键的旧帧不清除既有组。命令出现时物化尚未消费的 progress 事实。
    private func mergeCommand(_ c: ApiCommand) {
        sseSeq += 1
        let before = commands[c.key]
        let next = CommandMerge.materialized(CommandMerge.merged(old: before, new: c), pending: pendingProgress.take(c.key, after: nil))
        commands[c.key] = next
        inflight[c.key] = CommandMerge.inflight(after: next, current: inflight[c.key])
        outgoingTracker.observe(next, inflight: inflight[c.key]) // 送达证据在事实采纳处记录，不依赖视图读取时机（A-F1）
        // 同内容的活动成员再次到来也是新的存在事实：记序号（请求期间的 HTTP 重建据此保留），窗外的同时准入（A-F2）。已在窗不重复发布。
        let changed = next != before
        if changed || CommandWindow.isReconfirmable(next) { recordFact(c.key) }
        if commandWindow.needsAdmission(next, changed: changed) { admitToWindow(next) }
        restoreArchivedForWork(next.targetId) // 新工作立即恢复可见（只走正证据路径）
    }

    /// 权威快照（HTTP）：快照读取期间若该 key 已被 SSE 更新则保留本地队列组；不带四键即清除（#89 F1、F3）。
    /// HTTP 合并不记为 SSE 事实；命令出现时物化尚未消费的 progress 事实（其序号在到达时已记录）。
    private func mergeSnapshotCommand(_ c: ApiCommand, touchedDuringRequest: Bool, seqStart: Int) {
        let merged = CommandMerge.snapshotMerged(old: commands[c.key], new: c, touchedDuringRequest: touchedDuringRequest)
        // 只重放请求发起之后到达的 progress 帧（更早的已被快照覆盖）；帧的事实序号已在到达时记录，这里不再计数（O1-054、O1-056）。
        let next = CommandMerge.materialized(merged, pending: pendingProgress.take(c.key, after: seqStart))
        commands[c.key] = next
        inflight[c.key] = CommandMerge.inflight(after: next, current: inflight[c.key])
        outgoingTracker.observe(next, inflight: inflight[c.key])
    }

    /// 测试入口：按 SSE inbound 的顺序应用（与线上同一条路径）。
    func applyInboundForTest(_ c: ApiCommand) { mergeCommand(c) }

    private func applyProgress(key: String, state: String, reason: String?, queue: QueueMeta? = nil, stop: StopDisposition? = nil) {
        sseSeq += 1
        if let c = commands[key], c.reason == "queue_expired" || c.reason == "queue_expired_uncertain" {
            inflight[key] = nil
            return
        }
        guard let c = commands[key] else {
            // 命令尚未出现（O1-052 N1）：保存完整事实，命令出现时物化；在途的兼容值不与之冲突（物化后由派生决定）。
            pendingProgress.put(ProgressPayload(eventKey: key, state: state, reason: reason, queue: queue, stop: stop), seq: sseSeq)
            outgoingTracker.observeProgress(key: key, state: state, phase: queue?.phase) // 每个被接受的待物化帧各记送达证据（A-F1）：物化只留最后结果，帧也可能被有界淘汰
            recordFact(key)
            inflight[key] = CommandMerge.isInFlight(state: state) ? state : nil
            return
        }
        // 已知命令：经同一 Kit 出口更新（规则 A 与 B），在途表随最终命令派生（规则 C）。只有真正改变命令时才记为 SSE 事实。
        let next = CommandMerge.progressed(c, state: state, reason: reason, queue: queue, stop: stop)
        if next != c { commands[key] = next; recordFact(key); admitToWindow(next) }
        inflight[key] = CommandMerge.inflight(after: commands[key] ?? c, current: inflight[key])
        outgoingTracker.observe(commands[key] ?? c, inflight: inflight[key])
        confirmNativeIfPending(key)
    }

    /// 测试入口：按 SSE progress 帧的顺序应用（与线上同一条路径）。
    func applyProgressForTest(key: String, state: String, reason: String?, queue: QueueMeta? = nil, stop: StopDisposition? = nil) { applyProgress(key: key, state: state, reason: reason, queue: queue, stop: stop) }
    /// 测试入口：把一帧已解码的 SSE 事件交给线上同一个分发（progress / inbound）。
    func applyStreamEventForTest(_ ev: BridgeEvent) {
        switch ev {
        case .progress(let p): applyProgress(key: p.eventKey, state: p.state, reason: p.reason, queue: p.queue, stop: p.stop)
        case .inbound(let c): mergeCommand(c)
        default: break
        }
    }

    /// 原生插话的「并入未验证」只在权威快照的 native_delivered 里（progress 的 finished 不带 reason）：待确认时由一个补拉任务有界确认。
    /// 每条指令同一时间只有一个任务；读取总次数（含失败）最多 3 次；重复 progress 不放大次数。
    private func confirmNativeIfPending(_ key: String) {
        guard let c = commands[key], SendTimingRules.isNativePending(c), nativeConfirmTasks[key] == nil, nativeConfirmAttempts[key, default: 0] < 3 else { return }
        let gen = sessionGen
        nativeConfirmTasks[key] = Task { [weak self] in await self?.runNativeConfirmation(key, gen: gen) }
    }
    /// 读取间隔：第 n 次读取前等待；缺省 1 / 2 / 4 秒，测试可替换。
    @ObservationIgnored var nativeConfirmDelay: (Int) -> Duration = { .seconds(1 << $0) }
    @ObservationIgnored private var nativeConfirmAttempts: [String: Int] = [:]
    @ObservationIgnored private var nativeConfirmTasks: [String: Task<Void, Never>] = [:]

    /// 拿到权威结果（命令不再待确认）、代次变化或任务被取消即停；瞬时读取失败不停，退避后继续直到上限。
    private func runNativeConfirmation(_ key: String, gen: Int) async {
        defer { if gen == sessionGen { nativeConfirmTasks[key] = nil } }
        while gen == sessionGen, !Task.isCancelled, nativeConfirmAttempts[key, default: 0] < 3 {
            let n = nativeConfirmAttempts[key, default: 0]
            nativeConfirmAttempts[key] = n + 1
            try? await Task.sleep(for: nativeConfirmDelay(n))
            guard gen == sessionGen, !Task.isCancelled else { return }
            _ = try? await pullState()
            guard gen == sessionGen, let c = commands[key] else { return }
            if !SendTimingRules.isNativePending(c) { nativeConfirmAttempts[key] = nil; return }
        }
    }

    /// 新发送协议的判据：快照里 target 带 capabilities 字段；缺字段 = 旧 Bridge，不发 mode。
    var supportsSendTiming: Bool { state?.targets.contains { $0.supportsSendTiming } ?? false }

    private func merge(_ items: [HistoryItem]) {
        var byseq = Dictionary(uniqueKeysWithValues: history.map { ($0.seq, $0) })
        for it in items { byseq[it.seq] = it }
        history = byseq.values.sorted { $0.seq < $1.seq }.suffix(500)
    }

    // ---- 事件流 ----
    func startStream() {
        guard !streamDisabled, streamTask == nil, let endpoint, let token else { return }
        streamGen += 1
        let gen = streamGen
        streamTask = Task { [weak self] in
            var since: Int? = self?.history.last?.seq
            while !Task.isCancelled {
                guard let self, gen == self.streamGen else { return }
                self.streamState = String(localized: "连接中")
                do {
                    let client = BridgeClient(endpoint: endpoint, token: token)
                    let source: AsyncThrowingStream<BridgeEvent, Error>
                    if let override = self.eventsOverride { source = try await override(since) } else { source = try await client.events(since: since) }
                    for try await ev in source {
                        guard gen == self.streamGen else { return }
                        self.streamState = String(localized: "在线")
                        switch ev {
                        case .ready:
                            // 重连后的 ready：只有拉到权威 state 才恢复在线；失败保持离线（启动轮询会有界重试 refresh）
                            if case .offline = self.link {
                                do { try await self.pullState(); if gen == self.streamGen { self.link = .connected } }
                                catch { if gen == self.streamGen { self.link = .offline(LText(String(localized: "重连后同步失败 · \(Self.describe(error))"))) } }
                            }
                            if let id = self.openThread { Task { await self.loadTranscriptLatest(id) } } // 断线期间的变化不补发：每次 ready 补拉打开的线程
                        case .outbox(let item):
                            self.merge([item]); since = item.seq
                            if item.text.hasPrefix("switched:") { try? await self.pullState() } // 切换完成的回执：刷新绑定
                        case .progress(let p): self.applyProgress(key: p.eventKey, state: p.state, reason: p.reason, queue: p.queue, stop: p.stop)
                        case .inbound(let c): self.mergeCommand(c)
                        case .approval(let a): self.mergeApproval(a)
                        case .targets(let t, let spaces, let blocked, let fresh, let observation): self.applyTargetsFrame(t, spaces: spaces, currentBlocked: blocked, currentBlockedFresh: fresh, observation: observation); self.fixSelection(); self.evaluateRecommendation() // 结构变化重新评估（A1-136 F2-R2）
                        case .resetRequired: await self.refresh(); since = self.history.last?.seq
                        case .device(let d): self.applyDeviceFrame(d) // 本设备权限 / 暂停变化（device 帧）：即时更新
                        case .transcriptChanged(let c):
                            self.transcriptChanged(c)
                        case .sync, .ping, .unknown: break
                        }
                    }
                    // 服务端正常结束了流：同样按断开处理（connecting 时也标明，稍后完成的 refresh 若仍有效会再置 connected）
                    if gen == self.streamGen, self.link == .connected || self.link == .connecting { self.link = .offline(LText(String(localized: "事件流结束，重试中"))) }
                    if gen == self.streamGen { self.workingSince = [:] } // 流结束：计时从下次观测重新起算
                } catch {
                    guard gen == self.streamGen else { return }
                    if self.isRemoteAuthLost(error) { self.handleRemoteAuthLost(); return } // 鉴权失效：停流，不再按断线重试
                    self.workingSince = [:]
                    self.streamState = String(localized: "断开，重试中")
                    if self.link == .connected { self.link = .offline(LText(String(localized: "事件流断开，重试中"))) }
                }
                await self.streamRetrySleep(.seconds(3))
            }
        }
    }

    func stopStream() {
        streamGen += 1
        sessionGen += 1
        spaceInvalidate() // 断开或换连接：待应用的空间上移与旧代次的有效判定一并失效（#98 F3）
        archivedPaging = [:] // 归档历史属于当前 Bridge 与连接：断开即清空，在途返回由代次核对丢弃（R2）
        pendingProgress.clear(); sseSeq = 0; lastFactSeq = [:]
        closeReminders() // 停机 / 忘记配对 / 换连接：本次提醒展示随连接结束（R2）
        withdrawnOffers = [:] // 撤回的原文提示只属于当前连接（O1-331 R2）
        commandNotes = [:]; commandBusy = []; commandRequests = []
        for t in nativeConfirmTasks.values { t.cancel() } // 原生确认的补拉属于旧代次：取消并清零次数
        nativeConfirmTasks = [:]; nativeConfirmAttempts = [:]
        hookSettings = [:]
        hooksConnection = nil
        hookSequences = [:]
        searching = false // 旧代次的搜索结果已按代次丢弃，在途标记随之放掉
        leaveLocated() // 停机 / 换连接：定位与 pin 一并退出，迟到的定位响应因代次变化被丢弃
        deciding = [] // 旧代次的提交不再归还 busy（defer 按代次判断），这里统一放掉，断连后可重试
        for (k, v) in reminderSends where v.busy { reminderSends[k] = ReminderSend(sendId: v.sendId, busy: false, blocked: nil, interrupted: true) } // 提醒卡发送中断连：放掉 busy，标「结果未知」，旧任务返回时因代次变化不再覆盖
        streamTask?.cancel()
        streamTask = nil
        streamState = String(localized: "未连接")
        for k in transcripts.keys { transcripts[k]?.abandonRequests() }
        transcriptRequestBook.removeAll()
        setTranscriptActive(nil) // 连接换代：激活读取停止（#88 S4） // 旧代次的读取不再写入，busy 归还（A1-121 F3）
        workingSince = [:]
    }

    /// Bridge 停了：断流并把连接态标为离线，旧的目标/审批快照保留但界面按未连接表达。
    func disconnect(reason: LText) {
        stopStream()
        link = .offline(reason)
    }

    func refresh() async {
        guard endpoint != nil, token != nil else { link = .notPaired; return }
        let gen = sessionGen
        link = .connecting
        refreshAuthFailed = false
        do {
            try await pullState()
            guard gen == sessionGen else { return } // 期间已断开/换会话：不改连接态、不起新流
            link = .connected
            diagnose("refresh 成功")
            startStream()
        } catch {
            guard gen == sessionGen, !(error is CancellationError) else { return }
            if case BridgeError.http(let code) = error, code == 401 || code == 403 {
                refreshAuthFailed = true // 令牌无效 / 设备已撤销：需要重新自配对（远程的会话清理已在 fetchState 完成）
            }
            link = .offline(LText(Self.describe(error)))
            diagnose("refresh_failed")
        }
    }

    /// 远程模式下的鉴权失效（GET state 或 SSE 握手 / 流中的 401 / 403）。写接口的 403 是权限不足，不走这里。
    private func isRemoteAuthLost(_ error: Error) -> Bool {
        guard connectionModeProvider() == .remote, case BridgeError.http(let code) = error else { return false }
        return code == 401 || code == 403
    }

    /// 远程 Mac 已移除本机或令牌失效：清掉令牌、端点、审批与设备，停止事件流（不再每 3 秒重连），由用户重新配对。
    /// 降权（权限变为只读）不是撤销，不进入这里。
    private func handleRemoteAuthLost() {
        forget()
        link = .offline(LText(String(localized: "远程 Mac 已移除本机或令牌已失效，请重新配对")))
        onConnectionForgotten?() // 固定的审批卡与提示属于旧连接：由界面层一并重置（普通断线不走这里）
    }

    /// 连接被彻底遗忘（鉴权失效导致的自动撤销）时通知界面层，AppDelegate 接到刘海的 resetConnection。
    @ObservationIgnored var onConnectionForgotten: (() -> Void)?
    /// SSE 断线后的重试等待（测试可注入，以便确定地断言“没有进入重试”）。
    @ObservationIgnored var streamRetrySleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// 目标快照的唯一写入口：pullState 与 SSE 的 targets 帧都经这里，工作计时随之更新。
    /// SSE targets 帧的写入计数（只在 applyTargetsFrame 递增）。
    @ObservationIgnored private var targetsFrameWrites = 0
    /// 权威同步的发起序号与最近一次采用了自己 targets 的 GET 的序号（只用于排序，视图不订阅，C7）。
    @ObservationIgnored private var getSerial = 0
    @ObservationIgnored private var appliedGetSerial = 0
    func applyStateSnapshot(_ s: BridgeState, now: Date = Date()) {
        state = s
        noteBridgeIdentity()
        endReminderPresentationIfIdentityChanged()
        currentBlocked = s.currentBlocked
        currentBlockedFresh = s.currentBlockedFresh
        Self.observeWorking(&workingSince, targets: s.targets, now: now)
    }

    func applyTargetsFrame(_ t: [TargetSummary], spaces: [SpaceInfo]?, currentBlocked blocked: [CurrentBlocked]? = nil, currentBlockedFresh fresh: Bool? = nil, observation: BridgeObservation? = nil, now: Date = Date()) {
        currentBlocked = blocked
        currentBlockedFresh = fresh
        targetsFrameWrites &+= 1
        state?.targets = t
        state?.spaces = spaces
        state?.observation = observation
        Self.observeWorking(&workingSince, targets: t, now: now)
        observeArchive(observation)
        applySpaceSnapshot(observation: observation)
    }

    /// 工作时长的状态转换：进入 working 记下开始时刻；已在 working 的保持原时刻（不重置）；离开 working 即删除。
    static func observeWorking(_ since: inout [String: Date], targets: [TargetSummary], now: Date) {
        var next: [String: Date] = [:]
        for t in targets where ThreadIdentity.status(t) == .working { next[t.id] = since[t.id] ?? now }
        since = next
    }

    /// 视图统一取值：列表、chip、底部提示都经这里推导，不各自从 AgentStatus 生成文案。
    func activityKind(_ t: TargetSummary) -> ActivityKind {
        ThreadActivity.activity(online: targetOnline(t.id), status: ThreadIdentity.status(t), pending: approvals(for: t).count)
    }

    func activityText(_ t: TargetSummary, at now: Date) -> String {
        ThreadActivity.describe(kind: activityKind(t), since: workingSince[t.id], now: now)
    }

    /// 拉一次权威 state 并合并，不改连接态（refresh / ready / 切换完成共用）。
    /// 共同提交点：HTTP 返回后先复核会话代次，过期（期间 stopStream/disconnect 过）就整体丢弃，不写任何状态。
    /// 远程模式的鉴权失效在这里统一处理（refresh、SSE ready、切换后补拉等所有读取都经过它）：只有仍是当前代次的响应才清会话，过期的 401 不影响新连接。
    private func fetchState() async throws -> BridgeState? {
        let gen = sessionGen
        do {
            if let f = stateOverride { return try await f() }
            guard let endpoint, let token else { return nil }
            return try await BridgeClient(endpoint: endpoint, token: token).state()
        } catch {
            if isRemoteAuthLost(error), gen == sessionGen { handleRemoteAuthLost() }
            throw error
        }
    }

    /// device 的独立版本号：每次 SSE device 帧写入都 +1。GET state 开始时记下它，返回时若已变（期间收到了更新的帧），
    /// 就只合并其余 state，不用旧响应里的 device 覆盖较新的帧，state.device 也随之保持一致。
    private(set) var deviceRevision = 0
    /// 本设备自己的 device 帧：只认本设备（device 未知时接受首帧）。
    func applyDeviceFrame(_ d: DeviceInfo) {
        guard device == nil || device?.id == d.id else { return }
        device = d
        deviceRevision += 1
    }

    func pullState() async throws { // 非 private：测试直接走权威同步入口
        let gen = sessionGen
        let rev = deviceRevision
        getSerial &+= 1
        let mySerial = getSerial
        let frames = targetsFrameWrites
        let seqStart = sseSeq
        guard var s = try await fetchState() else { return }
        guard gen == sessionGen else { throw CancellationError() }
        let deviceSuperseded = rev != deviceRevision
        if deviceSuperseded { s.device = device } // 期间有更新的 device 帧：保留它，state.device 同步成一致
        // 保留当前 targets 的条件：期间有 SSE targets 帧写入，或已有更晚发起的 GET 被采用。GET 自己的应用不算更新的写入。
        // GET 与 SSE 没有共同的数据版本：SSE 帧先于或晚于 GET 都可能短暂显示旧值；依赖 Bridge hub 在下一次轮询推送内容不同的新帧收敛（hub 不重发同一内容）。
        // 必须防住的是“新 SSE 帧之后被旧 GET 覆盖”，因为 hub 不会再发同一帧，旧值会永久停留。
        let keepTargets = targetsFrameWrites != frames || appliedGetSerial > mySerial
        if keepTargets { // 保留当前目标及与其同批的字段，旧 GET 不回退
            s.targets = state?.targets ?? []
            s.spaces = state?.spaces
            s.observation = state?.observation
            s.currentBlocked = currentBlocked
            s.currentBlockedFresh = currentBlockedFresh
        } else {
            appliedGetSerial = mySerial
        }
        applyStateSnapshot(s)
        awaitingFreshState = false
        merge(s.history.items)
        let snapshotKeys = (s.commands ?? []).map(\.key)
        let touchedKeys = Set(snapshotKeys.filter { (lastFactSeq[$0] ?? 0) > seqStart })
        let snapshotInflight = Dictionary(uniqueKeysWithValues: (s.inflight ?? []).map { ($0.eventKey, $0.state) })
        for c in s.commands ?? [] { mergeSnapshotCommand(c, touchedDuringRequest: touchedKeys.contains(c.key), seqStart: seqStart) }
        // 当前消息窗口：只有 HTTP 明确给出 commands 列表（含空列表）才重建；缺键是旧服务端未知，保留窗口。请求期间线上更新的成员一并保留。
        if let listed = s.commands {
            let concurrent = lastFactSeq.filter { $0.value > seqStart }.compactMap { commands[$0.key] }
            var w = commandWindow
            if w.rebuild(server: listed.compactMap { commands[$0.key] }, concurrent: concurrent) { commandWindow = w }
        }
        // 在途表由最终 commands 派生（#89 规则 C）：快照不得把已终态或排队中的命令重新标为在途。
        inflight = CommandMerge.deriveInflight(commands: commands, local: inflight, snapshot: snapshotInflight)
        if !deviceSuperseded { device = s.device }
        if let list = s.approvals {
            let ids = Set(list.map(\.id))
            for (id, a) in approvals where a.status == ApprovalStatus.pending.rawValue && !ids.contains(id) { approvals[id] = nil }
            for a in list { mergeApproval(a) }
        }
        observeArchive(s.observation) // 最终合并之后再裁决整理（R3）；历史投影也已合入，旧目标可被发现（R5）
        applySpaceSnapshot(observation: s.observation) // 空间排序同样在最终合并之后裁决
        lastSync = Date()
        baselineReminders(from: s)
        seedMarks()
        fixSelection()
        pruneRequestDrafts()
        if case .failed = switchState { switchState = .idle } // 一次成功的权威同步清除“绑定未确认”
    }

    /// 选中目标/线程按当前 targets 校验：目标消失就回到当前绑定或第一个；不每次同步强制跳回绑定，免得打断用户看别的目标。
    /// state 拉取与实时 targets 事件共用（A1-089 F4）。线程只可能是所选目标自己的那一条；遗留的旧系统线程编号在这里也回落。
    private func fixSelection() {
        let targets = state?.targets ?? []
        if selectedTarget == nil || !targets.contains(where: { $0.id == selectedTarget }) {
            if let first = autoTarget(targets) {
                selectedTarget = first
                selectedThread = threads(for: first).first?.id
            } else {
                selectedTarget = nil
                selectedThread = nil
            }
        } else if let th = selectedThread, !threads(for: selectedTarget).contains(where: { $0.id == th }) {
            selectedThread = threads(for: selectedTarget).first?.id
        }
    }

    /// 首次选择或所选目标已失效时自动挑一个来看（方向 B，A1-109 §3）：只是浏览，不切换消息目标、不 reveal；已有合法手选不经过这里。
    /// 在线信息可信（刚拿到的权威 targets）时：在线且有确定归属待办 > 在线且最近有回执 > 在线的绑定目标 > 按 id 第一个在线；
    /// 否则或都不在线：绑定目标 > 最近有回执 > 目录第一个。
    private func autoTarget(_ targets: [TargetSummary]) -> String? {
        let pending = Self.exactPendingTargets(pendingApprovals, targets: targets)
        // fixSelection 只在刚拿到 Bridge 权威 targets 时调用（pullState / 实时 targets 事件），此刻的 online 是新鲜的：
        // 不能看 link——冷启动时 pullState 发生在 refresh 置 connected 之前，看 link 会退回离线绑定并被当成有效选择保留（A1-110 F1）
        return Self.autoPick(targets: targets, onlineTrusted: true, bound: state?.binding?.targetId, pending: pending, activity: lastActivity)
    }

    /// 有确定归属待办的目标：只认 exact，优先按 ID；旧 Bridge 的标签恰好对应一个目标；候选 / 未匹配的继续只在铃铛里。
    static func exactPendingTargets(_ approvals: [ApprovalView], targets: [TargetSummary]) -> Set<String> {
        Set(approvals.filter { $0.attribution == ApprovalAttribution.exact.rawValue }.compactMap { a in
            ApprovalText.target(of: a, in: targets)?.id
        })
    }

    /// 登记了目标、且每个都已确认离线（online == false）。online 为空是“状态未知”（Bridge 拿不到新鲜 Herdr 快照），不能算离线（A1-111 F1）。
    static func allConfirmedOffline(_ targets: [TargetSummary]) -> Bool {
        !targets.isEmpty && targets.allSatisfy { $0.online == false }
    }

    /// 纯规则，供测试直接调用。
    static func autoPick(targets: [TargetSummary], onlineTrusted: Bool, bound: String?, pending: Set<String>, activity: (String) -> Int) -> String? {
        let online = onlineTrusted ? targets.filter { $0.online == true }.sorted { $0.id < $1.id } : []
        func latest(_ ts: [TargetSummary]) -> String? { ts.filter { activity($0.id) > 0 }.max { activity($0.id) < activity($1.id) }?.id }
        return online.first { pending.contains($0.id) }?.id
            ?? latest(online)
            ?? online.first { $0.id == bound }?.id
            ?? online.first?.id
            ?? targets.first { $0.id == bound }?.id
            ?? latest(targets)
            ?? targets.first?.id
    }

    static var readOnlyNote: String { String(localized: "这台 Mac 当前是只读：在「配对新设备」窗口的设备表里改成可控") }

    /// 绝对期限内完成一次操作：超时抛 CancellationError（请求本身也被取消）。
    private func withDeadline<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(for: .seconds(seconds)); throw CancellationError() }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }

    // ---- 账户额度（#26，只读）----
    /// 测试接缝：账户读取（参数为是否手动刷新）。
    var accountsOverride: (@Sendable (Bool) async throws -> AccountsResponse)?
    private(set) var accounts: AccountsResponse?
    private(set) var accountsError: LText?
    private(set) var accountsLoading = false
    /// 旧 Bridge 没有 /v1/accounts（404）：整个账户区块不显示，不当成错误。
    private(set) var accountsUnsupported = false
    private(set) var accountsConnection: String?
    private var accountsSeq = 0
    var visibleAccounts: AccountsResponse? { accountsConnection == connectionId ? accounts : nil }
    // Approval hook settings share the connection generation; late results never cross a reconnect.
    enum HookInstallState: Equatable { case unknown, loading, off, on, stale, unsupported }
    struct HookSetting {
        var state: HookInstallState = .unknown
        var busy = false
        var note: LText?
        var installation: HookInstallation?
        /// 配置不可读（503）时带出的故障：状态仍未知，只读显示。
        var unreadable: HookLaunchFailure?
    }
    private(set) var hookSettings: [HookProvider: HookSetting] = [:]
    private var hooksConnection: String?
    private var hookSequences: [HookProvider: Int] = [:]
    var hookStatusOverride: (@Sendable (HookProvider) async throws -> HookInstallation)?
    var hookMutationOverride: (@Sendable (HookProvider, Bool, String?) async throws -> HookInstallResult)?
    /// 发行身份的策略 seam（#108）：生产来自编译期标记 + bundle id；测试只能在实例上注入，没有偏好或环境变量入口。
    var isDistribution = RuntimeEnvironment.isDistribution
    static var nonDistributionHookNote: LText { LText(String(localized: "开发或测试构建不修改共享 Claude 审批钩子。请在正式版 Palmhelm 中安装或修复。")) } // 存生成方式：显示时按当前语言取
    static var hookOwnershipOtherNote: LText { LText(String(localized: "Claude 审批钩子当前指向另一个数据目录。")) } // 存生成方式：显示时按当前语言取
    static var hookOwnershipUnknownNote: LText { LText(String(localized: "无法确认审批钩子的归属，请重新读取状态或升级 Bridge。")) } // 存生成方式：显示时按当前语言取
    static var hookRepairChangedNote: LText { LText(String(localized: "钩子配置已改变，本次未修改，请重新读取后再确认。")) } // 存生成方式：显示时按当前语言取

    /// 带版本确认的修复请求：捕获发起时的会话代次、Bridge 身份、端点与 Bridge 给出的配置版本。
    struct HookRepairRequest: Equatable {
        let provider: HookProvider
        let gen: Int
        let connection: String
        let endpoint: BridgeEndpoint?
        let version: String
    }
    /// 正式版下 Claude 钩子指向别处 / 无法确认归属、且 Bridge 给出了可确认的版本时，返回确认请求；其余一律 nil（不提供快捷操作）。
    func hookRepairCandidate(_ provider: HookProvider) -> HookRepairRequest? {
        guard isDistribution, provider == .claude, link == .connected, canControl else { return nil }
        let setting = hookSetting(provider)
        guard !setting.busy, let inst = setting.installation, inst.ownership == .other || inst.ownership == .unknown, let v = inst.confirmableVersion else { return nil }
        return HookRepairRequest(provider: provider, gen: sessionGen, connection: connectionId, endpoint: endpoint, version: v)
    }
    func hookSetting(_ provider: HookProvider) -> HookSetting { hooksConnection == connectionId ? (hookSettings[provider] ?? HookSetting()) : HookSetting() }

    func loadHookInstallation(_ provider: HookProvider) async {
        if hooksConnection != connectionId { hookSettings = [:]; hookSequences = [:]; hooksConnection = connectionId }
        guard !hookSetting(provider).busy else { return }
        guard hookStatusOverride != nil || (endpoint != nil && token != nil) else { hookSettings[provider] = HookSetting(); return }
        let seq = (hookSequences[provider] ?? 0) + 1
        hookSequences[provider] = seq
        let gen = sessionGen, conn = connectionId
        hookSettings[provider, default: HookSetting()].state = .loading
        do {
            let value: HookInstallation
            if let hookStatusOverride { value = try await hookStatusOverride(provider) }
            else if let endpoint, let token { value = try await BridgeClient(endpoint: endpoint, token: token).hookInstallation(provider) }
            else { return }
            guard gen == sessionGen, conn == connectionId, seq == hookSequences[provider] else { return }
            hookSettings[provider, default: HookSetting()].installation = value
            hookSettings[provider, default: HookSetting()].unreadable = nil
            hookSettings[provider, default: HookSetting()].state = value.installed ? (value.stale == true ? .stale : .on) : .off
        } catch {
            guard gen == sessionGen, conn == connectionId, seq == hookSequences[provider] else { return }
            hookSettings[provider, default: HookSetting()].installation = nil
            if let unreadable = error as? HookStatusUnreadable {
                // 状态未知（不是成功，也不是未安装）；故障保留显示。
                hookSettings[provider, default: HookSetting()].unreadable = unreadable.lastFailure
                hookSettings[provider, default: HookSetting()].state = .unknown
                return
            }
            hookSettings[provider, default: HookSetting()].unreadable = nil
            hookSettings[provider, default: HookSetting()].state = (error as? BridgeError) == .http(status: 404) ? .unsupported : .unknown
        }
    }

    static func hookNote(_ result: HookInstallResult, install: Bool) -> String {
        if result.ok, result.error == nil { return install ? String(localized: "已安装定义；请在客户端核对是否生效") : String(localized: "已卸载 Palmhelm 的审批定义") }
        switch result.error {
        case "hook_runtime_unavailable": return String(localized: "审批运行程序无法准备，请更新 / 修复后重试")
        case "invalid_response": return String(localized: "Bridge 的回复不认识，请升级后重试")
        case "http_403", "read_only": return Self.readOnlyNote
        case "custom_claude_config_unsupported", "custom_codex_home_unsupported": return String(localized: "只支持默认配置目录，请取消自定义配置目录后重试")
        case "settings_dir_missing", "codex_dir_missing": return String(localized: "未找到客户端的默认配置目录，请先运行对应客户端")
        case "settings_parse_error", "hooks_parse_error": return String(localized: "客户端配置不是合法 JSON，请先手工修复")
        case "hook_confirmation_required": return Self.hookRepairChangedNote.text
        case "settings_locked", "hooks_locked", "settings_changed", "hooks_changed": return String(localized: "配置正在被修改，请稍后重试")
        default: return install ? String(localized: "安装失败；未确认结果，请重新读取状态") : String(localized: "卸载失败；未确认结果，请重新读取状态")
        }
    }

    /// Claude 普通写只在 Bridge 明确报告 current / none 时放行；other / unknown / 旧 Bridge 没有归属字段 / 尚无状态，一律不发请求
    /// （旧 Bridge 没有条件写保护，不能当作 current）。other / unknown 只能走带版本确认的修复。
    static func hookOwnershipRefusal(_ provider: HookProvider, _ installation: HookInstallation?) -> LText? {
        guard provider == .claude else { return nil }
        switch installation?.ownership {
        case .some(.current), .some(.none): return nil
        case .some(.other): return hookOwnershipOtherNote
        default: return hookOwnershipUnknownNote
        }
    }

    func setHookInstallation(_ provider: HookProvider, install: Bool) async {
        // 非发行构建：任何 Claude 写（安装 / 更新 / 修复 / 卸载）都在传输前拒绝；UI 禁用不是唯一防线。
        if provider == .claude, !isDistribution { hooksNote(provider, Self.nonDistributionHookNote); return }
        guard link == .connected else { return }
        guard canControl else { hookSettings[provider, default: HookSetting()].note = LText(Self.readOnlyNote); return }
        let setting = hookSetting(provider)
        guard !setting.busy, setting.state == .on || setting.state == .stale || setting.state == .off else { return }
        if let why = Self.hookOwnershipRefusal(provider, setting.installation) { hooksNote(provider, why); return }
        await performHookMutation(provider, install: install, version: nil)
    }

    /// 确认后的条件修复：重新核对发行身份、控制权、连接、捕获的 scope 与当前配置版本；任何一项变化都零写。
    func confirmHookRepair(_ request: HookRepairRequest) async {
        guard request.provider == .claude, isDistribution else { return }
        guard link == .connected, canControl, request.gen == sessionGen, request.connection == connectionId, request.endpoint == endpoint else { return }
        guard let current = hookRepairCandidate(request.provider), current == request else {
            hooksNote(request.provider, Self.hookRepairChangedNote)
            return
        }
        await performHookMutation(request.provider, install: true, version: request.version)
    }

    private func hooksNote(_ provider: HookProvider, _ text: LText) {
        if hooksConnection != connectionId { hookSettings = [:]; hookSequences = [:]; hooksConnection = connectionId }
        hookSettings[provider, default: HookSetting()].note = text
    }

    private func performHookMutation(_ provider: HookProvider, install: Bool, version: String?) async {
        guard hookMutationOverride != nil || (endpoint != nil && token != nil) else { return }
        let seq = (hookSequences[provider] ?? 0) + 1
        hookSequences[provider] = seq
        let gen = sessionGen, conn = connectionId
        hookSettings[provider, default: HookSetting()].busy = true
        let result: HookInstallResult
        do {
            if let hookMutationOverride { result = try await hookMutationOverride(provider, install, version) }
            else if let endpoint, let token { result = try await BridgeClient(endpoint: endpoint, token: token).setHookInstallation(provider, install: install, expectedConfigVersion: version) }
            else { return }
        } catch { result = HookInstallResult(ok: false, error: "failed") }
        guard gen == sessionGen, conn == connectionId, seq == hookSequences[provider] else { return }
        hookSettings[provider, default: HookSetting()].busy = false
        let confirmed = version != nil && ["hook_confirmation_required", "settings_changed"].contains(result.error ?? "")
        hookSettings[provider, default: HookSetting()].note = LText(confirmed ? Self.hookRepairChangedNote.text : Self.hookNote(result, install: install))
        await loadHookInstallation(provider)
    }

    // ---- Claude 额度的状态行开关（#26 第二段）：写用户的 settings.json，需要 control；单飞；结果只回固定原因码 ----
    /// 状态行是否已安装：进入设置时读取；未知 / 加载中 / 旧 Bridge（404）/ 内容不对 都不是「已关闭」，确定之前不可操作。
    enum ClaudeStatuslineState: Equatable { case unknown, loading, off, on, unsupported }
    var claudeStatuslineStatusOverride: (@Sendable () async throws -> Bool)?
    private(set) var claudeStatuslineState: ClaudeStatuslineState = .unknown
    var claudeStatuslineOverride: (@Sendable (Bool) async throws -> ClaudeStatuslineResult)?
    private(set) var claudeStatuslineBusy = false
    private(set) var claudeStatuslineNote: LText?
    private var claudeStatuslineSeq = 0

    /// 固定原因码 → 文案；未知码统一显示固定文案，不回显服务端字符串。
    static func claudeStatuslineNoteText(_ r: ClaudeStatuslineResult, install: Bool) -> String {
        if let e = r.error {
            switch e {
            case "settings_parse_error": return String(localized: "settings.json 不是合法 JSON，已放弃修改，请先手工修复")
            case "settings_symlink", "settings_not_owned", "settings_wrong_type": return String(localized: "settings.json 是符号链接或不属于当前用户，已放弃修改")
            case "settings_writable_by_others": return String(localized: "settings.json 组或他人可写，请先手工 chmod 600")
            case "settings_changed", "settings_locked": return String(localized: "settings.json 正在被修改，请稍后重试")
            case "claude_config_dir_unsupported": return String(localized: "暂不支持 CLAUDE_CONFIG_DIR，请先取消该变量")
            case "statusline_state_missing": return String(localized: "原状态行的记录缺失，请手工处理后再操作")
            case "invalid_response": return String(localized: "Bridge 的回复不认识，请升级 Bridge 后重试")
            case "http_403": return Self.readOnlyNote
            case "unsupported_platform": return String(localized: "此系统不支持 Claude 额度（仅 macOS）")
            default: return install ? String(localized: "安装失败") : String(localized: "卸载失败")
            }
        }
        if !install { return r.restored == "not_ours" ? String(localized: "状态行已被手动改过，未恢复；Palmhelm 的私有文件已删除") : String(localized: "已关闭 Claude 额度") }
        return String(localized: "已开启：状态行已换成 Palmhelm 的透传包装，原来的状态行照常显示")
    }

    /// 进入设置时加载状态。只有确定的 true / false 才改变状态；失败（含 404 旧 Bridge）记为 unsupported 或保持未知。
    func loadClaudeStatusline() async {
        guard claudeStatuslineStatusOverride != nil || (endpoint != nil && token != nil) else { claudeStatuslineState = .unknown; return }
        claudeStatuslineSeq += 1; let my = claudeStatuslineSeq
        claudeStatuslineState = .loading
        let conn = connectionId
        do {
            let installed: Bool
            if let f = claudeStatuslineStatusOverride { installed = try await f() }
            else if let endpoint, let token { installed = try await BridgeClient(endpoint: endpoint, token: token).claudeStatuslineInstalled() }
            else { return }
            guard my == claudeStatuslineSeq, conn == connectionId else { return }
            claudeStatuslineState = installed ? .on : .off
        } catch BridgeError.http(404) {
            guard my == claudeStatuslineSeq, conn == connectionId else { return }
            claudeStatuslineState = .unsupported
        } catch {
            guard my == claudeStatuslineSeq, conn == connectionId else { return }
            claudeStatuslineState = .unknown
        }
    }

    func setClaudeStatusline(install: Bool) async {
        guard canControl else { claudeStatuslineNote = LText(Self.readOnlyNote); return }
        guard claudeStatuslineOverride != nil || (endpoint != nil && token != nil) else { claudeStatuslineNote = LText(String(localized: "还没有配对")); return }
        guard claudeStatuslineState == .on || claudeStatuslineState == .off else { claudeStatuslineNote = LText(String(localized: "正在读取当前状态，请稍后再试")); return }
        guard !claudeStatuslineBusy else { return }
        claudeStatuslineBusy = true; defer { claudeStatuslineBusy = false }
        let conn = connectionId
        let r: ClaudeStatuslineResult
        do {
            if let f = claudeStatuslineOverride { r = try await f(install) }
            else if let endpoint, let token { r = try await BridgeClient(endpoint: endpoint, token: token).setClaudeStatusline(install: install) }
            else { return }
        } catch {
            guard conn == connectionId else { return }
            claudeStatuslineNote = LText(Self.claudeStatuslineNoteText(ClaudeStatuslineResult(ok: false, error: "failed"), install: install))
            return
        }
        guard conn == connectionId else { return }
        claudeStatuslineNote = LText(Self.claudeStatuslineNoteText(r, install: install))
        if r.error == nil, r.ok == true {
            await loadClaudeStatusline()
            await loadAccounts(refresh: true) // 安装后账户卡出现或消失
        }
    }

    /// 同用量的两层代次：换连接 / 断开作废在途结果；只保留最新一次请求的结果。refresh 为手动刷新（服务端 60 秒节流）。
    @discardableResult
    func loadAccounts(refresh: Bool = false) async -> Bool {
        guard accountsOverride != nil || (endpoint != nil && token != nil) else { accounts = nil; accountsError = nil; accountsConnection = nil; return false }
        accountsSeq += 1; let my = accountsSeq
        let gen = sessionGen, conn = connectionId
        accountsLoading = true
        defer { if my == accountsSeq { accountsLoading = false } }
        do {
            let r: AccountsResponse
            if let f = accountsOverride { r = try await f(refresh) }
            else if let endpoint, let token { r = try await BridgeClient(endpoint: endpoint, token: token).accounts(refresh: refresh) }
            else { return false }
            guard my == accountsSeq, gen == sessionGen, conn == connectionId else { return false }
            accounts = r; accountsError = nil; accountsUnsupported = false; accountsConnection = conn
            return true
        } catch {
            guard my == accountsSeq, gen == sessionGen, conn == connectionId else { return false }
            if case BridgeError.http(404) = error { accounts = nil; accountsError = nil; accountsUnsupported = true; accountsConnection = conn; return false }
            accountsError = LText(Self.describe(error))
            return false
        }
    }

    // ---- 用量与价格刷新（D4）----
    /// 测试接缝：用量请求 / 价格刷新的传输（缺省走真实 BridgeClient）。
    var usageOverride: (@Sendable (UsageWindow) async throws -> UsageResponse)?
    var refreshPricesOverride: (@Sendable () async throws -> PriceRefreshResult)?

    /// 最近一次成功的用量快照属于哪个连接身份与何时取到：换了连接（别的 Bridge）不显示前一台的数据；离线时同连接的上次快照继续显示并标时间。
    /// 当前请求的窗口意图（用量页与设置共用）：每次 loadUsage 都先记下它；价格刷新成功后按它重拉，不从结果快照推断（快照可能是别的窗口 / 还没到）。
    private(set) var usageWindowIntent: UsageWindow = .h24
    private(set) var usageConnection: String?
    /// 每个范围最近一次成功的快照（O1-368 追加）：切换范围 / 切回用量页先显示它，不清空、不进骨架；后台静默刷新。
    /// 只属于当前连接（换连接 / 忘记配对时整体清空）。
    private var usageByWindow: [String: UsageResponse] = [:]
    private var usageCacheConnection: String?
    private var usageFetchedByWindow: [String: Date] = [:] // 每个范围快照的采集时刻（切换时随快照一起显示）
    /// 最近一次完成（成功或失败）的范围；用于区分「首次无数据」与「加载中」。
    var usageSettledWindow: String?
    private(set) var usageFetchedAt: Date?
    var visibleUsage: UsageResponse? { usageConnection == connectionId ? usage : nil }

    /// 带两层代次：连接代次（换连接 / 断开 / forget 作废在途请求）与窗口请求代次（换窗口或又点了刷新，晚到的旧请求不覆盖当前结果，也不写错误）。
    @discardableResult
    func loadUsage(_ window: UsageWindow) async -> Bool {
        guard usageOverride != nil || (endpoint != nil && token != nil) else { usage = nil; usageError = nil; usageConnection = nil; return false }
        usageWindowIntent = window
        showUsageWindow(window) // 先显示这个范围已有的快照（不清空、不进骨架）；结果到达后静默替换
        usageSeq += 1; let my = usageSeq
        let gen = sessionGen, conn = connectionId
        let life = last30dLifeKey
        var capReq = 0
        if window == .d30 { last30dReq += 1; capReq = last30dReq } // 30 天请求同样占用能力代次
        usageLoading = true
        defer { if my == usageSeq { usageLoading = false } }
        do {
            let r: UsageResponse
            if let f = usageOverride { r = try await f(window) }
            else if let endpoint, let token { r = try await BridgeClient(endpoint: endpoint, token: token).usage(window: window) }
            else { return false }
            if window == .d30 { noteLast30dFromUsage(r, error: nil, key: life, req: capReq) }
            guard my == usageSeq, gen == sessionGen, conn == connectionId else { return false }
            storeUsage(r, for: window, connection: conn)
            usage = r; usageError = nil; usageConnection = conn; usageFetchedAt = Date(); usageSettledWindow = window.rawValue
            return true
        } catch {
            if window == .d30 { noteLast30dFromUsage(nil, error: error, key: life, req: capReq) }
            guard my == usageSeq, gen == sessionGen, conn == connectionId else { return false }
            usageError = LText(Self.describe(error)); usageSettledWindow = window.rawValue
            return false
        }
    }

    /// 切到某个范围：有该范围的缓存就立即显示（同一连接）；没有则为 nil，卡内显示加载状态。不触发网络请求。
    func showUsageWindow(_ window: UsageWindow) {
        if usageCacheConnection != connectionId { usageByWindow = [:]; usageFetchedByWindow = [:]; usageCacheConnection = connectionId }
        if let cached = usageByWindow[window.rawValue] {
            usage = cached; usageConnection = connectionId; usageFetchedAt = usageFetchedByWindow[window.rawValue]
        } else {
            usage = nil; usageConnection = nil
        }
        usageError = nil
    }

    private func storeUsage(_ r: UsageResponse, for window: UsageWindow, connection: String) {
        if usageCacheConnection != connection { usageByWindow = [:]; usageFetchedByWindow = [:]; usageCacheConnection = connection }
        usageByWindow[window.rawValue] = r
        usageFetchedByWindow[window.rawValue] = Date()
    }

    // ---- 近 30 天能力发现（#32，O1-244 / R2）----
    // 能力绑定生命周期 key（sessionGen + 连接标识）；探测（probe）与真实的 30 天用量请求共用同一个能力请求代次 last30dReq：
    // 只有最新一次请求的结果才能写入能力（迟到的旧结果，无论成功还是 404，都丢弃）。网络错误保留原判断。
    enum Last30dCapability: Equatable { case unknown, supported, unsupported }
    private(set) var last30dCapability: Last30dCapability = .unknown
    private(set) var last30dKey: String?
    private var last30dReq = 0
    /// 生命周期：配对 / 断开 / 忘记配对都会递增 sessionGen；换连接改变连接标识。
    private var last30dLifeKey: String { "\(sessionGen)|\(connectionId)" }
    /// 第三档只在：当前生命周期内已确认支持。忘记配对后即使连接标识相同也不成立。
    var last30dAvailable: Bool { last30dCapability == .supported && last30dKey == last30dLifeKey }

    /// 写入能力：只接受最新的请求代次，且生命周期必须仍是请求发起时的那个。
    private func settleLast30d(_ c: Last30dCapability, key: String, req: Int) {
        guard req == last30dReq, key == last30dLifeKey else { return }
        last30dCapability = c; last30dKey = key
    }
    /// 用量请求（window=30d）的结果：成功且有 last30d → 支持；成功缺字段，或 400 / 404 / 解码失败 → 不支持；网络错误 → 保留。
    private func noteLast30dFromUsage(_ r: UsageResponse?, error: Error?, key: String, req: Int) {
        if let r { settleLast30d(r.estimateV1?.windows.last30d != nil ? .supported : .unsupported, key: key, req: req); return }
        guard let error else { return }
        if case BridgeError.http(let status) = error, status == 400 || status == 404 { settleLast30d(.unsupported, key: key, req: req) }
        else if case BridgeError.decoding = error { settleLast30d(.unsupported, key: key, req: req) }
    }

    /// 探测：每个生命周期一次；发起新请求即递增代次，使更早发出的探测 / 用量结果失效。
    func probeLast30d() async {
        guard usageOverride != nil || (endpoint != nil && token != nil) else { return }
        let key = last30dLifeKey
        if last30dKey != key { last30dCapability = .unknown; last30dKey = nil } // 生命周期变了：旧判断不成立
        if last30dKey == key, last30dCapability != .unknown { return }
        last30dReq += 1; let my = last30dReq
        do {
            let r: UsageResponse
            if let f = usageOverride { r = try await f(.d30) }
            else if let endpoint, let token { r = try await BridgeClient(endpoint: endpoint, token: token).usage(window: .d30) }
            else { return }
            settleLast30d(r.estimateV1?.windows.last30d != nil ? .supported : .unsupported, key: key, req: my)
        } catch BridgeError.http(let status) where status == 400 || status == 404 {
            settleLast30d(.unsupported, key: key, req: my)
        } catch BridgeError.decoding {
            settleLast30d(.unsupported, key: key, req: my)
        } catch {
            // 网络或其他错误：保留原判断
        }
    }

    /// 价格刷新（设置页与用量页共用一份状态与单飞）。
    enum PriceNote: Equatable {
        case current, updated
        case failed(String)            // 固定原因码（UsageCopy.refreshFailure 说人话）
        case rateLimited(until: Date)  // 429：接收时刻 + retryAfterMs；不自动重试
        case usageNotRefreshed         // 价格已更新，但重拉用量失败：保留旧快照
    }
    private(set) var priceRefreshBusy = false
    private(set) var priceNote: PriceNote?
    private var priceRefreshSeq = 0
    private var priceNoteConnection: String?
    var visiblePriceNote: PriceNote? { priceNoteConnection == connectionId ? priceNote : nil }

    /// 不能点「立即更新价格」的原因（nil 为可点）：未连接 / 只读 / 正在更新 / 429 冷却中 / 旧版 Bridge。关闭自动更新不影响手动更新。
    func priceRefreshBlocker(now: Date = Date()) -> String? {
        guard isPaired || refreshPricesOverride != nil else { return String(localized: "还没有配对") }
        guard link == .connected else { return String(localized: "未连接 Bridge，暂时不能更新") }
        guard canControl else { return Self.readOnlyNote }
        if priceRefreshBusy { return String(localized: "正在更新…") }
        if case .rateLimited(let until)? = visiblePriceNote, until > now { return String(localized: "更新太频繁，\(Int(until.timeIntervalSince(now).rounded(.up))) 秒后再试") }
        if let u = visibleUsage, UsageModel.mode(u) == .legacy { return UsageCopy.refreshFailure("unsupported") }
        return nil
    }

    /// 立即更新价格：单飞；任何路径都释放 busy，晚到的结果不清新请求的 busy、不写到另一个连接。200 后对原连接重拉用量（金额 / 档位 / pricing 都来自新响应）。
    func refreshPrices() async {
        guard priceRefreshBlocker() == nil else { return }
        priceRefreshSeq += 1; let my = priceRefreshSeq
        let gen = sessionGen, conn = connectionId
        priceRefreshBusy = true
        priceNote = nil
        defer { if my == priceRefreshSeq { priceRefreshBusy = false } }
        let result: PriceRefreshResult
        do {
            if let f = refreshPricesOverride { result = try await f() }
            else if let endpoint, let token { result = try await BridgeClient(endpoint: endpoint, token: token).refreshPrices() }
            else { return }
        } catch { result = .failed(code: "transport") }
        guard my == priceRefreshSeq, gen == sessionGen, conn == connectionId else { return } // 期间换了连接 / forget / 又有新请求：旧结果不写
        priceNoteConnection = conn
        switch result {
        case .current: priceNote = .current
        case .updated: priceNote = .updated
        case .rateLimited(let ms): priceNote = .rateLimited(until: Date().addingTimeInterval(Double(ms) / 1000)); return
        case .failed(let code): priceNote = .failed(code); return
        }
        let ok = await loadUsage(usageWindowIntent) // 按「当前请求的窗口意图」重拉：期间用户切了窗口，就重拉新的那个
        guard my == priceRefreshSeq, gen == sessionGen, conn == connectionId else { return }
        if !ok { priceNote = .usageNotRefreshed } // 保留旧快照
    }

    // ---- 发送 ----
    struct Sent: Identifiable, Equatable {
        let id: UUID
        let text: String
        let at: Date
        let afterSeq: Int
        let targetId: String?
        /// 发送当时的稳定时间锚（毫秒）：最近回执的入队时间；没有回执时用本机发送时刻（O1-364 R3）。
        var anchorT: Int?
        var eventKey: String?
        var error: LText?
        /// 发送时输入区的原始草稿与附件路径：业务拒绝（HTTP 200 + rejected 回执）后用来恢复到输入框。
        var draft: String = ""
        var attachmentPaths: [String] = []
        /// 与 attachmentPaths 一一对应的来源；缺失（旧快照）按用户引用处理。
        var attachmentSources: [AttachmentSource] = []
        /// 直达记录的 agent（nil = 普通发送）：重试时沿用原来的发送方式（#57）。
        var agent: String? = nil
        /// 原发送的模式与排队期限（nil = 默认）：重试时原样沿用（#57）。
        var mode: SendMode? = nil
        var queueTTLSeconds: Int? = nil
        var restored = false
        /// send_now 结果不明（无 eventKey）：投影为中性「结果未知」，不写确定失败。
        var resultUnknown = false
        /// 原生插话绑定的会话代次：发送时已知则即此值，否则由线程第一次取得的代次绑定（见 bindSentEpochs）；之后固定。
        var sessionEpoch: String? = nil
        /// 本机发出的 owner 操作（面板 / 任务 / 重置占用 / 切换）：没有排队指令，结果只来自系统回执，不进普通待发回显（见 ownerPlacement）。
        var ownerKind: OwnerOperationKind? = nil
        /// 发起时线程 transcript 尾部的 itemId：owner 操作在线程里的稳定位置锚（只是本地元数据，`at` 不变）。
        var anchorItemId: String? = nil
        /// 请求时带给 Bridge 的 owner 报告语言（nil = 省略 = 中文）：随这条发送固定，重试沿用，不随界面语言变化。
        var responseLanguage: MessageResponseLanguage? = nil
    }
    var sent: [Sent] = []
    /// 正在重试的失败记录（防止同一条被连点）。
    private var resendBusy = Set<UUID>()

    // MARK: 会话记录线程（2a）：来自 agent 自己的会话文件，按目标缓存；只对打开的线程读取与补拉。
    var transcripts: [String: TranscriptThread] = [:] { didSet { bindSentEpochs() } }
    /// 读取簿记（最新页在途标记与请求计数）：不存进 transcripts，写入不触发观察（#102，与 iOS 同）。
    @ObservationIgnored var transcriptRequestBook: [String: TranscriptRequestBook] = [:]
    /// 激活会话的读取（#88 S4）：只在窗口为 key、线程可见且显示对话时运行；切走、失焦、停止即停。
    var activeTranscriptThread: String?
    var transcriptActivation = TranscriptActivation()
    var transcriptCadence = TranscriptReadCadence()
    /// 最近一次被采纳的激活（骨架门禁）与长回复展开的序号（#88 S4）。
    var transcriptConfirmedToken: TranscriptActivation.Token?
    var transcriptExpansionSeq = 0
    /// 线程最近使用序号（全局 4 MiB 上限的 LRU 依据）。
    var transcriptLastUsed: [String: Int] = [:]
    var transcriptClock = 0
    var activeTranscriptTask: Task<Void, Never>?
    /// 长回复的按段展开状态，键为「线程|条目」；只在本次浏览内保留（停止激活即丢弃）。
    var transcriptExpansions: [String: TranscriptExpansion] = [:]
    /// 发送时还没有原生代次的本机发送：线程第一次取得代次即绑定到该发送（首次绑定语义，与 iOS 同一规则）。
    private func bindSentEpochs() {
        for i in sent.indices where sent[i].sessionEpoch == nil {
            if let t = sent[i].targetId, let e = transcripts[t]?.sessionEpoch { sent[i].sessionEpoch = e }
        }
    }
    /// Mac 的打开线程就是左栏选中的线程。
    var openThread: String? { selectedThread }

    /// 会话记录变化通知：reset / session 使旧分页作废；只给打开的线程补拉。
    func transcriptChanged(_ c: TranscriptChange) {
        guard c.targetId == openThread else { return }
        if c.kind != TranscriptChangeKind.append.rawValue { invalidateTranscript(c.targetId) }
        else if transcripts[c.targetId]?.revision == c.revision { return }
        Task { await loadTranscriptLatest(c.targetId) } // 不在事件循环里等待读取，免得拖住后面的审批 / 进度帧
    }

    // MARK: 会话搜索（h6b）：查询、结果与定位由 Session 持有，视图只渲染与转发。
    private(set) var searching = false
    private(set) var searchResponse: SearchResponse?
    private(set) var searchError: String?
    /// 最近一次成功提交的查询（已规范化）：定位后在记录里用它高亮。
    private(set) var searchQuery = ""
    /// 当前定位（唯一）：同一时刻最多一个线程处于定位视图；nil 为常规最新页。pin 与它同进同出（见 leaveLocated）。
    private(set) var located: SearchLocation?
    /// 打开命中失败的固定文案（已移动 / 打开失败 / 稍后再试）。
    private(set) var locateNote: LText?
    /// 对话 / 终端：打开命中时强制回到对话。
    var threadMode = 0
    /// 请求主窗口切到对话页（独立搜索窗口打开命中时）：主窗口 onAppear / onChange 处理后清零（R5）。
    var requestConversation = false
    /// 测试接缝：返回 nil 表示当前不可用（未连接）；缺省用真实 BridgeClient。
    var searchClientOverride: (() -> (any SearchTranscriptClient)?)?
    /// 定位代次：新定位、退出定位、失效、停机都会递增；迟到的定位响应只在代次未变时生效。
    private(set) var locateGen = 0
    private var locateSerial = 0

    func searchClient() -> (any SearchTranscriptClient)? {
        if let f = searchClientOverride { return f() }
        guard let endpoint, let token else { return nil }
        return BridgeClient(endpoint: endpoint, token: token)
    }

    /// 查询守卫：同一时刻只有一个在途搜索（Bridge 也会以 409 拒绝第二个）；按钮与 Return 共用这里。
    func runSearch(_ raw: String) async {
        guard !searching, let q = SearchText.normalizedQuery(raw), let client = searchClient() else { return }
        searching = true
        let gen = sessionGen
        var response: SearchResponse?
        var failure: String?
        do { response = try await client.search(q: q, limit: BridgeAPI.searchLimit) } catch { failure = SearchText.failure(error) }
        guard gen == sessionGen else { return } // 断开 / 换连接后 stopStream 已清 searching，旧结果不写
        searching = false
        searchQuery = q
        searchResponse = response; searchError = failure
    }

    /// 退出定位视图（唯一出口）：解除该线程的 pin、清定位元数据、作废在途定位。
    func leaveLocated() {
        if let l = located { transcripts[l.threadId]?.invalidate() }
        locateGen += 1
        located = nil; locateNote = nil
    }

    /// 会话记录整体失效（reset / 410）：线程从最新页重来；若它正处于定位视图或正在定位，一并退出。
    func invalidateTranscript(_ id: String) {
        transcripts[id]?.invalidate()
        if located?.threadId == id || openThread == id { locateGen += 1 }
        if located?.threadId == id { located = nil; locateNote = nil }
    }

    /// 定位专用的一次读取：占用该线程的请求槽（两槽满则不发、返回 nil），读完归还。
    private func fetchForLocate(_ id: String, before: String?, client: any SearchTranscriptClient) async -> Result<TranscriptPage, Error>? {
        guard canStartTranscriptRequest(id) else { return nil }
        if transcripts[id] == nil { transcripts[id] = TranscriptThread() }
        withRequestBook(id) { $0.activeRequests += 1 }
        let gen = sessionGen
        let result: Result<TranscriptPage, Error>
        do { result = .success(try await client.transcript(targetId: id, before: before, limit: BridgeAPI.transcriptPageLimit)) } catch { result = .failure(error) }
        guard gen == sessionGen else { return result } // 停机 / 换连接：stopStream 已归还槽位，不再记账
        withRequestBook(id) { $0.activeRequests -= 1 }
        return result
    }

    /// 打开一条命中：定位结束后兑现 dirty 补拉（R2），补拉不早于本次定位应用。
    func openSearchHit(_ hit: SearchHit) async {
        let my = beginNavigation()
        guard guardOpenTarget(hit.targetId, serial: my) else { return } // 与 openThread 同一在线 + 目标存在守卫
        selectedRequest = nil
        await locate(hit)
        await transcriptRefillIfDirty(hit.targetId)
    }

    private func locate(_ hit: SearchHit) async {
        let id = hit.targetId
        requestConversation = true
        leaveLocated()
        selectTarget(id)
        threadMode = 0
        locateGen += 1
        let token = locateGen
        let gen = sessionGen
        guard let client = searchClient() else { locateNote = LText(SearchText.openFailed); return }
        guard let result = await fetchForLocate(id, before: hit.pageBefore, client: client) else {
            guard token == locateGen else { return }
            locateNote = LText(SearchText.locateBusy)
            await loadTranscriptLatest(id)
            return
        }
        guard token == locateGen, gen == sessionGen, openThread == id else { return }
        var note: LText?
        switch result {
        case .failure(let e):
            note = LText(SearchLocate.failure(e))
        case .success(let page) where hit.pageBefore == nil:
            note = SearchLocate.inPage(hit, page) == nil ? nil : LText(SearchText.moved) // Kit 只会给“已移动”
            if note == nil, page.isAvailable {
                var t = transcripts[id] ?? TranscriptThread()
                t.replaceWithLatest(page) // 自读的最新页整体替换并推进快照（R3）
                transcripts[id] = t
            }
        case .success(let page):
            var t = transcripts[id] ?? TranscriptThread()
            note = SearchLocate.apply(page: page, hit: hit, to: &t) == nil ? nil : LText(SearchText.moved)
            if note == nil { transcripts[id] = t }
        }
        if let note {
            locateNote = note
            await loadTranscriptLatest(id)
        } else {
            locateSerial += 1
            located = SearchLocation(threadId: id, itemId: hit.itemId, query: searchQuery, serial: locateSerial)
        }
    }

    /// 独立搜索窗口的目标行入口：选中目标并请求主窗口回对话页（普通 selectTarget 不带页面副作用，S3）。
    func openFromSearch(targetId: String) {
        let my = beginNavigation()
        guard guardOpenTarget(targetId, serial: my) else { return }
        selectedRequest = nil
        applySelection(targetId)
        finishNav(my, .thread(targetId))
        requestConversation = true
    }

    /// 回到最新：退出定位视图并重新拉最新页。
    /// 窗口离开最新时回到最新：只改渲染范围，行已在本地（O1-341）。
    func showLatestRows(_ id: String) { transcripts[id]?.showLatestRows() }

    func returnToLatest(_ id: String) async {
        leaveLocated()
        invalidateTranscript(id)
        await loadTranscriptLatest(id)
    }

    @discardableResult
    func send(_ text: String, draft: String = "", attachmentPaths: [String] = [], attachmentSources: [AttachmentSource] = [], mode: SendMode? = nil, queueTTLSeconds: Int? = nil) async -> Bool {
        await sendDelivery(text, draft: draft, attachmentPaths: attachmentPaths, attachmentSources: attachmentSources, mode: mode, queueTTLSeconds: queueTTLSeconds).ok
    }

    /// 普通发送的完整结果（含本次记录的编号）：输入区据此判断本次是否已入账（#57）。
    private func sendDelivery(_ text: String, draft: String, attachmentPaths: [String], attachmentSources: [AttachmentSource], mode: SendMode?, queueTTLSeconds: Int?, replacing: UUID? = nil) async -> Delivery {
        // 旧 Bridge（没有 capabilities）：不发 mode，请求体与旧版一致；显式 send_now 不删，交给 deliver 本地拒绝（零请求、保稿）。
        await deliver(text, wire: text, targetId: state?.binding?.targetId, draft: draft, attachmentPaths: attachmentPaths, attachmentSources: attachmentSources, mode: supportsSendTiming || mode == .sendNow ? mode : nil, queueTTLSeconds: queueTTLSeconds, replacing: replacing)
    }

    /// 业务拒绝后可恢复的发送：HTTP 已受理（有 eventKey）、回执被标为 rejected（原始 error 为空）、未恢复过，且保存了草稿或附件。
    func restorableSend(threadId: String) -> Sent? { Self.restorableSend(in: sent, history: history, threadId: threadId) }

    static func restorableSend(in sent: [Sent], history: [HistoryItem], threadId: String) -> Sent? {
        let rejected = ThreadRow.withRejections(sent, history: history)
        for (raw, shown) in zip(sent, rejected) where !raw.restored && raw.error == nil && shown.error != nil && raw.eventKey != nil {
            guard raw.targetId == threadId, !raw.draft.isEmpty || !raw.attachmentPaths.isEmpty else { continue }
            return raw
        }
        return nil
    }

    /// 恢复成功：这条发送的提醒（sent: 与全部 rj: 别名）一起标已读并持久化，立即移出提醒页。别名要在 restored 置位前取（之后恢复入口已消失）。
    func markRestored(_ id: UUID) {
        guard let i = sent.firstIndex(where: { $0.id == id }) else { return }
        let aliases = [ReminderLedger.sentId(id)] + alertEntries().filter { $0.alert.restoreSendId == id }.map(\.alert.id)
        sent[i].restored = true
        reminderLedger.markSeen(bridgeId: reminderIdentity.id, ids: aliases, retained: retainedReminderIds)
        persistLedger(); reminderVersion += 1
    }

    /// 直达：不改飞书绑定，消息经「派给 <agent>」送到该线程的 agent；本地回显归该线程，保存的仍是用户原文。
    @discardableResult
    func sendDirect(_ text: String, agent: String, threadId: String, draft: String = "", attachmentPaths: [String] = [], attachmentSources: [AttachmentSource] = [], queueTTLSeconds: Int? = nil) async -> Bool {
        await sendDirectDelivery(text, agent: agent, threadId: threadId, draft: draft, attachmentPaths: attachmentPaths, attachmentSources: attachmentSources, queueTTLSeconds: queueTTLSeconds).ok
    }

    /// 直达的完整结果（含本次记录的编号）。直达只接受原生插话（steer）与原生立即发送（send_now）；其余都是普通直达（不带 mode）。
    private func sendDirectDelivery(_ text: String, agent: String, threadId: String, draft: String, attachmentPaths: [String], attachmentSources: [AttachmentSource], queueTTLSeconds: Int?, mode: SendMode? = nil, replacing: UUID? = nil) async -> Delivery {
        await deliver(text, wire: OwnerCommand.direct(agent: agent, text: text), targetId: threadId, draft: draft, attachmentPaths: attachmentPaths, attachmentSources: attachmentSources, mode: mode == .steer || mode == .sendNow ? mode : nil, queueTTLSeconds: queueTTLSeconds, agent: agent, replacing: replacing)
    }

    /// 一次发送的结果：ok 是真正的成功（Bridge 受理）；id 是本次发送的编号（失败也有，原因记在 Sent.error；被本地守卫拦下时为 nil）。
    /// 输入区靠 recorded（是否已入账）决定清不清草稿：入账即清（成功或失败都有记录）；守卫拦下（没有记录）保留草稿。ok 只表示 Bridge 受理。
    struct Delivery: Equatable {
        let ok: Bool
        let id: UUID?
        /// 确定拒绝（没有写入）时给出的固定原因：输入区保留草稿，不记为一条发送。
        var refusal: LText? = nil
    }

    /// 测试接缝：发送传输（缺省走真实 BridgeClient）。
    var sendOverride: (@Sendable (String, UUID) async throws -> MessageReceipt)?
    /// 测试接缝：拉权威 state（缺省走真实 BridgeClient）。
    var stateOverride: (@Sendable () async throws -> BridgeState)?

    /// 测试接缝记录：最近一次发送用的模式（真实请求体由 BridgeClient 决定）。
    private(set) var lastSendMode: SendMode?
    private(set) var lastQueueTTLSeconds: Int?
    private(set) var lastResponseLanguage: MessageResponseLanguage?
    /// 英文界面向未声明 messageResponseLanguages 的旧 Bridge 发“面板/任务”报告请求时，提示一次（报告会是中文）；不阻止发送。界面读取后置 false。
    var reportLanguageNotice = false
    private var reportLanguageNoticeShown = false
    private func noteReportLanguage(_ resolved: MessageResponseLanguage?) {
        guard resolved == .en, state?.bridge?.supportsReportLanguage(.en) != true, !reportLanguageNoticeShown else { return }
        reportLanguageNoticeShown = true; reportLanguageNotice = true
    }

    private func transmit(_ wire: String, _ id: UUID, mode: SendMode?, queueTTLSeconds: Int? = nil, responseLanguage: MessageResponseLanguage? = nil) async throws -> MessageReceipt {
        lastSendMode = mode
        lastResponseLanguage = responseLanguage
            lastQueueTTLSeconds = queueTTLSeconds
        if let f = sendOverride { return try await f(wire, id) }
        guard let endpoint, let token else { throw BridgeError.badURL }
        return try await BridgeClient(endpoint: endpoint, token: token, session: messageTransport).sendMessage(text: wire, clientMsgId: id, mode: mode, queueTTLSeconds: queueTTLSeconds, responseLanguage: responseLanguage)
    }

    private func deliver(_ text: String, wire: String, targetId: String?, draft: String, attachmentPaths: [String], attachmentSources: [AttachmentSource] = [], mode: SendMode? = nil, queueTTLSeconds: Int? = nil, agent: String? = nil, replacing: UUID? = nil) async -> Delivery {
        guard sendOverride != nil || (endpoint != nil && token != nil), canControl else { return Delivery(ok: false, id: nil) }
        if let ttl = queueTTLSeconds {
            guard [3600, 86400].contains(ttl), link == .connected,
                  state?.targets.first(where: { $0.id == targetId })?.capabilities?.queueDeadline == true else { return Delivery(ok: false, id: nil) }
        }
        // 直达：传输前复核目标仍是发起时的 agent（改名 / 换目标零请求，重试也复核）；插话还要复核目标的 nativeSteer。缺任一 = 没有记录，草稿保留。
        if let agent {
            guard state?.targets.first(where: { $0.id == targetId })?.agentName == agent else {
                return Delivery(ok: false, id: nil, refusal: LText(SendTimingCopy.directTargetChanged))
            }
            if mode == .steer, !(state?.targets.first { $0.id == targetId }?.nativeSteerEnabled ?? false) {
                return Delivery(ok: false, id: nil, refusal: LText(SendTimingCopy.directSteerUnavailable + String(localized: "，消息没有发出")))
            }
            if mode == .sendNow, state?.targets.first(where: { $0.id == targetId })?.capabilities?.nativeSendNow != true {
                return Delivery(ok: false, id: nil, refusal: LText(SendTimingCopy.directSendNowUnavailable + String(localized: "，消息没有发出")))
            }
        } else if mode == .sendNow {
            // 立即发送只属于原生直达：绑定或其他普通发送带上它，零请求。
            return Delivery(ok: false, id: nil, refusal: LText(SendTimingCopy.sendNowNotDirect + String(localized: "，消息没有发出")))
        }
        let id = UUID()
        let source: ResponseLanguageSource = replacing.flatMap { r in sent.first { $0.id == r } }.map { .fixed($0.responseLanguage) } ?? .current
        let wantedLanguage = agent == nil ? source.resolve(forWire: wire) : nil
        noteReportLanguage(wantedLanguage)
        let reportLanguage = wantedLanguage.flatMap { $0 == .en && state?.bridge?.supportsReportLanguage(.en) != true ? nil : $0 } // 旧 Bridge 不声明能力：不发字段（它只会生成中文）
        let gen = sessionGen, conn = connectionId // 传输期间忘记配对 / 换连接：结果只属于发出它的代次
        // 守卫已通过：在首次 await 之前，同一段同步代码里原子替换旧失败记录（R1：传输期间不出现两条相同正文）。
        // 被确定拒绝时原记录原位放回（正文、草稿、附件与错误都保留），重试失败不丢内容。
        var replaced: (index: Int, record: Sent)?
        if let replacing, let at = sent.firstIndex(where: { $0.id == replacing }) { replaced = (at, sent.remove(at: at)) }
        sent.append(Sent(id: id, text: text, at: Date(), afterSeq: history.last?.seq ?? 0, targetId: targetId, anchorT: history.last?.t ?? Int(Date().timeIntervalSince1970 * 1000), draft: draft, attachmentPaths: attachmentPaths, attachmentSources: attachmentSources, agent: agent, mode: mode, queueTTLSeconds: queueTTLSeconds, sessionEpoch: targetId.flatMap { transcripts[$0]?.sessionEpoch },
                         ownerKind: agent == nil && targetId != nil ? OwnerOperation.kind(ofWire: wire) : nil, anchorItemId: targetId.flatMap { transcripts[$0]?.items.last?.id }, responseLanguage: reportLanguage))
        do {
            let r = try await transmit(wire, id, mode: mode, queueTTLSeconds: queueTTLSeconds, responseLanguage: reportLanguage)
            if let i = sent.firstIndex(where: { $0.id == id }) { sent[i].eventKey = r.eventKey }
            // 原生插话的「并入未验证」只在权威快照里（progress 的 finished 不带 reason）：受理后取一次快照细化状态。
            if agent != nil, mode == .steer || mode == .sendNow { await refresh() }
            return Delivery(ok: true, id: id)
        } catch {
            // 代次已变（忘记配对 / 换连接）：旧结果一律不写——不恢复旧记录、不写错误、不给提示，新一代的输入框原样保留（H3-1）。
            guard gen == sessionGen, conn == connectionId else { return Delivery(ok: false, id: nil) }
            // 确定拒绝（服务端明确未写入）：不留失败记录，草稿保留并给固定原因；其余错误保留原失败记录（可重试）。
            if let action = error as? MessageActionError, action.isDefinitiveRefusal {
                sent.removeAll { $0.id == id }
                if let replaced { sent.insert(replaced.record, at: min(replaced.index, sent.count)) }
                return Delivery(ok: false, id: nil, refusal: LText(Self.describe(error, sendNow: mode == .sendNow)))
            }
            if let i = sent.firstIndex(where: { $0.id == id }) {
                // send_now 结果不明时不写确定失败（失败会给出“重试”）：保留事实，由投影显示中性「结果未知」。
                if mode == .sendNow { sent[i].resultUnknown = true } else { sent[i].error = LText(Self.describe(error)) }
            }
            return Delivery(ok: false, id: id)
        }
    }

    /// 目标的立即插入能力与状态（界面用；未知 = 旧 Bridge 未声明）。
    func steerAvailability(_ threadId: String?) -> SteerAvailability {
        state?.targets.first { $0.id == threadId }?.steerAvailability ?? .unknown
    }
    func targetStatus(_ threadId: String?) -> String? { state?.targets.first { $0.id == threadId }?.status }
    /// 直达的原生插话能力（Bridge 的 nativeSteer；缺省 = 不支持）。绑定目标的 hook steer 不授权它。
    func nativeSteerEnabled(_ threadId: String?) -> Bool { state?.targets.first { $0.id == threadId }?.nativeSteerEnabled ?? false }
    /// 直达的立即发送能力（Bridge 的 nativeSendNow）：三态，nil 隐藏、false 灰显、true 可选；不借 nativeSteer 或 hook steer。
    func nativeSendNow(_ threadId: String?) -> Bool? { state?.targets.first { $0.id == threadId }?.capabilities?.nativeSendNow }
    /// 会话记录回执与本机权威指令的精确关联（只看 eventKey）；对不上返回 nil。
    func linkedCommand(_ receipt: TranscriptReceipt?) -> ApiCommand? {
        guard let k = receipt?.eventKey else { return nil }
        return commands[k]
    }

    /// 重新发送是一个新的用户动作：只接收本设备的确定过期行，保留旧行并生成新 UUID。
    func resendExpired(_ command: ApiCommand) async {
        guard let c = commands[command.key], c.reason == "queue_expired", c.state == "paused",
              c.origin == "api", let ownId = device?.id, c.device?.id == ownId, canControl,
              link == .connected, device?.paused != true, !commandBusy.contains(c.key),
              let targetId = c.targetId, let target = state?.targets.first(where: { $0.id == targetId }) else { return }
        guard sendBlocker() == nil else { return }
        let original = sent.first(where: { $0.eventKey == c.key })
        guard ComposerRules.missingFiles(paths: original?.attachmentPaths ?? []).isEmpty else {
            commandNotes[c.key] = LText(String(localized: "附件已不可用，请重新选择后发送"))
            return
        }
        guard let text = original?.text ?? ((!c.truncated && c.text != "（内容已隐藏）") ? c.text : nil) else {
            commandNotes[c.key] = LText(String(localized: "原文不完整，请重新输入后发送"))
            return
        }
        let gen = sessionGen
        commandBusy.insert(c.key)
        defer { if gen == sessionGen { commandBusy.remove(c.key) } }
        switch SendTimingRules.resendRoute(c, bindingTargetId: state?.binding?.targetId, target: target) {
        case .bound:
            _ = await send(text, mode: .queue)
        case .direct(let agent):
            _ = await sendDirect(text, agent: agent, threadId: targetId)
        case .blocked:
            commandNotes[c.key] = LText(String(localized: "原目标或绑定已变化，请先确认会话再发送"))
        }
    }

    /// 撤回排队中的消息（单飞；失败只留固定提示，不改本地状态）。
    /// 撤回只核身份与 control，不因暂停拒绝（撤回是收尾动作）。
    func withdrawQueued(_ c: ApiCommand) async {
        guard canControl else { commandNotes[c.key] = LText(Self.readOnlyNote); return }
        let ok = await runCommandAction(c.key, .withdraw) { client in _ = try await client.withdraw(eventKey: c.key) }
        // 只在服务端确认撤回之后回填原文（O1-327）。
        if ok { offerWithdrawnDraft(c) }
    }

    /// 撤回成功后等待回填的原文（按草稿键保存）：输入框为空时已直接回填；有内容时只保留这里，由用户选择替换或忽略。
    struct WithdrawnDraftOffer: Equatable {
        let text: String
        let attachmentPaths: [String]
        let attachmentSources: [AttachmentSource]
    }
    private(set) var withdrawnOffers: [String: WithdrawnDraftOffer] = [:]
    func withdrawnOffer(_ threadId: String) -> WithdrawnDraftOffer? { withdrawnOffers[draftKey(threadId)] }
    /// 测试入口：装入凭据（刷新与真实传输需要它们；正式路径仍由配对与钥匙串装入）。
    // 测试接缝：消息发送与排队操作的传输会话；缺省 nil = 生产直连会话。
    var messageTransport: URLSession?
    func setCredentialsForTest(endpoint ep: BridgeEndpoint?, token t: String?) { endpoint = ep; token = t }

    /// 原文只来自本机发送时保存的记录（草稿与附件路径）；没有记录时不回填，也不剥离任何署名（O1-331 R1）。
    private func offerWithdrawnDraft(_ c: ApiCommand) {
        guard let threadId = c.targetId else { return }
        // 只来自本机发送记录；没有记录就不回填（不按外形猜测署名，O1-331 R1）。
        guard let m = sent.first(where: { $0.eventKey == c.key }) else { return }
        let offer = WithdrawnDraftOffer(text: m.draft.isEmpty ? m.text : m.draft, attachmentPaths: m.attachmentPaths, attachmentSources: m.attachmentSources)
        guard !(offer.text.isEmpty && offer.attachmentPaths.isEmpty) else { return }
        let key = draftKey(threadId)
        if composerDrafts[key]?.isEmpty ?? true, fillComposer(threadId, offer) { return }
        withdrawnOffers[key] = offer
    }

    /// 把原文放进输入框（附件按记录恢复；附件缺失则整个不恢复，返回 false）。
    private func fillComposer(_ threadId: String, _ offer: WithdrawnDraftOffer) -> Bool {
        let record = Sent(id: UUID(), text: offer.text, at: Date(), afterSeq: 0, targetId: threadId, draft: offer.text, attachmentPaths: offer.attachmentPaths, attachmentSources: offer.attachmentSources)
        var text = ""
        var attachments: [ComposerAttachment] = []
        guard ComposerRules.restore(record, canEdit: true, draft: &text, attachments: &attachments) else { return false }
        let d = ComposerDraft(text: text, attachments: attachments)
        composerDrafts[draftKey(threadId)] = d.isEmpty ? nil : d
        withdrawnOffers[draftKey(threadId)] = nil
        return true
    }

    /// 用撤回的原文替换当前输入框内容（用户明确选择）。附件缺失时不替换，保留提示。
    @discardableResult
    func replaceWithWithdrawnOffer(_ threadId: String) -> Bool {
        let key = draftKey(threadId)
        guard let offer = withdrawnOffers[key], !composerBusy.contains(key) else { return false }
        guard fillComposer(threadId, offer) else { composerNotes[key] = LText(String(localized: "附件文件不存在或读不了，没能放回输入框；原文仍保留在这里")); return false }
        composerNotes[key] = nil
        return true
    }

    func dismissWithdrawnOffer(_ threadId: String) { withdrawnOffers[draftKey(threadId)] = nil }

    /// ⌘↩ 的唯一入口（界面闭包与测试共用）：直达工作中明确拦下，不落回普通发送；其余按 SendTimingRules 分流。
    /// 返回需要显示给用户的提示（nil = 已提交或无需提示）。
    @discardableResult
    func commandReturn(threadId: String, agent: String?) async -> LText? {
        // 与发送共用同一守卫（离线、暂停、未配对、只读）；绑定切换中不允许普通目标发送（与输入区一致）。
        if let reason = sendBlock() { return reason }
        if agent == nil, switchState != .idle { return LText(String(localized: "绑定切换中，稍后再发")) }
        // 工作状态以目标为准；直达工作中即普通排队（立即插入只从菜单显式选择），绑定目标沿用 hook 的 ⌘↩ 规则。
        let working = targetStatus(threadId) == "working"
        switch SendTimingRules.commandReturn(working: working, steer: steerAvailability(threadId), direct: agent != nil) {
        case .send(let mode):
            _ = await submitComposer(threadId: threadId, agent: agent, mode: mode)
            return nil
        case .blocked:
            let steer = steerAvailability(threadId), direct = agent != nil
            return LText({ if case .blocked(let r) = SendTimingRules.commandReturn(working: working, steer: steer, direct: direct) { return r }; return "" }())
        }
    }

    /// 改为立即插入 / 立即发送遵守发送的约束：在线、暂停、control、单飞；能力或目标已变 = 零请求。
    func promoteQueued(_ c: ApiCommand, mode: SendMode = .steer) async {
        if let reason = sendBlock() { commandNotes[c.key] = reason; return }
        // 按原消息的路由判定，不看当前视图：直达只看原目标的 nativeSteer / nativeSendNow；绑定消息只看原目标的 hook steer（能力撤销或不可用 = 零请求）。
        if mode == .sendNow {
            guard c.directAgent != nil else { commandNotes[c.key] = LText(SendTimingCopy.sendNowNotDirect); return }
            guard directRouteUnchanged(c) else { commandNotes[c.key] = LText(SendTimingCopy.directTargetChanged); return }
            guard nativeSendNow(c.targetId) == true else { commandNotes[c.key] = LText(SendTimingCopy.directSendNowUnavailable); return }
        } else if c.directAgent != nil {
            guard nativeSteerEnabled(c.targetId) else { commandNotes[c.key] = LText(SendTimingCopy.directSteerUnavailable); return }
        } else {
            guard steerAvailability(c.targetId) == .available else { commandNotes[c.key] = LText(SendTimingCopy.notPromotable); return }
        }
        let kind: QueuedAction = mode == .sendNow ? .promoteSendNow : .promote
        await runCommandAction(c.key, kind) { client in _ = try await client.promote(eventKey: c.key, mode: mode) }
    }

    /// 原直达消息的目标与 agent 仍与发起时一致（改名、换目标即不再是同一路由）。
    private func directRouteUnchanged(_ c: ApiCommand) -> Bool {
        guard let target = state?.targets.first(where: { $0.id == c.targetId }), let agent = c.directAgent else { return false }
        return SendTimingRules.resendRoute(c, bindingTargetId: nil, target: target) == .direct(agent)
    }

    /// 单飞：同一条消息同时只有一个操作；结果只写回发起时的代次（迟到结果丢弃，单飞槽不被新代次释放）。
    @discardableResult
    private func runCommandAction(_ key: String, _ kind: QueuedAction, _ op: (BridgeClient) async throws -> Void) async -> Bool {
        guard !commandBusy.contains(key) else { return false }
        let gen = sessionGen, conn = connectionId
        commandBusy.insert(key)
        commandRequests.append(kind)
        do {
            if let commandOverride { try await commandOverride(kind, key) }
            else if let endpoint, let token { try await op(BridgeClient(endpoint: endpoint, token: token, session: messageTransport)) }
            else { // 没有传输（没有凭据或客户端）：请求没有发出，明确失败，不能当成成功（O1-331 S1）
                guard gen == sessionGen else { return false }
                commandBusy.remove(key)
                commandNotes[key] = LText(String(localized: "未连接 Bridge，操作没有发出"))
                return false
            }
            guard gen == sessionGen else { return false }
            commandBusy.remove(key)
            commandNotes[key] = nil
            await refresh()
            // 成功要在最后一个 await 之后确认：刷新期间换了连接 / 忘记配对，就不回填（O1-331 R3）
            return gen == sessionGen && conn == connectionId
        } catch let e as MessageActionError {
            guard gen == sessionGen else { return false }
            commandBusy.remove(key)
            commandNotes[key] = LText(SendTimingCopy.text(for: e, sendNow: kind == .promoteSendNow))
            if case .conflict = e { await refresh() } // 冲突保留原消息：刷新为权威状态
            return false
        } catch {
            guard gen == sessionGen else { return false }
            commandBusy.remove(key)
            commandNotes[key] = LText(String(localized: "操作没有完成，请重新读取状态"))
            return false
        }
    }

    /// 发送守卫（权限 / 连接 / 暂停）：目标切换、线程内操作与提醒卡操作共用；返回不能发的原因，nil 为可发。
    func sendBlocker() -> String? { sendBlock()?.text }
    /// 同上，但返回可存进状态的延迟文案（语言切换后仍按当前语言显示）。
    func sendBlock() -> LText? {
        guard isPaired || sendOverride != nil else { return LText(String(localized: "还没有配对")) }
        guard canControl else { return LText(Self.readOnlyNote) }
        guard link == .connected else { return LText(String(localized: "未连接 Bridge，暂时不能发送")) }
        if device?.paused == true { return LText(String(localized: "这台设备已暂停接收任务，发送会被拒绝")) }
        return nil
    }

    /// 在某个线程里发起的操作（切到这里 / 面板 / 任务 / 重置）：本地回显与按 replyTo 关联的回执都留在发起的线程。被守卫拦下为 nil。
    @discardableResult
    func send(_ text: String, inThread threadId: String) async -> UUID? {
        guard sendBlocker() == nil else { return nil }
        return await deliver(text, wire: text, targetId: threadId, draft: "", attachmentPaths: []).id
    }

    /// 确认框捕获的“重置当前线程”请求：scope 与展示名在此刻固定（不读飞书绑定）。目标缺失或 id 不可无损解析为 nil（不给入口）。
    func ownerResetRequest(threadId: String) -> OwnerResetRequest? {
        guard let scope = ledgerScope(threadId), let t = state?.targets.first(where: { $0.id == threadId }) else { return nil }
        return OwnerResetRequest(scope: scope, displayName: ThreadIdentity.title(t))
    }

    enum OwnerResetDeferred { case sent(UUID), refused(LText) }
    /// 确认后执行：复核捕获的 scope 仍是当前线程 / 连接与权限，任一不满足零发送；通过后走 owner 原文通道（不经 composer / 直达，不带“派给”）。
    func confirmOwnerReset(_ r: OwnerResetRequest) async -> OwnerResetStart {
        switch await confirmOwnerResetDeferred(r) {
        case .sent(let id): return .sent(id)
        case .refused(let why): return .refused(why.text)
        }
    }

    /// 同上，拒绝原因以延迟文案返回：视图可以把它存进状态，语言切换后仍按当前语言显示（Kit 的 OwnerResetStart 只带 String）。
    func confirmOwnerResetDeferred(_ r: OwnerResetRequest) async -> (OwnerResetDeferred) {
        guard ledgerScope(r.scope.targetId) == r.scope, state?.targets.contains(where: { $0.id == r.scope.targetId }) == true else { return .refused(LText(OwnerOperationCopy.scopeChanged)) }
        if let why = sendBlock() { return .refused(why) }
        guard let id = await send(r.command, inThread: r.scope.targetId) else { return .refused(sendBlock() ?? LText(String(localized: "没有发出去：连接或权限刚刚变了"))) }
        return .sent(id)
    }

    /// owner 操作（含已完成的结果）在线程里的稳定位置：锚在可见窗口内就紧跟其后，否则进入“本机操作记录”分组（只在最新窗）。投影只在数据变化时重算，不绑定滚动。
    func ownerPlacement(threadId: String, visibleItemIds: Set<String>) -> OwnerPlacement<Sent> {
        let ops = sent.filter { $0.targetId == threadId && $0.ownerKind != nil }
            .sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
        let latest = ThreadTailRules.isLatest(transcripts[threadId])
        return OwnerPlacementRules.place(ThreadRow.withRejections(ops, history: history).map { ($0, $0.anchorItemId) }, visibleItemIds: visibleItemIds, allowLocal: latest)
    }

    /// 不归任何线程（收件箱提醒卡等）：界面按返回的编号读自己的结果（outcome）；失败与拒绝进收件箱提醒区。
    @discardableResult
    func sendTracked(_ text: String) async -> UUID? {
        guard sendBlocker() == nil else { return nil }
        return await deliver(text, wire: text, targetId: nil, draft: "", attachmentPaths: []).id
    }

    /// 某次发送关联到的全部回执正文：只按本次发送的 replyTo（eventKey）收齐，按 seq 排序；别的发送的回执、无关的交错回执都不会混进来。
    func receiptItems(of id: UUID, statusPhase: OutgoingPhase? = nil) -> [HistoryItem] {
        guard let k = sent.first(where: { $0.id == id })?.eventKey else { return [] }
        return history.filter { $0.replyTo == k && !QueueStatusPresentation.statusCoversAck(uuid: $0.uuid, eventKey: k, phase: statusPhase) }.sorted { $0.seq < $1.seq }
    }
    func receipts(of id: UUID, statusPhase: OutgoingPhase? = nil) -> [String] { receiptItems(of: id, statusPhase: statusPhase).map(\.text) }

    /// 某次发送的结果：发送失败原因，或关联到的全部回执正文。长的面板 / 任务正文会分成多条同 replyTo 的回执，这里按 seq 收齐拼接，迟到的后一片到了再补上。
    /// statusPhase：调用方已解析的有效状态；气泡状态行已表达的 native 投递 ack 不再重复进回执正文（A1-011，数据不删）。
    /// `reply` 是回执原文（解析用）；`display` 是同一批回执在当前显示语言下的正文（只给界面显示）。
    func outcome(of id: UUID, statusPhase: OutgoingPhase? = nil) -> (reply: String?, error: LText?, display: String?)? {
        guard let s = sent.first(where: { $0.id == id }) else { return nil }
        let items = receiptItems(of: id, statusPhase: statusPhase)
        return (items.isEmpty ? nil : items.map(\.text).joined(separator: "\n"), s.error, items.isEmpty ? nil : items.map(ReceiptText.display).joined(separator: "\n"))
    }

    /// 一次目标切换的追踪：用本次发送的编号读结果与候选；新的切换一开始就替换它（旧候选随之作废）。
    struct SwitchTrack: Equatable { let id: UUID; let project: String; let agent: String?; let threadId: String? }
    private(set) var switchTrack: SwitchTrack?

    /// 当前切换的候选（回执说“匹配到 N 个 agent：a、b、c”）：按这次发送的回执实时求值，迟到的回执到了也能选；没有追踪时为空。
    var switchCandidates: [String] {
        guard let tr = switchTrack else { return [] }
        return receipts(of: tr.id).lazy.map { Self.switchCandidates(in: $0) }.first { !$0.isEmpty } ?? []
    }

    /// 切换结果（回执正文 / 失败原因）：只给发起它的线程看。
    func switchOutcome(for threadId: String?) -> (reply: String?, error: LText?, display: String?)? {
        guard let tr = switchTrack, tr.threadId == nil || tr.threadId == threadId else { return nil }
        return outcome(of: tr.id)
    }

    /// 从回执里解析“目标匹配到 N 个 agent：a、b、c”这类候选（与 iPhone 同一规则）。
    static func switchCandidates(in text: String?) -> [String] {
        guard let text, text.hasPrefix(OwnerCommand.rejectedNotVerified) else { return [] }
        guard let r = text.range(of: OwnerCommand.multiMatchMarker), let end = text[r.upperBound...].firstIndex(of: "。") else { return [] }
        return text[r.upperBound..<end].split(separator: "、").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("等 ") }
    }

    /// 绑定是否已是想要的目标：知道明确目标身份就只比身份；否则比项目名，且指定了 agent 时 agent 名也必须相同（同项目的另一个 agent 不算成功）。
    static func bindingConfirms(_ b: PalmhelmKit.Binding?, project: String, agent: String?, targetId: String?) -> Bool {
        guard let b else { return false }
        if let targetId { return b.targetId == targetId }
        guard b.projectName == project else { return false }
        if let agent { return b.agentName == agent }
        return true
    }

    private enum SwitchResult { case confirmed, rejected, timedOut }

    /// 切换目标：HTTP 受理不等于已切换；之后在绝对 5 秒期限内（含请求时间）拉权威 state 确认绑定。
    /// 单飞（行、迟到候选、候选按钮共用）；经过既有的权限 / 连接 / 暂停守卫；新操作一开始就作废旧候选；结果归发起线程。
    /// 确认按明确的目标身份（targetId，或 项目名 + agent 名），不会把同项目的另一个 agent 当成功。
    /// 被 Bridge 业务拒绝（含多匹配）时绑定没变：回到 idle，原因与候选由 switchOutcome / switchCandidates 呈现；确认超时才进入 failed：
    /// 普通发送保持关闭，直到下一次成功同步（事件流 switched 回执、重连、手动刷新）。
    func switchTo(project: String, agent: String? = nil, targetId: String? = nil, inThread threadId: String? = nil) async {
        guard switchState != .pending else { return }
        if let why = sendBlock() { switchTrack = nil; switchState = .failed(why); return }
        switchTrack = nil
        switchState = .pending
        let gen = sessionGen
        let text = OwnerCommand.switchTo(project: project, agent: agent)
        let d = await deliver(text, wire: text, targetId: threadId, draft: "", attachmentPaths: [])
        guard gen == sessionGen else { switchState = .idle; return } // 期间断开 / 忘记配对：旧结果不写
        guard d.ok, let id = d.id else { switchState = .failed(LText(String(localized: "切换指令发送失败"))); return }
        switchTrack = SwitchTrack(id: id, project: project, agent: agent, threadId: threadId)
        let result: SwitchResult = (try? await withDeadline(5) { [weak self] in
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(400))
                // 换了账号 / 停止后不再拉取新连接的快照（O1-338 S2）
                guard let self, await self.sessionGen == gen else { return SwitchResult.timedOut }
                if await self.rejected(id) { return .rejected }
                if (try? await self.pullState()) != nil, await self.bindingConfirmed(project: project, agent: agent, targetId: targetId) { return .confirmed }
            }
            return .timedOut
        }) ?? .timedOut
        guard gen == sessionGen else { switchState = .idle; return }
        switch result {
        case .confirmed, .rejected: switchState = .idle
        case .timedOut: switchState = .failed(LText(String(localized: "没能确认已切换到 \(project)\(agent.map { " · \($0)" } ?? "")，先别发送；同步成功后会自动恢复")))
        }
    }

    /// 从候选里选一个 agent 继续切换：能唯一对应到目标就按目标身份确认，否则按 项目名 + agent 名。
    func chooseSwitchCandidate(_ agent: String) async {
        guard let tr = switchTrack else { return }
        let match = (state?.targets ?? []).filter { $0.projectName == tr.project && $0.agentName == agent }
        await switchTo(project: tr.project, agent: agent, targetId: match.count == 1 ? match[0].id : nil, inThread: tr.threadId)
    }

    private func rejected(_ id: UUID) -> Bool { receipts(of: id).contains { $0.hasPrefix("rejected:") } }
    private func bindingConfirmed(project: String, agent: String?, targetId: String?) -> Bool {
        Self.bindingConfirms(state?.binding, project: project, agent: agent, targetId: targetId)
    }

    // ---- 收件箱提醒区（无目标条目的去向）----
    /// 提醒（不计数）：无目标发送失败、没有被线程承接的 rejected: 回执。restoreSendId：这条背后有可恢复的输入快照（未归属的恢复入口）。
    struct InboxAlert: Identifiable, Equatable {
        let id: String
        let text: String
        let t: Int?
        var restoreSendId: UUID?
        /// 背后的发送已恢复：提醒页立即移出（Kit ReminderRules 优先隐藏）。
        var restored = false
    }

    /// 无目标条目经 Kit 的 ThreadRouting 分流：请求 → 待答卡（approvals 是权威，不从 history 重造）；提醒 → 这里；纯回执（ack / switched / queued …）不展示。
    /// 只有线程承接的发送（targetId ≠ nil）才抑制它的拒绝回执：已在线程里可见就不重复进提醒；无目标发送的拒绝仍然进提醒。
    var inboxAlerts: [InboxAlert] {
        let shown = reminderVisibleIds
        return presentedAlertEntries().filter { shown.contains($0.alert.id) }.map(\.alert)
    }

    /// 最终呈现的提醒条目（新 → 旧，同一 sendId 只留最新一条）：未读数、标读批次与 inboxAlerts 共用这一集合；原始候选只用于 retained 与恢复别名。
    func presentedAlertEntries() -> [(time: Int, order: Int, alert: InboxAlert)] {
        var seen = Set<UUID>()
        return alertEntries().reversed().filter { e in
            guard let sid = e.alert.restoreSendId else { return true }
            return seen.insert(sid).inserted
        }
    }

    /// 提醒区的全部候选（未裁剪、按事件时间升序）：可见性与「仍保留着的提醒 id」都从这里来。
    private func alertEntries() -> [(time: Int, order: Int, alert: InboxAlert)] {
        // 按事件时间合并：网络失败（Sent.at）与拒绝（HistoryItem.t，缺失时用它回复的那次发送的时间，再没有就 0），同时间按 种类、再按序号 / 编号稳定排序。
        // 不设展示上限（t18）；未恢复的有效发送快照（restoreSendId 非空）按 sendId 去重（取最新那条），
        // 同一 sendId 的别名只显示最新一条，避免重复的恢复入口。
        var entries: [(time: Int, order: Int, alert: InboxAlert)] = []
        for s in sent where s.targetId == nil {
            guard let err = s.error else { continue }
            let t = Int(s.at.timeIntervalSince1970 * 1000)
            entries.append((t, 0, InboxAlert(id: "sent:\(s.id.uuidString)", text: String(localized: "发送失败 · \(err.text)"), t: t, restoreSendId: Self.restorable(s) ? s.id : nil, restored: s.restored)))
        }
        let correlated = Set(sent.filter { $0.targetId != nil }.compactMap(\.eventKey))
        for it in history where it.target == nil && !it.uuid.hasPrefix(UuidPrefix.blockedReminder) { // 超时提醒走 blockedReminders（带重置操作）
            guard ThreadRouting.route(.receipt(it.text)) == .alert, !correlated.contains(it.replyTo ?? "") else { continue }
            let owner = it.replyTo.flatMap { k in sent.first { $0.eventKey == k && $0.targetId == nil } }
            let ownerAt = owner.map { Int($0.at.timeIntervalSince1970 * 1000) }
            // 有效时间缺失时用精确关联的发送时间；都没有就是 nil（排序用的 0 不冒充真实时间）
            entries.append((it.t ?? ownerAt ?? 0, 1 + it.seq, InboxAlert(id: "rj:\(it.uuid)", text: ReceiptText.summary(it), t: it.t ?? ownerAt, restoreSendId: owner.flatMap { Self.restorable($0) ? $0.id : nil }, restored: owner?.restored ?? false)))
        }
        entries.sort { ($0.time, $0.order, $0.alert.id) < ($1.time, $1.order, $1.alert.id) }
        return entries
    }
    private static func restorable(_ s: Sent) -> Bool { !s.restored && (!s.draft.isEmpty || !s.attachmentPaths.isEmpty) }

    /// 当前阻塞投影（state / targets 帧同源；nil = 旧 Bridge，不能当成没有阻塞）。
    private(set) var currentBlocked: [CurrentBlocked]?
    /// currentBlocked 的证据是否新鲜（Bridge 的 Herdr 快照未过期）：false / nil 都不能当作可靠的当前阻塞。
    private(set) var currentBlockedFresh: Bool?
    /// 提醒已读账本（Bridge 身份 + 回执 uuid，持久化）：只在打开提醒弹层时快照式标已读。
    var reminderLedger = ReminderLedger.load(from: AppDefaults.standard) // internal：测试可换成干净账本
    private(set) var reminderVersion = 0
    /// 账本键的身份（见 ReminderLedger.identity）：Bridge id；旧 Bridge 没有 id 时退回本机配对设备 id；都没有则只在内存里（不持久化）。
    var reminderIdentity: (id: String, persistent: Bool) { ReminderLedger.identity(bridgeId: state?.bridge?.id, accountKey: device?.id) }
    /// 仍保留着的提醒 id：历史窗口里的超时提醒与回执、本机 Sent 里的失败项（不论展示时是否被上限裁掉）——它们的已读标记受保护，不被容量淘汰。
    private var retainedReminderIds: Set<String> { Set(allReminders.map(\.uuid)).union(alertEntries().map(\.alert.id)) }
    private func persistLedger() { if reminderIdentity.persistent { reminderLedger.save(to: AppDefaults.standard) } }
    var allReminders: [HistoryItem] { history.filter { $0.uuid.hasPrefix(UuidPrefix.blockedReminder) } }
    /// 超时提醒（blocked，回执 nblocked2:）：可见性见 ReminderRules.visibleIds；新 → 旧。
    var blockedReminders: [HistoryItem] {
        let shown = reminderVisibleIds
        return allReminders.filter { shown.contains($0.uuid) }.sorted { $0.seq > $1.seq }
    }
    /// 提醒入口的未读数：可见项中仍未读的个数（rejected 回执与发送失败共用同一个账本）。
    var unreadReminderCount: Int {
        let shown = reminderVisibleIds
        return reminderCandidates().filter { shown.contains($0.id) && !$0.seen }.count
    }
    /// 提醒页当前可见的 id。时钟（timeValidityVersion：有效集合变化才发布）、身份与本次打开的保留集在这里带入；规则只在 Kit。
    private var reminderVisibleIds: Set<String> {
        _ = reminderVersion
        _ = timeValidityVersion
        return reminderVisibleIds(atMs: Int(currentDate.timeIntervalSince1970 * 1000))
    }
    func reminderVisibleIds(atMs nowMs: Int) -> Set<String> {
        let retained = reminderPresentation?.bridgeId == reminderIdentity.id ? reminderPresentation?.retained ?? [] : []
        return Set(ReminderRules.visibleIds(reminderCandidates(), retained: retained, nowMs: nowMs))
    }
    /// 提醒页的候选（未裁剪）：超时提醒的有效时间缺失时用投影里的 blockedSince；可恢复失败在恢复前不按已读隐藏。
    func reminderCandidates() -> [ReminderCandidate] {
        let id = reminderIdentity.id
        let blocked = allReminders.map { r in
            ReminderCandidate(id: r.uuid, t: r.t ?? ReminderRules.blockedSince(of: r, currentBlocked: currentBlocked), kind: .blocked(reminderStatus(r)), seen: reminderLedger.isSeen(bridgeId: id, r))
        }
        let plain = presentedAlertEntries().map { e in
            ReminderCandidate(id: e.alert.id, t: e.alert.t, kind: .plain, seen: reminderLedger.isSeen(bridgeId: id, id: e.alert.id), restorable: e.alert.restoreSendId != nil, restored: e.alert.restored)
        }
        return blocked + plain
    }
    /// 一次提醒页展示（弹层打开到关闭）：开始时可见的那批是本次保留集，只豁免本次标已读造成的隐藏；身份变化即失效。
    struct ReminderPresentation: Equatable { let bridgeId: String; let retained: Set<String> }
    private(set) var reminderPresentation: ReminderPresentation?
    /// 卡片上的等待时长（分钟）：取投影里当前的 blockedSince；解除阻塞后再次阻塞按新的起点算。
    func waitedMinutes(_ item: HistoryItem, at date: Date? = nil) -> Int? {
        ReminderRules.waitedMinutes(of: item, currentBlocked: currentBlocked, nowMs: Int((date ?? currentDate).timeIntervalSince1970 * 1000))
    }
    func reminderStatus(_ item: HistoryItem) -> ReminderStatus {
        ReminderRules.status(of: item, currentBlocked: currentBlocked, evidenceFresh: currentBlockedFresh, linked: activityLinked, commandsTruncated: state?.commandsTruncated ?? false)
    }
    /// 打开提醒弹层：只标「此刻看到的」这一批；同一身份的重复打开不重建批次，页内新到的提醒仍是未读。
    func openReminders() {
        guard reminderPresentation?.bridgeId != reminderIdentity.id else { return }
        let id = reminderIdentity.id
        // 一次标记（超时提醒 + 普通回执 + 发送失败，同一个账本、同一次快照）；豁免只给本次由未读变已读的条目——
        // 打开前已读的（含仍是当前阻塞的）靠自身条件显示，不因这次打开获得新豁免。
        let batch = ReminderRules.visibleIds(reminderCandidates(), retained: [], nowMs: Int(currentDate.timeIntervalSince1970 * 1000))
        let fresh = batch.filter { !reminderLedger.isSeen(bridgeId: id, id: $0) }
        reminderLedger.markSeen(bridgeId: id, ids: fresh, retained: retainedReminderIds)
        persistLedger()
        reminderPresentation = ReminderPresentation(bridgeId: id, retained: Set(fresh))
        reminderVersion += 1
    }
    func closeReminders() { reminderPresentation = nil; reminderVersion += 1 }
    /// 身份（Bridge）变化即结束本次展示：旧批次的保留集不跟到新身份上。视图仍开着时由 onChange(reminderIdentity) 按新身份重开。
    private func endReminderPresentationIfIdentityChanged() {
        guard let p = reminderPresentation, p.bridgeId != reminderIdentity.id else { return }
        closeReminders()
    }
    /// 首次见到这个 Bridge：旧提醒归历史（仍是当前阻塞的、可恢复的失败除外）。用「本次成功同步」的证据判定当前性——
    /// 首次连接时 pullState 跑在 link 变成 connected 之前，不能看 link（否则当前阻塞的提醒会被标成已读）。
    func baselineReminders(from s: BridgeState) {
        var keep = Set(allReminders.filter {
            ReminderRules.status(of: $0, currentBlocked: s.currentBlocked, evidenceFresh: s.currentBlockedFresh, linked: true, commandsTruncated: s.commandsTruncated ?? false).allowsReset
        }.map(\.uuid))
        let entries = alertEntries()
        keep.formUnion(entries.filter { $0.alert.restoreSendId != nil }.map(\.alert.id)) // 可恢复的失败保持未读
        reminderLedger.baselineIfNeeded(bridgeId: reminderIdentity.id, ids: allReminders.map(\.uuid) + entries.map(\.alert.id), keepUnread: { keep.contains($0) }, retained: retainedReminderIds)
        persistLedger(); reminderVersion += 1
    }

    // ---- 超时提醒卡的「重置占用」（F2 / F3）----
    /// 一张提醒卡的本次发送：编号与在途状态放在 Session，按稳定提醒 id（连接身份 + 提醒 uuid）保存；卡重建、弹层 / 侧栏关闭重开都能恢复，结果仍用 outcome(of:) 读。
    struct ReminderSend: Equatable {
        var sendId: UUID?
        var busy = false
        /// 没发出去的原因（守卫拦下 / 连接或权限已变化）：回到卡上显示，不静默吞掉。
        var blocked: LText?
        /// 发送途中连接中断：结果未知（可能已受理）。不自动重发；重连后用户可再次操作。
        var interrupted = false
    }
    private(set) var reminderSends: [String: ReminderSend] = [:]
    func reminderKey(_ item: HistoryItem) -> String { "\(connectionId)~\(item.uuid)" }
    func reminderSend(_ item: HistoryItem) -> ReminderSend { reminderSends[reminderKey(item)] ?? ReminderSend() }
    /// 入口守卫：离线 / 设备暂停 / 只读 / 未配对时卡上同步显示原因并禁用（nil 为可点）。
    func resetOccupancyBlocker() -> String? { sendBlocker() }

    /// 确认后真正发送「重置占用」：入口守卫保留；被拦下（含确认框打开期间连接 / 权限变了）要把原因留在卡上。同一张卡同时只发一次。
    func resetOccupancy(for item: HistoryItem, name: String) async {
        let key = reminderKey(item)
        guard reminderSends[key]?.busy != true else { return }
        if let why = sendBlock() { reminderSends[key] = ReminderSend(sendId: reminderSends[key]?.sendId, busy: false, blocked: why); return }
        // 确认框打开期间目标可能已换成别的命令：此刻必须仍是「当前」，否则零发送（Bridge 也会按 eventKey 再核一次）。
        guard case .current(let eventKey) = reminderStatus(item) else {
            reminderSends[key] = ReminderSend(sendId: reminderSends[key]?.sendId, busy: false, blocked: LText(String(localized: "这条提醒已不是当前状态，没有重置")))
            return
        }
        reminderSends[key] = ReminderSend(sendId: nil, busy: true, blocked: nil)
        let gen = sessionGen
        let id = await sendTracked(OwnerCommand.resetOccupancy(name, expectedEventKey: eventKey))
        guard gen == sessionGen else { return } // 期间断开 / 忘记配对：旧结果不写
        if let id { reminderSends[key] = ReminderSend(sendId: id, busy: false, blocked: nil) }
        else { reminderSends[key] = ReminderSend(sendId: nil, busy: false, blocked: sendBlock() ?? LText(String(localized: "没有发出去：连接或权限刚刚变了"))) }
    }

    /// 这个目标当前未解决的身份暂停（服务端权威，TargetSummary.identityPauseKey）；界面据此显示「确认是同一个会话，恢复」。
    func identityPauseKey(_ threadId: String?) -> String? { state?.targets.first { $0.id == threadId }?.identityPauseKey }

    /// 身份暂停的条件恢复：发「恢复身份 #<eventKey>」（需要 control、在线）。目标与执行端由服务端从暂停记录解析；服务端逐项核验，不满足就零目标写入；
    /// 不放弃在途命令，直达线程保持直达，不改变绑定。返回给界面的固定提示（成功为 nil）。
    func recoverIdentityPause(eventKey: String) async -> String? {
        if let why = sendBlocker() { return why }
        guard let cmd = ReceiptText.identityRecoverCommand(eventKey: eventKey) else { return String(localized: "这个暂停记录不能直接用于恢复，请到 Herdr 处理") }
        let id = await sendTracked(cmd)
        return id == nil ? (sendBlocker() ?? String(localized: "没有发出去：连接或权限刚刚变了")) : nil
    }

    // ---- 输入区草稿（按 连接身份 + targetId 保存在内存）----
    /// 编辑中的草稿与附件放在稳定的 Session 里：切线程、切 对话 / 统计、换主题、窗口重建都不丢，也不会串到别的目标或别的 Bridge。
    struct ComposerDraft {
        var text = ""
        var attachments: [ComposerAttachment] = []
        var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
    }
    private(set) var composerDrafts: [String: ComposerDraft] = [:]
    /// 正在发送的输入区（busy）：放在 Session 里，视图被撤掉重建也不会出现“看起来空闲、实际在途”的重复发送。
    private(set) var composerBusy: Set<String> = []

    /// 草稿键 = 连接身份（Bridge 编号）+ 目标；Mac 的线程编号就是目标编号。
    func draftKey(_ threadId: String) -> String { markKey(threadId) }
    func draft(_ threadId: String) -> ComposerDraft { composerDrafts[draftKey(threadId)] ?? ComposerDraft() }
    func setDraft(_ d: ComposerDraft, for threadId: String) { composerDrafts[draftKey(threadId)] = d.isEmpty ? nil : d }
    func isComposerBusy(_ threadId: String) -> Bool { composerBusy.contains(draftKey(threadId)) }
    /// 输入区的提示（附件文件缺失等）：按线程保存在 Session，视图重建不丢；下一次成功发送 / 恢复时清掉。
    private(set) var composerNotes: [String: LText] = [:]
    func composerNote(_ threadId: String) -> LText? { composerNotes[draftKey(threadId)] }
    private static func missingNote(_ names: [String], suffix: String) -> String { String(localized: "附件文件不存在或读不了：\(names.joined(separator: "、"))，\(suffix)") }

    /// 输入区发送：取草稿快照 → 发送 → 收尾。全在 Session 里完成，视图中途被撤掉也不丢结果。
    /// 入账（有发送记录，成功或失败）即清掉本次快照里的附件，草稿仅在期间未被改动时清空；守卫拦下（没有记录）保留全部。返回是否真正成功。
    @discardableResult
    func submitComposer(threadId: String, agent: String?, mode: SendMode? = nil, queueTTLSeconds: Int? = nil) async -> Bool {
        let key = draftKey(threadId)
        guard !composerBusy.contains(key) else { return false }
        let snap = composerDrafts[key] ?? ComposerDraft()
        let body = snap.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(body.isEmpty && snap.attachments.isEmpty) else { return false }
        // 服务边界：远程模式不转发图片（远端拿不到文件字节）。零发送、草稿与附件原样保留；普通文本照常发送
        if !snap.attachments.isEmpty, connectionModeProvider() == .remote {
            composerNotes[key] = LText(String(localized: "远程模式下暂不支持发送图片（图片只在这台 Mac 上）"))
            return false
        }
        // 发送前确认所有附件文件还在、读得了（加入后被删 / 移走）：缺失 → 零发送、保留草稿、说清缺哪个
        let missing = ComposerRules.missingFiles(paths: snap.attachments.map(\.path))
        guard missing.isEmpty else { composerNotes[key] = LText(Self.missingNote(missing, suffix: String(localized: "没有发送，草稿已保留"))); return false }
        composerNotes[key] = nil
        let text = ((body.isEmpty ? [] : [body]) + snap.attachments.map { String(localized: "图片：\($0.path)") }).joined(separator: "\n")
        let paths = snap.attachments.map(\.path)
        let sources = snap.attachments.map(\.source)
        composerBusy.insert(key)
        defer { composerBusy.remove(key) }
        let gen = sessionGen
        // 入账（有发送记录，成功或失败）即清掉本次快照（#57）；守卫拦下、没有记录时保留草稿。
        let delivery = if let agent {
            await sendDirectDelivery(text, agent: agent, threadId: threadId, draft: snap.text, attachmentPaths: paths, attachmentSources: sources, queueTTLSeconds: queueTTLSeconds, mode: mode)
        } else {
            await sendDelivery(text, draft: snap.text, attachmentPaths: paths, attachmentSources: sources, mode: mode, queueTTLSeconds: queueTTLSeconds)
        }
        guard gen == sessionGen else { return false } // 代次已变：不结算草稿、不写提示，新一代的输入框原样保留
        if let refusal = delivery.refusal { composerNotes[key] = refusal }
        let ok = delivery.ok
        var cur = composerDrafts[key] ?? ComposerDraft()
        ComposerRules.settle(recorded: delivery.id != nil, draftSnap: snap.text, attachSnap: snap.attachments, draft: &cur.text, attachments: &cur.attachments)
        composerDrafts[key] = cur.isEmpty ? nil : cur
        if ok { withdrawnOffers[key] = nil } // 发出新消息后，之前撤回的原文提示不再适用
        return ok
    }

    /// 把业务被拒的发送恢复到本线程输入框（发送期间冻结：不改草稿）。
    @discardableResult
    func restoreRejected(_ m: Sent, threadId: String) -> Bool {
        let key = draftKey(threadId)
        var cur = composerDrafts[key] ?? ComposerDraft()
        let editable = ComposerRules.canEdit(canControl: canControl, busy: composerBusy.contains(key))
        // 先完整验证：附件缺失时整个恢复不做、不标已恢复，快照与「恢复到输入框」入口保留并说明
        let missing = ComposerRules.missingFiles(paths: m.attachmentPaths)
        if editable, !missing.isEmpty { composerNotes[key] = LText(Self.missingNote(missing, suffix: String(localized: "没能恢复，原发送记录与恢复入口保留"))); return false }
        guard ComposerRules.restore(m, canEdit: editable, draft: &cur.text, attachments: &cur.attachments) else { return false }
        composerDrafts[key] = cur.isEmpty ? nil : cur
        composerNotes[key] = nil
        markRestored(m.id)
        return true
    }

    /// 重试一次发送失败的消息（#57）：按原文、原草稿、原附件、原模式与排队期限重新发出，走原来的普通 / 直达路径。
    /// 守卫（重入、附件缺失、普通重试的目标已变）不过：不发送，失败记录保留，composerNotes 说明原因。
    /// 守卫通过后，在首次 await 之前就用新记录原子替换旧失败记录（传输期间只有一条气泡）；守卫拦下（没有新记录）时旧记录保留。
    @discardableResult
    func resendFailed(_ m: Sent, threadId: String) async -> Bool {
        let key = draftKey(threadId)
        guard !resendBusy.contains(m.id), sent.contains(where: { $0.id == m.id }) else { return false }
        // 普通重试沿用当前绑定投递：原目标与当前绑定不一致就不发，不把 A 的消息改投到 B（R2）
        if m.agent == nil {
            guard let original = m.targetId else {
                composerNotes[key] = LText(String(localized: "这条消息没有记录原目标，不能重试，请重新输入后发送"))
                return false
            }
            if let current = state?.binding?.targetId, current != original {
                let name = state?.targets.first { $0.id == original }.map(ThreadIdentity.title) ?? original
                composerNotes[key] = LText(String(localized: "这条消息原本发给 \(name)，当前绑定已变，请重新发送"))
                return false
            }
            if state?.binding?.targetId == nil {
                let originalName = state?.targets.first { $0.id == original }.map(ThreadIdentity.title) ?? original
                composerNotes[key] = LText(String(localized: "当前没有绑定目标，这条消息原本发给 \(originalName)，请重新发送"))
                return false
            }
        }
        let missing = ComposerRules.missingFiles(paths: m.attachmentPaths)
        guard missing.isEmpty else { composerNotes[key] = LText(Self.missingNote(missing, suffix: String(localized: "没有重新发送，失败记录保留"))); return false }
        composerNotes[key] = nil
        resendBusy.insert(m.id)
        defer { resendBusy.remove(m.id) }
        let gen = sessionGen
        let delivery: Delivery
        if let agent = m.agent {
            delivery = await sendDirectDelivery(m.text, agent: agent, threadId: threadId, draft: m.draft, attachmentPaths: m.attachmentPaths, attachmentSources: m.attachmentSources, queueTTLSeconds: m.queueTTLSeconds, mode: m.mode, replacing: m.id)
        } else {
            delivery = await sendDelivery(m.text, draft: m.draft, attachmentPaths: m.attachmentPaths, attachmentSources: m.attachmentSources, mode: m.mode, queueTTLSeconds: m.queueTTLSeconds, replacing: m.id)
        }
        guard gen == sessionGen else { return false } // 代次已变：旧记录已不恢复，也不写提示进新一代
        if let refusal = delivery.refusal { composerNotes[key] = refusal }
        return delivery.ok
    }

    /// 未归属的失败发送（没有目标的快照）：只在用户点「恢复到输入框」时，恢复到**当时选中的线程**的输入框。
    /// 不自动投给当前线程；输入框里已有内容 / 正在发送 / 只读时不覆盖，返回原因。成功后标记已恢复（提醒里的恢复入口随之消失）。
    func restoreUnattributed(_ sendId: UUID) -> LText? {
        guard let m = sent.first(where: { $0.id == sendId }), m.targetId == nil, Self.restorable(m) else { return LText(String(localized: "这条发送已经恢复过，或没有可恢复的内容")) }
        guard let threadId = selectedThread ?? selectedTarget else { return LText(String(localized: "先选一个目标的线程，再恢复到它的输入框")) }
        guard canControl else { return LText(Self.readOnlyNote) }
        let key = draftKey(threadId)
        guard !composerBusy.contains(key) else { return LText(String(localized: "这个输入框正在发送，稍后再恢复")) }
        var cur = composerDrafts[key] ?? ComposerDraft()
        guard cur.isEmpty else { return LText(String(localized: "输入框里已有内容：先发送或清空，再恢复")) }
        let missing = ComposerRules.missingFiles(paths: m.attachmentPaths)
        guard missing.isEmpty else { return LText(Self.missingNote(missing, suffix: String(localized: "没能恢复，快照与恢复入口保留"))) }
        guard ComposerRules.restore(m, canEdit: true, draft: &cur.text, attachments: &cur.attachments) else { return LText(String(localized: "恢复失败")) }
        composerDrafts[key] = cur.isEmpty ? nil : cur
        composerNotes[key] = nil
        markRestored(m.id)
        return nil
    }

    // ---- 线程 ----
    struct Thread: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String?
        let preview: String
        let lastSeq: Int
        let count: Int
        /// 最近一条回执的写入时间（毫秒）；旧 Bridge 没有。
        var lastT: Int? = nil
    }

    var threads: [Thread] {
        var byId: [String: (title: String, agent: String?, items: [HistoryItem])] = [:]
        // 无目标的回执不进线程（系统线程已撤掉）：请求走待答卡，提醒进收件箱提醒区（inboxAlerts），其余纯回执丢弃；原始 history / commands / sent 数据都保留。
        for item in history {
            guard let key = item.target?.id else { continue }
            var e = byId[key] ?? (title: item.target?.projectName ?? key, agent: nil, items: [])
            e.items.append(item)
            if let a = item.target?.agentName { e.agent = a }
            byId[key] = e
        }
        for c in commands.values {
            guard let tid = c.targetId, byId[tid] == nil else { continue }
            let t = state?.targets.first { $0.id == tid }
            byId[tid] = (title: t?.projectName ?? tid, agent: t?.agentName, items: [])
        }
        return byId.map { id, e in
            let last = e.items.last
            let pending = runningCommands.filter { $0.targetId == id }.count
            let preview = last.map { ReceiptText.summary($0).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "") } ?? (pending > 0 ? String(localized: "排队 \(pending)") : String(localized: "还没有回执"))
            return Thread(id: id, title: e.title, subtitle: e.agent, preview: preview, lastSeq: last?.seq ?? 0, count: e.items.count, lastT: last?.t)
        }
        .sorted { $0.lastSeq > $1.lastSeq }
    }

    /// 本线程的回执，加上回复本线程发起的操作（面板 / 任务 / 重置 / 切换）的无目标回执（按 replyTo 承接）。
    func threadHistory(_ threadId: String) -> [HistoryItem] {
        let keys = Set(sent.filter { $0.targetId == threadId }.compactMap(\.eventKey))
        return history.filter { $0.target?.id == threadId || ($0.target == nil && keys.contains($0.replyTo ?? "")) }
    }

    func rows(for threadId: String) -> [ThreadRow] {
        let cmds = commands.values.filter { $0.targetId == threadId }
        // 业务拒绝的回执可能不带目标：必须用全量 history 关联本线程的发送
        let mine = ThreadRow.withRejections(sent, history: history).filter { $0.targetId == threadId }
        return ThreadRow.fallback(history: threadHistory(threadId), commands: Array(cmds), window: commandWindow, sent: mine)
    }

    func forget() {
        withdrawnOffers = [:] // 忘记配对：残留的撤回原文提示一并清掉，同一 Bridge 重新配对也不复活（O1-331 R2）
        transcripts = [:]; transcriptRequestBook.removeAll()
        stopStream() // 也让在途同步失效
        inflight = [:]; lastSync = nil // 本连接的发送状态与同步时间不能带到下一个连接
        decideError = [:]; lastDecisionNote = nil; lastDecisionWarn = false; noteClear?.cancel(); noteClear = nil // 审批错误、提示与其定时器随连接结束
        sent = []; history = []; commands = [:]; commandWindow = CommandWindow(); outgoingTracker = OutgoingStatusTracker(); pendingProgress.clear(); sseSeq = 0; lastFactSeq = [:]; device = nil; approvals = [:]
        composerDrafts = [:]; composerBusy = []; switchTrack = nil // 取消配对：草稿与切换追踪一并清掉
        questionDrafts = [:]; requestReasons = [:]; reminderSends = [:]; composerNotes = [:]; beginNavigation(); selectedRequest = nil
        usage = nil; usageError = nil; usageConnection = nil; usageFetchedAt = nil; usageByWindow = [:]; usageFetchedByWindow = [:]; usageCacheConnection = nil; usageSettledWindow = nil; usageSeq += 1; usageLoading = false; usageWindowIntent = .h24 // 忘记配对：旧用量与在途请求作废
        accounts = nil; accountsError = nil; accountsConnection = nil; accountsUnsupported = false; accountsSeq += 1; accountsLoading = false // 账户额度同样作废
        priceRefreshSeq += 1; priceRefreshBusy = false; priceNote = nil; priceNoteConnection = nil
        KeychainStore.clearEndpoint()
        token = nil; endpoint = nil; state = nil; noteBridgeIdentity(); workingSince = [:]
        selectedTarget = nil; selectedThread = nil
        searchResponse = nil; searchError = nil; searchQuery = ""; located = nil; locateNote = nil
        link = .notPaired
    }

    private func describe(_ error: Error, sendNow: Bool = false) -> String { Self.describe(error, sendNow: sendNow) }
    /// 纯函数：LText 闭包里用它，避免捕获 self。
    nonisolated static func describe(_ error: Error, sendNow: Bool = false) -> String {
        if let e = error as? MessageActionError {
            if case .http(let s) = e { return describe(BridgeError.http(status: s)) }
            return SendTimingCopy.text(for: e, sendNow: sendNow)
        }
        if let e = error as? BridgeError {
            switch e {
            case .badURL: return String(localized: "地址无效")
            case .plaintextRefused: return String(localized: "非本机地址必须用 https")
            case .http(let s): return s == 401 ? String(localized: "未授权（令牌无效或已被移除）") : s == 409 ? String(localized: "已暂停接收此设备的任务") : String(localized: "Bridge 返回 \(s)")
            case .decoding: return String(localized: "响应无法解析")
            case .messageTooLong: return String(localized: "原因超过 \(ApprovalMessage.maxUTF16) 字")
            }
        }
        if let e = error as? HookClient.HookError {
            switch e {
            case .bridgeNotRunning: return String(localized: "Bridge 未运行")
            case .unauthorized: return String(localized: "Hook 密钥不匹配")
            case .invalidResponse: return String(localized: "响应无法解析")
            case .http(let c): return String(localized: "钩子口返回 \(c)")
            }
        }
        return String(localized: "无法连接")
    }
}

/// 连接阶段的唯一投影（左栏、底栏、统计页共用）。按优先级取第一个成立的阶段：
/// 凭据未读完 > Bridge 进程状态 > 配对/同步 > 会话。
enum ConnectionPhase: Equatable {
    case readingCredentials
    case engineOff
    case engineStarting
    case engineStopping
    case engineFailed(LText)
    case preparingPairing
    case pairing
    // 远程模式：只看凭据、连接态与远程 Mac，不看本机 Bridge 进程
    case remoteNotPaired
    case remoteConnecting
    case connected
    case offline(LText)

    static func from(
        mode: ConnectionMode = .local,
        engineStatus: BridgeEngine.Status,
        portFileReady: Bool,
        credentialsLoaded: Bool,
        secretsLoaded: Bool,
        link: MacSession.Link
    ) -> ConnectionPhase {
        if mode == .remote {
            guard credentialsLoaded else { return .readingCredentials }
            switch link {
            case .notPaired: return .remoteNotPaired
            case .connecting: return .remoteConnecting
            case .connected: return .connected
            case .offline(let reason): return .offline(reason)
            }
        }
        guard credentialsLoaded, secretsLoaded else { return .readingCredentials }
        switch engineStatus {
        case .stopped: return .engineOff
        case .starting: return .engineStarting
        case .stopping: return .engineStopping
        case .failed(let reason): return .engineFailed(reason)
        case .running:
            guard portFileReady else { return .engineStarting }
            switch link {
            case .notPaired: return .preparingPairing
            case .connecting: return .pairing
            case .connected: return .connected
            case .offline(let reason): return .offline(reason)
            }
        }
    }

    /// 凭据读取中的提示：主窗、菜单、设置共用。超过看门狗期限时换成“请处理系统授权窗口”，不要求重启，也不以空配置启动。
    static func credentialsWaitText(stalled: Bool) -> String {
        stalled ? String(localized: "钥匙串读取较慢，请处理系统授权窗口（如有）") : String(localized: "正在读取凭据（如有授权窗口请允许）")
    }

    var label: String {
        switch self {
        case .readingCredentials: ConnectionPhase.credentialsWaitText(stalled: false)
        case .engineOff: String(localized: "Bridge 未启动")
        case .engineStarting: String(localized: "Bridge 启动中…")
        case .engineStopping: String(localized: "Bridge 停止中…")
        case .engineFailed(let reason): String(localized: "Bridge 启动失败：\(reason.text)")
        case .preparingPairing: String(localized: "准备自动配对…")
        case .pairing: String(localized: "正在配对/同步…")
        case .remoteNotPaired: String(localized: "未连接远程 Mac")
        case .remoteConnecting: String(localized: "正在连接远程 Mac…")
        case .connected: String(localized: "在线")
        case .offline(let reason): String(localized: "离线：\(reason.text)")
        }
    }

    /// 过渡态（指示灯用黄色）：正在读取、启动、停止或配对，结果尚未确定。
    var isTransitional: Bool {
        switch self {
        case .readingCredentials, .engineStarting, .engineStopping, .preparingPairing, .pairing, .remoteConnecting: true
        case .engineOff, .engineFailed, .remoteNotPaired, .connected, .offline: false
        }
    }
}
