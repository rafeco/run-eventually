import AppKit

// Vector artwork rendered at the full macOS icon resolution.
// Run with: swift scripts/generate-app-icon.swift OUTPUT.png
guard CommandLine.arguments.count == 2 else { fatalError("Expected output PNG path") }
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}
let navy = color(13, 30, 48)
let mint = color(110, 235, 190)
let white = color(240, 247, 255)
let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
navy.setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(36, 74, 100), ending: navy)!.draw(in: tile, angle: -90)

// A clock reads clearly at small sizes; the completion badge signals catch-up.
context.setLineCap(.round)
context.setLineJoin(.round)
context.setStrokeColor(white.cgColor)
context.setLineWidth(38)
context.strokeEllipse(in: CGRect(x: 262, y: 294, width: 500, height: 500))
context.move(to: CGPoint(x: 512, y: 699))
context.addLine(to: CGPoint(x: 512, y: 544))
context.addLine(to: CGPoint(x: 635, y: 462))
context.strokePath()
context.setFillColor(white.cgColor)
context.fillEllipse(in: CGRect(x: 487, y: 519, width: 50, height: 50))

// A dark rim keeps the badge distinct from the clock outline.
context.setFillColor(navy.cgColor)
context.fillEllipse(in: CGRect(x: 570, y: 191, width: 284, height: 284))
context.setFillColor(mint.cgColor)
context.fillEllipse(in: CGRect(x: 589, y: 210, width: 246, height: 246))
context.setStrokeColor(navy.cgColor)
context.setLineWidth(29)
context.move(to: CGPoint(x: 652, y: 335))
context.addLine(to: CGPoint(x: 695, y: 294))
context.addLine(to: CGPoint(x: 773, y: 373))
context.strokePath()

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: CommandLine.arguments[1])
)
