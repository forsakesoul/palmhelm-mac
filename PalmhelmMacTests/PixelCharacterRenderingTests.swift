import AppKit
import SwiftUI
import XCTest
import PalmhelmKit
@testable import PalmhelmMac

@MainActor
final class PixelCharacterRenderingTests: XCTestCase {
    func testSwiftUIHostDisplaysAndAdvancesOnlyTheCharacterLayer() async throws {
        let host = NSHostingView(rootView: PixelCharacterView(character: .horse, mode: .run))
        let panel = NSPanel(contentRect: NSRect(x: -3000, y: -3000, width: 30, height: 21), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.contentView = nil; panel.close() }
        host.layoutSubtreeIfNeeded()
        func character(in view: NSView) -> PixelCharacterLayerView? {
            (view as? PixelCharacterLayerView) ?? view.subviews.lazy.compactMap { character(in: $0) }.first
        }
        let view = try XCTUnwrap(character(in: host))
        XCTAssertEqual(view.bounds.size, CGSize(width: 30, height: 21))
        XCTAssertTrue(view.timer?.isValid == true)
        let first = try XCTUnwrap(view.layer?.contents) as AnyObject
        try await Task.sleep(for: .milliseconds(145))
        let next = try XCTUnwrap(view.layer?.contents) as AnyObject
        XCTAssertFalse(first === next, "真实 SwiftUI 挂载后仍播放，而不是靠漏绘降低 CPU")
        host.rootView = PixelCharacterView(character: .horse, mode: .run, animating: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(view.timer, "减少动态效果或不可见时停表")
    }

    func testRasterMatchesThePreviousCanvasFrames() throws {
        for character in NotchCharacter.allCases {
            for mode in [PixelMode.run, .wait, .done] {
                for (tick, still, nod) in [(0, false, false), (1, false, true), (4, false, false), (37, false, false), (0, true, false)] {
                    for (zoom, scale): (CGFloat, CGFloat) in [(1, 1), (1, 2), (1.25, 1), (1.25, 2), (2, 1), (2, 2)] {
                        let size = CGSize(width: 30 * zoom, height: 21 * zoom)
                        let color = color(mode)
                        let actual = try XCTUnwrap(PixelCharacterRaster.image(character, mode: mode, tick: tick, still: still, nod: nod, size: size, scale: scale, color: NSColor(color).cgColor))
                        let renderer = ImageRenderer(content: reference(character, mode: mode, tick: tick, still: still, nod: nod, color: color).frame(width: size.width, height: size.height))
                        renderer.scale = scale
                        let expected = try XCTUnwrap(renderer.cgImage)
                        assertPixels(actual, expected, "\(character) \(mode) tick=\(tick) still=\(still) nod=\(nod) zoom=\(zoom) backing=\(scale)")
                    }
                }
            }
        }
    }

    func testLayerRendersTheSamePixelsAndKeepsTheGlobalFrameSelection() throws {
        let view = PixelCharacterLayerView(frame: NSRect(x: 0, y: 0, width: 30, height: 21))
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)), "小人不能吞掉外层 Button 的点击")
        let color = NSColor(Color(hex: 0xF06A3A)).cgColor
        for character in NotchCharacter.allCases {
            view.configure(state: .init(character: character, mode: .run, animating: true, since: nil), color: color)
            for tick in [1, 4, 37, 10001] {
                view.advance(at: Date(timeIntervalSinceReferenceDate: (Double(tick) + 0.5) * PixelBitmaps.frameInterval))
                let layer = try XCTUnwrap(view.layer), context = bitmap(width: 30, height: 21)
                layer.render(in: context)
                let expected = try XCTUnwrap(PixelCharacterRaster.image(character, mode: .run, tick: tick, still: false, nod: false, size: view.bounds.size, scale: 1, color: color))
                assertPixels(try XCTUnwrap(context.makeImage()), expected, "layer \(character) tick=\(tick)")
            }
        }
    }

    func testTimerStopsForStillDetachedAndCompletedCharacters() throws {
        let view = PixelCharacterLayerView(frame: NSRect(x: 0, y: 0, width: 30, height: 21))
        let panel = NSPanel(contentRect: NSRect(x: -3000, y: -3000, width: 30, height: 21), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        defer { panel.contentView = nil; panel.close() }
        let orange = NSColor(Color(hex: 0xF06A3A)).cgColor
        view.configure(state: .init(character: .horse, mode: .run, animating: true, since: nil), color: orange)
        XCTAssertTrue(view.timer?.isValid == true)
        let timer = view.timer
        view.configure(state: .init(character: .horse, mode: .run, animating: true, since: nil), color: orange)
        XCTAssertTrue(timer === view.timer, "祖先更新不重建计时器或丢帧")
        view.configure(state: .init(character: .horse, mode: .run, animating: false, since: nil), color: orange)
        XCTAssertNil(view.timer)
        view.configure(state: .init(character: .horse, mode: .done, animating: true, since: Date().addingTimeInterval(-1)), color: orange)
        XCTAssertNil(view.timer, "点头结束后无需继续周期唤醒")
        view.configure(state: .init(character: .horse, mode: .done, animating: true, since: Date()), color: orange)
        XCTAssertTrue(view.timer?.isValid == true)
        panel.contentView = nil
        XCTAssertNil(view.timer, "离开窗口立即停止")
    }

    func testDoneOnlyNodsOnceAndThenStops() async throws {
        let view = PixelCharacterLayerView(frame: NSRect(x: 0, y: 0, width: 30, height: 21))
        let panel = NSPanel(contentRect: NSRect(x: -3000, y: -3000, width: 30, height: 21), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = view
        defer { panel.contentView = nil; panel.close() }
        let state = PixelCharacterState(character: .horse, mode: .done, animating: true, since: Date())
        let color = NSColor(Color(hex: PalmhelmSemanticColor.ok.dark)).cgColor
        view.configure(state: state, color: color)
        let down = try XCTUnwrap(view.layer?.contents) as AnyObject
        try await Task.sleep(for: .milliseconds(400))
        let up = try XCTUnwrap(view.layer?.contents) as AnyObject
        XCTAssertFalse(down === up)
        XCTAssertNil(view.timer)
        view.configure(state: state, color: color)
        let current = try XCTUnwrap(view.layer?.contents) as AnyObject
        XCTAssertTrue(up === current, "同一 toast 的祖先刷新不重播点头")
        XCTAssertNil(view.timer)
    }

    // a4c3a5d 的 Canvas 路径：用旧渲染器作像素对照，不用新位图实现反算期望值。
    private func reference(_ character: NotchCharacter, mode: PixelMode, tick: Int, still: Bool, nod: Bool, color: Color) -> some View {
        Canvas { ctx, size in
            let u = size.width / CGFloat(PixelBitmaps.cols)
            for c in PixelBitmaps.cells(character, mode: mode, tick: tick, still: still, nod: nod) {
                let x0 = (CGFloat(c.x) * u).rounded(), y0 = (CGFloat(c.y) * u).rounded()
                let rect = CGRect(x: x0, y: y0, width: (CGFloat(c.x + 1) * u).rounded() - x0, height: (CGFloat(c.y + 1) * u).rounded() - y0)
                ctx.fill(Path(rect), with: .color(color.opacity(c.alpha)))
            }
        }
    }

    private func color(_ mode: PixelMode) -> Color {
        switch mode {
        case .run: Color(hex: 0xF06A3A)
        case .wait: PalmhelmTheme.notchWarn
        case .done: Color(hex: PalmhelmSemanticColor.ok.dark)
        }
    }

    private func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private func assertPixels(_ actual: CGImage, _ expected: CGImage, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, message, file: file, line: line)
        guard actual.width == expected.width, actual.height == expected.height else { return }
        func bytes(_ image: CGImage) -> [UInt8] {
            let c = bitmap(width: image.width, height: image.height)
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let differences = zip(bytes(actual), bytes(expected)).filter { $0 != $1 }.count
        XCTAssertEqual(differences, 0, message, file: file, line: line)
    }
}
