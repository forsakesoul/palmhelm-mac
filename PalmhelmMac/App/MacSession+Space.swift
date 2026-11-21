import Foundation
import AppKit
import PalmhelmKit

// 空间分组排序（#98，Mac）：把 Kit 的 SpaceOrderSession 接到目标栏上。
// 有效快照在最终合并之后应用（与整理一致）；目标栏可见时冻结，离开再回来静默应用；偏好只存本机。

extension MacSession {
    var spaceBridgeId: String { state?.bridge?.id ?? "local" }

    /// 目标栏（空间视角）的段：按偏好排序；收件箱视角不变（由 railSections 分流）。
    /// items 由目标栏投影传入同一次构建的输入；缺省按当前事实现算。
    func spaceSections(items: [LensInput]? = nil) -> [LensSection] {
        _ = spaceVersion
        return SpaceOrderSession.sections(bridgeId: spaceBridgeId, items: items ?? railInputs, spaces: state?.spaces, document: spaceDocument)
    }

    func applySpaceSnapshot(observation: BridgeObservation?) {
        let effective = observation.map { SpaceObservationGate.effective(complete: $0.complete, fresh: $0.fresh) } ?? false
        spaceLastEffective = effective
        // 在副本上计算，只有结果不同才赋值 / 保存 / 推进版本：@Observable 对 inout 写入即使值未变也会通知（20 个未变快照通知 20 次）。
        var next = spaceDocument
        SpaceOrderSession.applySnapshot(&next, bridgeId: spaceBridgeId, items: railInputs, effective: effective, frozen: spaceListVisible, generation: spaceSessionGen)
        commitSpaceDocument(next)
    }

    /// 排序文档的判变提交：值不变不写、不存盘、不通知。
    private func commitSpaceDocument(_ next: SpaceOrderDocument) {
        guard next != spaceDocument else { return }
        spaceDocument = next
        persistSpaceOrder()
    }

    /// 断开、换连接、停止：清除待应用的上移，并让最近一次有效判定失效（之后只有新代次的有效快照才能恢复）。
    func spaceInvalidate() {
        var next = spaceDocument
        SpaceOrderSession.invalidate(&next)
        spaceLastEffective = false
        commitSpaceDocument(next)
    }

    func setSpaceListVisible(_ visible: Bool) {
        guard spaceListVisible != visible else { return }
        spaceListVisible = visible
        if !visible {
            var next = spaceDocument
            SpaceOrderSession.reenter(&next, bridgeId: spaceBridgeId, items: railInputs, effective: spaceLastEffective)
            commitSpaceDocument(next)
        }
    }

    func isSpaceGroupPinned(_ sectionId: String) -> Bool {
        guard let id = SpaceOrderSession.groupId(sectionId: sectionId) else { return false }
        return spaceDocument.state.pinned.contains(id)
    }

    func setSpaceGroupPinned(_ sectionId: String, _ pinned: Bool) {
        guard let id = SpaceOrderSession.groupId(sectionId: sectionId) else { return }
        spaceDocument.state = SpaceOrderReducer.reduce(spaceDocument.state, pinned ? .pin(id) : .unpin(id))
        persistSpaceOrder()
    }

    /// 边界动作禁用（读屏动作与菜单据此决定是否提供）。
    /// visible 缺省按当前事实现算；目标栏每个表头传入同一次投影的可见顺序，不逐表头重算整表。
    func spaceCanMove(_ sectionId: String, delta: Int, visible: [String]? = nil) -> Bool {
        guard let id = SpaceOrderSession.groupId(sectionId: sectionId) else { return false }
        return SpaceOrderSession.canMove(spaceDocument, id: id, delta: delta, visible: visible ?? spaceVisibleGroupIds())
    }

    /// 上移 / 下移一位（读屏动作、⋯ 菜单与键盘共用）。返回播报文字，未移动返回 nil。
    @discardableResult
    func moveSpaceGroup(_ sectionId: String, delta: Int) -> String? {
        guard let id = SpaceOrderSession.groupId(sectionId: sectionId), spaceCanMove(sectionId, delta: delta) else { return nil }
        let name = spaceSections().first { $0.id == sectionId }?.title ?? ""
        SpaceOrderSession.move(&spaceDocument, id: id, delta: delta, visible: spaceVisibleGroupIds())
        persistSpaceOrder()
        return spaceAnnouncement(name: name, groupId: id)
    }

    /// “{名称} 已移到第 N 位”（N 从 1 起，按移动后的显示顺序）。
    func spaceAnnouncement(name: String, groupId: String) -> String? {
        guard let index = spaceVisibleGroupIds().firstIndex(of: groupId) else { return nil }
        return String(localized: "\(name) 已移到第 \(index + 1) 位")
    }

    /// 读屏播报（NSAccessibility announcement）。
    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: message])
    }

    /// 拖动到某一段之前（draggable / dropDestination 共用）。被拖的段是置顶组时只在置顶区内移动；普通组不越过置顶区。
    func dropSpaceGroup(_ draggedSectionId: String, before targetSectionId: String) {
        guard let dragged = SpaceOrderSession.groupId(sectionId: draggedSectionId),
              let target = SpaceOrderSession.groupId(sectionId: targetSectionId), dragged != target else { return }
        let visible = spaceVisibleGroupIds()
        guard let from = visible.firstIndex(of: dragged), let to = visible.firstIndex(of: target) else { return }
        let delta = to < from ? -1 : 1
        // 逐位移动（Kit 的边界规则决定能否越过）。向下移动时被拖的段先离开自身位置，目标因此前移一位，终点是 to - 1。
        var i = from
        let end = delta > 0 ? to - 1 : to
        while i != end {
            let before = spaceVisibleGroupIds()
            SpaceOrderSession.move(&spaceDocument, id: dragged, delta: delta, visible: before)
            if spaceVisibleGroupIds() == before { break }
            i += delta
        }
        persistSpaceOrder()
    }

    /// 设置里的重置（确认后调用）。
    func resetSpaceOrder() {
        SpaceOrderSession.reset(&spaceDocument, bridgeId: spaceBridgeId, items: railInputs)
        persistSpaceOrder()
    }

    private func spaceVisibleGroupIds() -> [String] {
        spaceSections().compactMap { SpaceOrderSession.groupId(sectionId: $0.id) }
    }

    private func persistSpaceOrder() {
        spaceStore.save(spaceDocument)
        spaceVersion += 1
    }
}
