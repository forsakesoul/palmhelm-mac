import SwiftUI
import AppKit
import PalmhelmKit

// 刘海角色（像素）：四个内置，造型与帧取自设计稿 mockup.html，Palmhelm 自己的形象。
// 每格 1.5pt、整格对齐、不抗锯齿；画布 20×14 格（约 30×21pt，右侧留「!」的位置；最后一行给完成点头用）。帧数据是常量位图，不用图片资源或动画依赖。

enum NotchCharacter: String, CaseIterable, Identifiable, Sendable {
    case horse, robot, cat, bars
    var id: String { rawValue }
    var label: String { switch self { case .horse: String(localized: "小马"); case .robot: String(localized: "小机器人"); case .cat: String(localized: "小猫"); case .bars: String(localized: "律动条") } }
    static let `default`: NotchCharacter = .horse
}

/// 角色偏好（设置 › 外观 › 刘海角色）：只影响本机刘海，存 AppDefaults，不同步、不进 Bridge。
@MainActor
@Observable
final class NotchCharacterStore {
    static let shared = NotchCharacterStore()
    static let key = "palmhelm.notchCharacter"
    private let defaults: UserDefaults
    var character: NotchCharacter { didSet { defaults.set(character.rawValue, forKey: Self.key) } }
    init(defaults: UserDefaults = AppDefaults.standard) {
        self.defaults = defaults
        character = defaults.string(forKey: Self.key).flatMap(NotchCharacter.init(rawValue:)) ?? .default
    }
}

/// 角色此刻的动作：工作 = 循环动画；待答 = 静止帧 +「!」闪烁；完成 = 绿色点一次头。
enum PixelMode: Equatable { case run, wait, done }

enum PixelBitmaps {
    static let cols = 20, rows = 14 // 多留一行：完成时点头（下沉一格）不出画布
    static let cell: CGFloat = 1.5
    typealias Grid = [[Bool]]

    private static func grid(_ rows: [String]) -> Grid { rows.map { Array($0.padding(toLength: 16, withPad: ".", startingAt: 0)).map { $0 == "#" } } }
    private static func put(_ g: Grid, _ pts: [(Int, Int)]) -> Grid { var g = g; for (x, y) in pts { g[y][x] = true }; return g }

    // 小马
    private static let hTop = ["..........#.#...", "..........####..", ".........##.###.", ".........#######", "........####..##", ".......####.....", ".##########.....", "..#########.....", "..#########....."]
    private static let hLegs: [String: [String]] = [
        "r1": ["..##......##....", ".#.........##...", "#...........#..."], "r2": ["..##.....##.....", "..#.#....#.#....", "..#..#...#..#..."],
        "r3": ["...##...##......", "....#..#.#......", "....#.#...#....."], "r4": ["..##.....##.....", ".#..#...#..#....", ".#...#..#...#..."],
        "st": ["..#.#....#.#....", "..#.#....#.#....", "..#.#....#.#...."],
    ]
    private static func horse(_ legs: String, _ tail: [(Int, Int)]) -> Grid { put(grid(hTop + hLegs[legs]!), tail) }
    private static let tailUp = [(0, 5)], tailDown = [(0, 7), (1, 8)]
    // 小机器人
    private static let r1 = [".....#......", ".....#......", "..########..", "..#..##..#..", "..########..", "...######...", ".##########.", "#..######..#", "...######...", "...#....#...", "...#....#..."]
    private static var r2: [String] { var r = r1; r[0] = "............"; r[6] = "..########.."; r[7] = ".#.######.#."; return r }
    // 小猫
    private static let cTop = ["............#.#.", "............###.", "............#.##", "............####", "............###.", ".############...", "..###########...", "..##########...."]
    private static let cLegs: [String: [String]] = ["w1": ["..#.#....#.#....", "..#..#...#..#..."], "w2": ["...##.....##....", "...##.....##...."]]
    private static func cat(_ legs: String, _ tail: [(Int, Int)]) -> Grid { put(grid(cTop + cLegs[legs]!), tail) }
    private static let catUp = [(0, 2), (0, 3), (1, 4)], catDown = [(0, 5), (0, 6), (1, 7)]

    struct FrameSet {
        let run: [Grid]      // 工作循环帧
        let bob: [Int]       // 每帧纵向偏移（格）
        let stand: Grid      // 待答 / 完成的静止帧
        let dust: Bool       // 小马蹄下的淡扬尘
    }

    static func set(_ c: NotchCharacter) -> FrameSet? {
        switch c {
        case .horse: FrameSet(run: [horse("r1", tailUp), horse("r2", tailDown), horse("r3", tailUp), horse("r4", tailDown)], bob: [0, -1, 0, -1], stand: horse("st", tailDown), dust: true)
        case .robot: FrameSet(run: [grid(r1), grid(r2), grid(r1), put(grid(r2), [(3, 3), (8, 3)])], bob: [0, 0, 0, 0], stand: grid(r1), dust: false) // 敲键盘、天线闪、偶尔眨眼
        case .cat: FrameSet(run: [cat("w1", catUp), cat("w2", catDown), cat("w1", catDown), cat("w2", catUp)], bob: [0, -1, 0, -1], stand: cat("w2", catUp), dust: false)
        case .bars: nil
        }
    }

    /// 工作帧序号：约 110ms 一帧、4 帧循环。
    static let frameInterval: TimeInterval = 0.11
    static func tick(at date: Date) -> Int { Int((date.timeIntervalSinceReferenceDate / frameInterval).rounded(.down)) }

    /// 完成点头：从 toast 创建时刻起约 2 帧（0.22s）下沉一格，之后停在静帧；只点一次，与全局帧计数无关。
    static let nodFrames = 2
    static func nodding(elapsed: TimeInterval) -> Bool { elapsed >= 0 && elapsed < Double(nodFrames) * frameInterval }

    /// 律动条某根的高度（格）：五根正弦起伏；待答固定 2；完成整体下沉一格（点头）。
    static func barHeight(index b: Int, mode: PixelMode, tick: Int, still: Bool, nod: Bool = false) -> Int {
        switch mode {
        case .run: still ? 6 : 3 + Int((7 * (0.5 + 0.5 * sin(Double(tick) * 0.9 + Double(b) * 1.1))).rounded())
        case .wait: 2
        case .done: 6 - (nod ? 1 : 0)
        }
    }

    /// 要画的格子（col,row,alpha）：纯函数，便于测试。still = 减少动态效果 / 不可见时的静止帧。
    static func cells(_ c: NotchCharacter, mode: PixelMode, tick: Int, still: Bool, nod: Bool = false) -> [(x: Int, y: Int, alpha: Double)] {
        var out: [(Int, Int, Double)] = []
        if let s = set(c) {
            var g = s.stand
            var dy = 1
            if mode == .run { let f = still ? 0 : ((tick % 4) + 4) % 4; g = s.run[f]; dy = 1 + s.bob[f] }
            if mode == .done { dy = 1 + (nod ? 1 : 0) } // 点一次头（nod 由 toast 创建时刻起算，见 nodding）
            for (y, row) in g.enumerated() { for (x, on) in row.enumerated() where on { out.append((x, y + dy, 1)) } }
            if mode == .run, s.dust, !still { out.append((tick % 2, 12, 0.35)); out.append((2 - (tick % 2), 12, 0.35)) }
        } else {
            for b in 0..<5 { for y in 0..<barHeight(index: b, mode: mode, tick: tick, still: still, nod: nod) { out.append((1 + b * 3, 11 - y, 1)); out.append((2 + b * 3, 11 - y, 1)) } }
        }
        if mode == .wait, still || tick % 6 < 4 { for y in [0, 1, 2, 3, 5] { out.append((18, y + 1, 1)) } } // 「!」约 0.66s 一闪
        return out.map { (x: $0.0, y: $0.1, alpha: $0.2) }
    }
}

/// 周期更新只改小人图层的 contents，不使 SwiftUI 时间线反复求值。
struct PixelCharacterView: View {
    let character: NotchCharacter
    let mode: PixelMode
    var animating = true
    var scale: CGFloat = 1
    /// 完成点头的起点（toast 创建时刻）；仅 .done 用。
    var since: Date?

    var body: some View {
        PixelCharacterLayer(state: PixelCharacterState(character: character, mode: mode, animating: animating, since: since), color: NSColor(color).cgColor)
            .frame(width: CGFloat(PixelBitmaps.cols) * PixelBitmaps.cell * scale, height: CGFloat(PixelBitmaps.rows) * PixelBitmaps.cell * scale)
            .accessibilityHidden(true) // 含义由旁边的文字 / 数字与整体的 VoiceOver 摘要表达，颜色不是唯一信号
    }

    private var color: Color {
        switch mode {
        case .run: Color(hex: 0xF06A3A)                       // 工作：品牌橙
        case .wait: PalmhelmTheme.notchWarn                       // 待答：warn
        case .done: Color(hex: PalmhelmSemanticColor.ok.dark)     // 完成：ok
        }
    }

}

struct PixelCharacterState: Equatable {
    let character: NotchCharacter
    let mode: PixelMode
    let animating: Bool
    let since: Date?
}

private struct PixelCharacterLayer: NSViewRepresentable {
    let state: PixelCharacterState
    let color: CGColor
    func makeNSView(context: Context) -> PixelCharacterLayerView { PixelCharacterLayerView() }
    func updateNSView(_ view: PixelCharacterLayerView, context: Context) { view.configure(state: state, color: color) }
    static func dismantleNSView(_ view: PixelCharacterLayerView, coordinator: ()) { view.stop() }
}

/// 有限帧按当前尺寸缓存；bars 的正弦没有有限周期，每拍独立绘制，不能误改成四帧循环。
@MainActor
final class PixelCharacterLayerView: NSView {
    private var state: PixelCharacterState?
    private var color = NSColor.clear.cgColor
    private var rasterSize = CGSize.zero
    private var rasterScale: CGFloat = 0
    private var frames: [Int: CGImage] = [:]
    private var displayed: Int?
    private(set) var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.contentsGravity = .topLeft
        layer?.masksToBounds = true
        layer?.actions = ["contents": NSNull()]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // 装饰图层不抢外层刘海按钮的点击。

    func configure(state: PixelCharacterState, color: CGColor) {
        guard self.state != state || self.color != color else { return }
        self.state = state; self.color = color
        frames = [:]; displayed = nil
        refreshRaster(force: true)
        start()
    }

    override func layout() { super.layout(); refreshRaster() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refreshRaster() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshRaster(force: true); start() }

    private func refreshRaster(force: Bool = false) {
        let scale = window?.backingScaleFactor ?? 1
        let changed = rasterSize != bounds.size || rasterScale != scale
        if changed {
            rasterSize = bounds.size; rasterScale = scale
            layer?.contentsScale = scale
            frames = [:]; displayed = nil
        }
        if changed || force { advance(at: Date()) }
    }

    func advance(at date: Date) {
        guard let state, rasterSize.width > 0, rasterSize.height > 0 else { return }
        let still = !state.animating
        let tick = still ? 0 : PixelBitmaps.tick(at: date)
        let nod = !still && (state.since.map { PixelBitmaps.nodding(elapsed: date.timeIntervalSince($0)) } ?? false)
        let key: Int
        switch state.mode {
        case .run: key = still ? 0 : tick % 4
        case .wait: key = still || tick % 6 < 4 ? 0 : 1
        case .done: key = nod ? 1 : 0
        }
        let uncached = state.character == .bars && state.mode == .run && !still
        guard uncached || displayed != key else { return }
        guard let image = frames[key] ?? PixelCharacterRaster.image(state.character, mode: state.mode, tick: tick, still: still, nod: nod, size: rasterSize, scale: rasterScale, color: color) else { return }
        if !uncached { frames[key] = image }
        layer?.contents = image
        displayed = key
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func start() {
        stop()
        guard window != nil, let state, state.animating else { return }
        let interval: TimeInterval
        let repeating = state.mode != .done
        if repeating { interval = PixelBitmaps.frameInterval }
        else {
            guard let since = state.since else { return }
            let now = Date(), end = since.addingTimeInterval(Double(PixelBitmaps.nodFrames) * PixelBitmaps.frameInterval)
            guard now < end else { return }
            interval = max(0.001, (now < since ? since : end).timeIntervalSince(now))
        }
        let next = Timer(timeInterval: interval, repeats: repeating) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advance(at: Date())
                if !repeating { self?.start() }
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
}

enum PixelCharacterRaster {
    static func image(_ character: NotchCharacter, mode: PixelMode, tick: Int, still: Bool, nod: Bool, size: CGSize, scale: CGFloat, color: CGColor) -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0,
              let ctx = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: scale, y: -scale) // Canvas 的原点在左上，位图坐标系需翻转。
        ctx.setShouldAntialias(false)
        ctx.setFillColor(color)
        let u = CGFloat(ctx.width) / scale / CGFloat(PixelBitmaps.cols) // 与 Canvas 一样，先按 backing pixels 对齐画布尺寸。
        for c in PixelBitmaps.cells(character, mode: mode, tick: tick, still: still, nod: nod) {
            let x0 = (CGFloat(c.x) * u).rounded(), y0 = (CGFloat(c.y) * u).rounded()
            ctx.setAlpha(c.alpha)
            ctx.fill(CGRect(x: x0, y: y0, width: (CGFloat(c.x + 1) * u).rounded() - x0, height: (CGFloat(c.y + 1) * u).rounded() - y0))
        }
        return ctx.makeImage()
    }
}
