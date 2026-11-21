import Foundation

/// #89 片 B 联验的真实字节：Bridge 22253ff + 已审 queue-semantics-bridge-v2.patch 的真实投影代码（`commandsFor` / `TargetHistory.History` / progress 轮询）
/// 对同一批固定 key（e2e:np 暂停无 commands、e2e:unc 暂停有 abandoned commands、e2e:dl 排队带真实期限、e2e:fin 终态）产出的字节，原样固定在这里。
/// 它们是 producer→consumer 契约字节，不是真实 HTTP / SSE 传输；消费者测试经 Kit 真实解码与 Session 真实采纳入口读取。
enum QueueV2WireBytes {
    static let commands = #"""
{"commands":[{"key":"e2e:np","inboxSeq":1,"createdT":1001,"text":"正文 e2e:np","truncated":false,"origin":"api","device":null,"targetId":"t-x","state":"paused","lane":"ordinary","stopDisposition":"not_dispatched"},{"key":"e2e:unc","inboxSeq":2,"createdT":1002,"text":"正文 e2e:unc","truncated":false,"origin":"api","device":null,"targetId":"t-x","state":"paused","lane":"ordinary","stopDisposition":"execution_uncertain"},{"key":"e2e:dl","inboxSeq":3,"createdT":1003,"queueDeadlineT":1790000000000,"text":"正文 e2e:dl","truncated":false,"origin":"api","device":null,"targetId":"t-x","state":"queued","lane":"ordinary"},{"key":"e2e:fin","inboxSeq":4,"createdT":1004,"text":"正文 e2e:fin","truncated":false,"origin":"api","device":null,"targetId":"t-x","state":"finished","lane":"ordinary"}]}
"""#
    static let history = #"""
{"items":[{"id":"inbox:e2e:np","source":"inbox","key":"e2e:np","inboxSeq":1,"createdT":1001,"text":"正文 e2e:np","truncated":false,"origin":"api","device":null,"targetId":"t-x","state":"paused","lane":"ordinary","stopDisposition":"not_dispatched"},{"id":"inbox:e2e:unc","source":"inbox","key":"e2e:unc","inboxSeq":2,"createdT":1002,"text":"正文 e2e:unc","truncated":false,"origin":"api","device":null,"targetId":"t-x","state":"paused","lane":"ordinary","stopDisposition":"execution_uncertain"},{"id":"inbox:e2e:dl","source":"inbox","key":"e2e:dl","inboxSeq":3,"createdT":1003,"queueDeadlineT":1790000000000,"text":"正文 e2e:dl","truncated":false,"origin":"api","device":null,"targetId":"t-x","state":"queued","lane":"ordinary"},{"id":"inbox:e2e:fin","source":"inbox","key":"e2e:fin","inboxSeq":4,"createdT":1004,"text":"正文 e2e:fin","truncated":false,"origin":"api","device":null,"targetId":"t-x","state":"finished","lane":"ordinary"}],"nextBefore":null,"hasMore":false,"partial":false}
"""#
    static let progressSSE = #"""
event: progress
data: {"eventKey":"e2e:np","state":"paused","stopDisposition":"not_dispatched","queueReason":null,"queuePosition":null,"observedAt":null,"phase":null}

event: progress
data: {"eventKey":"e2e:unc","state":"paused","stopDisposition":"execution_uncertain","queueReason":null,"queuePosition":null,"observedAt":null,"phase":null}

event: progress
data: {"eventKey":"e2e:dl","state":"started","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"dispatch"}

event: progress
data: {"eventKey":"e2e:dl","state":"started","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"awaiting"}

event: progress
data: {"eventKey":"e2e:dl","state":"started","queueReason":null,"queuePosition":null,"observedAt":null,"phase":"running"}
"""# + "\n\n"
}
