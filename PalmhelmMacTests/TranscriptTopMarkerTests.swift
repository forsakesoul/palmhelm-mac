// O1-344 R2：顶部标记只由点击加载；出现（打开对话、列表很短）时不自动请求。
import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

@MainActor final class TranscriptTopMarkerTests: XCTestCase {
 func testTopMarkerDoesNotLoadBeforeAnExplicitClick() async throws {
  var thread=TranscriptThread();thread.status = .ok;thread.hasMore=true;thread.nextBefore="older"
  thread.items=(0..<20).map { TranscriptItem(id:"m\($0)",role:"user",text:"message") }
  var calls=0
  let view=NSHostingView(rootView:TranscriptTopMarker(thread:thread){calls += 1}.frame(width:300))
  let panel=NSPanel(contentRect:NSRect(x:-4000,y:-4000,width:300,height:80),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  panel.isReleasedWhenClosed=false;panel.contentView=view;panel.orderBack(nil)
  defer {panel.contentView=nil;panel.close()}
  view.layoutSubtreeIfNeeded()
  try await Task.sleep(for:.milliseconds(250))
  XCTAssertEqual(calls,0,"未点击顶部按钮时不能自动加载更早记录")
 }
}
