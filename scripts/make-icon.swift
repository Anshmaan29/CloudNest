import AppKit

// Build-time vector artwork; no image package or renderer is shipped in the app.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon artwork") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 202, yRadius: 202)
    NSGradient(starting: NSColor(srgbRed: 0.23, green: 0.29, blue: 0.67, alpha: 1),
               ending: NSColor(srgbRed: 0.10, green: 0.14, blue: 0.33, alpha: 1))!.draw(in: tile, angle: -90)
    let cloud = NSBezierPath()
    cloud.move(to: NSPoint(x: 304, y: 348))
    cloud.curve(to: NSPoint(x: 256, y: 591), controlPoint1: NSPoint(x: 147, y: 348), controlPoint2: NSPoint(x: 140, y: 550))
    cloud.curve(to: NSPoint(x: 570, y: 672), controlPoint1: NSPoint(x: 261, y: 772), controlPoint2: NSPoint(x: 475, y: 817))
    cloud.curve(to: NSPoint(x: 770, y: 501), controlPoint1: NSPoint(x: 711, y: 710), controlPoint2: NSPoint(x: 815, y: 615))
    cloud.curve(to: NSPoint(x: 715, y: 348), controlPoint1: NSPoint(x: 895, y: 451), controlPoint2: NSPoint(x: 834, y: 348))
    cloud.close()
    NSColor(srgbRed: 0.94, green: 0.96, blue: 1, alpha: 1).setFill(); cloud.fill()
    let nest = NSBezierPath()
    nest.move(to: NSPoint(x: 359, y: 488))
    nest.curve(to: NSPoint(x: 665, y: 488), controlPoint1: NSPoint(x: 415, y: 369), controlPoint2: NSPoint(x: 606, y: 369))
    nest.lineWidth = 26; nest.lineCapStyle = .round
    NSColor(srgbRed: 0.25, green: 0.34, blue: 0.69, alpha: 1).setStroke(); nest.stroke()
    NSColor(srgbRed: 0.38, green: 0.76, blue: 0.94, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 479, y: 498, width: 66, height: 66)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let file = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    try data.write(to: file, options: .atomic)
}
