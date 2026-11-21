import Foundation
import AppKit
import PalmhelmKit

/// 持有有效性定时任务与时钟通知的注册：Session 销毁（或显式结束）时取消任务、在各自的通知中心移除观察，不留弱 owner 的悬挂任务与无效监听。
final class TimeValidityResources: @unchecked Sendable {
    var task: Task<Void, Never>?
    private(set) var ended = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    var observerCount: Int { observers.count }
    func add(_ center: NotificationCenter, _ token: NSObjectProtocol) { observers.append((center, token)) }
    func end() {
        ended = true
        task?.cancel(); task = nil
        for o in observers { o.center.removeObserver(o.token) }
        observers = []
    }
    deinit { end() }
}

/// 时间有效性的调度状态（存储在 MacSession，忽略观察）。
struct TimeValidityState {
    /// 上一次计算时仍有效的待答 / 提醒集合：只在它变化时才发布 timeValidityVersion。
    var signature: Set<String> = []
    /// 已挂定时器对应的边界（毫秒时间戳）；没有未来边界时为 nil。
    var deadlineMs: Int?
    /// 最近一次挂定时器时的睡眠时长（毫秒，测试读取：改时重基准后应按新的 now 重算）。
    var lastDelayMs: Int?
    var generation = 0
    let resources = TimeValidityResources()
    var task: Task<Void, Never>? {
        get { resources.task }
        nonmutating set { resources.task = newValue }
    }
}

/// 提醒入口的摘要：判变后才写，入口小视图只读它（稳定的 targets 帧不使入口重算）。
struct ReminderSummary: Equatable {
    var reminders = 0
    var alerts = 0
    var unread = 0
}

/// 待答过期（expiresT）与提醒 72 小时上限是唯一两类“随时间失效”的事实：不再用 5 秒 / 分钟广播驱动整窗，
/// 而是在最近的边界时刻发布一次版本，读这些集合的 getter 随版本失效；回前台、唤醒、改时补算。
extension MacSession {
    /// 一个时刻上的有效集合签名，以及之后最近的失效边界。只读原始数据。
    func timeValidityPlan(at now: Date) -> (signature: Set<String>, next: Int?) {
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        var signature = Set<String>()
        var next: Int?
        func consider(_ boundary: Int) { if boundary > nowMs, next.map({ boundary < $0 }) ?? true { next = boundary } }
        let pending = ApprovalStatus.pending.rawValue
        for a in approvals.values where a.status == pending && a.expiresT > nowMs { signature.insert("l:" + a.id); consider(a.expiresT) }
        for id in reminderVisibleIds(atMs: nowMs) { signature.insert("r:" + id) }
        // 隐藏条件是 t < now - maxAge：t + maxAge 仍可见，之后 1 毫秒隐藏。没有可信时间的提醒不造边界。
        for c in reminderCandidates() {
            if let t = c.t, t <= Int.max - ReminderRules.maxAgeMs - 1 { consider(t + ReminderRules.maxAgeMs + 1) }
        }
        return (signature, next)
    }

    /// 唯一的集中入口：数据变化、到期、回前台、唤醒、显著改时都走这里。判变后才发布；然后按最近的未来边界重挂定时器。
    /// 到期只影响本地展示，不发任何网络请求。
    /// rebase：系统时钟被改、前台恢复、唤醒——旧的相对睡眠按改时前的时间算，必须按同一绝对 E 与新的 now 重挂（签名不变仍零 UI 发布）。
    /// 普通数据事件（rebase 为假）同一边界保留已挂任务。
    func reconcileTimeValidity(fromTime: Bool = false, rebase: Bool = false) {
        guard !validity.resources.ended else { return } // 已结束：不再挂任务、不再发布
        let now = currentDate
        let plan = timeValidityPlan(at: now)
        if plan.signature != validity.signature {
            validity.signature = plan.signature
            timeValidityVersion += 1
        }
        // 提醒入口摘要：用同一轮输入判变后才写（带当前时刻的可见集合）。
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let shown = reminderVisibleIds(atMs: nowMs)
        let summary = ReminderSummary(
            reminders: allReminders.filter { shown.contains($0.uuid) }.count,
            alerts: presentedAlertEntries().filter { shown.contains($0.alert.id) }.count,
            unread: reminderCandidates().filter { shown.contains($0.id) && !$0.seen }.count)
        if summary != reminderSummary { reminderSummary = summary }
        guard let next = plan.next else {
            validity.task?.cancel(); validity.task = nil; validity.deadlineMs = nil
            return
        }
        if next == validity.deadlineMs, validity.task != nil, !rebase { return } // 同一边界：不取消重建（改时重基准除外）
        validity.task?.cancel()
        validity.deadlineMs = next
        validity.generation += 1
        let generation = validity.generation
        // 睡眠上限一小时：异常远期的时间戳不溢出，醒来重新核验并重挂。
        let delayMs = min(max(0, next - nowMs), 3_600_000)
        validity.lastDelayMs = delayMs
        validity.task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, let self, self.validity.generation == generation else { return }
            self.validity.task = nil
            self.reconcileTimeValidity(fromTime: true)
        }
    }

    /// 观察原始输入（待答、历史、发送、状态、提醒账本与身份），变化后在主 Actor 上重算并重新订阅。
    /// tracking 闭包只读原始事实，不读也不写 timeValidityVersion / reminderSummary，避免观察自己的输出。
    func trackTimeValidityInputs() {
        withObservationTracking {
            _ = approvals
            _ = history
            _ = sent
            _ = state
            _ = currentBlocked
            _ = currentBlockedFresh
            _ = link
            _ = device
            _ = reminderLedger
            _ = reminderPresentation
            _ = reminderVersion
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconcileTimeValidity()
                self?.trackTimeValidityInputs()
            }
        }
    }

    /// 前台恢复、系统唤醒、显著改时：补算一次（睡眠期间到期的边界、被改过的时钟）。
    func observeClockEvents() {
        guard validity.resources.observerCount == 0 else { return } // 不重复注册
        let reconcile: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.reconcileTimeValidity(fromTime: true, rebase: true) } }
        let center = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        validity.resources.add(center, center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil, using: reconcile))
        validity.resources.add(center, center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: nil, using: reconcile))
        validity.resources.add(workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil, using: reconcile))
    }

    /// 结束本 Session 的有效性调度（任务与时钟通知的注册）。连接换代 / stopStream 不调用它：断线阅读缓存仍要到期，换代后按当前事实重新协调。
    func endTimeValidity() { validity.resources.end() }
}
