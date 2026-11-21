import AppKit
// 用法：swift raster.swift <svg> <out.png> <px>：用 NSImage 的 SVG 解码按像素尺寸渲染（不依赖第三方工具）
let a = CommandLine.arguments
let svg = URL(fileURLWithPath: a[1]); let out = URL(fileURLWithPath: a[2]); let px = Int(a[3])!
guard let img = NSImage(contentsOf: svg) else { print("bad svg"); exit(1) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("\(out.lastPathComponent) \(px)")
