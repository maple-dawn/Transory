// 生成 App 图标（方案 ③「T 小精灵」）。
// 用法：swift scripts/make-icon.swift Resources/AppIcon.iconset && iconutil -c icns Resources/AppIcon.iconset
//
// 坐标与设计稿的 SVG 一致：1024×1024 画布，左上角为原点；图标主体是 824×824 的圆角方块。

import AppKit
import CoreGraphics

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ from: UInt32, _ to: UInt32) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(from), color(to)] as CFArray, locations: [0, 1])!
}

/// 四角星芒，(cx, cy) 为中心，r 为半径，k 控制收腰程度。
func sparkle(cx: CGFloat, cy: CGFloat, r: CGFloat, k: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx, y: cy - r))
    path.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + k * 0.8, y: cy - k), control2: CGPoint(x: cx + k, y: cy - k * 0.8))
    path.addCurve(to: CGPoint(x: cx, y: cy + r), control1: CGPoint(x: cx + k, y: cy + k * 0.8), control2: CGPoint(x: cx + k * 0.8, y: cy + k))
    path.addCurve(to: CGPoint(x: cx - r, y: cy), control1: CGPoint(x: cx - k * 0.8, y: cy + k), control2: CGPoint(x: cx - k, y: cy + k * 0.8))
    path.addCurve(to: CGPoint(x: cx, y: cy - r), control1: CGPoint(x: cx - k, y: cy - k * 0.8), control2: CGPoint(x: cx - k * 0.8, y: cy - k))
    path.closeSubpath()
    return path
}

func drawIcon(in context: CGContext) {
    // 翻转成左上角原点，和 SVG 坐标一致。
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)

    // 白色圆角底 + 柔和投影
    let base = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 12), blur: 32, color: color(0x2A2F6B, 0.16))
    context.addPath(base)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    // 背后的浅色圆
    context.saveGState()
    context.addEllipse(in: CGRect(x: 540, y: 530, width: 300, height: 300))
    context.clip()
    context.drawLinearGradient(gradient(0xE9ECFF, 0xF4EEFF), start: CGPoint(x: 540, y: 530), end: CGPoint(x: 840, y: 830), options: [])
    context.restoreGState()

    // 圆润的 T（横 + 竖），共用一个渐变
    let tShape = CGMutablePath()
    tShape.addRoundedRect(in: CGRect(x: 262, y: 270, width: 500, height: 160), cornerWidth: 80, cornerHeight: 80)
    tShape.addRoundedRect(in: CGRect(x: 432, y: 270, width: 160, height: 490), cornerWidth: 80, cornerHeight: 80)
    context.saveGState()
    context.addPath(tShape)
    context.clip(using: .winding)
    context.drawLinearGradient(gradient(0x3D5BFF, 0x8B4DFF), start: CGPoint(x: 270, y: 270), end: CGPoint(x: 640, y: 760), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    // 表情
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: 482 - 17, y: 548 - 17, width: 34, height: 34))
    context.fillEllipse(in: CGRect(x: 542 - 17, y: 548 - 17, width: 34, height: 34))
    let smile = CGMutablePath()
    smile.move(to: CGPoint(x: 476, y: 610))
    smile.addQuadCurve(to: CGPoint(x: 548, y: 610), control: CGPoint(x: 512, y: 646))
    context.addPath(smile)
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(22)
    context.setLineCap(.round)
    context.strokePath()

    // 星芒
    context.addPath(sparkle(cx: 800, cy: 256, r: 60, k: 10))
    context.setFillColor(color(0x4B5BFF))
    context.fillPath()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: context)
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// macOS iconset 需要的文件：每个尺寸的 1x 和 2x。
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: output.appending(path: "icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: output.appending(path: "icon_\(points)x\(points)@2x.png"))
}
print("已生成 \(output.path)")
