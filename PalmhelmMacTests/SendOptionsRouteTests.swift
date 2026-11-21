import XCTest
import PalmhelmKit
@testable import PalmhelmMac

// A1-002：发送方式浮层的选择函数在选择当刻重读当前路由；打开后路由改变（绑定 ↔ 直达）的旧动作零发送。
final class SendOptionsRouteTests: XCTestCase {
    private let items = SendTimingRules.menu(steer: .available, direct: false, queueDeadline: true)

    func testDirectAgentFollowsCurrentBinding() {
        XCTAssertNil(SendOptionsRoute.directAgent(threadId: "t", bindingTargetId: "t", agentName: "claude"), "绑定线程不是直达")
        XCTAssertEqual(SendOptionsRoute.directAgent(threadId: "t", bindingTargetId: "other", agentName: "claude"), "claude")
        XCTAssertNil(SendOptionsRoute.directAgent(threadId: "t", bindingTargetId: "other", agentName: "bad name"), "不可直达的名字")
        XCTAssertNil(SendOptionsRoute.directAgent(threadId: nil, bindingTargetId: "other", agentName: "claude"))
    }

    // #81：协作角色（_execute/_advisor）与普通 agent 同样可直达；绑定线程仍不是直达。
    func testCollaborationRolesAreDirectTargetsLikeAnyOtherAgent() {
        for name in ["task_x_execute", "task_x_advisor", "task_x_execute2", "task_x_advisor2"] {
            XCTAssertEqual(SendOptionsRoute.directAgent(threadId: "t", bindingTargetId: "other", agentName: name), name)
            XCTAssertNil(SendOptionsRoute.directAgent(threadId: "t", bindingTargetId: "t", agentName: name))
        }
    }

    func testOpenedBoundThenBindingMovedAwayIsRefused() {
        let opened = SendOptionsRoute.ticket(threadId: "t", epoch: 1, linkConnected: true, bindingTargetId: "t", agentName: "claude")
        // 打开后飞书绑定换走：当前路由变成直达。旧闭包里的 agent 仍是 nil，票据若用旧 agent 构造会误判相等。
        let now = SendOptionsRoute.ticket(threadId: "t", epoch: 1, linkConnected: true, bindingTargetId: "other", agentName: "claude")
        XCTAssertFalse(SendOptionsGate.permits(opened: opened, current: now, supportsSendTiming: true, items: items, choice: .queueAfterTurn))
    }

    func testOpenedDirectThenBoundHereIsRefusedAndUnchangedRoutePasses() {
        let opened = SendOptionsRoute.ticket(threadId: "t", epoch: 1, linkConnected: true, bindingTargetId: "other", agentName: "claude")
        let bound = SendOptionsRoute.ticket(threadId: "t", epoch: 1, linkConnected: true, bindingTargetId: "t", agentName: "claude")
        XCTAssertFalse(SendOptionsGate.permits(opened: opened, current: bound, supportsSendTiming: true, items: items, choice: .queueAfterTurn))
        XCTAssertTrue(SendOptionsGate.permits(opened: opened, current: opened, supportsSendTiming: true, items: items, choice: .queueAfterTurn), "正控：路由未变")
    }
}
