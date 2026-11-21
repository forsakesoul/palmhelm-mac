import CoreGraphics
import XCTest
@testable import PalmhelmMac

// 对话页底部跟随（G / S2）的纯规则：贴底判定、用户意图与布局变化的分离、排队滚底的执行前复核。
final class ThreadFollowTests: XCTestCase {
    func testFollowsOnlyWhenStuckWithoutPinOnConversation() {
        XCTAssertTrue(ThreadFollow.follows(stuck: true, pinnedHit: nil, threadMode: 0))
        XCTAssertFalse(ThreadFollow.follows(stuck: false, pinnedHit: nil, threadMode: 0), "上翻阅读时不拉回")
        XCTAssertFalse(ThreadFollow.follows(stuck: true, pinnedHit: "x2", threadMode: 0), "定位视图不跟随")
        XCTAssertFalse(ThreadFollow.follows(stuck: true, pinnedHit: nil, threadMode: 1), "终端页不跟随")
    }

    func testAtBottomWithinFortyPoints() {
        // 内容 1000、视口 400、无底部 inset：偏移 600 即贴底；偏移 559 距底 41pt 不算。
        XCTAssertTrue(ScrollSnap(contentOffsetY: 600, contentHeight: 1000, containerHeight: 400).atBottom)
        XCTAssertTrue(ScrollSnap(contentOffsetY: 570, contentHeight: 1000, containerHeight: 400).atBottom)
        XCTAssertFalse(ScrollSnap(contentOffsetY: 559, contentHeight: 1000, containerHeight: 400).atBottom)
    }

    func testBottomInsetFromFooterCountsAsHidden() {
        // 底栏遮住底部 80pt：视口可见部分是 400 - 80。偏移 640 时最后一行刚好在底栏之上，算贴底；偏移 600 不算。
        XCTAssertTrue(ScrollSnap(contentOffsetY: 640, contentHeight: 1000, containerHeight: 400, contentInsetBottom: 80).atBottom)
        XCTAssertFalse(ScrollSnap(contentOffsetY: 600, contentHeight: 1000, containerHeight: 400, contentInsetBottom: 80).atBottom)
    }

    func testLayoutGrowthWithoutUserScrollKeepsStuck() {
        let stuck = ScrollSnap(contentOffsetY: 600, contentHeight: 1000, containerHeight: 400)
        // 流式增长：内容变高、偏移未动，距底变远，但不是用户操作，贴底状态不变。
        let grown = ScrollSnap(contentOffsetY: 600, contentHeight: 1300, containerHeight: 400)
        XCTAssertFalse(ThreadFollow.updatesStuck(old: stuck, new: grown))
        XCTAssertTrue(ThreadFollow.nextStuck(current: true, old: stuck, new: grown, userScrolling: false))
        // 底栏增高使视口变矮：同样沿用。
        let shorter = ScrollSnap(contentOffsetY: 600, contentHeight: 1000, containerHeight: 300)
        XCTAssertTrue(ThreadFollow.nextStuck(current: true, old: stuck, new: shorter, userScrolling: false))
    }

    func testUserScrollUpWinsEvenWhenContentGrowsInTheSameFrame() {
        let stuck = ScrollSnap(contentOffsetY: 600, contentHeight: 1000, containerHeight: 400)
        // 同一帧：用户正在上翻（偏移 100）且内容变高。用户意图优先，贴底必须变为 false。
        let scrolledUpAndGrown = ScrollSnap(contentOffsetY: 100, contentHeight: 1300, containerHeight: 400)
        XCTAssertFalse(ThreadFollow.nextStuck(current: true, old: stuck, new: scrolledUpAndGrown, userScrolling: true))
        // 同样的几何但不在滚动（布局变化）：不改写。
        XCTAssertTrue(ThreadFollow.nextStuck(current: true, old: stuck, new: scrolledUpAndGrown, userScrolling: false))
    }

    func testUserScrolledBackToBottomRestoresStuck() {
        let up = ScrollSnap(contentOffsetY: 100, contentHeight: 1000, containerHeight: 400)
        let back = ScrollSnap(contentOffsetY: 600, contentHeight: 1000, containerHeight: 400)
        XCTAssertTrue(ThreadFollow.nextStuck(current: false, old: up, new: back, userScrolling: true))
    }

    func testQueuedFollowRunsOnlyWhileIntentStillHolds() {
        XCTAssertTrue(ThreadFollow.runsQueued(stuck: true, pinnedHit: nil, threadMode: 0, selectedThread: "A", threadId: "A"))
        XCTAssertFalse(ThreadFollow.runsQueued(stuck: false, pinnedHit: nil, threadMode: 0, selectedThread: "A", threadId: "A"), "排队期间用户上翻：放弃")
        XCTAssertFalse(ThreadFollow.runsQueued(stuck: true, pinnedHit: "x2", threadMode: 0, selectedThread: "A", threadId: "A"), "排队期间进入定位：放弃")
        XCTAssertFalse(ThreadFollow.runsQueued(stuck: true, pinnedHit: nil, threadMode: 1, selectedThread: "A", threadId: "A"), "排队期间切到终端：放弃")
        XCTAssertFalse(ThreadFollow.runsQueued(stuck: true, pinnedHit: nil, threadMode: 0, selectedThread: "B", threadId: "A"), "排队期间切线程：放弃")
    }

    // F1：idle 时底栏只增高（inset 0→120）不是用户离开底部：保持贴底，并继续跟随。
    func testIdleFooterInsetGrowthKeepsStuckAndFollows() {
        let before = ScrollSnap(contentOffsetY: 640, contentHeight: 1000, containerHeight: 400, contentInsetBottom: 0)
        let after = ScrollSnap(contentOffsetY: 640, contentHeight: 1000, containerHeight: 400, contentInsetBottom: 120)
        XCTAssertFalse(after.atBottom, "几何上距底变远，但这不是用户操作")
        XCTAssertFalse(ThreadFollow.updatesStuck(old: before, new: after))
        let stuck = ThreadFollow.nextStuck(current: true, old: before, new: after, userScrolling: false)
        XCTAssertTrue(stuck)
        XCTAssertTrue(ThreadFollow.follows(stuck: stuck, pinnedHit: nil, threadMode: 0), "之后的增长仍跟随")
    }

    // F1：用户正在滚动且底栏同时变化：以新几何为准，离底优先。
    func testUserScrollWithInsetChangeTakesGeometry() {
        let before = ScrollSnap(contentOffsetY: 600, contentHeight: 1000, containerHeight: 400, contentInsetBottom: 0)
        let scrolledUp = ScrollSnap(contentOffsetY: 100, contentHeight: 1000, containerHeight: 400, contentInsetBottom: 120)
        XCTAssertFalse(ThreadFollow.nextStuck(current: true, old: before, new: scrolledUp, userScrolling: true))
    }
}
