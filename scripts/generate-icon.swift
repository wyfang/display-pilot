import AppKit
import CoreGraphics

// 1024 点矢量画布；各档尺寸均直接绘制，不放大小尺寸位图。
private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: alpha)
}

private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func gradient(_ context: CGContext, path: CGPath, colors: [CGColor],
                      start: CGPoint, end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

private func monitor(_ context: CGContext, frame: CGRect, front: Bool) {
    let center = frame.midX
    let footY = frame.minY - 74
    let stem = roundedRect(CGRect(x: center - 22, y: footY + 12, width: 44, height: 75), radius: 12)
    let foot = roundedRect(CGRect(x: center - 83, y: footY, width: 166, height: 24), radius: 12)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: color(0x0B1048, alpha: 0.35))
    context.setFillColor(color(front ? 0xE9F8FF : 0xB7CFFF))
    context.addPath(stem)
    context.addPath(foot)
    context.fillPath()
    context.restoreGState()

    let outer = roundedRect(frame, radius: 34)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -13), blur: 32,
                      color: color(0x070B35, alpha: front ? 0.48 : 0.27))
    context.setFillColor(color(front ? 0xF5FCFF : 0xD1DFFF))
    context.addPath(outer)
    context.fillPath()
    context.restoreGState()

    let screenRect = CGRect(x: frame.minX + 17, y: frame.minY + 32,
                            width: frame.width - 34, height: frame.height - 49)
    let screen = roundedRect(screenRect, radius: 19)
    gradient(context, path: screen,
             colors: front ? [color(0x284DDB), color(0x23C7D8), color(0x9AF0E1)]
                           : [color(0x413AB4), color(0x7476F6), color(0xB8B4FF)],
             start: CGPoint(x: screenRect.minX, y: screenRect.minY),
             end: CGPoint(x: screenRect.maxX, y: screenRect.maxY))

    // 轻量的弧形光带，让两个屏幕在小尺寸下仍呈现同一套桌面。
    context.saveGState()
    context.addPath(screen)
    context.clip()
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: screenRect.minX - 20, y: screenRect.minY + 28))
    wave.addCurve(to: CGPoint(x: screenRect.maxX + 30, y: screenRect.maxY - 36),
                  control1: CGPoint(x: screenRect.midX - 35, y: screenRect.minY - 18),
                  control2: CGPoint(x: screenRect.midX - 10, y: screenRect.maxY + 30))
    context.setStrokeColor(color(0xFFFFFF, alpha: front ? 0.24 : 0.17))
    context.setLineWidth(29)
    context.addPath(wave)
    context.strokePath()
    context.restoreGState()

    context.setFillColor(color(front ? 0x5D94AD : 0x8C93CA, alpha: 0.7))
    context.fillEllipse(in: CGRect(x: center - 3, y: frame.minY + 12, width: 6, height: 6))
}

private func render(size: Int, to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tile = roundedRect(CGRect(x: 88, y: 88, width: 848, height: 848), radius: 190)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 22, color: color(0x101432, alpha: 0.24))
    context.setFillColor(color(0x3439A4))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()
    gradient(context, path: tile,
             colors: [color(0x242674), color(0x454FDB), color(0x5489ED)],
             start: CGPoint(x: 240, y: 110), end: CGPoint(x: 810, y: 960))

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x66E8EC, alpha: 0.5), color(0x66E8EC, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 897, y: 881), startRadius: 0,
                                endCenter: CGPoint(x: 897, y: 881), endRadius: 680,
                                options: .drawsAfterEndLocation)
    context.restoreGState()

    // 1 点的内侧高光保持边缘干净，不依赖系统自动圆角。
    context.addPath(roundedRect(CGRect(x: 89, y: 89, width: 846, height: 846), radius: 189))
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.16))
    context.setLineWidth(2)
    context.strokePath()

    monitor(context, frame: CGRect(x: 174, y: 441, width: 438, height: 299), front: false)
    monitor(context, frame: CGRect(x: 410, y: 289, width: 438, height: 299), front: true)

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DisplayPilotIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 图标"])
    }
    try png.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    fputs("用法: generate-icon.swift <输出.iconset目录>\n", stderr)
    exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base, to: destination.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2, to: destination.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
