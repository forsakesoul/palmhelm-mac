import Foundation
import PalmhelmKit

// #21 S2（Mac）：派发的会话侧落点。门禁与普通发送同一函数（sendBlocker）；结果只在发起时的连接上落账（A1-187 R1/R2/R5）。
extension MacSession {
    /// 派发门禁：与普通发送相同（sendBlocker）。只在预览与确认发出之前复核；已受理的结果照常落账，之后不因门禁变化而撤回。
    func issueTaskBlocker() -> String? { sendBlocker() }

    /// 派发的传输：测试替身优先，否则是真实客户端。
    func issueTaskTransport() -> IssueTaskTransport? {
        if let override = issueTaskTransportOverride { return override() }
        return issueTaskClient()
    }

    /// 预览（经门禁）：门禁不过即抛出，不发出请求。
    func issueTaskPreviewChecked(_ request: IssueTaskRequest) async throws -> IssueTaskPreview {
        if let reason = issueTaskBlocker() { throw IssueTaskBlocked(reason: reason) }
        guard let transport = issueTaskTransport() else { throw IssueTaskBlocked(reason: String(localized: "还没有配对")) }
        return try await transport.issueTaskPreview(request)
    }

    /// 确认（经门禁）：在发出请求之前再复核一次，门禁变化即拒绝且零请求。
    func issueTaskCreateChecked(_ request: IssueTaskRequest) async throws -> IssueTaskCreated {
        if let reason = issueTaskBlocker() { throw IssueTaskBlocked(reason: reason) }
        guard let transport = issueTaskTransport() else { throw IssueTaskBlocked(reason: String(localized: "还没有配对")) }
        return try await transport.issueTaskCreate(request)
    }

    /// 受理成功：沿用既有回显（Sent）与对账（eventKey），之后刷新状态。连接已变化则不落账，返回 false。
    @discardableResult
    func recordIssueAccepted(clientMsgId: String, summary: String, targetId: String, eventKey: String, epoch: Int) -> Bool {
        guard epoch == connectionEpoch, let id = UUID(uuidString: clientMsgId) else { return false }
        sent.append(Sent(id: id, text: summary, at: Date(), afterSeq: history.last?.seq ?? 0, targetId: targetId,
                         anchorT: history.last?.t ?? Int(Date().timeIntervalSince1970 * 1000), eventKey: eventKey))
        Task { await refresh() }
        return true
    }
}
