import SwiftUI
import PalmhelmKit

/// 右侧工作区里的请求详情（提问 / 计划 / 长命令）：完整显示同一张请求卡（草稿在 Session，进出、切线程、换主题都不丢）。
/// 请求处理 / 过期 / 撤回后卡没了，这里改显示卡外反馈（审批确认、失败原因），由用户点「返回」离开，不自动跳走把反馈吞掉。
struct RequestDetailPane: View {
    @Environment(MacSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { session.selectedRequest = nil } label: { Label("返回线程", systemImage: "chevron.left") }.buttonStyle(.link)
                    .accessibilityLabel("返回线程")
                Spacer()
                if let a = session.activeRequest, let t = session.target(forApproval: a), a.attribution == ApprovalAttribution.exact.rawValue {
                    Button("查看 \(ThreadIdentity.title(t)) 的对话") { session.selectTarget(t.id) }.buttonStyle(.link).font(.caption)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let a = session.activeRequest {
                ScrollView {
                    PendingCard(approval: a).frame(maxWidth: 720).frame(maxWidth: .infinity).padding(20)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("这条待答已处理、过期或撤回").font(.headline)
                    if let n = session.lastDecisionNote { Text(n.text).font(.callout).foregroundStyle(session.lastDecisionWarn ? PalmhelmTheme.warn : PalmhelmTheme.ok).multilineTextAlignment(.center) } // 卡外反馈
                    Button("返回线程") { session.selectedRequest = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            }
        }
    }
}
